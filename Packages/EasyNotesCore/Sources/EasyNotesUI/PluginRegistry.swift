import EasyNotesCore
import SwiftUI

/// 每個外掛的入口。App 啟動時依序呼叫，外掛在這裡註冊檔案類型、編輯器與選單。
public protocol EasyNotesPlugin {
    @MainActor static func register(in registry: PluginRegistry)
}

/// 外掛註冊表。只在啟動時寫入；Core 需要的部分由 `makeKinds()` 轉成無 UI 的 KindRegistry。
/// 擴充點等真的有外掛需要時才加，不預先設計。
@MainActor
public final class PluginRegistry {
    public struct NewFileCommand: Identifiable {
        public var id: String { title }
        public let title: String
        public let kind: any DocumentKind.Type
        public let symbol: String
        public let shortcut: KeyboardShortcut?
        /// 新檔案的預設名稱
        public let defaultName: String
    }

    public struct MenuItem: Identifiable {
        public var id: String { title }
        public let title: String
        public let shortcut: KeyboardShortcut?
        public let action: @MainActor () -> Void

        public init(_ title: String, shortcut: KeyboardShortcut? = nil, action: @escaping @MainActor () -> Void) {
            self.title = title
            self.shortcut = shortcut
            self.action = action
        }
    }

    public struct Menu: Identifiable {
        public var id: String { title }
        public let title: String
        /// 各區段之間以分隔線隔開
        public let sections: [[MenuItem]]
    }

    private var kinds: [any DocumentKind.Type] = []
    private var symbols: [String: String] = [:]
    private var tints: [String: KindTint] = [:]
    private var editors: [String: (String) -> AnyView] = [:]
    public private(set) var newFileCommands: [NewFileCommand] = []
    public private(set) var controllers: [any EditorController] = []
    public private(set) var menus: [Menu] = []

    public init() {}

    // MARK: 註冊

    /// 第一個註冊的 Kind 是預設類型：`[[連結]]` 找不到目標時建立這種檔案。
    /// `tint`：圖示、篩選 chip、縮圖底色用的類型顏色，App 不寫死
    public func addKind(_ kind: any DocumentKind.Type, symbol: String, tint: KindTint = .neutral) {
        kinds.append(kind)
        symbols[kind.id] = symbol
        tints[kind.id] = tint
    }

    /// 編輯器以 Vault 內的相對路徑建立；每次切換檔案都會重新呼叫
    public func addEditor(for kindID: String, _ make: @escaping @MainActor (_ path: String) -> some View) {
        editors[kindID] = { AnyView(make($0)) }
    }

    public func addNewFile(_ title: String, kind: any DocumentKind.Type, symbol: String,
                           shortcut: KeyboardShortcut? = nil, defaultName: String) {
        newFileCommands.append(NewFileCommand(title: title, kind: kind, symbol: symbol, shortcut: shortcut,
                                              defaultName: defaultName))
    }

    public func addController(_ controller: any EditorController) {
        controllers.append(controller)
    }

    public func addMenu(_ title: String, sections: [[MenuItem]]) {
        menus.append(Menu(title: title, sections: sections))
    }

    // MARK: 查詢

    /// 重複註冊同一副檔名會拋出錯誤
    public func makeKinds() throws -> KindRegistry {
        try KindRegistry(kinds)
    }

    public var defaultKind: (any DocumentKind.Type)? {
        kinds.first
    }

    public func symbol(for kindID: String?) -> String {
        kindID.flatMap { symbols[$0] } ?? "doc"
    }

    public func tint(for kindID: String?) -> KindTint {
        kindID.flatMap { tints[$0] } ?? .neutral
    }

    public func editor(for kindID: String?, path: String) -> AnyView? {
        kindID.flatMap { editors[$0] }?(path)
    }
}
