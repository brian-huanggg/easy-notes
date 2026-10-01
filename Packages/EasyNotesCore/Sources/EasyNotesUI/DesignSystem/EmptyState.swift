import SwiftUI

/// 空狀態。`.page`：整頁置中（空 Vault `xGsaX`）；`.dropZone`：有邊框的拖放區（空資料夾 `m4Bb4`）。
/// 按鈕由呼叫端提供（通常來自 Registry 的 New File 指令），元件本身不認識任何檔案類型。
public struct EmptyState<Actions: View>: View {
    public enum Style: Sendable { case page, dropZone }

    let title: String
    let message: String
    let symbol: String
    let style: Style
    let actions: Actions

    public init(_ title: String, message: String, symbol: String, style: Style = .page,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.style = style
        self.actions = actions()
    }

    public var body: some View {
        switch style {
        case .page:
            VStack(spacing: 0) {
                StackedPages(symbol: symbol).padding(.bottom, 26)
                Text(title).textStyle(.emptyTitle).foregroundStyle(Palette.textPrimary)
                Text(message)
                    .textStyle(.emptyMessage)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 10)
                HStack(spacing: 8) { actions }.padding(.top, 22)
            }
            .padding(32)
        case .dropZone:
            let shape = RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Palette.textTertiary)
                Text(title).textStyle(TextStyle(15, .semibold)).foregroundStyle(Palette.textPrimary)
                Text(message).textStyle(.control.regular).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) { actions }.padding(.top, 8)
            }
            .padding(.vertical, 34)
            .padding(.horizontal, 28)
            .frame(maxWidth: 420)
            .background(shape.fill(Palette.bgCanvas))
            .overlay(shape.strokeBorder(Palette.borderStrong))
        }
    }
}

private extension TextStyle {
    var regular: TextStyle { TextStyle(size, .regular, lineHeight: lineHeight, tracking: tracking, uppercase: uppercase) }
}

/// 空 Vault 的插圖：兩張略微旋轉的紙疊在一起，中間是圖示
private struct StackedPages: View {
    let symbol: String

    var body: some View {
        ZStack {
            page.rotationEffect(.degrees(-6)).offset(x: -18, y: 6)
            page.rotationEffect(.degrees(5)).offset(x: 18, y: 2)
            page.overlay(Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(Palette.textSecondary))
        }
        .frame(width: 130, height: 100)
    }

    private var page: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return shape.fill(Palette.surfaceRaised)
            .overlay(shape.strokeBorder(Palette.border))
            .frame(width: 74, height: 90)
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}
