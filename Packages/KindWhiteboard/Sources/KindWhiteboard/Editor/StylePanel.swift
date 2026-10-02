import ExcalidrawKit
import SwiftUI

/// 樣式面板（見 architecture/whiteboard.md「4c：樣式面板」）：只顯示選取元素適用的區塊，只用預設色盤。
/// 多選時值不一致就不標記任何選項
struct StylePanel: View {
    let editor: BoardEditor

    /// Excalidraw 調色盤第 4 階（外框、字色）
    static let strokePalette = ["#1e1e1e", "#868e96", "#e03131", "#c2255c", "#9c36b5", "#6741d9",
                                "#1971c2", "#0c8599", "#099268", "#2f9e44", "#f08c00"]
    /// 第 1 階（填色），第一個是無
    static let fillPalette = ["transparent", "#e9ecef", "#ffc9c9", "#fcc2d7", "#eebefa", "#d0bfff",
                              "#a5d8ff", "#99e9f2", "#96f2d7", "#b2f2bb", "#ffec99", "#ffd8a8"]
    static let strokeWidths: [(String, Double)] = [(L("細"), 1), (L("中"), 2), (L("粗"), 4)]
    static let strokeStyles: [(String, String)] = [(L("實線"), "solid"), (L("虛線"), "dashed"), (L("點線"), "dotted")]
    static let fontSizes: [(String, Double)] = [(L("小"), 16), (L("中"), 20), (L("大"), 28), (L("特大"), 36)]
    static let textAligns: [(String, String, String)] = [(L("靠左"), "left", "text.alignleft"),
                                                         (L("置中"), "center", "text.aligncenter"),
                                                         (L("靠右"), "right", "text.alignright")]
    static let arrowheads: [(String, String?)] = [(L("無"), nil), (L("箭頭"), "arrow"), (L("三角形"), "triangle"),
                                                  (L("橫線"), "bar"), (L("圓點"), "circle"), (L("菱形"), "diamond")]

    /// 透明度滑桿拖曳中的值（放開前不讀場景，避免跳動）
    @State private var draggingOpacity: Double?

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        let style = editor.styleSummary
        return VStack(alignment: .leading, spacing: 14) {
            if !style.fills.isEmpty {
                section(L("填色")) {
                    colors(Self.fillPalette, current: style.fills) { editor.setStyle(.fill($0)) }
                }
            }
            if !style.strokeColors.isEmpty {
                section(L("外框")) {
                    colors((style.strokeCanBeNone ? ["transparent"] : []) + Self.strokePalette,
                           current: style.strokeColors) { editor.setStyle(.strokeColor($0)) }
                    HStack(spacing: 16) {
                        if !style.strokeWidths.isEmpty {
                            options(Self.strokeWidths, current: style.strokeWidths, set: { editor.setStyle(.strokeWidth($0)) }) { width in
                                Capsule().frame(width: 22, height: width)
                            }
                        }
                        if !style.strokeStyles.isEmpty {
                            options(Self.strokeStyles, current: style.strokeStyles, set: { editor.setStyle(.strokeStyle($0)) }) { kind in
                                StrokeSample(style: kind)
                            }
                        }
                    }
                }
            }
            if !style.rounded.isEmpty {
                section(L("邊角")) {
                    options([(L("直角"), false), (L("圓角"), true)], current: style.rounded, set: { editor.setStyle(.rounded($0)) }) { on in
                        Image(systemName: on ? "app" : "square").font(.system(size: 17))
                    }
                }
            }
            if !style.startArrowheads.isEmpty {
                section(L("箭頭")) {
                    VStack(alignment: .leading, spacing: 6) {
                        arrowheadRow(.start, current: style.startArrowheads)
                        arrowheadRow(.end, current: style.endArrowheads)
                    }
                }
            }
            if !style.textColors.isEmpty {
                section(L("文字")) {
                    colors(Self.strokePalette, current: style.textColors) { editor.setStyle(.textColor($0)) }
                    HStack(spacing: 16) {
                        options(Self.fontSizes, current: style.fontSizes, set: { editor.setStyle(.fontSize($0)) }) { size in
                            Text(Self.fontSizes.first { $0.1 == size }?.0 ?? "")
                                .font(.system(size: 9 + size / 4, weight: .medium))
                        }
                        options(Self.textAligns.map { ($0.0, $0.1) }, current: style.textAligns,
                                set: { editor.setStyle(.textAlign($0)) }) { align in
                            Image(systemName: Self.textAligns.first { $0.1 == align }?.2 ?? "text.alignleft")
                        }
                    }
                }
            }
            if !style.opacities.isEmpty {
                section(L("透明度")) { opacity(style.opacities) }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: 元件

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func colors(_ palette: [String], current: Set<String>, set: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), alignment: .leading, spacing: 6) {
            ForEach(palette, id: \.self) { hex in
                Button { set(hex) } label: {
                    Swatch(hex: hex, selected: current == [hex])
                }
                .buttonStyle(.plain)
                .help(hex == "transparent" ? L("無") : hex)
                .accessibilityLabel(hex == "transparent" ? L("無") : hex)
            }
        }
    }

