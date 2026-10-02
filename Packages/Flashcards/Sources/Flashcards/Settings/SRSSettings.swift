import EasyNotesCore
import Foundation

/// 全域設定（所有牌組共用）
public struct GlobalSettings: Codable, Equatable, Sendable {
    /// 新的一天從幾點開始（0–23）
    public var rolloverHour = 4
    /// 評分按鈕上顯示下次間隔
    public var showIntervals = true
    /// 紀錄夠多時提醒執行參數最佳化（3d）
    public var optimizeReminder = true

    public init() {}
}

/// Flashcards 的設定：presets、資料夾 → preset、全域設定。
///
/// 存檔時攤平成欄位（`SRSSettings.Field`），每台裝置只寫自己的 `.easynotes/srs/<deviceId>.config.json`；
/// 讀取時合併所有裝置的檔案，每個欄位取最新的值（欄位 LWW）。
public struct SRSConfig: Equatable, Sendable {
    /// 內建 preset 的 id，不能刪除；沒有指定 preset 的根目錄使用它
    public static let defaultPresetID = "default"

    /// preset id → preset；一定包含 `default`
    public var presets: [String: Preset]
    /// 資料夾路徑 → preset id；沒有列出的資料夾繼承上層
    public var decks: [String: String]
    public var global: GlobalSettings

    public init(presets: [String: Preset] = [:], decks: [String: String] = [:], global: GlobalSettings = GlobalSettings()) {
        self.presets = presets
        self.decks = decks
        self.global = global
        if self.presets[Self.defaultPresetID] == nil { self.presets[Self.defaultPresetID] = Preset() }
    }

    /// 資料夾實際使用的 preset id：自己有指定就用自己的，否則往上找，最後是 `default`
    public func presetID(for folder: String) -> String {
        var path = folder
        while true {
            if let id = decks[path], presets[id] != nil { return id }
            guard !path.isEmpty else { return Self.defaultPresetID }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    public func preset(for folder: String) -> Preset {
        presets[presetID(for: folder)] ?? Preset()
    }

    /// 依名稱排序，`default` 在最前面
    public var sortedPresetIDs: [String] {
        presets.keys.sorted { a, b in
            if a == Self.defaultPresetID || b == Self.defaultPresetID { return a == Self.defaultPresetID }
            return (presets[a]!.name, a) < (presets[b]!.name, b)
        }
    }

    /// 刪除 preset：使用它的牌組改回繼承上層
    public mutating func removePreset(_ id: String) {
        guard id != Self.defaultPresetID else { return }
        presets[id] = nil
        decks = decks.filter { $0.value != id }
    }

    /// 新的 preset id：`p-` + 6 碼小寫英數
    public static func newPresetID() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "p-" + String((0..<6).map { _ in chars.randomElement()! })
    }

    /// 資料夾改名或搬移：它與所有子資料夾的指定跟著搬
    public func movingFolder(from old: String, to new: String) -> SRSConfig {
        var copy = self
        copy.decks = [:]
        for (path, id) in decks {
            if path == old {
                copy.decks[new] = id
            } else if path.hasPrefix(old + "/") {
                copy.decks[new + path.dropFirst(old.count)] = id
            } else {
                copy.decks[path] = copy.decks[path] ?? id
            }
        }
        return copy
    }
}

/// 設定檔的讀寫與欄位 LWW 合併
public enum SRSSettings {
    public static func path(deviceID: String) -> String { "\(ReviewLog.folder)/\(deviceID).config.json" }

    /// 一個欄位的值與修改時間；`k` 例如 `["presets", "p-k3x9a2", "newPerDay"]`、`["decks", "日文/N2"]`
    public struct Field: Codable, Equatable, Sendable {
        public var k: [String]
        public var v: JSONValue
        /// Unix 毫秒
        public var t: Int64

        public init(k: [String], v: JSONValue, t: Int64) {
            self.k = k
            self.v = v
            self.t = t
        }
    }

    struct File: Codable {
        var version = 1
        var fields: [Field]
    }

    // MARK: 讀取

    /// 合併所有裝置的設定檔
    public static func load(_ fs: VaultFS) -> SRSConfig {
        config(from: winners(loadFields(fs)))
    }

    /// deviceId → 該裝置的欄位
    static func loadFields(_ fs: VaultFS) -> [String: [Field]] {
        let dir = fs.url(for: ReviewLog.folder)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        var result: [String: [Field]] = [:]
        for url in urls where url.lastPathComponent.hasSuffix(".config.json") {
            guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else { continue }
            result[String(url.lastPathComponent.dropLast(".config.json".count))] = file.fields
        }
        return result
    }

