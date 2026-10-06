# Shell, Lists and Editor (UI)

The shell follows `design/easy-notes-ui.pen`; the design file does not change the data model or plugin boundaries.

## Mapping from the design file to the EasyNotes model

| Design | EasyNotes counterpart |
| --- | --- |
| Sidebar vault header (name + account) | A single vault, not switchable; the account comes from Supabase Auth |
| Spaces | First-level folders of the vault root; `+` = new first-level folder |
| All Documents / Recents | The index's `files` table, ordered by `mtime` |
| Pinned (same concept in sidebar and list page) | frontmatter `pinned: true` (syncs with the file, readable and writable by Claude Code) |
| Tags | The existing tag index |
| Filter All / Notes / Boards / PDFs / Sheets | Generated from the Kinds registered in the Registry; plugins that are not implemented are not shown |
| Type colors `type-doc` / `type-board` / `type-pdf` / `type-csv` | Plugins provide the color when registering a Kind; the App hardcodes nothing |
| Card thumbnail and subtitle ("CSV · 86 rows", "PDF · 18 pages") | Each plugin's DocumentPreviewProvider produces the thumbnail and a one-line summary |
| New Document menu (⌘N, ⇧⌘N, import PDF / CSV, new folder) | `addNewFile` plus `addImport` (copies an external file into the vault) |
| Document icon, cover, tags | frontmatter `icon`, `cover` (image path in the vault), `tags` |
| Review | Registered by the Flashcards plugin with `addPanel`; hidden when not registered |
| Recently Deleted (kept 30 days) | "Recently Deleted" |
| Synced · 2 min ago | Sync status (synced / pending upload / conflict) |
| Folder icon (`folder-open`) | Reveal in Finder (iOS: show in the Files app) |
| Me (Mobile tab) | Account, sync panel, settings |

## Design system

- Pen variables (`mode: light / dark`) become `EasyNotesUI/DesignSystem/`: `Palette`, `KindTint`, `TextStyle`, `Metrics`, `ThemeCSS` and shared components (Sidebar Item, Icon Button, Doc Card, Doc Row, Pin Card, Tab Bar, empty state). Type colors are provided by plugins when they register a Kind; the App and list pages only read the Registry.
- The same tokens are emitted as CSS variables by `ThemeCSS.stylesheet()`; WebEditorHost injects them into CM6 as a user script before the page loads (not through the Bridge); the WebView follows the system light / dark mode by itself.
- Fonts: Pen does not support Apple fonts, so the design uses Inter as a stand-in (`font-ui`, `font-doc`, `font-cjk`). The implementation always uses system fonts: SF Pro for Latin text and PingFang TC for Chinese (SwiftUI default; CM6 uses `-apple-system`); Inter is not bundled; sizes, weights and line heights follow the design.
- `DesignSystemGallery` can render screenshots in an Xcode Preview or with `EASYNOTES_SNAPSHOT_DIR=… swift test` for comparison with the design.

## Shell and navigation

