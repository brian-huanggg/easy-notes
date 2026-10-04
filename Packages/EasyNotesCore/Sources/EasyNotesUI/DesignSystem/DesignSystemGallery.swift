import SwiftUI

/// 設計系統一覽：所有顏色 tokens 與共用元件，給 Xcode Preview 與截圖比對設計稿用。
/// 示範資料只在這裡，不代表任何外掛。
public struct DesignSystemGallery: View {
    @State private var chip = 0
    @State private var viewMode = 0
    @State private var tab = 0

    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Divider().overlay(Palette.border.color)
            VStack(alignment: .leading, spacing: 26) {
                toolbar
                header
                cards
                HStack(alignment: .top, spacing: 32) {
                    mobile
                    VStack(alignment: .leading, spacing: 20) {
                        swatches
                        bars
                        EmptyState("This folder is empty", message: "Drop files here, or create something new in this folder.",
                                   symbol: "folder", style: .dropZone) {
                            Button(String("New Note"), systemImage: "doc.text") {}.buttonStyle(.enPrimary)
                            Button(String("New Whiteboard"), systemImage: "scribble") {}.buttonStyle(.enSecondary(size: .large))
                        }
                    }
                }
            }
            .padding(Metrics.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bgPanel)
        }
        .background(Palette.bgCanvas)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                VaultHeader(name: "My Vault", account: "me@example.com")
                SearchFieldButton("Search", shortcut: "⌘K") {}
            }
            VStack(spacing: 2) {
                SidebarItem("All Documents", symbol: "doc.on.doc", count: 24, isSelected: true)
                SidebarItem("Recents", symbol: "clock.arrow.circlepath")
                SidebarItem("Pinned", symbol: "pin", count: 5)
            }
            VStack(spacing: 2) {
                SidebarGroupLabel("Spaces", actionSymbol: "plus", actionHelp: "New Folder") {}
                SidebarItem("Work", symbol: "folder", count: 12)
                SidebarItem("Roadmap 2026", symbol: "doc.text", symbolTint: KindTint.neutral.base, indent: 1)
                SidebarItem("Idea Dump", symbol: "scribble", symbolTint: KindTint.violet.base, indent: 1)
                SidebarItem("Research", symbol: "folder", count: 7)
            }
            VStack(spacing: 2) {
                SidebarGroupLabel("Tags")
                SidebarItem("reading", symbol: "number", count: 14)
            }
            Spacer(minLength: 0)
            StatusRow("Synced", detail: "2 min ago", symbol: "checkmark.icloud", tint: Palette.cardDue)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(width: Metrics.sidebarWidth)
        .background(Palette.bgSidebar)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            IconButton("sidebar.left", help: "Sidebar") {}
            IconButton("chevron.left", help: "Back") {}
            IconButton("chevron.right", help: "Forward") {}
            Breadcrumb(["Work", "Roadmap 2026"])
            Pill("Saved", symbol: "icloud")
            Spacer()
            IconSegmentedControl(selection: $viewMode, segments: [
                .init(0, symbol: "square.grid.2x2", help: "Grid"),
                .init(1, symbol: "list.bullet", help: "List"),
            ])
            Button(String("Recently edited"), systemImage: "arrow.up.arrow.down") {}.buttonStyle(.enSecondary)
            Button(String("New Document"), systemImage: "plus") {}.buttonStyle(.enPrimary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: "All Documents").textStyle(.pageTitle).foregroundStyle(Palette.textPrimary)
                Text(verbatim: "24 documents · 4 folders").textStyle(.pageSubtitle).foregroundStyle(Palette.textTertiary)
            }
            HStack(spacing: 6) {
                ForEach(Array(["All", "Notes", "Boards", "PDFs", "Sheets"].enumerated()), id: \.offset) { i, title in
                    FilterChip(title, symbol: i == 0 ? nil : ["doc.text", "scribble", "doc.richtext", "tablecells"][i - 1],
                               tint: i == 0 ? nil : KindTint.presets[i - 1].base, isSelected: chip == i) { chip = i }
                }
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Pinned", symbol: "pin", detail: "4", actionTitle: "See all") {}
            HStack(alignment: .top, spacing: Metrics.gridSpacing) {
                DocCard("Product Roadmap 2026", symbol: "doc.text", tint: .neutral, meta: "1,240 words · 2h ago",
                        badge: PreviewBadge("Pinned", symbol: "pin")) {
                    TextPreview(title: "Product Roadmap 2026", lines: [
                        "Three outcomes this year: sync that never loses data,",
                        "a writing surface that feels native, and flashcards",
                        "that schedule like Anki.", "Q1 — Sync and conflict copies",
                    ])
                }
                DocCard("Idea Dump", symbol: "scribble", tint: .violet, meta: "32 strokes · 4h ago") {
                    ThumbBoard(tint: .violet)
                }
                DocCard("Research: Note Taking", symbol: "doc.richtext", tint: .red, meta: "18 pages · 2d ago") {
                    ThumbPDF(tint: .red, pages: 18)
                }
                DocCard("Q4 Goals & OKRs", symbol: "tablecells", tint: .green, meta: "86 rows · 1h ago") {
                    ThumbTable(tint: .green)
                }
            }
        }
    }

    private var mobile: some View {
        VStack(alignment: .leading, spacing: 14) {
            SearchFieldButton("Search documents", size: .mobile) {}
            SectionHeader("Pinned", symbol: "pin", detail: "4", size: .mobile, actionTitle: "See all") {}
            HStack(spacing: 12) {
                DocCard("Product Roadmap", symbol: "doc.text", tint: .neutral, meta: "2h ago", size: .compact)
                DocCard("Design Principles", symbol: "scribble", tint: .violet, meta: "Yesterday", size: .compact)
            }
            SectionHeader("Recent", symbol: "clock.arrow.circlepath", detail: "Today", size: .mobile)
            VStack(spacing: 4) {
                DocRow("Daily Note — Oct 1", symbol: "doc.text", tint: .neutral, meta: "Edited 20m ago · 120 words")
                DocRow("Q4 Goals & OKRs", symbol: "tablecells", tint: .green, meta: "CSV · 86 rows · 1h ago")
            }
            DocRow("Beta Launch Plan", symbol: "doc.text", tint: .neutral, meta: "Updated today", style: .card)
            TabBar(selection: $tab, items: [
                .init(0, title: "Docs", symbol: "doc.text"),
                .init(1, title: "Search", symbol: "magnifyingglass"),
                .init(2, title: "Spaces", symbol: "square.stack.3d.up"),
                .init(3, title: "Me", symbol: "person.crop.circle"),
            ])
        }
        .frame(width: 350)
    }

    private var swatches: some View {
        let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 14)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Palette.all + KindTint.presets.flatMap { [$0.base, $0.soft] }, id: \.name) { token in
                RoundedRectangle(cornerRadius: 5).fill(token)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.border))
                    .frame(width: 28, height: 28)
                    .help(token.name)
            }
        }
    }

    private var bars: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormatBar([
                ToolItem("textformat", help: "Text") {},
                ToolItem("checklist", help: "Checklist") {},
                ToolItem("photo", help: "Image") {},
                ToolItem("tablecells", help: "Table") {},
            ], style: .floating)
            FormatBar([
                ToolItem("textformat", help: "Text") {},
                ToolItem("checklist", help: "Checklist") {},
                ToolItem("photo", help: "Image") {},
                ToolItem("tablecells", help: "Table") {},
            ], style: .keyboard, dismiss: ToolItem("keyboard.chevron.compact.down", help: "Hide Keyboard") {})
            .frame(width: 350)
        }
    }
}

#Preview("Light") {
    DesignSystemGallery().environment(\.colorScheme, .light).frame(width: 1440)
}

#Preview("Dark") {
    DesignSystemGallery().environment(\.colorScheme, .dark).frame(width: 1440)
}

#Preview("Empty Vault") {
    EmptyState("Your vault is empty",
               message: "Everything you create lives as a plain file on disk. Start with a note or a whiteboard.",
               symbol: "doc.badge.plus") {
        Button(String("New Note"), systemImage: "doc.text") {}.buttonStyle(.enPrimary(size: .large))
        Button(String("New Whiteboard"), systemImage: "scribble") {}.buttonStyle(.enSecondary(size: .large))
    }
    .frame(width: 800, height: 600)
    .background(Palette.bgPanel)
}
