import SwiftUI

// 卡片縮圖（放在 PreviewFrame 內）。元件不認識檔案類型：顏色由呼叫端傳入外掛註冊的 KindTint。

/// 文字文件的真實預覽：標題 + 前幾行（設計稿 Doc Card 的 Preview Lines 換成真實文字）
public struct TextPreview: View {
    let title: String?
    let lines: [String]
    let scale: CGFloat

    public init(title: String?, lines: [String], scale: CGFloat = 1) {
        self.title = title
        self.lines = lines
        self.scale = scale
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                    .padding(.bottom, 2 * scale)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 8.5 * scale))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(15 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

/// 設計稿 `C/Thumb Board`：點狀格線 + 便利貼、方框、圓、連接線、手寫線
public struct ThumbBoard: View {
    let tint: KindTint
    let scale: CGFloat

    public init(tint: KindTint, scale: CGFloat = 1) {
        self.tint = tint
        self.scale = scale
    }

    public var body: some View {
        Canvas { context, size in
            let s = scale
            var y: CGFloat = 14 * s
            while y < size.height {
                var x: CGFloat = 16 * s
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2 * s, height: 2 * s)), with: .style(Palette.borderStrong))
                    x += 20 * s
                }
                y += 20 * s
            }
            let base = GraphicsContext.Shading.style(tint.base)
            var connector = Path()
            connector.move(to: CGPoint(x: 60 * s, y: 52 * s))
            connector.addCurve(to: CGPoint(x: 118 * s, y: 86 * s), control1: CGPoint(x: 100 * s, y: 52 * s),
                               control2: CGPoint(x: 112 * s, y: 60 * s))
            context.stroke(connector, with: base, lineWidth: 1.5 * s)

            let note = Path(roundedRect: CGRect(x: 22 * s, y: 27 * s, width: 49 * s, height: 43 * s), cornerRadius: 3 * s)
            context.drawLayer { layer in
                layer.rotate(by: .degrees(4))
                layer.fill(note, with: .style(Palette.yellow))
            }
            let box = Path(roundedRect: CGRect(x: 104 * s, y: 76 * s, width: 62 * s, height: 40 * s), cornerRadius: 6 * s)
            context.fill(box, with: .style(tint.soft))
            context.stroke(box, with: base, lineWidth: 1.5 * s)
            context.stroke(Path(ellipseIn: CGRect(x: 166 * s, y: 26 * s, width: 44 * s, height: 44 * s)),
                           with: base, lineWidth: 1.5 * s)

            var ink = Path()
            ink.move(to: CGPoint(x: 36 * s, y: 124 * s))
            ink.addCurve(to: CGPoint(x: 64 * s, y: 116 * s), control1: CGPoint(x: 46 * s, y: 104 * s),
                         control2: CGPoint(x: 52 * s, y: 132 * s))
            ink.addCurve(to: CGPoint(x: 92 * s, y: 110 * s), control1: CGPoint(x: 74 * s, y: 102 * s),
                         control2: CGPoint(x: 82 * s, y: 124 * s))
            context.stroke(ink, with: .style(Palette.textSecondary),
                           style: StrokeStyle(lineWidth: 1.5 * s, lineCap: .round))
        }
        .background(Palette.bgPanel)
    }
}

/// 設計稿 `C/Thumb PDF`：灰底上的一頁紙、左上類型標記、右上頁數
public struct ThumbPDF: View {
    let tint: KindTint
    let badge: String
    let pages: Int?
    let scale: CGFloat

    public init(tint: KindTint, badge: String = "PDF", pages: Int? = nil, scale: CGFloat = 1) {
        self.tint = tint
        self.badge = badge
        self.pages = pages
        self.scale = scale
    }

    public var body: some View {
        let s = scale
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(Palette.textTertiary).frame(width: 58 * s, height: 7 * s)
                Rectangle().fill(Palette.border).frame(height: 1).padding(.vertical, 5 * s)
                VStack(alignment: .leading, spacing: 4.5 * s) {
                    ForEach([88, 82, 88, 74, 88, 86, 60] as [CGFloat], id: \.self) { width in
                        Capsule().fill(Palette.skeleton).frame(width: width * s, height: 4 * s)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12 * s)
            .frame(width: 112 * s, height: 140 * s, alignment: .topLeading)
            .background(UnevenRoundedRectangle(topLeadingRadius: 3 * s, topTrailingRadius: 3 * s).fill(Palette.surfaceRaised))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 3 * s, topTrailingRadius: 3 * s).strokeBorder(Palette.borderStrong))
            .padding(.top, 14 * s)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            Text(badge)
                .font(.system(size: 9 * s, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6 * s)
                .padding(.vertical, 3 * s)
                .background(RoundedRectangle(cornerRadius: 4 * s).fill(tint.base))
                .padding(14 * s)
        }
        .overlay(alignment: .topTrailing) {
            if let pages {
                Label("\(pages)", systemImage: "square.on.square")
                    .font(.system(size: 10 * s))
                    .foregroundStyle(Palette.textSecondary)
                    .labelStyle(.titleAndIcon)
                    .padding(.top, 16 * s)
                    .padding(.trailing, 32 * s)
            }
        }
        .background(Palette.bgHover)
    }
}

/// 設計稿 `C/Thumb CSV`：類型色的表頭 + 灰條儲存格
public struct ThumbTable: View {
    let tint: KindTint
    let columns: [String]
    let scale: CGFloat

    public init(tint: KindTint, columns: [String] = ["name", "qty", "price", "date"], scale: CGFloat = 1) {
        self.tint = tint
        self.columns = columns
        self.scale = scale
    }

    public var body: some View {
        let s = scale
        let widths: [[CGFloat]] = [[38, 34, 38, 38], [38, 28, 38, 38], [38, 32, 36, 34], [38, 36, 38, 38], [38, 30, 38, 36], [38, 34, 38, 32]]
        VStack(spacing: 0) {
            row(height: 22 * s, fill: tint.soft) { index in
                Text(columns[safe: index] ?? "")
                    .font(.system(size: 8.5 * s, weight: .semibold))
                    .foregroundStyle(tint.base)
            }
            ForEach(widths.indices, id: \.self) { r in
                row(height: 18 * s, fill: nil) { c in
                    Capsule().fill(Palette.skeleton).frame(width: widths[r][c] * s, height: 4 * s)
                }
            }
            Spacer(minLength: 0)
        }
        .background(Palette.bgCanvas)
    }

    private func row(height: CGFloat, fill: ColorToken?, @ViewBuilder cell: @escaping (Int) -> some View) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                cell(index)
                    .padding(.horizontal, 8 * scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) { Rectangle().fill(Palette.border).frame(width: 1) }
            }
        }
        .frame(height: height)
        .background(fill ?? ColorToken.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
