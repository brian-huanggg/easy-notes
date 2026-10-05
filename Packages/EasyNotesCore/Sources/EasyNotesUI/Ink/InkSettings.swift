import Foundation
import Observation

/// 手寫工具（白板與 PDF 共用，見 architecture/ui.md「手寫工具列」）
public enum InkTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case pen, highlighter, eraser, lasso

    public var id: String { rawValue }
}

/// 畫筆種類：鋼筆、原子筆、鉛筆（PencilKit 的 pen / monoline / pencil）
public enum PenKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fountain, ballpoint, pencil

    public var id: String { rawValue }

    /// PencilKit 墨水的 rawValue（`PKInk.InkType`）
    var inkType: String {
        switch self {
        case .fountain: "com.apple.ink.pen"
        case .ballpoint: "com.apple.ink.monoline"
        case .pencil: "com.apple.ink.pencil"
        }
    }
}

public enum EraserKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 整筆（`vector`）
    case stroke
    /// 部分（`bitmap`）
    case partial

    public var id: String { rawValue }
}

/// Pencil 點兩下要做的事（由系統設定的 `UIPencilInteraction.preferredTapAction` 換算）
public enum PencilTapAction: Sendable {
    case switchEraser, switchPrevious, toggleOptions, none
}

/// 畫布要套用的工具（平台無關的值，iOS 再換成 `PKTool`）
public enum InkToolSpec: Equatable, Sendable {
    /// `inkType` 是 `PKInk.InkType` 的 rawValue；`widthScale` 乘上墨水的 `defaultWidth`
    case ink(inkType: String, color: String, widthScale: Double)
    case eraser(partial: Bool, widthScale: Double)
    case lasso

    public var isInk: Bool {
        if case .ink = self { true } else { false }
    }
}

/// 手寫工具的狀態（純值，可單元測試）；`InkSettings` 負責觀察與存檔
public struct InkState: Codable, Equatable, Sendable {
    public static let penPresets = ["#1e1e1e", "#1971c2", "#e03131", "#2f9e44", "#f08c00"] // l10n:fixed
    public static let highlighterPresets = ["#ffd43b", "#69db7c", "#74c0fc", "#f783ac", "#ffa94d"] // l10n:fixed
    /// 三段粗細：墨水 `defaultWidth` 的倍數
    public static let widthScales: [Double] = [0.5, 1, 2]
    public static let maxCustomColors = 5

    public private(set) var tool: InkTool = .pen
    public private(set) var previousTool: InkTool = .eraser
    public var penKind: PenKind = .fountain
    public var penColor = penPresets[0]
    public var penWidth = 1
    public var highlighterColor = highlighterPresets[0]
    public var highlighterWidth = 1
    public var eraserKind: EraserKind = .stroke
    public var eraserWidth = 1
    public private(set) var customPenColors: [String] = []
    public private(set) var customHighlighterColors: [String] = []

    public init() {}

    public mutating func select(_ next: InkTool) {
        guard next != tool else { return }
        previousTool = tool
        tool = next
    }

    /// 回傳 true = 要收起 / 叫回選項膠囊
    @discardableResult
    public mutating func pencilTap(_ action: PencilTapAction) -> Bool {
        switch action {
        case .switchEraser:
            if tool == .eraser {
                select(previousTool == .eraser ? .pen : previousTool)
            } else {
                select(.eraser)
            }
        case .switchPrevious:
            select(previousTool)
        case .toggleOptions:
            return true
        case .none:
            break
        }
        return false
    }

    public var spec: InkToolSpec {
        switch tool {
        case .pen:
            .ink(inkType: penKind.inkType, color: penColor, widthScale: Self.scale(penWidth))
        case .highlighter:
            .ink(inkType: "com.apple.ink.marker", color: highlighterColor, widthScale: Self.scale(highlighterWidth))
        case .eraser:
            .eraser(partial: eraserKind == .partial, widthScale: Self.scale(eraserWidth))
        case .lasso:
            .lasso
        }
    }

    private static func scale(_ level: Int) -> Double {
        widthScales[min(max(level, 0), widthScales.count - 1)]
    }

    // MARK: 顏色（只有畫筆與螢光筆有）

    public func presets(for tool: InkTool) -> [String] {
        tool == .highlighter ? Self.highlighterPresets : Self.penPresets
    }

    public func customColors(for tool: InkTool) -> [String] {
        tool == .highlighter ? customHighlighterColors : customPenColors
    }

    public func color(for tool: InkTool) -> String {
        tool == .highlighter ? highlighterColor : penColor
    }

    public mutating func setColor(_ hex: String, for tool: InkTool) {
        if tool == .highlighter { highlighterColor = hex } else { penColor = hex }
    }

    /// 加一個自訂顏色並選取它。`replacingLast`：取代上一次加的（系統顏色選擇器拖曳中會連續送值）。
    /// 已在預設或自訂色裡就只選取；滿了就丟掉最舊的
    public mutating func addColor(_ raw: String, for tool: InkTool, replacingLast: Bool = false) {
        let hex = raw.lowercased()
        var list = customColors(for: tool)
        if replacingLast, let last = list.last, last == color(for: tool) { list.removeLast() }
        if !presets(for: tool).contains(hex), !list.contains(hex) {
            list.append(hex)
            if list.count > Self.maxCustomColors { list.removeFirst(list.count - Self.maxCustomColors) }
        }
        if tool == .highlighter { customHighlighterColors = list } else { customPenColors = list }
        setColor(hex, for: tool)
    }

    /// 刪除自訂顏色；刪的是目前的顏色就回到第一個預設色
    public mutating func removeColor(_ hex: String, for tool: InkTool) {
        if tool == .highlighter { customHighlighterColors.removeAll { $0 == hex } } else { customPenColors.removeAll { $0 == hex } }
        if color(for: tool) == hex { setColor(presets(for: tool)[0], for: tool) }
    }

    // MARK: 粗細

    public func widthLevel(for tool: InkTool) -> Int {
        switch tool {
        case .highlighter: highlighterWidth
        case .eraser: eraserWidth
        default: penWidth
        }
    }

    public mutating func setWidthLevel(_ level: Int, for tool: InkTool) {
        let level = min(max(level, 0), Self.widthScales.count - 1)
        switch tool {
        case .highlighter: highlighterWidth = level
        case .eraser: eraserWidth = level
        default: penWidth = level
        }
    }
}

/// 手寫工具列的共用狀態（App 偏好，存在 `UserDefaults`，不進 Vault、不同步）。白板與 PDF 共用同一份
@MainActor
@Observable
public final class InkSettings {
    public static let shared = InkSettings(defaults: .standard)
    static let key = "inkSettings" // l10n:fixed

    public var state: InkState {
        didSet { if state != oldValue { save() } }
    }

    /// 選項膠囊（畫筆種類、粗細、顏色）是否顯示；不存檔
    public var showsOptions = true

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(InkState.self, from: $0) } ?? InkState()
    }

    public var spec: InkToolSpec { state.spec }

    /// 工具列按了某個手寫工具：已是這個工具就收起 / 叫回選項膠囊
    public func choose(_ tool: InkTool, alreadyInking: Bool) {
        if alreadyInking, state.tool == tool {
            showsOptions.toggle()
        } else {
            state.select(tool)
            showsOptions = true
        }
    }

    public func pencilTap(_ action: PencilTapAction) {
        if state.pencilTap(action) { showsOptions.toggle() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.key) }
    }
}
