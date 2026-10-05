# Changelog

All notable changes to this project are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-10-05

### Added

- Tables are directly editable: click a cell to type (bold, links and other inline formatting still render inside cells), Tab / Enter moves to the next cell and adds a row at the end automatically; the "+" at the right and bottom of a table adds columns and rows, and a cell's "⋯" menu inserts, moves and deletes rows and columns and sets alignment.
- Math: LaTeX support, with `$…$` for inline math and `$$…$$` for display math; moving the cursor into a formula shows the source and a live preview.
- Property panel: a note's frontmatter shows below the title, where you can edit values, rename properties, switch types (text, list, checkbox, date), and add or delete properties; tags render as tag chips and a click opens that tag. A note with no properties can start from "Add property" in the document header.
- Cards support Markdown and LaTeX math (no HTML needed): `**bold**`, `*italic*`, `~~strikethrough~~`, `==highlight==`, `` `code` ``, links, inline math `$E=mc^2$` and centered display math `$$…$$`; the review screen and card browser show the typeset result directly, and a cloze can hide a whole formula. When exporting to Anki, formulas are converted to Anki's MathJax format.
- New toolbar for whiteboard and PDF (GoodNotes style): tools are centered in one row (select, pen, highlighter, eraser, lasso and insert tools); after choosing a pen an options bar floats below, offering fountain pen / ballpoint / pencil, three widths and colors, plus "+" to add custom colors (long-press to delete); Undo / Redo moved to a floating button at the lower left. Pen settings are shared between whiteboard and PDF and remembered across launches. Double-tapping Apple Pencil switches the eraser or the previous tool.
- After drawing a stroke, holding still for about half a second turns it into a straight line; keep the pen down to adjust the end point, which snaps when near horizontal, vertical or 45° (whiteboard and PDF).
- Multi-line cards: when a list item ends with ` ::` (or ` ;;`), the indented child items below belong to the same card and can contain lists, paragraphs and code blocks; a line with only `::` separates front and back, a cloze can be on any line, and content after the divider shows only on the back. Cards can also include images `![[x.png]]`, and a cloze can hide a whole piece of inline code. Lists, code and image positions are preserved when exporting to Anki.
- Import from Anki: "Import from Anki" at the top of the review page takes an `.apkg`; decks become folders and cards become notes (preserving lists, images, formulas and clozes), with review logs and due dates carried over; a summary and skipped items (image occlusion, custom note types) are shown before importing, and re-importing creates no duplicate cards.
- Tables (CSV / TSV) get a toolbar and formula bar on top: the toolbar offers undo / redo, insert or delete rows and columns, sort by this column, freeze first column, and toggle first row as header; the formula bar shows the current cell's position and full content (including line breaks), suited to editing long text, with Enter to write, ⇧Enter for a newline and Esc to cancel. A status bar below shows row and column counts, and with several cells selected shows average, count and sum.
- Find in note: press ⌘F to open a search bar above the editor that highlights all matches and shows "n of m"; Enter / ⇧Enter jumps to next / previous, case sensitivity can be toggled, and Esc closes it.
- Table rows and columns can be reordered by dragging: a handle appears when hovering the left of a row or above a column name; drag to the desired position and release; a click on the handle opens that row or column's menu.
- When the cursor is inside inline math (`$…$`), a preview of the formula floats below.
- Multiple tabs (Mac / iPad): notes, whiteboards, PDFs and tables open in a new tab by default, and a file that is already open is switched to; ⌘T new tab, ⌘W close, ⇧⌘[ / ⇧⌘] switch, and the context menu closes other tabs. Reopening the app restores the last tabs.
- Audio in cards (`![[x.mp3]]`, including `[sound:]` imported from Anki) shows a play button, one click plays and another stops; mp3, m4a, wav, aac, ogg and flac are supported.
- macOS auto-update: the app checks GitHub for new versions, and "Check for Updates…" in the "EasyNotes" menu checks manually; updates are signature-verified.
- "What's New" window: the first launch after an update lists this version's changes, and it can be reopened from "What's New…" in the Help menu.

