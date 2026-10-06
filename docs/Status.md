# Status

The prototype phase is complete: every feature below ships in a release (see [Changelog](./Changelog.md); design in [architecture](./architecture/README.md)). This file lists only what is **still open**. Delete an item when it is verified; move items into an issue tracker (for example GitHub Issues) if you want per-task tracking.

"Verified" means checked on a real device or in the real app; unit tests and builds passing is tracked separately in CI / `swift test`.

## Device verification pending

Implemented, builds and unit / e2e tests pass, but not yet checked on real hardware.

| Area | To verify |
| --- | --- |
| Markdown | Zhuyin composition inside table cells, property values and the tag input on iPad / Mac WebKit; iPad touch for the cell "⋯" menu, "+" button and property delete button; KaTeX fonts loaded from `file://` and dark mode in WKWebView; scrolling and typing smoothness in a 1,000-line note with many tables and formulas |
| Editor | Zhuyin composition receiving a sync or external change (WebKit, iPad / Mac); Claude Code editing the open note while typing (`VaultWriteTests` not yet run on Mac); CRLF note keeps line endings; `$$` block behavior; checklist circle checkbox |
| Tabs | Restore after restart; whiteboard / PDF / sheet tab switching with unsaved changes; memory with many tabs (Instruments); tab drag reorder and its design file |
| Sidebar | Double-click rename and drag-to-move in the app (`Vault.move` unit-tested) |
| Sync | Settings > Keyboard Shortcuts on Mac (not built or run here: recording, conflict rejection, reset, menus and the sidebar ⌘K hint updating live after a change); ⌘S sync now and ⌘W / ⌥⌘W closing the window on Mac (not built or run here: ⌘S must not clash with an editor key handler; ⌘W with one tab closes the window); Sign in with Apple login flow; Mac + iPad offline edits of one note converge; rename on iPad while editing on Mac keeps both; restore within 30 days; energy (no network in background, few uploads while typing); `editSavedDuringDownloadIsMerged` and `localFileCreatedDuringPullIsNotOverwritten` / `threeDevicesOfflineEditsConverge` need a Mac `swift test` run |
| Permanent delete | "Delete Immediately" and "Empty Recently Deleted" on Mac and iPad with both signed in: the file disappears on the other device within a sync round and is not in either Recently Deleted; a PDF with ink, a sheet with column widths and a whiteboard each leave no sidecar behind on either device; a folder with mixed types; offline hard delete, quit, relaunch, then sync purges instead of soft-deleting; a file edited offline on one device while another purges it comes back as a new file; confirmation dialog and the borderless row buttons in Recently Deleted on iPhone / iPad / Mac; thumbnails of the deleted file are gone from `.easynotes/cache/preview` |
| Flashcards | Review on Mac / iPad / iPhone against the design (light / dark); undo with U; multi-device review then sync; custom study on Mac and iPad; card browser actions and iPhone portrait layout; formulas, multi-line cards and images in review (baseline alignment, wrapping, dark mode, unparseable formula fallback); 10-formula card flip latency; Anki TSV import after export; `.apkg` import UI end to end and re-import without duplicates; disabled "Start Review" button appearance; click-to-enlarge image sheet, no horizontal scrolling on long text / code / wide inline formulas, and the cloze type-in field (Return, shortcuts off while typing, focus back after the answer shows) on Mac / iPad / iPhone and the review top bar fallback layouts (icon-only buttons, counts on a second row) on iPhone portrait / split view (written without a Swift toolchain, not yet compiled) |
| Whiteboard | `![[x.excalidraw]]` widget (display, raw syntax on cursor line, click to open); Mac view matches excalidraw.com; thumbnails update within seconds and regenerate after clearing the cache; note card display, auto height and side panel on Mac / iPad; Claude Code adding a text element while the board is open |
| PDF | Import and companion-file flow; sticky-note Zhuyin on iPad / Mac; sync merge and multi-device annotation; rotated pages in app and export; 200-page scroll memory; cross-page undo ordering; original PDF hash unchanged; exported PDF in Preview; hold-to-straighten and the new ink toolbar on iPad |
| Sheets | Open and edit CSV on real devices (Zhuyin, TSV clipboard, ⌘Z, external edits live, WebContent process ends on close); column width / freeze / header persistence and sidecar follows rename / move / delete; list thumbnail and `![[x.csv]]` embed in light / dark; toolbar, formula bar (Zhuyin in fx), status bar on Mac / iPad WKWebView; 10,000-row scrolling; `swift test` for `KindSheet` and Core on macOS (including Big5, CP950 is Apple-only) |
| i18n | zh-Hant screens identical to before migration (Mac, iPad, editor WebView, whiteboard, review); English: no leftover Chinese anywhere, pseudolanguage layout, plurals, language switch rebuilds the index, two devices in different languages sync without conflict copies, Zhuyin under the English UI, first-launch sample content |
| Markdown images | Paste an image (screenshot, Photos, Finder file, image copied from Safari) with ⌘V, the Mac Edit menu and the iPad / iPhone paste menu; text paste unaffected; format bar photo menu on iPhone (keyboard bar) and iPad (floating bar): photo library and Files; HEIC photo arrives as JPEG with the right orientation; cover from the photo library; whether the WKWebView paste event carries the image on iOS (if not, native `paste` interception is needed); Google Photos has no Files provider, so only copy and paste reaches it |
| Appearance | Light / dark setting switches shell and editor WebView on Mac / iPad and persists |
| Diagnostics | Settings > Diagnostics > "Export Diagnostics…" on Mac (save panel) and iPad / iPhone (Files picker, not built-run here): the file opens, holds `app.easynotes` log lines, shows `<private>` for paths and contains no note text; macOS reads the system scope (`environment.scope` is `system`) and a non-admin user falls back to `process`; a MetricKit payload actually arrives after a real crash or hang on a release build (delivery is at most daily, so it cannot be forced; `Debug > Simulate MetricKit Diagnostics` in Xcode covers the plumbing) and shows up in the export; the section layout on iPhone and in the Mac Settings window (460 pt wide) |
| Release | Sparkle end-to-end update from an older build; "What's New" window screens (Mac, iPad, light / dark) |
| E2E | iPad simulator smoke (including simulator vault path access); GitHub Actions `--ci` run (ad-hoc signing, no Sign in with Apple entitlement) |
| IME checklist | Mac and iPad: type 「知識管理系統」 with no lost or duplicated characters and the candidate window following the cursor (on-screen and external keyboard); sync or external change during composition keeps Zhuyin symbols out of the file; ⌘S or switching notes mid-composition saves the chosen characters; Zhuyin in a table cell, whiteboard text and PDF sticky note |

