import AuthenticationServices
import SwiftUI

/// 側邊欄工具列的同步狀態：已同步 / 同步中 / 待上傳 / 衝突 / 錯誤，點開可登入、立即同步、查看衝突副本
struct SyncStatusButton: View {
    @Environment(SyncCoordinator.self) private var sync
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            Label(title, systemImage: symbol)
        }
        .help(title)
        .popover(isPresented: $showPanel) {
            SyncPanel(close: { showPanel = false })
                .frame(minWidth: 280)
                .padding()
                .presentationCompactAdaptation(.popover)
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
