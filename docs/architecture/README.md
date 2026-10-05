# EasyNotes Architecture

This document describes the current design and the reasons behind it. It does not track progress or dates: open work lives in [Status](../Status.md) and user-visible changes in [Changelog](../Changelog.md). Rejected decisions are deleted; history lives in git.

**How to read**: this file holds cross-feature principles, technology choices, module structure and dependency rules. Each feature has its own file; read it in full. Read this file and `core.md` only when adding a plugin, changing Core or an extension point, or making a change that spans plugins.

| Work | File |
| --- | --- |
| New plugin, Core or extension-point changes, sync and merge, Claude Code integration, size / memory / energy budgets | [core.md](./core.md) |
| Shell, navigation, lists, document header, design system | [ui.md](./ui.md) |
| Markdown, Bridge protocol, typing feel | [markdown.md](./markdown.md) |
| Whiteboard | [whiteboard.md](./whiteboard.md) |
| PDF ink and annotation | [pdf.md](./pdf.md) |
| Sheets | [sheets.md](./sheets.md) |
| Cards and review | [flashcards.md](./flashcards.md) |
| Localization, string conventions, strings that are not translated | [translation.md](./translation.md) |
| Threat model, trust boundaries, security invariants (WebView / Bridge, sync, file parsing, signing) | [security.md](./security.md) |

EasyNotes is a personal knowledge base app (not published, not commercial). Core only handles files, sync, indexing and plugin registration; Markdown, whiteboard, PDF ink, CSV and Flashcards are compile-time plugins. All data is real files in open formats, synced between iOS, iPadOS and macOS through Supabase, and Claude Code can read and write them directly.

## Background and goals

Two problems to solve:

- **Scattered knowledge**: notes, whiteboards, sheets and cards live in different apps and cannot link to or search each other.
- **File-type lock-in**: Apple Notes, Notion and RemNote keep data in proprietary formats that are hard to use outside the app.

Positioning: an "Apple Pencil and AI agent flavored Obsidian" for personal use. Obsidian's open files, Apple Notes' light feel, GoodNotes' PDF ink, and Claude Code reading and writing the whole vault without MCP or format conversion.

| Item | Target |
| --- | --- |
| Platforms | iOS, iPadOS, macOS (one SwiftUI Multiplatform target) |
| Sync | Supabase (Auth + Storage + Postgres + Realtime) |
| File types | `.md` at the center; Whiteboard, PDF ink, CSV and Flashcards are plugins |
| Non-functional | App < 100 MB (estimated 15–30 MB), memory and energy budgets, offline use, reliable sync (see [core.md](./core.md) "Non-functional budgets") |
| Scope | Personal use: not published, not commercial (license limits are relaxed, but MIT / BSD packages are still preferred) |
| Vault location | macOS: `~/Documents/EasyNotes` (visible, not sandboxed); iOS: the app's Documents (visible in the Files app) |
| Distribution | iOS / iPadOS: TestFlight (`upload-testflight.sh`); macOS: DMG (`make-dmg.sh`) plus Sparkle auto-update (see "Release flow"). macOS is not sandboxed, so it cannot ship through TestFlight / the Mac App Store; "iPad app can run on Mac" is turned off in App Store Connect so a Mac never installs the iPad build (sandboxed vault, iOS UI) |

## Design principles

1. **Files are the truth**: each note is a file on disk; the database is only a rebuildable index. Deleting the index loses nothing.
2. **Open formats**: `.md`, `.excalidraw`, `.csv`, `.pdf` plus annotation sidecars can all be opened by other tools; the app never rewrites the user's format and preserves unknown fields.
3. **Local first**: every operation writes locally first and works fully offline; sync runs in the background.
4. **Core knows no file types**: Core has only files (Vault), sync, index and plugin registration. Markdown is a plugin too and uses the same interface as the others.
5. **Plugins split by feature, assembled at compile time**: plugins depend only on Core and never on each other; WebView versus native is an internal choice of each plugin.
6. **Native shell, the right editing surface**: navigation, data, sync and ink use Swift; editing surfaces with mature libraries (CodeMirror 6, RevoGrid) use a WebView.
7. **Optimized for Claude Code**: formats Claude can read and write directly; external edits are detected and synced immediately; `CLAUDE.md` at the vault root explains the conventions.

## Technology decisions

Swift for the shell and data layer; WebView for Markdown and CSV (CodeMirror 6, RevoGrid); native for ink, whiteboard and PDF (PencilKit, PDFKit, Core Animation layers). The whiteboard does not use Excalidraw's web runtime; only the `.excalidraw` file format is kept and the whiteboard is built natively. The editors of Notion, Obsidian and Typora are all web technology: smoothness depends on engineering, not on being native.