## Not started or incomplete

- **Permanent delete, not yet run anywhere**: the code, `supabase/migrations/20261006000000_hard_delete.sql` and the new tests (`SyncEngineTests`, `CompanionTests`, `FolderSyncBackendTests`, and `SupabaseBackendTests` / `RLSAttackTests` against a local Supabase) were written in a session without a Swift toolchain or Docker, so nothing has been compiled or run. Run `swift test` for `EasyNotesCore` and `./scripts/test-sync.sh` first, then `supabase db push` for the cloud project (the app must not ship before the migration: the new select list asks for the `purged` column). Also add an E2E test for "Delete Immediately" (`A11yID.Menu.deleteImmediately`, `confirmDeleteImmediately`), and a `check-l10n.py --stale` pass.
- **Permanent delete follow-ups**: versions of a file committed before `file_blobs` existed are not attributed, so their old blobs survive a purge; an interrupted client between `purge_files` and the Storage delete leaves orphan blobs (nothing lists them); a device offline for more than 365 days keeps a stale copy of a purged file; signed-out "Delete Immediately" is local only and lands in Recently Deleted after the next sign-in; the Settings sync panel has no way to see or clear orphans.
- **Sign in with Apple** login flow (Supabase Auth).
- **Release baseline**: size, memory and energy baseline for a Release build, checked against the budgets in [core.md](./architecture/core.md); Core tests importing no plugin and each plugin's `Package.swift` depending only on Core / UI (verify by script); a test for "Claude Code changes 50 files → only 50 re-indexed".
- **fsrs-rs** parameter optimization (UniFFI, XCFramework): disallowed when logs are insufficient, result written back to the preset's `w`; measure the app-size impact; compare optimized parameters with Anki's on the same logs.
- **Sheets**: alignment (left / center / right) and wrap per column stored in `.csv.meta.json` (merge like column width); cut / copy / paste buttons (first confirm the WKWebView clipboard API works on Mac and iPad); filter button.
- **Whiteboard**: snapshot test (fixture rendered to PNG compared with a baseline, `EASYNOTES_SNAPSHOT_DIR`); 1,000-element thumbnail < 200 ms and memory budget; confirm typing never crosses the Bridge because of embeds; Mac view uses `SceneRenderer` pan / zoom.
- **Design**: missing design-file frames for iPad layout, ⌘K quick open, `[[` autocomplete, cursor-line raw md state, conflict hint, Me / settings / sync panel, Sign in with Apple, and the tab bar.
- **Product wishes**: Xmind-style mind map; Notion-style database list.

