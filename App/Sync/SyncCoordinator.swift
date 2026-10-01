import AuthenticationServices
import CryptoKit
import EasyNotesCore
import Foundation
import Observation
import Supabase
import SupabaseSync
#if os(iOS)
import UIKit
#endif

/// App 層的同步：登入狀態、何時同步、Realtime 連線。同步本身由 Core 的 SyncEngine 負責。
/// - 本地變更：閒置 3 秒後批次上傳；持續編輯時最多延後 30 秒
/// - 回到前景：補拉並連上 Realtime；進背景：上傳待傳的變更並斷開 Realtime（不保持背景連線）
@MainActor @Observable
final class SyncCoordinator {
    enum Account: Equatable {
        case unknown
        case signedOut
        case signedIn(email: String?)
    }

    private(set) var account: Account = .unknown
    private(set) var status = SyncEngine.Status()
    /// 尚未查看的衝突副本（同步每一輪會產生新的，直到使用者看過）
    private(set) var conflicts: [String] = []
    private(set) var authError: String?

    @ObservationIgnored private let store: VaultStore
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var deviceID: String?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var pendingSince: Date?
    @ObservationIgnored private var channel: RealtimeChannelV2?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var nonce: String?

    static let idleDelay: Duration = .seconds(3)
    static let maxDelay: TimeInterval = 30

    init(store: VaultStore) {
        self.store = store
        store.onLocalChange = { [weak self] in self?.schedule(after: Self.idleDelay) }
        store.onMove = { [weak self] from, to in
            guard let engine = self?.engine else { return }
            Task { try? await engine.moved(from: from, to: to) }
        }
        Task { await observeAuth() }
    }

    // MARK: 登入

    private func observeAuth() async {
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .userUpdated, .tokenRefreshed:
                if let session { await start(session.user) } else { await stop() }
            case .signedOut, .userDeleted:
                await stop()
            default:
                break
            }
        }
    }

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        nonce = raw
        request.requestedScopes = [.email]
        request.nonce = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        authError = nil
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
                  let nonce
            else {
                authError = "Apple 沒有回傳登入憑證"
                return
            }
            do {
                try await supabase.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: token, nonce: nonce))
            } catch {
                authError = error.localizedDescription
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { authError = error.localizedDescription }
        }
    }

    func signOut() async {
        await store.flushEditors()
        if let engine { await engine.sync() } // 登出前把待傳的變更送出
        try? await supabase.auth.signOut()
    }

    private func start(_ user: User) async {
        account = .signedIn(email: user.email)
        guard userID != user.id else { return }
        await stop(keepAccount: true)
        do {
            let engine = try SyncEngine(
                fs: store.fs, backend: SupabaseBackend(client: supabase),
                userID: user.id.uuidString, deviceName: Self.deviceName,
                hooks: .init(
                    willChange: { [weak store] path in await store?.prepareForSync(path) },
                    didChange: { [weak store] path, oldPath, data in
                        await store?.applySyncChange(path: path, oldPath: oldPath, data: data)
                    },
                    statusChanged: { [weak self] status in await self?.update(status) }))
            self.engine = engine
            userID = user.id
            deviceID = await engine.deviceID
            await connectRealtime()
            schedule(after: .zero)
        } catch {
            status.lastError = error.localizedDescription
        }
    }

    private func stop(keepAccount: Bool = false) async {
        scheduled?.cancel()
        await disconnectRealtime()
        engine = nil
        userID = nil
        status = .init()
        conflicts = []
        if !keepAccount { account = .signedOut }
    }

    // MARK: 排程

    /// 合併短時間內的連續變更；持續編輯時最多延後 `maxDelay` 秒
    func schedule(after delay: Duration) {
        guard let engine else { return }
        let now = Date()
        if pendingSince == nil { pendingSince = now }
        let overdue = now.timeIntervalSince(pendingSince!) >= Self.maxDelay
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            if !overdue { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.pendingSince = nil
            // 不跟著排程一起被取消：同步一旦開始就跑完
            await Task { await engine.sync() }.value
        }
    }

    func syncNow() {
        Task {
            await store.flushEditors()
            schedule(after: .zero)
        }
    }

    func scenePhaseChanged(active: Bool) {
        isActive = active
        Task {
            if active {
                await connectRealtime()
                schedule(after: .zero)
            } else {
                await disconnectRealtime()
                schedule(after: .zero) // 進背景前送出待傳的變更
            }
        }
    }

    // MARK: 最近刪除

    func recentlyDeleted() async throws -> [RemoteFile] {
        guard let engine else { return [] }
        return try await engine.recentlyDeleted()
    }

    /// 還原後開啟該檔案
    func restore(_ file: RemoteFile) async throws {
        guard let engine else { return }
        let path = try await engine.restore(file)
        store.selection = path
    }

    func dismissConflicts() {
        conflicts = []
    }

    private func update(_ status: SyncEngine.Status) {
        self.status = status
        for path in status.conflicts where !conflicts.contains(path) { conflicts.append(path) }
    }

    // MARK: Realtime（只在前景）

    private func connectRealtime() async {
        guard channel == nil, engine != nil, isActive else { return }
        let channel = supabase.channel("files")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "files")
        self.channel = channel
        do {
            try await channel.subscribeWithError()
        } catch {
            self.channel = nil
            return
        }
        Task { [weak self] in
            for await action in changes { self?.remoteChanged(action) }
        }
    }

    private func disconnectRealtime() async {
        guard let channel else { return }
        self.channel = nil
        await supabase.removeChannel(channel)
    }

    private func remoteChanged(_ action: AnyAction) {
        let device: String? = switch action {
        case .insert(let a): a.record["device_id"]?.stringValue
        case .update(let a): a.record["device_id"]?.stringValue
        case .delete: nil
        }
        guard device == nil || device != deviceID else { return } // 自己的提交
        schedule(after: .milliseconds(300))
    }

    private static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }
}