### Routes considered

| Route | Pros | Cons | Verdict |
| --- | --- | --- | --- |
| A. Swift shell + WebView editors | Native feel + web ecosystem | Two stacks, Bridge complexity | **Adopted** |
| B. Pure Swift, drop Excalidraw | One stack, lightest | A self-built live-preview editor is about half the app; loses the whiteboard ecosystem | Rejected |
| C. Tauri / Capacitor, all web | Write once, run anywhere | Non-native shell, contradicts the Apple Notes positioning | Rejected |

### WebView trade-offs

| Pros | Cons |
| --- | --- |
| Use CodeMirror 6, RevoGrid, KaTeX directly | Each WebContent process costs about 30–80 MB more memory |
| Same rendering on iOS and macOS | Cold start about 100–300 ms, needs pre-warming |
| Fast iteration, debuggable with Safari Web Inspector | Bridge is asynchronous and needs serialization |
| JS bundled in the app is allowed (the App Store forbids downloaded code) | IME, selection and accessibility need extra tuning; higher Pencil latency |

Split rule: **content editing surface with a mature library → web**; shell, navigation, data, sync, system integration and ink → native.

Current decision: **keep WebView + Bridge, but only for the Markdown and CSV plugins.** Zhuyin (Bopomofo) composition and performance were verified on real devices; the Bridge is never on the typing path; WebKit is a system framework and adds no app size. Whiteboard, PDF, the review UI, embedded previews and whiteboard note cards are always rendered natively, and never one WebView per card. A native text engine (for example STTextView) is reconsidered only if iPhone testing shows WebView memory getting the app killed in the background.

### Markdown editor: CodeMirror 6, not TipTap

|  | TipTap (ProseMirror) | CodeMirror 6 |
| --- | --- | --- |
| Source of truth | Its own document tree, converted back to md on save | The md text itself |
| md fidelity | Normalizes list markers, blank lines, escapes | Preserved as written |
| Chinese IME | contenteditable has more composition problems on iOS WebKit | Mature |
| Large files | Renders the whole document | Renders only the visible range |
| Track record | Notion-style block editors | Obsidian |

"Files are never locked in" requires clean md on disk, so CodeMirror 6 is used with decorations for Live Preview.

### Ink: PencilKit, not MaLiang

