import AuthenticationServices
import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// Display of sync status: synced / syncing / pending upload / conflict / error / signed out
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

    /// "2 minutes ago"; nil when signed out or never synced
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

/// The sync status row at the bottom of the sidebar; click to sign in, sync now, or view conflict copies
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
        .accessibilityIdentifier(A11yID.Sidebar.sync)
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

/// Files deleted within 30 days (deleted on any device show here), restorable with the same file id, or deletable for good
struct RecentlyDeletedView: View {
    private enum Purge: Identifiable {
        case one(RemoteFile)
        case all
        var id: String {
            switch self {
            case .one(let file): file.id.uuidString
            case .all: "all"
            }
        }
    }

    @Environment(SyncCoordinator.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RemoteFile]?
    /// The file being restored or deleted for good
    @State private var restoring: UUID?
    @State private var emptying = false
    @State private var confirming: Purge?
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
                ToolbarItem(placement: .destructiveAction) {
                    Button(L("清空最近刪除"), role: .destructive) { confirming = .all }
                        .disabled((files?.isEmpty ?? true) || busy)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding()
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil },
                                                                set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { target in
            Button(L("永久刪除"), role: .destructive) {
                switch target {
                case .one(let file): Task { await purge(file) }
                case .all: Task { await emptyAll() }
                }
            }
            Button(L("取消"), role: .cancel) {}
        } message: { target in
            switch target {
            case .one: Text(L("永久刪除後無法還原，其他裝置上的也會一併刪除。"))
            case .all: Text(L("永久刪除後無法還原，所有裝置上的這些檔案都會一併刪除。"))
            }
        }
    }

    private var busy: Bool { restoring != nil || emptying }

    private var confirmTitle: String {
        switch confirming {
        case .one(let file): L("永久刪除「\((file.path as NSString).lastPathComponent)」？")
        case .all, nil: L("永久刪除「最近刪除」裡的所有檔案？")
        }
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
                // Borderless: inside a List row, plain buttons make the whole row tappable and both would fire
                Button(L("還原")) { Task { await restore(file) } }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                Button(L("永久刪除"), role: .destructive) { confirming = .one(file) }
                    .buttonStyle(.borderless)
                    .disabled(busy)
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
            await load() // For example another device deleted it for good meanwhile
        }
        restoring = nil
    }

    private func purge(_ file: RemoteFile) async {
        restoring = file.id
        error = nil
        do {
            try await sync.purge(file)
            files?.removeAll { $0.id == file.id }
        } catch {
            self.error = error.localizedDescription
        }
        restoring = nil
    }

    private func emptyAll() async {
        emptying = true
        error = nil
        do {
            try await sync.emptyRecentlyDeleted()
            files = []
        } catch {
            self.error = error.localizedDescription
            await load() // Part of it may have gone
        }
        emptying = false
    }
}