## Security review

Design and invariants are in [security.md](./architecture/security.md). First static pass done; open items:

- [ ] macOS has no Hardened Runtime (fine for personal use; must be fixed before giving the app to anyone else).
- [ ] External URLs: the JS side creates no `<a>` and calls no `window.open`, so clicking an `http(s)` link in md currently opens nothing (product behavior, not a vulnerability); when supporting it later, go through the navigation delegate's `openExternally`.
- [ ] Keychain: confirm supabase-swift's default session storage location and accessibility.
- [ ] Storage upload limit and quota: local `file_size_limit = 50MiB`; verify the cloud project's actual limit, quota and whether sign-up is open (local `enable_signup = true`, minimum password 6, no email verification); `commit_file` does not validate `p_path` and `p_size` (the client does; a server-side CHECK is defense in depth and needs a new migration and `supabase db push`).
- [ ] Dependency audit: `pnpm audit` is clean; SPM packages unchecked (no osv-scanner locally).
- [ ] Secret scan: grep over the working tree and history found nothing and `.env*` / credentials never entered version control; run gitleaks across everything and scan the app bundle.
- [ ] Build artifact check: `codesign -dvvv --entitlements -`, `otool -L`, no extra files in the app bundle.
- [ ] CI: dependency audit, secret scan, Semgrep.
- [ ] Dynamic testing, long-running coverage fuzzing, and systematic PDFKit / CoreGraphics crash testing (only fixed-seed fuzz rounds on macOS debug so far); symlinks leaving the vault and entry points other than Bridge and `vault://` still need a pass.
- [ ] Real-device checks: WebView CSP with Zhuyin input and iOS; `isInspectable` off in a Release build.

## Open design questions

- Should Sheets remember sort and filter state? (Suggestion: per device only, not synced.)
- Should ink on a PDF sticky note move with the note? Strokes and sticky notes are independent elements today and strokes stay in place when a note moves (GoodNotes moves them together and would need to record which note a stroke belongs to).
- Should `DocumentKind.index()`'s `summary` become language-neutral structured data, replacing the "rebuild the index when the language changes" rule in [translation.md](./architecture/translation.md)?

## Release sizes

Record the size printed by `./scripts/make-dmg.sh` for each release (macOS Release, universal).

| Version | DMG | .app | Executable | Note |
| --- | --- | --- | --- | --- |
| 1.1.0 | 10.6 MB | 36.7 MB | 33.9 MB | `EasyNotesTestSupport` is compiled only in DEBUG |
| 1.2.0 | not measured | not measured | not measured | |

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Sync data loss | Loss of trust | Content-addressed Storage (deleted only when unreferenced and only by an explicit permanent delete), server-side version check, diff3 merge, conflict copies, soft delete; a hard delete never destroys unsynced edits on another device |
| External tool rename seen as delete + add | Lose history and merge base | Infer renames by hash; worst case loses history, never content |
| Premature plugin interface | Later plugins bound to the wrong abstraction | Markdown went through the plugin interface first; extension points are extracted only when a second plugin needs them |
| WebView memory | iPhone kills the app in the background | One shared WebView, one process pool across tabs |
| Large PDF memory | Crash | Create `PKCanvasView` only for visible pages and recycle when off screen |
| `PKCanvasView` is iOS-only | No ink on macOS | Accepted: macOS shows ink, structural elements stay editable |
| swift-fsrs lagging | Scheduling differs from Anki | Regression tests against fsrs-rs reference vectors; if needed switch scheduling to fsrs-rs's UniFFI binding |
| Package licenses | Little impact for personal use | Still prefer MIT / BSD: RevoGrid (MIT), fsrs-rs (BSD-3) |