|  | PencilKit | [MaLiang](https://github.com/Harley-xk/MaLiang) |
| --- | --- | --- |
| Maintenance | Apple, updated yearly | Last release 2.9.2 (2020-12), 54 open issues |
| Latency | Lowest (system prediction + low-latency rendering) | Own Metal rendering, needs tuning |
| Palm rejection, double-tap, Scribble | Built in | Must be written |
| Brushes | System brushes, limited customization | Custom brushes via textures |
| Platforms | Editing canvas on iOS/iPadOS only; macOS can display | iOS only, Swift 5.0 |
| Data | `dataRepresentation()` is closed, but `PKStroke` exposes every point | Own format |

A notes app values latency and system integration over custom brushes, so PencilKit it is. On save, strokes are converted to Excalidraw freedraw JSON to avoid format lock-in.

## System architecture

```
UI layer
  App (SwiftUI shell)          Plugins (editors, panels, previews)
  EasyNotesUI (PluginRegistry, WebEditorHost, DesignSystem)
        │ access data only through Vault / Registry
Core layer (EasyNotesCore, no UI dependency)
  KindRegistry
  Vault (VaultFS, VaultWatcher) ──► Index (SQLite + FTS5)
        │                         └─► SyncEngine ──► SyncBackend
        ▼
  Files on disk (the only truth)
Supabase (SyncBackend implementation, assembled by the App)
  Auth · Storage · Postgres (commit_file RPC) · Realtime
```

**The Vault is the only truth**; Index and Sync derive from it. Core knows plugins only through PluginRegistry; a plugin's editor (WebView or native) never touches the network and always reads and writes files through the Vault.

### Module structure

```
Packages/
  EasyNotesCore/     Core (knows no file types)
    EasyNotesCore    Vault, Index, Sync, DocumentKind and KindRegistry (no UI dependency, unit-testable)
    EasyNotesUI      PluginRegistry, EasyNotesPlugin, DocumentSession, EditorController,
                     WebEditorHost (pre-warming, Bridge, local resources), DesignSystem (tokens, shared components),
                     ink toolbar (InkSettings, StraightLineAssist; shared by whiteboard and PDF)
  KindMarkdown/      .md: CodeMirror 6 editor (WebView), Live Preview, Writing mode
  ExcalidrawKit/     Shared library (not a plugin, registers nothing): Excalidraw element model, merge,
                     PencilKit ⇄ freedraw conversion, geometry and CoreGraphics renderer
  KindWhiteboard/    .excalidraw: PencilKit ink layer + native structural element layer
  KindPDF/           .pdf + .pdf.ink annotation sidecar: PDFKit + per-page PencilKit overlay
  KindSheet/         .csv, .tsv: RevoGrid editor (WebView)
  Flashcards/        Card parsing, FSRS scheduling, review UI (not a file type)
  SupabaseSync/      SyncBackend implementation for Supabase
  AppUpdater/        Sparkle wrapper (macOS only)
App/                 SwiftUI shell; registers the plugins into PluginRegistry at launch
web/                 TypeScript sources of the WebView plugins; one entry per plugin, bundled into each plugin
```

### Dependency rules

- **Plugins depend only on EasyNotesCore, EasyNotesUI and shared libraries**, never on each other. To use another plugin's capability, query the Registry. For example, a whiteboard showing an md note card asks the Registry for the `.md` DocumentPreviewProvider instead of importing KindMarkdown.
- **Shared libraries** (currently only `ExcalidrawKit`) are extracted only when two or more plugins need the same format code. They are not plugins: no dependency on the EasyNotesUI Registry, no Kind / editor / menu registration, only models, conversion and rendering, and no dependency on any plugin. `ExcalidrawKit` exists because PDF annotation needs the whiteboard's element model, merge, stroke conversion and renderer; copying would let two copies drift, and folding it into KindWhiteboard would make PDF impossible to remove independently.
- **Core never imports a plugin**; the App target assembles them.
- **Plugins are compile-time SPM modules**; no code is loaded at run time.
- **WebView or native is a plugin's internal choice.** WebView plugins share EasyNotesUI's WebEditorHost and still obey "the typing hot path never crosses the Bridge".
- **Markdown is a plugin too**, with no privileged channel, which keeps the plugin interface honest.
- **Card syntax belongs to the vault's Markdown dialect**, so syntax highlighting is the Markdown plugin's job; Flashcards only parses, schedules and reviews. This avoids injecting JS extensions into another plugin at run time.

## Plugin feature design

Each plugin decides its own format, editor and merge strategy. Items marked "not done" are deliberate cuts, not omissions.

| Plugin | Format | Editor | Sync merge |
| --- | --- | --- | --- |
| Markdown | `.md` + YAML frontmatter | CodeMirror 6 (WebView) | diff3 three-way merge (per line) |
| Whiteboard | `.excalidraw` (official JSON) | PencilKit + CALayer structural layer (native) | By element `id` + `version` |
| PDF | `.pdf` (unmodified) + `.pdf.ink` (JSON sidecar) | PDFKit + per-page PencilKit overlay (native) | PDF is not merged; sidecar by page + element `id` |
| Sheets | `.csv`, `.tsv`; column widths etc. in `.csv.meta.json` | RevoGrid (WebView) | diff3 (per record, then per cell within a record) |
| Flashcards | Cards live in `.md`; logs in `.easynotes/srs/<deviceId>.jsonl`; settings in `.easynotes/srs/<deviceId>.config.json` | Native review UI | Cards follow md; logs and settings are written per device and never conflict; settings merge by per-field last-writer-wins |

### Cross-plugin features

- `[[note]]` links; `![[drawing.excalidraw]]` and `![[table.csv]]` embed previews inside md, provided by each plugin's DocumentPreviewProvider registered in the Registry.
- Each `DocumentKind`'s `index()` extracts plain text and links, so text elements inside whiteboards are searchable and appear in backlinks (ink strokes are not indexed).
- App settings live in `.easynotes/` (like `.obsidian/`) and sync with the vault.
- UI languages (zh-Hant, English (US)): each module ships its own string catalog; paths, filename conventions and sync-protocol strings inside the vault never change with language. See [translation.md](./translation.md).

## Release flow

Version number, Changelog, tag and update channel are all driven by commits and never edited by hand.

- **Commit messages**: Conventional Commits, enforced by `.githooks/commit-msg` (commitlint, `commitlint.config.mjs`); `pnpm install` at the root sets `core.hooksPath`. The type decides the Changelog section: `feat` → Added, `fix` → Fixed, `perf` → Changed, `security` → Security; `docs` / `refactor` / `test` / `chore` / `build` / `ci` / `style` / `revert` and merge commits are excluded. The subject of a `feat` / `fix` / `perf` / `security` commit is therefore the line users read: English (en-US), describing what users can see.
- **Changelog**: `docs/Changelog.md` is generated by git-cliff (`cliff.toml`) from commits since the last tag, in Keep a Changelog format. To hand-write a version, add a `## [Unreleased]` block before releasing; it is renamed to that version and not regenerated. `scripts/changelog.py` reads and writes the file.
- **Single source of the version** is `MARKETING_VERSION` in `project.yml` (Info.plist, Sparkle and TestFlight all read it). The build number (`CURRENT_PROJECT_VERSION`) is a timestamp set when packaging; Sparkle uses it to order versions, so it must increase. `scripts/release.sh` runs tests, generates the Changelog, sets `MARKETING_VERSION` and the "What's New" content, then commits and tags without pushing; the version bump defaults to the commit types.
- **`scripts/publish-release.sh`** works on the version tag at HEAD: builds the DMG, signs it with Sparkle's `generate_appcast`, pushes, and creates a GitHub Release (with the DMG and `appcast.xml`); `--testflight` also uploads iOS / iPadOS. Pushing and creating a Release are outward-facing, so it confirms first by default.
- **Sparkle** (`Packages/AppUpdater`): linked on macOS only (a platform condition on the target; XcodeGen package dependencies cannot filter by platform). `SUFeedURL` points at the latest Release's `appcast.xml` (`releases/latest/download/…`), so the repo must be public; a private repo's Releases cannot be read by the installed app. Updates are verified with an EdDSA signature: the public key is `SPARKLE_PUBLIC_ED_KEY` in `project.yml` (the app does not start update checks while it is empty) and the private key is in the release Mac's keychain (`scripts/sparkle-tools.sh generate-keys` / `export-key`; losing it means no more updates can be shipped to installed copies, so back it up). Release notes are that version's Changelog block, embedded in the appcast.
- **"What's New" window**: `scripts/release.sh` converts that version's Changelog block to `App/Resources/WhatsNew.json` bundled into the app (the Changelog is the only source and is updated only at release time). At launch `lastSeenVersion` (UserDefaults) is compared with the current version and the window shows only if the current one is newer. With no record, a fresh install (sample content created in this launch) shows nothing; any other case (an update from a version before this feature) shows it. It does not show if the JSON's version differs from the current version, nor in UI tests. The window title and section names go through `L("…")`. The Mac Help menu can reopen it.

## Testing

Layered: lower layers are more numerous and faster; E2E verifies only the wiring and does not retest logic covered below.

| Layer | Content | Command |
| --- | --- | --- |
| Unit | Each package's `swift test` (Core's Vault, index and sync engine use a fake backend; plugin formats and merge) | `swift test` |
| Web | CM6 rebase, line breaks, Zhuyin composition (Chromium simulating an IME) | `pnpm test`, `node test/ime.e2e.mjs` |
| Integration | SupabaseSync RPC concurrency and RLS against a local Supabase | `scripts/test-sync.sh` |
| E2E | XCUITest drives the app from outside (macOS, iPad simulator) | `scripts/test-e2e.sh` |
| Real device | Zhuyin (WebKit), Apple Pencil, energy and memory | manual |