    /// 一排選項（圖示由 `label` 畫，名稱給 VoiceOver 與滑鼠提示）
    private func options<T: Hashable>(_ items: [(String, T)], current: Set<T>, set: @escaping (T) -> Void,
                                      @ViewBuilder label: @escaping (T) -> some View) -> some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.1) { title, value in
                Button { set(value) } label: {
                    label(value)
                        .frame(width: 34, height: 30)
                        .background(current == [value] ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(current == [value] ? Color.accentColor : .primary)
                .help(title)
                .accessibilityLabel(title)
            }
        }
    }

    private func arrowheadRow(_ end: ArrowEnd, current: Set<String>) -> some View {
        HStack(spacing: 6) {
            Text(end == .start ? L("起點") : L("終點")).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            options(Self.arrowheads.map { ($0.0, $0.1 ?? "") }, current: current,
                    set: { editor.setStyle(.arrowhead(end, $0.isEmpty ? nil : $0)) }) { kind in
                ArrowheadSample(kind: kind, end: end)
            }
        }
    }

    private func opacity(_ current: Set<Double>) -> some View {
        let value = draggingOpacity ?? (current.count == 1 ? current.first! : 100)
        return HStack(spacing: 10) {
            Slider(value: SwiftUI.Binding(get: { value }, set: { v in
                draggingOpacity = v
                editor.previewStyle(.opacity(v))
            }), in: 0...100, step: 10) { editing in
                if !editing {
                    draggingOpacity = nil
                    editor.endStylePreview()
                }
            }
            Text(current.count > 1 && draggingOpacity == nil ? L("混合") : "\(Int(value))")
                .font(.caption.monospacedDigit())
                .frame(width: 32, alignment: .trailing)
        }
    }
}

/// 色塊；`transparent` 畫成白底加一條斜線
private struct Swatch: View {
    let hex: String
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(hex == "transparent" ? Color.white : Color(cgColor: SceneColor.parse(hex) ?? CGColor(gray: 0, alpha: 0)))
            .overlay {
                if hex == "transparent" {
                    Path { p in p.move(to: CGPoint(x: 4, y: 26)); p.addLine(to: CGPoint(x: 26, y: 4)) }
                        .stroke(Color.red.opacity(0.8), lineWidth: 1.5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.15)))
            .frame(width: 30, height: 30)
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

private struct StrokeSample: View {
    let style: String

    var body: some View {
        Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 22, y: 1)) }
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: style == "dotted" ? .round : .butt,
                                       dash: style == "dashed" ? [5, 3] : style == "dotted" ? [0.1, 4] : []))
            .frame(width: 22, height: 2)
    }
}

/// 用渲染器的箭頭幾何畫示意圖，與畫布上一致
private struct ArrowheadSample: View {
    let kind: String
    let end: ArrowEnd

    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            let a = CGPoint(x: 3, y: y), b = CGPoint(x: size.width - 3, y: y)
            var line = Path()
            line.move(to: a); line.addLine(to: b)
            ctx.stroke(line, with: .foreground, lineWidth: 1.5)
            guard !kind.isEmpty else { return }
            let (tip, from) = end == .end ? (b, a) : (a, b)
            for head in ElementGeometry.arrowhead(kind, tip: tip, from: from, strokeWidth: 1.5) {
                let path = Path(head.path)
                if head.fill { ctx.fill(path, with: .foreground) }
                ctx.stroke(path, with: .foreground, lineWidth: 1.5)
            }
        }
        .frame(width: 28, height: 16)
    }
}
