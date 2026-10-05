import SwiftUI

// Toolbar shared by whiteboard and PDF (GoodNotes style, see "Ink toolbar" in architecture/ui.md):
// a top row (tools centered, actions on the right) + the floating Undo / Redo and ink options capsule below

/// The top row: `tools` centered (horizontally scrollable when they do not fit), `actions` at the right; its own row below the navigation bar
public struct EditorToolbar<Tools: View, Actions: View>: View {
    private let tools: Tools
    private let actions: Actions

    public init(@ViewBuilder tools: () -> Tools, @ViewBuilder actions: () -> Actions) {
        self.tools = tools()
        self.actions = actions()
    }

    public var body: some View {
        CenterTrailingLayout {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { tools }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { tools }
                }
            }
            HStack(spacing: 6) { actions }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The first child is centered as far as possible and the second at the right; when the two would overlap, the middle one shifts left (and then shrinks to the remaining width)
private struct CenterTrailingLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let trailing = subviews[1].sizeThatFits(.unspecified)
        let trailingWidth = trailing.width > 0 ? trailing.width + spacing : 0
        let available = max(bounds.width - trailingWidth, 0)
        let center = subviews[0].sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
        let width = min(center.width, available)
        var x = bounds.midX - width / 2
        x = min(x, bounds.maxX - trailingWidth - width)
        x = max(x, bounds.minX)
        subviews[0].place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}

/// An icon button of the toolbar (a background when selected)
public struct ToolbarIconButton: View {
    let title: String
    let systemImage: String
    let active: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 34, height: 34)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

public struct ToolbarSeparator: View {
    public init() {}

    public var body: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }
}

/// Pen, highlighter, eraser, lasso: choosing one enters ink mode; pressing the selected tool again collapses / restores the options capsule
public struct InkToolButtons: View {
    @Binding var inking: Bool
    private let settings = InkSettings.shared

    public init(inking: Binding<Bool>) {
        _inking = inking
    }

    public var body: some View {
        ForEach(InkTool.allCases) { tool in
            ToolbarIconButton(tool.title, systemImage: tool.systemImage, active: inking && settings.state.tool == tool) {
                settings.choose(tool, alreadyInking: inking)
                inking = true
            }
        }
    }
}

/// The floating row below the toolbar: Undo / Redo at the left, the ink options capsule in the middle (when in ink mode and options are shown). Empty space lets touches through
public struct EditorFloatingRow: View {
    let inking: Bool
    let undo: UndoRedoPill
    private let settings = InkSettings.shared

    public init(inking: Bool, undo: UndoRedoPill) {
        self.inking = inking
        self.undo = undo
    }

    public var body: some View {
        CenterLeadingLayout {
            if inking, settings.showsOptions, settings.state.tool != .lasso {
                InkOptionsBar()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
            undo
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeOut(duration: 0.15), value: inking && settings.showsOptions)
    }
}

/// The first child is centered as far as possible and the second at the left (symmetric with `CenterTrailingLayout`)
private struct CenterLeadingLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing
        return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let leading = subviews[1].sizeThatFits(.unspecified)
        let leadingWidth = leading.width + spacing
        let available = max(bounds.width - leadingWidth, 0)
        let center = subviews[0].sizeThatFits(ProposedViewSize(width: available, height: nil))
        let width = min(center.width, available)
        var x = bounds.midX - width / 2
        x = max(x, bounds.minX + leadingWidth)
        x = min(x, bounds.maxX - width)
        subviews[0].place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
    }
}

/// The Undo / Redo capsule. `manager` is used only to show whether undo is possible; pressing calls `undo` / `redo` (the host may end text editing first)
public struct UndoRedoPill: View {
    let manager: () -> UndoManager?
    let undo: () -> Void
    let redo: () -> Void
    @State private var canUndo = false
    @State private var canRedo = false

    public init(manager: @escaping () -> UndoManager?, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        self.manager = manager
        self.undo = undo
        self.redo = redo
    }

    public var body: some View {
        HStack(spacing: 2) {
            Button { undo(); refresh() } label: { icon("arrow.uturn.backward") }
                .disabled(!canUndo)
                .help(L("復原"))
                .accessibilityLabel(L("復原"))
            Button { redo(); refresh() } label: { icon("arrow.uturn.forward") }
                .disabled(!canRedo)
                .help(L("重做"))
                .accessibilityLabel(L("重做"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .onAppear(perform: refresh)
        // Must not listen to NSUndoManagerCheckpoint: canUndo / canRedo themselves emit it, forming an infinite loop
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in refresh() }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 34, height: 34).contentShape(Rectangle())
    }

    private func refresh() {
        canUndo = manager()?.canUndo ?? false
        canRedo = manager()?.canRedo ?? false
    }
}

/// The ink options capsule: pen kind | width | color (a highlighter has no kind; an eraser is whole / partial + width)
struct InkOptionsBar: View {
    private let settings = InkSettings.shared

    var body: some View {
        // Exactly the needed width (centered) when it fits, horizontal scrolling only when it does not
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        .foregroundStyle(Color.primary)
    }