E2E design:

- **Assert on files, not on screens**: each test creates its own temporary vault and the app opens it through the DEBUG launch argument `-EasyNotesVaultRoot`; tests read and write files on disk, playing the role of Finder / Claude Code, and verify the app's actions through file contents. On the iOS simulator the vault lives under `SIMULATOR_SHARED_RESOURCES_DIRECTORY` (readable and writable by every app in the simulator).
- **One test contract**: launch argument names (`LaunchKey`) and accessibility identifiers (`A11yID`) live in `App/Support/UITestContract.swift`, compiled into both the app and the test target. Tests find elements by identifier only, never by UI text (so translation cannot break them); identifiers that contain a path carry the vault-relative path.
- **Test hooks exist only in DEBUG** (`App/Support/TestHooks.swift`): Release ignores every launch argument, and vault location and sync behave normally.
- **Sync E2E needs no network**: `EasyNotesTestSupport`'s `FolderSyncBackend` uses a folder as the remote (`commit` semantics match `commit_file`, cross-process exclusion via `flock`); the app uses it through `-EasyNotesSyncFolder` and watches the folder instead of Realtime; the test process runs its own `SyncEngine` on the same folder, playing another device. Supabase itself is covered by the integration tests.
- **ASCII input only**: XCUITest's `typeText` bypasses the IME, so it cannot test Zhuyin composition; that is covered by the web-layer Chromium simulation and real-device checks.
- **WebView wiring only**: editor logic is tested in the web layer; E2E only confirms that typing is saved through the Bridge and that external edits appear in an open editor.
- **Scope**: Mac and iPad (sidebar layout). The iPhone bottom tabs are a separate UI and are not in E2E scope.
