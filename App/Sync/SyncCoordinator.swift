import AuthenticationServices
import CryptoKit
import EasyNotesCore
import Foundation
import Observation
import Supabase
import SupabaseSync
#if DEBUG
import EasyNotesTestSupport
#endif
#if os(iOS)
import UIKit
#endif

/// App-level sync: sign-in state, when to sync, the Realtime connection. Sync itself is done by Core's SyncEngine.
/// - Local changes: batch upload after 3 s idle; at most 30 s delay during continuous editing
/// - Return to foreground: catch up and connect Realtime; go to background: upload pending changes and drop Realtime (no background connection)
@MainActor @Observable
final class SyncCoordinator {
    enum Account: Equatable {
        case unknown
        case signedOut
        case signedIn(email: String?)
    }

    private(set) var account: Account = .unknown
    private(set) var status = SyncEngine.Status()
    /// Conflict copies not yet seen (sync creates new ones each round until the user has looked)
    private(set) var conflicts: [String] = []
    private(set) var authError: String?

    @ObservationIgnored private let store: VaultStore
    @ObservationIgnored private let mode: TestHooks.Sync
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var deviceID: String?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var pendingSince: Date?
    @ObservationIgnored private var channel: RealtimeChannelV2?
    /// E2E folder backend: folder watching replaces Realtime
    @ObservationIgnored private var folderWatch: AnyObject?
    @ObservationIgnored private var isActive = true
    /// Remembering only the last one would not match the token Apple actually sends (nonce mismatch on first sign-in), so all are kept and looked up by token on completion.
    @ObservationIgnored private var nonces: [String: String] = [:]

    static let idleDelay: Duration = .seconds(3)
    static let maxDelay: TimeInterval = 30

    init(store: VaultStore, mode: TestHooks.Sync = TestHooks.sync) {
        self.store = store
        self.mode = mode
        store.onLocalChange = { [weak self] in self?.schedule(after: Self.idleDelay) }
        store.onMove = { [weak self] from, to in
            guard let engine = self?.engine else { return }
            Task { try? await engine.moved(from: from, to: to) }
        }
        store.onPurge = { [weak self] path in
            _ = try await self?.engine?.requestPurge(path)
        }
        switch mode {
        case .supabase:
            Task { await observeAuth() }
        case .off:
            account = .signedOut
        case .folder(let url):
            #if DEBUG
            // E2E: a fixed account without Sign in with Apple; the remote is a folder the test process can also read and write
            Task {
                do {
                    let backend = try FolderSyncBackend(root: url)
                    await start(userID: "e2e", email: "e2e@easynotes.local", backend: backend)
                } catch {
                    status.lastError = error.localizedDescription
                }
            }
            #else
            _ = url
            #endif
        }
    }

    // MARK: Sign-in

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
        let hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        nonces[hashed] = raw
        request.requestedScopes = [.email]
        request.nonce = hashed
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        authError = nil
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) })
            else {
                authError = L("Apple 沒有回傳登入憑證")
                return
            }
            guard let nonce = Self.nonceClaim(token).flatMap({ nonces[$0] }) else {
                authError = L("登入憑證與這次登入要求不符，請再試一次")
                return
            }
            nonces = [:]
            do {
                try await supabase.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: token, nonce: nonce))
            } catch {
                authError = error.localizedDescription
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled { authError = error.localizedDescription }
        }
    }

    /// The nonce claim in the identity token (JWT) payload, i.e. the SHA256(nonce) Apple received
    private static func nonceClaim(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload["nonce"] as? String
    }

    func signOut() async {
        await store.flushEditors()
        if let engine { await engine.sync() } // Send pending changes before signing out
        guard mode == .supabase else { return }
        try? await supabase.auth.signOut()
    }

    private func start(_ user: User) async {
        await start(userID: user.id.uuidString, email: user.email, backend: SupabaseBackend(client: supabase))
    }

    private func start(userID id: String, email: String?, backend: any SyncBackend) async {
        account = .signedIn(email: email)
        guard userID != id else { return }
        await stop(keepAccount: true)
        do {
            let engine = try SyncEngine(
                fs: store.fs, backend: backend,
                userID: id, deviceName: Self.deviceName,
                syncedMetaFolders: store.plugins.syncedMetaFolders,
                hooks: .init(
                    willChange: { [weak store] path in await store?.prepareForSync(path) },
                    didChange: { [weak store] path, oldPath, data in
                        await store?.applySyncChange(path: path, oldPath: oldPath, data: data)
                    },
                    statusChanged: { [weak self] status in await self?.update(status) },
                    didPurge: { [weak store] in await store?.prunePreviews() }))
            self.engine = engine
            userID = id
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

    // MARK: Scheduling

    /// Coalesces consecutive changes in a short time; during continuous editing delays at most `maxDelay` seconds
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
            // Not cancelled along with the schedule: once sync starts it runs to completion
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
                schedule(after: .zero) // Send pending changes before going to the background
            }
        }
    }

    // MARK: Recently deleted

    func recentlyDeleted() async throws -> [RemoteFile] {
        guard let engine else { return [] }
        return try await engine.recentlyDeleted()
    }

    /// Opens the file after restoring
    func restore(_ file: RemoteFile) async throws {
        guard let engine else { return }
        let path = try await engine.restore(file)
        store.selection = path
    }

    /// Permanently deletes one entry of "Recently Deleted" (with its companions) on every device
    func purge(_ file: RemoteFile) async throws {
        guard let engine else { return }
        try await engine.purge(file)
    }

    /// "Empty": permanently deletes everything in "Recently Deleted"
    func emptyRecentlyDeleted() async throws {
        guard let engine else { return }
        try await engine.purgeAllDeleted()
    }

    func dismissConflicts() {
        conflicts = []
    }

    private func update(_ status: SyncEngine.Status) {
        self.status = status
        for path in status.conflicts where !conflicts.contains(path) { conflicts.append(path) }
    }

    // MARK: Realtime (foreground only)

    private func connectRealtime() async {
        guard engine != nil, isActive else { return }
        if case .folder(let url) = mode {
            #if DEBUG
            guard folderWatch == nil else { return }
            folderWatch = FolderSyncBackend.watch(url) { [weak self] in
                Task { @MainActor in self?.schedule(after: .milliseconds(300)) }
            }
            #endif
            return
        }
        guard channel == nil, mode == .supabase else { return }
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
        folderWatch = nil
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
        guard device == nil || device != deviceID else { return } // Our own commit
        schedule(after: .milliseconds(300))
    }

    /// Used in conflict-copy file names (sync and external edits found at save time)
    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }
}