- **Accessibility identifiers**: shell elements that E2E operates or inspects (sidebar items and file tree, list documents and filters, toolbar, menu items, ⌘K, editor container) carry an `A11yID` identifier (`App/Support/UITestContract.swift`). A container uses `.accessibilityElement(children: .contain)` before getting its identifier, otherwise it would hide its children's identifiers. Add one whenever you add such an element.
- Navigation = `Route` (all documents / recents / pinned / folder / tag / file / plugin panel) plus back / forward history (⌘[ / ⌘]); the app opens on all documents. iPhone uses bottom tabs (Docs / Search / Spaces / Me) instead of a collapsing `NavigationSplitView`.
- **Tabs (Mac / iPad, not iPhone)**: a tab bar above the content area (`DocumentTabBar`, shown only with more than one tab). `TabSet<State>` (EasyNotesUI, generic, pure logic) manages only the tab list and the current tab; `VaultStore`'s `TabState` = location + that tab's own back / forward, and the current tab's values stay in sync with `route`, `backStack` and `forwardStack` (didSet). **Background tabs do not hold an editor**: switching = loading that tab's `Route` with the existing editor lifecycle (Markdown swaps `EditorState`, other plugins rebuild), so the tab count does not affect memory.
  - Opening a file (sidebar, list, ⌘K, `[[link]]`, new, import) opens it in a new tab by default (right of the current tab); a file already open in a tab is switched to instead of duplicated. Folders, tags, lists and plugin panels navigate within the current tab with normal history.
  - Rename / move updates all tabs; deleting a file or folder closes background tabs pointing to it and the current tab goes up one level. Closing the last tab = replace with "All Documents". After closing a file tab, if nothing else has it open, the editor is told to drop its retained state.
  - The tab list is stored in `UserDefaults` (per device, not in the vault, not synced), location only and no history; it is restored the first time SplitShell shows on the next launch, skipping files that no longer exist. E2E (`-EasyNotesVaultRoot`, `-EasyNotesOpen`) neither restores nor keeps it.
  - Shortcuts: ⌘T new tab, ⌘W close the tab (with only one tab, closes the window on Mac), ⌥⌘W close the window (Mac), ⇧⌘] / ⇧⌘[ next / previous tab, ⌘S sync now (`SyncCoordinator.syncNow`: flush editors, then sync immediately).
- **Configurable shortcuts (Mac only; iOS has none)**: the App-level menu actions (new / close tab, close window, sync now, quick open, back / forward, next / previous tab) are `ShortcutAction`s with a default `ShortcutBinding`; user overrides live in `UserDefaults` (`ShortcutStore`, per device, not synced) and menus read them through `.shortcut(_:)`. Settings > Keyboard Shortcuts records a new combination (needs ⌘, ⌃ or ⌥; a combination already used by another action is rejected; Esc cancels). Plugin menu shortcuts (new note, find, …) stay fixed.
- Plugins add sidebar items with `addPanel`; the App hardcodes none. The backlinks inspector was removed (the index still keeps backlink data).
- Interface language follows the system between zh-Hant and English (US); see [translation.md](./translation.md).
- Shortcuts: ⌘K quick open (reuses FTS5 search), Markdown "[[link]]" ⇧⌘K, new note ⌘N, new whiteboard ⇧⌘N, new folder ⇧⌘F.
- Sidebar file tree: on Mac, double-clicking a file or folder renames it in place (Return confirms, Esc cancels, losing focus confirms; for files only the name changes and the extension is kept); the context-menu "Rename" is still a dialog. Files and folders can be dragged to another folder, and dragging onto the "Spaces" header = move to the vault root; moving does not change the file name, so `[[links]]` need no rewriting; nothing moves when the destination has an item with the same name or a folder is dragged into itself (including its subfolders). Companions, sync (file id preserved), editor and navigation are handled the same as rename. The drag payload is a vault-relative path string, and the drop checks the path exists before moving.
- The import destination = the current folder (folder page = that folder, editor = the document's folder, other list pages = vault root); there is no separate `Inbox/`.

## Document list

- **Pinned is stored in frontmatter `pinned: true`**: Claude Code can read and write it directly and `.easynotes/` need not sync. `DocumentKind.setPinned` defaults to nil = unsupported, and the list's "Pin" menu appears only for supporting types; after writing, the App restores mtime so pinning does not push the document to the top of "Recents". The whiteboard will store it in `customData` later; PDF and others are handled when they get there. Pinning adds frontmatter to an md without one, so CM6 collapses it into a one-line property row when the cursor is not inside the block.
- `IndexEntry`'s `icon`, `pinned` and `summary` (a plugin provides a one-line summary; Core does not understand "word count"); the index also stores the content `hash` as the preview-cache key.
- `addKind(..., name:)` supplies the filter chip's name; Mobile and Desktop filters are the same (All + registered types).
- List documents and folders have a hover state: cards darken the border and lift, rows get `bg-hover`, the cursor becomes a pointing hand; iPad pointer uses the system highlight.

## Editor document header and toolbar

- **The header is CM6 decorations**: the cover + icon is a block widget at the start of the file; the title is simply the first `#` line (ordinary text, so composition is unaffected and the indexing rule is unchanged); the meta row (tags, "edited N minutes ago", no reading time) is a block widget after the title line. The raw YAML shows only when the cursor enters the frontmatter.
- **Cover** `cover: Attachments/xxx.jpg` (vault path): an image chosen from outside the vault (including pasted from the clipboard) is copied to the root `Attachments/`, with a number appended on name collision. The legacy `附件/` folder is neither moved nor are its links rewritten: when `vault://` finds no file in `Attachments/` it looks in `附件/`, so name-only `![[x.png]]` and legacy links that spell out `附件/` still display. Changing the cover / icon goes through the normal write path (updates mtime, enters sync), unlike pinning. Images are read through `vault://` and only vault paths are allowed.
- **Icon** supports emoji and SF Symbols (Lucide is not bundled): `icon: 🗺` or `icon: sf:map`; Core stores only the string. The picker is "Icons | Emoji"; Apple has no API listing all SF Symbols, so a common list is built in and the search box also accepts a full name; a nonexistent name shows the type's default icon. In list cards, an emoji is placed before the title and an SF Symbol replaces the type icon; the editor shows it through `symbol:///<name>`. Outside the app (for example in Obsidian) only the text `sf:` is visible.
- **Link cards**: a `[[link]]` alone on a line renders as a card (with the target's type icon), adjacent ones side by side; the design's "related pages" is this inline style, not an auto-generated block. The target's type, summary and time are passed as `LinkTarget` by `EditorController.linkTargetsChanged`; the WebView has no SF Symbols, so Swift draws the icon as a PNG from the Registry's symbol.
- **Toolbar**: the floating format toolbar (Desktop) and the iOS Format Bar share `FormatBar`, native SwiftUI, sending `exec` on press, off the typing path; the editor toolbar (save status, pin, more) lives in the App and is shared by all file types.

## Ink toolbar (shared by whiteboard and PDF, GoodNotes style)

- **Two layers**: the top row (below the navigation bar, `safeAreaInset(edge: .top)`) holds the tools; when a pen-type tool is selected, a capsule floats below it (pen kind, width, color), along with an Undo / Redo capsule on the left. The floating bars sit over the content without changing the canvas inset, so the view does not jump when switching tools, and empty areas let touches through. Tapping the already selected tool again collapses / restores the capsule.
- **Top row layout**: tools are centered, and actions related to the current selection or document go on the right (whiteboard style / duplicate / delete, PDF export). The tools in order are "Select (leave ink) | Pen, Highlighter, Eraser, Lasso | the plugin's own insert tools".
- **No `PKToolPicker`**: the system tool palette is a floating panel whose position and style cannot be embedded in a toolbar. Instead, the shared EasyNotesUI components set `PKCanvasView.tool` themselves:
  - `InkSettings` (`@Observable`, `@MainActor`, singleton): the current ink tool (pen / highlighter / eraser / lasso), pen kind, each tool's color and width, user-added colors. Stored in `UserDefaults` (app preference, not in the vault, not synced) and shared by whiteboard and PDF: a pen chosen in PDF is the same pen on the whiteboard. Whether ink mode is on is still remembered by each editor (whiteboard `BoardEditor.inking`, the PDF viewer's state).
  - **Pen kinds**: fountain pen (`pen`), ballpoint (`monoline`), pencil (`pencil`); the highlighter is `marker`. Only these four inks are used (other inks distort when saved as freedraw).
  - **Width**: three steps, the ink's `defaultWidth` × 0.5 / 1 / 2 (clamped to `validWidthRange`), remembered per tool.
  - **Color**: 5 presets per tool plus user-added colors ("+" opens the system color picker, at most 5, long-press to delete). Pen presets `#1e1e1e`, `#1971c2`, `#e03131`, `#2f9e44`, `#f08c00`; highlighter `#ffd43b`, `#69db7c`, `#74c0fc`, `#f783ac`, `#ffa94d` (opacity is determined by the `marker` ink itself). The canvas is always light, so colors do not invert in dark mode.
  - **Eraser**: whole stroke (`vector`) / partial (`bitmap`, three widths). Strokes split by partial erasing are still ordinary `PKStroke`s and are saved as freedraw as usual.
  - The `PKToolPicker` ruler is no longer offered: straight lines use "hold to straighten".
- **Pencil double-tap** (`UIPencilInteraction`, replacing the tool palette's behavior): follows the system setting; "switch eraser" = eraser ⇄ previous tool, "switch previous tool" = swap with the previous tool, "show color palette" = collapse / restore the capsule; not handled outside ink mode.
- **Hold to straighten (Apple Notes / GoodNotes style)**: after drawing a stroke, if the pen tip holds for about 0.5 s (moving < 3 points), the stroke becomes a straight line "start → current position"; keep the pen down to move the end point, which snaps when the angle is near horizontal, vertical or 45° (±3°). Implemented in EasyNotesUI's `StraightLineAssist` (iOS), attached to each of the whiteboard's and PDF's `PKCanvasView`:
  - Touches come from an observe-only gesture recognizer that does not intercept (`cancelsTouchesInView = false`, recognized simultaneously with all gestures), considering only touches the `drawingPolicy` allows to write and acting only for pen / highlighter. A stroke shorter than 12 points does not trigger (a tap-and-hold never becomes a line).
  - On trigger, `drawingGestureRecognizer` is disabled and re-enabled to cancel PencilKit's in-progress stroke; if PencilKit still leaves the stroke after cancelling, the `drawing` is restored to what it was at the start. While adjusting, a `CAShapeLayer` above the canvas previews the line (same color and width as the ink), and only on release is the straight-line `PKStroke` (same ink, color and width, one control point every 2 points along the line) added to the `drawing`.
  - `drawing` changes during adjustment are not written back (the host checks `isAdjusting`); only the change after release is, so the model sees just "one more straight line" and PDF's model undo is one step. The line registers one Undo on the canvas `undoManager` (restoring the `drawing` before the line was added): the whiteboard shares that stack with strokes; PDF's canvas `undoManager` is private and is discarded as before, with the model undo responsible.
  - Coordinates: canvas coordinates = the touch position in `PKCanvasView` ÷ `zoomScale` (the whiteboard canvas zooms; PDF's canvas does not scroll and stays at 1×).
- **Mac**: no PencilKit writing, so the whiteboard toolbar hides the ink tools (only select and insert tools); PDF keeps its bottom-right buttons.