    private var content: some View {
        let tool = settings.state.tool
        return HStack(spacing: 4) {
                switch tool {
                case .pen:
                    ForEach(PenKind.allCases) { kind in
                        option(kind.title, active: settings.state.penKind == kind) {
                            Image(systemName: kind.systemImage).font(.system(size: 17))
                        } action: { settings.state.penKind = kind }
                    }
                    divider
                    widths(for: tool)
                    divider
                    colors(for: tool)
                case .highlighter:
                    widths(for: tool)
                    divider
                    colors(for: tool)
                case .eraser:
                    ForEach(EraserKind.allCases) { kind in
                        option(kind.title, active: settings.state.eraserKind == kind) {
                            Image(systemName: kind.systemImage).font(.system(size: 17))
                        } action: { settings.state.eraserKind = kind }
                    }
                    if settings.state.eraserKind == .partial {
                        divider
                        widths(for: tool)
                    }
                case .lasso:
                    EmptyView()
                }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var divider: some View {
        Divider().frame(height: 24).padding(.horizontal, 4)
    }

    private func option(_ title: String, active: Bool, @ViewBuilder label: () -> some View,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .frame(width: 38, height: 38)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Three widths: thicker means a thicker line
    private func widths(for tool: InkTool) -> some View {
        ForEach(InkState.widthScales.indices, id: \.self) { level in
            option(L("粗細 \(level + 1)"), active: settings.state.widthLevel(for: tool) == level) {
                Capsule().frame(width: 20, height: [2.0, 4, 7][level])
            } action: { settings.state.setWidthLevel(level, for: tool) }
        }
    }

    private func colors(for tool: InkTool) -> some View {
        let current = settings.state.color(for: tool)
        return Group {
            ForEach(settings.state.presets(for: tool), id: \.self) { hex in
                swatch(hex, selected: current == hex, tool: tool)
            }
            ForEach(settings.state.customColors(for: tool), id: \.self) { hex in
                swatch(hex, selected: current == hex, tool: tool)
                    .contextMenu {
                        Button(L("刪除顏色"), systemImage: "trash", role: .destructive) {
                            settings.state.removeColor(hex, for: tool)
                        }
                    }
            }
            AddColorButton(tool: tool)
        }
    }

    private func swatch(_ hex: String, selected: Bool, tool: InkTool) -> some View {
        let color = Color(inkHex: hex)
        return Button { settings.state.setColor(hex, for: tool) } label: {
            Circle()
                .fill(color)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(InkColor.isLight(hex) ? Color.black : .white)
                    }
                }
                .padding(4)
                .overlay { if selected { Circle().strokeBorder(color, lineWidth: 2) } }
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("顏色 \(hex)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "+": the system color picker. It sends values continuously while dragging, so consecutive changes in a short time replace the color added last time instead of adding many
private struct AddColorButton: View {
    let tool: InkTool
    @State private var picked = Color.black
    @State private var lastChange: Date = .distantPast

    var body: some View {
        ZStack {
            // The system color well accepts taps; its appearance is replaced by a dashed circle + plus sign
            ColorPicker(L("加入顏色"), selection: $picked, supportsOpacity: false)
                .labelsHidden()
                .opacity(0.02)
                .scaleEffect(1.3)
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .foregroundStyle(Color.secondary)
                .frame(width: 26, height: 26)
                .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.secondary))
                .allowsHitTesting(false)
        }
        .frame(width: 38, height: 38)
        .help(L("加入顏色"))
        .onChange(of: picked) { _, color in
            let now = Date()
            let replacing = now.timeIntervalSince(lastChange) < 3
            lastChange = now
            InkSettings.shared.state.addColor(InkColor.hex(color), for: tool, replacingLast: replacing)
        }
    }
}

enum InkColor {
    static func hex(_ color: Color) -> String {
        let c = color.resolve(in: EnvironmentValues())
        let parts = [c.red, c.green, c.blue].map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }
        return "#" + parts.joined()
    }

    /// Whether the checkmark is black or white
    static func isLight(_ hex: String) -> Bool {
        let (r, g, b) = rgb(hex)
        return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(digits.prefix(6), radix: 16) ?? 0
        return (Double((value >> 16) & 0xff) / 255, Double((value >> 8) & 0xff) / 255, Double(value & 0xff) / 255)
    }
}

extension Color {
    init(inkHex hex: String) {
        let (r, g, b) = InkColor.rgb(hex)
        self.init(.sRGB, red: r, green: g, blue: b)
    }
}

// MARK: Names and icons

extension InkTool {
    public var title: String {
        switch self {
        case .pen: L("畫筆")
        case .highlighter: L("螢光筆")
        case .eraser: L("橡皮擦")
        case .lasso: L("套索")
        }
    }

    public var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
}

extension PenKind {
    var title: String {
        switch self {
        case .fountain: L("鋼筆")
        case .ballpoint: L("原子筆")
        case .pencil: L("鉛筆")
        }
    }

    var systemImage: String {
        switch self {
        case .fountain: "signature"
        case .ballpoint: "pencil.tip"
        case .pencil: "pencil"
        }
    }
}

extension EraserKind {
    var title: String {
        switch self {
        case .stroke: L("整筆擦除")
        case .partial: L("部分擦除")
        }
    }

    var systemImage: String {
        switch self {
        case .stroke: "eraser.line.dashed"
        case .partial: "eraser"
        }
    }
}