### Changed

- Ink tools use the new toolbar and no longer show the system floating tool palette; the whiteboard ink tools no longer offer a ruler (hold to straighten instead).
- The editor keeps cursor and undo history only for the 20 most recent notes and drops those not on screen when system memory is low, reducing memory use when many notes are open.

### Fixed

- After importing from Anki, newly created folders (spaces) did not appear in the sidebar until the app was restarted.
- The "Import from Anki" button and sheet, the ink toolbar (pen, eraser, colors, undo / redo) and the side-panel buttons were untranslated in the English interface.
- Typing `$$` and a newline immediately rendered that line as a blank formula with no visible source; a formula with no closing `$$` now stays as source, and a newline automatically adds the closing `$$`.

## [1.1.0] - 2026-10-05

### Added

- Custom Study: raise a deck's new / review limit for today (synced to other devices), review cards forgotten in the last few days, or review cards due within the next few days early. Open it from the "Custom Study" button at the top of the review page or a deck's context menu.
- Card browser: lists the cards of all decks or one deck, with filtering by state, text or tag search, and sorting by due date or lapses; notes can be opened directly, and cards suspended / resumed or reset.
- Export to Anki: exports all cards or one deck's cards as text files Anki can import (one file each for basic, bidirectional and cloze), preserving decks, tags and formatting such as bold; re-importing updates the existing cards.
- Whiteboard note cards: the toolbar's "Note card" puts any file in the vault onto the whiteboard; double-click a card to open it in a side panel (Mac / iPad), the card shows the file's title and first few lines with its height following the content (no longer auto-adjusted after a manual resize), the card title and link follow when the note is renamed, and on excalidraw.com it shows as a box with a link.
- macOS sidebar: double-click a file or folder to rename it in place; files and folders can be dragged to another folder, and dragging onto the "Spaces" header moves them to the top level.
- English support: the interface follows the system language; on macOS the language can be chosen in Settings (⌘,) and takes effect after a restart; the first-launch sample notes are also generated by language.

### Fixed

- A note with many `[[` (for example pasted gibberish) no longer freezes indexing and previews for tens of seconds; syncing an oversized file that both sides rewrote heavily now leaves a conflict copy instead of hanging sync.
- Clicking a `[[link]]` containing `../` no longer creates the new note outside the vault.
- Sync checks cloud data more strictly: files whose path points outside the vault are skipped, and downloaded content whose hash does not match the record is no longer applied.
- ⌘K quick open: after typing a keyword the result list could still show stale documents from the "Recents" list, and clicking opened the wrong file.
- The "Start Review" button now turns gray when all of today's cards are done.
- When sync received another device's change, text typed during the few seconds of the download could be overwritten.
- When using Zhuyin input and a sync or external change arrived at that moment, Zhuyin symbols could be left in the note and the chosen characters land elsewhere.
- Modifying the same file with an external tool such as Claude Code while a note, whiteboard or table was open could overwrite the external change or freshly typed text; both are now preserved.
- Editing a Windows line-ending (CRLF) note in the app changed the line endings of the whole file.
- When two devices created a file with the same name (for example "Untitled") almost at the same time, one could be overwritten by the other; it is now kept as a conflict copy.

## [1.0.0] - 2026-10-04

First public release (iOS / iPadOS through TestFlight; macOS through DMG).

### Added

