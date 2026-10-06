import Observation
import SwiftUI

/// App-level menu actions whose keyboard shortcut the user can change on Mac (plugin menu shortcuts stay fixed).
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTab, closeTab, closeWindow, syncNow, quickOpen, back, forward, nextTab, previousTab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: L("新分頁")
        case .closeTab: L("關閉分頁")
        case .closeWindow: L("關閉視窗")
        case .syncNow: L("立即同步")
        case .quickOpen: L("快速開啟…")
        case .back: L("上一頁")
        case .forward: L("下一頁")
        case .nextTab: L("下一個分頁")
        case .previousTab: L("上一個分頁")
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .newTab: .init("t")
        case .closeTab: .init("w")
        case .closeWindow: .init("w", option: true)
        case .syncNow: .init("s")
        case .quickOpen: .init("k")
        case .back: .init("[")
        case .forward: .init("]")
        case .nextTab: .init("]", shift: true)
        case .previousTab: .init("[", shift: true)
        }
    }
}

/// A key plus modifiers; `key` is a single lowercase character.
struct ShortcutBinding: Codable, Equatable {
    var key: String
    var command = true
    var shift = false
    var option = false
    var control = false

    init(_ key: String, command: Bool = true, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }

    /// Menu-style text such as "⌥⌘W"
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    /// A global shortcut needs at least one of ⌘ ⌃ ⌥, otherwise it would swallow typing.
    var isValid: Bool { !key.isEmpty && (command || control || option) }
}

/// User overrides of `ShortcutAction` defaults. Stored in `UserDefaults` (per device, not in the vault, not synced).
@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let storageKey = "KeyboardShortcutOverrides"

    private var overrides: [String: ShortcutBinding]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        overrides[action.rawValue] ?? action.defaultBinding
    }

    func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    /// The other action already using `binding`, if any.
    func conflict(for binding: ShortcutBinding, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.binding(for: $0) == binding }
    }

    /// Returns false (and changes nothing) when the binding is invalid or taken by another action.
    @discardableResult
    func set(_ binding: ShortcutBinding, for action: ShortcutAction) -> Bool {
        guard binding.isValid, conflict(for: binding, excluding: action) == nil else { return false }
        if binding == action.defaultBinding { overrides[action.rawValue] = nil } else { overrides[action.rawValue] = binding }
        save()
        return true
    }

    func reset(_ action: ShortcutAction) {
        overrides[action.rawValue] = nil
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

extension View {
    /// Applies the user's (or default) shortcut for `action` to a menu item.
    @MainActor
    func shortcut(_ action: ShortcutAction) -> some View {
        keyboardShortcut(ShortcutStore.shared.binding(for: action).keyboardShortcut)
    }
}
