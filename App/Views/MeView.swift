import EasyNotesCore
import EasyNotesUI
import SwiftUI

/// Account, sync, recently deleted and vault location. Shared by iPhone's "Me" tab, iPad's settings sheet and macOS's Settings window
struct MeView: View {
    @Environment(VaultStore.self) private var store
    @State private var showDeleted = false
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.system
    #if os(macOS)
    @State private var language = AppLanguage.current
    @State private var launchLanguage = AppLanguage.current
    #endif

    var body: some View {
        Form {
            Section(L("外觀")) {
                Picker(L("主題"), selection: $theme) {
                    ForEach(AppTheme.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.menu)
                #if os(macOS)
                Picker(L("語言"), selection: Binding(get: { language }, set: { language = $0; $0.save() })) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                if language != launchLanguage {
                    Text(L("重新啟動後生效")).font(.caption).foregroundStyle(.secondary)
                }
                #endif
            }
            #if os(macOS)
            ShortcutSettingsSection()
            #endif
            Section(L("帳號與同步")) {
                SyncPanel()
                    .padding(.vertical, 4)
            }
            Section {
                Button(L("最近刪除"), systemImage: "trash") { showDeleted = true }
                LabeledContent(L("保留期限"), value: L("\(SyncEngine.retentionDays) 天"))
            }
            Section("Vault") {
                LabeledContent(L("名稱"), value: store.vaultName)
                LabeledContent(L("位置")) {
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
        .navigationTitle(L("設定"))
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

#if os(macOS)
/// Keyboard shortcut list; click a shortcut, then press the new key combination (Esc cancels).
private struct ShortcutSettingsSection: View {
    @State private var store = ShortcutStore.shared
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        Section(L("鍵盤快速鍵")) {
            ForEach(ShortcutAction.allCases) { action in
                LabeledContent(action.title) {
                    HStack {
                        Button(recording == action ? L("按下按鍵…") : store.binding(for: action).display) {
                            recording == action ? stopRecording() : startRecording(action)
                        }
                        .monospaced()
                        Button(L("還原預設"), systemImage: "arrow.uturn.backward") { store.reset(action) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .disabled(!store.isCustomized(action))
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            Button(L("全部還原預設")) { store.resetAll() }
                .disabled(!ShortcutAction.allCases.contains { store.isCustomized($0) })
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        message = nil
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, for: action)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func handle(_ event: NSEvent, for action: ShortcutAction) {
        if event.keyCode == 53 { stopRecording(); return } // Esc
        guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1,
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return }
        let flags = event.modifierFlags
        let binding = ShortcutBinding(key, command: flags.contains(.command), shift: flags.contains(.shift),
                                      option: flags.contains(.option), control: flags.contains(.control))
        guard binding.isValid else { message = L("需包含 ⌘、⌃ 或 ⌥"); return }
        if let other = store.conflict(for: binding, excluding: action) {
            message = other.title + L("已使用此快速鍵")
            return
        }
        store.set(binding, for: action)
        message = nil
        stopRecording()
    }
}

/// Writes `AppleLanguages`, taking effect after a restart (no live switching, see translation.md). iOS uses system Settings
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zhHant = "zh-Hant", en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("跟隨系統")
        case .zhHant: "繁體中文" // l10n:fixed A language is shown in its own name
        case .en: "English"
        }
    }

    static var current: AppLanguage {
        guard let first = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first,
              UserDefaults.standard.object(forKey: Self.overrideKey) != nil else { return .system }
        return AppLanguage.allCases.first { first.hasPrefix($0.rawValue) } ?? .system
    }

    private static let overrideKey = "AppLanguageOverride"

    func save() {
        let defaults = UserDefaults.standard
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: Self.overrideKey)
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
            defaults.set(true, forKey: Self.overrideKey)
        }
    }
}
#endif