- Markdown notes: Live Preview, `[[links]]` and `[[` autocomplete, link rename, tags, full-text search, backlink index, callouts, checklists, document header (cover, icon, tags), floating format toolbar and iOS keyboard toolbar. Zhuyin input compatible.
- Ink: an Apple Pencil drawing surface saved as standard `.excalidraw` strokes.
- Files are the truth: the vault is real files on disk (macOS: `~/Documents/EasyNotes`), and external tool edits are detected and synced.
- Sync: Supabase sync across devices (Mac, iPad, iPhone) with offline editing, Markdown three-way merge, whiteboard element merge, sync status display, and Recently Deleted (kept 30 days, restorable).
- Interface: a new design system and shell (sidebar, ⌘K quick open, document list with thumbnails, pinning, type filter, dark mode), with iPhone using bottom tabs.
- Flashcards: write cards in Markdown with `::`, `;;`, `{{}}`; FSRS-6 scheduling (aligned with Anki), decks and settings presets, daily limits, review UI, undo, tag-filtered study; multi-device review logs merge automatically.
- App icon.
- Whiteboard: a native Excalidraw whiteboard editor whose files stay standard `.excalidraw` and open on excalidraw.com. Supports rectangles, ellipses, diamonds, arrows, text, images, sticky notes, frames and Apple Pencil ink.
- Whiteboard: arrows can bind to shapes and snap to connection points at the top, right, bottom and left of a shape; arrows follow when shapes move.
- Whiteboard: Freeform-style top toolbar, style panel (fill, stroke, text, opacity), rectangle / lasso selection, canvas background (none / grid / dots), infinite canvas.
- Whiteboard: an open whiteboard receives changes from sync and external tools (for example Claude Code) and is never overwritten by stale content.
- Whiteboard: macOS can edit structural elements (mouse and trackpad, keyboard shortcuts, autoscroll when dragging to the edge, drag-and-drop images, tool cursors); ink is view-only.
- Whiteboard: the document list shows thumbnails, and Markdown can embed a preview with `![[x.excalidraw]]`.
- PDF: open a PDF and show annotations (strokes, highlighter, sticky notes) without modifying the original PDF; the document list shows a page-1 thumbnail and page count; the New menu gains "Import PDF…" (⌘O).
- PDF: when a PDF file is replaced, a notice "The PDF has changed; annotations may be misaligned" appears with a "Keep annotations" option.
- PDF: macOS can add, drag, resize, edit and delete sticky notes on a PDF.
- PDF: iPad / iPhone can write on a PDF (toolbar "Pen": fountain pen, highlighter, eraser, lasso) with cross-page undo / redo and automatic saving after interaction stops.
- PDF: iPad / iPhone can add, move, resize, edit and delete sticky notes on a PDF, with undo / redo.
- PDF: "Export" flattens strokes, highlighter and sticky notes into a new PDF (the original is unchanged) that can be shared or saved to the PDF's folder (`<name> (annotated).pdf`, auto-numbered on a name clash, never overwriting); large files show page progress and can be cancelled.
- Tables: open and edit CSV / TSV. Insert and delete rows and columns, undo / redo, sort and filter (view only), and "sort by this column and write"; unmodified rows are written back byte for byte.
- Tables: Big5-encoded CSV opens read-only with one-click conversion to UTF-8.
- Tables: remembers column widths, frozen first column and "first row is header" (stored in `.csv.meta.json`, the CSV itself unchanged) and syncs across devices.
- Tables: the document list shows table thumbnails and Markdown can embed a preview with `![[x.csv]]`; the New menu gains "New Table" and "Import CSV…".
- Cover images support pasting an image from the clipboard (⌘V).
- Settings: appearance can be set to light, dark or follow system.

### Changed

- The sidebar's vault header uses the app icon.
- New attachments (cover, inserted and pasted images) are stored in `Attachments/`; the legacy `附件/` need not be moved and existing images and links display as before.
- The `CLAUDE.md` guide file of a newly created vault is now in English; existing ones are not rewritten.

### Fixed

- The document icon was not visible when choosing an icon in the light theme.
- The editor showed blank when an SF Symbol was used as the document icon.
- The iPhone portrait review deck list content overflowed the screen.

[Unreleased]: https://github.com/brian-huanggg/easy-notes/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/brian-huanggg/easy-notes/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/brian-huanggg/easy-notes/releases/tag/v1.0.0
