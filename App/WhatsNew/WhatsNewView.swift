import SwiftUI

/// 「新功能」視窗：依 Changelog 的章節列出該版的項目
struct WhatsNewView: View {
    let notes: WhatsNew
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L("EasyNotes \(notes.version) 的新功能"))
                        .font(.title.bold())
                    ForEach(notes.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.headline)
                            ForEach(section.items, id: \.self) { item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(Self.attributed(item))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("繼續")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(16)
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }

    /// 項目是 Markdown 行內語法（`程式碼`、**粗體**、連結）
    private static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
