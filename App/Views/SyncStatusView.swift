import AuthenticationServices
import EasyNotesCore
import SwiftUI

/// 側邊欄工具列的同步狀態：已同步 / 同步中 / 待上傳 / 衝突 / 錯誤，點開可登入、立即同步、查看衝突副本
struct SyncStatusButton: View {
    @Environment(SyncCoordinator.self) private var sync
    @State private var showPanel = false
    @State private var showDeleted = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            Label(title, systemImage: symbol)
        }
        .help(title)
        .popover(isPresented: $showPanel) {
            SyncPanel(close: { showPanel = false }, showDeleted: {
                showPanel = false
                showDeleted = true
            })
            .frame(minWidth: 280)
            .padding()
            .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showDeleted) {
            RecentlyDeletedView()
        }
    }

    private var symbol: String {
        guard case .signedIn = sync.account else { return "icloud.slash" }
        if !sync.conflicts.isEmpty { return "exclamationmark.triangle" }
        if sync.status.isSyncing { return "arrow.triangle.2.circlepath.icloud" }
        if sync.status.lastError != nil { return "exclamationmark.icloud" }
        if sync.status.pending > 0 { return "icloud.and.arrow.up" }
        return "checkmark.icloud"
    }

    private var title: String {
        guard case .signedIn = sync.account else { return "未登入，不會同步" }
        if !sync.conflicts.isEmpty { return "\(sync.conflicts.count) 個衝突副本" }
        if sync.status.isSyncing { return "同步中" }
        if sync.status.lastError != nil { return "同步失敗" }
        if sync.status.pending > 0 { return "\(sync.status.pending) 個檔案待上傳" }
        return "已同步"
    }
}

private struct SyncPanel: View {
    @Environment(SyncCoordinator.self) private var sync
    @Environment(VaultStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    let close: () -> Void
    let showDeleted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch sync.account {
            case .unknown:
                ProgressView()
            case .signedOut:
                Text("登入後，筆記會在 Mac、iPad、iPhone 間同步。").font(.callout)
                SignInWithAppleButton(.signIn) { request in
                    sync.prepare(request)
                } onCompletion: { result in
                    Task { await sync.complete(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 40)
            case .signedIn(let email):
                Label(email ?? "已登入", systemImage: "person.crop.circle").font(.callout)
                status
                if !sync.conflicts.isEmpty { conflicts }
                Button("最近刪除…", systemImage: "trash") { showDeleted() }
                    .buttonStyle(.borderless)
                HStack {
                    Button("立即同步", systemImage: "arrow.clockwise") { sync.syncNow() }
                        .disabled(sync.status.isSyncing)
                    Spacer()
                    Button("登出", role: .destructive) { Task { await sync.signOut() } }
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
                Label("同步中…", systemImage: "arrow.triangle.2.circlepath")
            } else if sync.status.pending > 0 {
                Label("\(sync.status.pending) 個檔案待上傳", systemImage: "icloud.and.arrow.up")
            } else if let last = sync.status.lastSynced {
                Label("已同步 · \(last.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
            }
            if let error = sync.status.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4)
            }
        }
        .font(.callout)
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("兩台裝置改了同一段，另一份內容存成衝突副本：").font(.caption).foregroundStyle(.secondary)
            ForEach(sync.conflicts, id: \.self) { path in
                Button((path as NSString).lastPathComponent) {
                    store.selection = path
                    close()
                }
                .buttonStyle(.borderless)
            }
            Button("知道了") { sync.dismissConflicts() }.font(.caption)
        }
    }
}

/// 30 天內刪除的檔案（任何裝置刪的都在這裡），可用同一個 file id 還原
private struct RecentlyDeletedView: View {
    @Environment(SyncCoordinator.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var files: [RemoteFile]?
    @State private var restoring: UUID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let files, files.isEmpty {
                    ContentUnavailableView("沒有最近刪除的檔案", systemImage: "trash",
                                           description: Text("刪除的檔案會保留 \(SyncEngine.retentionDays) 天。"))
                } else if let files {
                    List(files, id: \.id) { file in
                        row(file)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("最近刪除")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
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
                Button("還原") { Task { await restore(file) } }
                    .disabled(restoring != nil)
            }
        }
    }

    private func detail(_ file: RemoteFile) -> String {
        let folder = (file.path as NSString).deletingLastPathComponent
        let left = SyncEngine.retentionDays - Int(Date().timeIntervalSince(file.updatedAt) / 86_400)
        let when = file.updatedAt.formatted(.relative(presentation: .named))
        return "\(folder.isEmpty ? "Vault" : folder) · \(when)刪除 · 剩 \(max(left, 0)) 天"
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
