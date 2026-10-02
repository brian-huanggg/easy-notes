import EasyNotesUI
import Foundation
import SwiftUI

/// 列表卡片的縮圖：第一個標題 + 之後的前幾行，去掉 Markdown 語法後原生渲染
struct MarkdownPreview: DocumentPreviewProvider {
    static let maxLines = 8

    func makePreview(_ data: Data) -> DocumentPreview {
        let body = Frontmatter.body(of: String(decoding: data, as: UTF8.self))
        var title: String?
        var lines: [String] = []
        var inCode = false
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inCode.toggle()
                continue
            }
            guard !inCode, !line.isEmpty else { continue }
            if title == nil, lines.isEmpty, line.hasPrefix("# ") {
                title = Self.clean(String(line.dropFirst(2)))
                continue
            }
            let text = Self.clean(line)
            if !text.isEmpty { lines.append(String(text.prefix(80))) }
            if lines.count == Self.maxLines { break }
        }
        return DocumentPreview(title: title, lines: lines)
    }

    @MainActor func view(_ preview: DocumentPreview, scale: CGFloat) -> AnyView {
        AnyView(TextPreview(title: preview.title, lines: preview.lines, scale: scale))
    }

    /// 只給人看：去掉行首標記、強調符號，`[[目標|別名]]` 顯示別名
    static func clean(_ line: String) -> String {
        var s = line
        let rules: [(String, String)] = [
            (#"^#{1,6}\s+"#, ""),                          // 標題
            (#"^>\s?(\[![a-zA-Z]+\][+-]?\s*)?"#, ""),      // 引言、callout
            (#"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?"#, ""),  // 清單、待辦
            (#"!?\[\[([^\]|\n]*)\|([^\]\n]*)\]\]"#, "$2"), // [[目標|別名]]
            (#"!?\[\[([^\]\n]*)\]\]"#, "$1"),              // [[目標]]
            (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),           // [文字](網址)、圖片
            (#"\*\*|__|~~|`|==|\s\^[\w-]+$"#, ""),         // 強調、code、區塊 id
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