    /// 每個欄位取修改時間最新的值；時間相同時比 deviceId（任何裝置都得到相同結果）
    static func winners(_ devices: [String: [Field]]) -> [[String]: JSONValue] {
        var best: [[String]: (t: Int64, device: String, v: JSONValue)] = [:]
        for (device, fields) in devices {
            for field in fields {
                if let current = best[field.k], (current.t, current.device) >= (field.t, device) { continue }
                best[field.k] = (field.t, device, field.v)
            }
        }
        return best.mapValues(\.v)
    }

    static func config(from fields: [[String]: JSONValue]) -> SRSConfig {
        var presetFields: [String: [String: JSONValue]] = [:]
        var decks: [String: String] = [:]
        var global = JSONValue.encode(GlobalSettings()).objectValue ?? [:]
        for (key, value) in fields {
            switch (key.first, key.count) {
            case ("presets", 3): presetFields[key[1], default: [:]][key[2]] = value
            case ("decks", 2): if case .string(let id) = value { decks[key[1]] = id }
            case ("global", 2): global[key[1]] = value
            default: break
            }
        }
        let defaults = JSONValue.encode(Preset()).objectValue ?? [:]
        var presets: [String: Preset] = [:]
        for (id, fields) in presetFields {
            if fields["deleted"] == .bool(true), id != SRSConfig.defaultPresetID { continue }
            // 型別不對的欄位（例如之後的版本改了格式）用預設值
            var object = defaults
            for (name, value) in fields where defaults[name] != nil {
                var trial = object
                trial[name] = value
                if JSONValue.object(trial).decode(Preset.self) != nil { object = trial }
            }
            presets[id] = JSONValue.object(object).decode(Preset.self)
        }
        let globalSettings = JSONValue.object(global).decode(GlobalSettings.self) ?? GlobalSettings()
        return SRSConfig(presets: presets, decks: decks.filter { presets[$0.value] != nil }, global: globalSettings)
    }

    // MARK: 寫入

    /// 設定攤平成欄位；`default` preset 沒改過的欄位也列出（與舊值比較時才知道差異）
    static func flatten(_ config: SRSConfig) -> [[String]: JSONValue] {
        var result: [[String]: JSONValue] = [:]
        for (id, preset) in config.presets {
            for (name, value) in JSONValue.encode(preset).objectValue ?? [:] { result[["presets", id, name]] = value }
        }
        for (path, id) in config.decks { result[["decks", path]] = .string(id) }
        for (name, value) in JSONValue.encode(config.global).objectValue ?? [:] { result[["global", name]] = value }
        return result
    }

    /// `old` → `new` 有變動的欄位。消失的 preset 寫成 `deleted: true`，消失的資料夾指定寫成 `null`（繼承上層）
    static func changes(from old: SRSConfig, to new: SRSConfig, at time: Int64) -> [Field] {
        let before = flatten(old)
        let after = flatten(new)
        var fields: [Field] = []
        for (key, value) in after where before[key] != value {
            fields.append(Field(k: key, v: value, t: time))
        }
        // 重新建立的 preset（同一個 id）要清掉之前的刪除標記
        for id in new.presets.keys where old.presets[id] == nil {
            fields.append(Field(k: ["presets", id, "deleted"], v: .bool(false), t: time))
        }
        for id in old.presets.keys where new.presets[id] == nil {
            fields.append(Field(k: ["presets", id, "deleted"], v: .bool(true), t: time))
        }
        for path in old.decks.keys where new.decks[path] == nil {
            fields.append(Field(k: ["decks", path], v: .null, t: time))
        }
        return fields.sorted { $0.k.lexicographicallyPrecedes($1.k) }
    }

    /// 把 `old` → `new` 的變動寫進這台裝置的設定檔；沒有變動時不寫。回傳是否有寫入
    @discardableResult
    public static func save(_ new: SRSConfig, replacing old: SRSConfig, fs: VaultFS, deviceID: String,
                            now: Date = Date()) throws -> Bool {
        let changed = changes(from: old, to: new, at: Int64((now.timeIntervalSince1970 * 1000).rounded()))
        guard !changed.isEmpty else { return false }
        let path = path(deviceID: deviceID)
        var mine = (try? JSONDecoder().decode(File.self, from: fs.read(path)))?.fields ?? []
        let keys = Set(changed.map(\.k))
        mine.removeAll { keys.contains($0.k) }
        mine += changed
        mine.sort { $0.k.lexicographicallyPrecedes($1.k) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try fs.write(try encoder.encode(File(fields: mine)), to: path)
        return true
    }
}

/// 設定檔中的任意 JSON 值
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // 整數寫成整數（`20` 而不是 `20.0`），Int 欄位才解得回來
            if n.rounded() == n, abs(n) < 9e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { o } else { nil }
    }

    static func encode(_ value: some Encodable) -> JSONValue {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        (try? JSONEncoder().encode(self)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
