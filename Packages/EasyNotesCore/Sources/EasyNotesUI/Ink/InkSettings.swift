import Foundation
import Observation

/// Ink tools (shared by whiteboard and PDF, see "Ink toolbar" in architecture/ui.md)
public enum InkTool: String, Codable, CaseIterable, Identifiable, Sendable {
    case pen, highlighter, eraser, lasso

    public var id: String { rawValue }
}

/// Pen kinds: fountain pen, ballpoint, pencil (PencilKit's pen / monoline / pencil)
public enum PenKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fountain, ballpoint, pencil

    public var id: String { rawValue }

    /// The rawValue of the PencilKit ink (`PKInk.InkType`)
    var inkType: String {
        switch self {
        case .fountain: "com.apple.ink.pen"
        case .ballpoint: "com.apple.ink.monoline"
        case .pencil: "com.apple.ink.pencil"
        }
    }
}

public enum EraserKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Whole stroke (`vector`)
    case stroke
    /// Partial (`bitmap`)
    case partial

    public var id: String { rawValue }
}

/// What a Pencil double-tap does (converted from the system setting `UIPencilInteraction.preferredTapAction`)
public enum PencilTapAction: Sendable {
    case switchEraser, switchPrevious, toggleOptions, none
}

/// The tool the canvas should apply (a platform-independent value that iOS converts to `PKTool`)
public enum InkToolSpec: Equatable, Sendable {
    /// `inkType` is the rawValue of `PKInk.InkType`; `widthScale` multiplies the ink's `defaultWidth`
    case ink(inkType: String, color: String, widthScale: Double)
    case eraser(partial: Bool, widthScale: Double)
    case lasso

    public var isInk: Bool {
        if case .ink = self { true } else { false }
    }
}

/// The state of the ink tools (a pure value, unit-testable); `InkSettings` handles observation and persistence
public struct InkState: Codable, Equatable, Sendable {
    public static let penPresets = ["#1e1e1e", "#1971c2", "#e03131", "#2f9e44", "#f08c00"] // l10n:fixed
    public static let highlighterPresets = ["#ffd43b", "#69db7c", "#74c0fc", "#f783ac", "#ffa94d"] // l10n:fixed
    /// Three widths: multiples of the ink's `defaultWidth`
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

    /// Returns true = collapse / restore the options capsule
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

    // MARK: Color (only pen and highlighter have it)

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

    /// Adds a custom color and selects it. `replacingLast`: replaces the one added last time (the system color picker sends values continuously while dragging).
    /// If it is already among presets or custom colors it is only selected; when full the oldest is dropped
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

    /// Deletes a custom color; deleting the current color returns to the first preset
    public mutating func removeColor(_ hex: String, for tool: InkTool) {
        if tool == .highlighter { customHighlighterColors.removeAll { $0 == hex } } else { customPenColors.removeAll { $0 == hex } }
        if color(for: tool) == hex { setColor(presets(for: tool)[0], for: tool) }
    }

    // MARK: Width

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

/// Shared state of the ink toolbar (an app preference stored in `UserDefaults`, not in the vault, not synced). Shared by whiteboard and PDF
@MainActor
@Observable
public final class InkSettings {
    public static let shared = InkSettings(defaults: .standard)
    static let key = "inkSettings" // l10n:fixed

    public var state: InkState {
        didSet { if state != oldValue { save() } }
    }

    /// Whether the options capsule (pen kind, width, color) is shown; not persisted
    public var showsOptions = true

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(InkState.self, from: $0) } ?? InkState()
    }

    public var spec: InkToolSpec { state.spec }

    /// An ink tool was pressed on the toolbar: if it is already this tool, collapse / restore the options capsule
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
