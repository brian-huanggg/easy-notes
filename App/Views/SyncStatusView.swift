import AuthenticationServices
import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 同步狀態的顯示：已同步 / 同步中 / 待上傳 / 衝突 / 錯誤 / 未登入
extension SyncCoordinator {
    var statusSymbol: String {
        guard case .signedIn = account else { return "icloud.slash" }
        if !conflicts.isEmpty { return "exclamationmark.triangle" }
        if status.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        if status.lastError != nil { return "exclamationmark.icloud" }
        if status.pending > 0 { return "icloud.and.arrow.up" }
        return "checkmark.icloud"
    }

    var statusTitle: String {
        guard case .signedIn = account else { return L("未登入，不會同步") }
        if !conflicts.isEmpty { return L("\(conflicts.count) 個衝突副本") }
        if status.isSyncing { return L("同步中") }
        if status.lastError != nil { return L("同步失敗") }
        if status.pending > 0 { return L("\(status.pending) 個檔案待上傳") }
        return L("已同步")
    }

    /// 「2 分鐘前」；未登入或從未同步時為 nil
    var statusDetail: String? {
        guard case .signedIn = account, let last = status.lastSynced else { return nil }
        return last.formatted(.relative(presentation: .named))
    }

    var statusTint: ColorToken {
        guard case .signedIn = account else { return Palette.textTertiary }
        if !conflicts.isEmpty || status.lastError != nil { return Palette.cardLearn }
        if status.isSyncing || status.pending > 0 { return Palette.accent }
        return Palette.cardDue
    }

    var accountEmail: String? {
        if case .signedIn(let email) = account { email } else { nil }
    }
}

/// 側邊欄底部的同步狀態列，點開可登入、立即同步、查看衝突副本
struct SyncStatusRow: View {
    @Environment(SyncCoordinator.self) private var sync
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            StatusRow(sync.statusTitle, detail: sync.statusDetail, symbol: sync.statusSymbol, tint: sync.statusTint)
        }
        .buttonStyle(.plain)
        .help(sync.statusTitle)
        .popover(isPresented: $showPanel) {
            SyncPanel(close: { showPanel = false })
                .frame(minWidth: 280)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct SyncPanel: View {
    @Environment(SyncCoordinator.self) private var sync
    @Environment(VaultStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch sync.account {
            case .unknown:
                ProgressView()
            case .signedOut:
                Text(L("登入後，筆記會在 Mac、iPad、iPhone 間同步。")).font(.callout)
                SignInWithAppleButton(.signIn) { request in
                    sync.prepare(request)
                } onCompletion: { result in
                    Task { await sync.complete(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 40)
            case .signedIn(let email):
                Label(email ?? L("已登入"), systemImage: "person.crop.circle").font(.callout)
                status
                if !sync.conflicts.isEmpty { conflicts }
                HStack {
                    Button(L("立即同步"), systemImage: "arrow.clockwise") { sync.syncNow() }
                        .disabled(sync.status.isSyncing)
                    Spacer()
                    Button(L("登出"), role: .destructive) { Task { await sync.signOut() } }
                }
            }
            if let error = sync.authError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if sync.status.isSyncing {
                Label(L("同步中…"), systemImage: "arrow.triangle.2.circlepath")
            } else if sync.status.pending > 0 {
                Label(L("\(sync.status.pending) 個檔案待上傳"), systemImage: "icloud.and.arrow.up")
            } else if let last = sync.status.lastSynced {
                Label(L("已同步 · \(last.formatted(.relative(presentation: .named)))"), systemImage: "checkmark.icloud")
            }
            if let error = sync.status.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
        }
        .font(.callout)
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("兩台裝置改了同一段，另一份內容存成衝突副本：")).font(.caption).foregroundStyle(.secondary)
            ForEach(sync.conflicts, id: \.self) { path in
                Button((path as NSString).lastPathComponent) {
                    store.selection = path
                    close()
                }
                .buttonStyle(.borderless)
            }
            Button(L("知道了")) { sync.dismissConflicts() }.font(.caption)
        }
    }
}

/// 30 天內刪除的檔案（任何裝置刪的都在這裡），可用同一個 file id 還原
struct RecentlyDeletedView: View {
    @Environment(SyncCoordinator.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RemoteFile]?
    @State private var restoring: UUID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let files, files.isEmpty {
                    ContentUnavailableView(L("沒有最近刪除的檔案"), systemImage: "trash",
                                           description: Text(L("刪除的檔案會保留 \(SyncEngine.retentionDays) 天。")))
                } else if let files {
                    List(files, id: \.id) { file in
                        row(file)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(L("最近刪除"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("完成")) { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await load() }
    }

    private func row(_ file: RemoteFile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text((file.path as NSString).lastPathComponent)
                Text(detail(file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if restoring == file.id {
                ProgressView().controlSize(.small)
            } else {
                Button(L("還原")) { Task { await restore(file) } }
                    .disabled(restoring != nil)
            }
        }
    }

    private func detail(_ file: RemoteFile) -> String {
        let folder = (file.path as NSString).deletingLastPathComponent
        let left = SyncEngine.retentionDays - Int(Date().timeIntervalSince(file.updatedAt) / 86_400)
        let when = file.updatedAt.formatted(.relative(presentation: .named))
        return L("\(folder.isEmpty ? "Vault" : folder) · \(when)刪除 · 剩 \(max(left, 0)) 天")
    }

    private func load() async {
        do { files = try await sync.recentlyDeleted() } catch {
            self.error = error.localizedDescription
            files = []
        }
    }

    private func restore(_ file: RemoteFile) async {
        restoring = file.id
        error = nil
        do {
            try await sync.restore(file)
            files?.removeAll { $0.id == file.id }
        } catch {
            self.error = error.localizedDescription
        }
        restoring = nil
    }
}
