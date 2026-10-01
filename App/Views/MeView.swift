import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// 帳號、同步、最近刪除與 Vault 位置。iPhone 的「我」分頁、iPad 的設定 sheet、macOS 的 Settings 視窗共用
struct MeView: View {
    @Environment(VaultStore.self) private var store
    @State private var showDeleted = false

    var body: some View {
        Form {
            Section("帳號與同步") {
                SyncPanel()
                    .padding(.vertical, 4)
            }
            Section {
                Button("最近刪除", systemImage: "trash") { showDeleted = true }
                LabeledContent("保留期限", value: "\(SyncEngine.retentionDays) 天")
            }
            Section("Vault") {
                LabeledContent("名稱", value: store.vaultName)
                LabeledContent("位置") {
                    Text(store.fs.root.path(percentEncoded: false))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Button(revealTitle, systemImage: "folder") { reveal(store.fs.root) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showDeleted) { RecentlyDeletedView() }
        .navigationTitle("設定")
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}
