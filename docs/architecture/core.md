# Core: Extension Points, Sync and Integration

## Extension points

```swift
// EasyNotesCore: file type (no UI, unit-testable)
protocol DocumentKind {
    static var id: String { get }
    static var fileExtensions: [String] { get }
    static func template(title: String) -> Data
    static func index(_ data: Data, fileName: String) -> IndexEntry
    static func merge(base: Data?, local: Data, remote: Data) -> Data?  // nil = conflict copy
    static func renameLinks(in data: Data, from: String, to: String) -> Data?  // default nil = no links to rewrite
    static func setPinned(_ pinned: Bool, in data: Data) -> Data?  // default nil = pinning unsupported
    static func companionOf(_ path: String) -> String?  // default nil; a companion returns its main file's path (x.pdf.ink → x.pdf)
}

// Result of index(); icon, pinned and summary are decided by the plugin, Core stores but never interprets them
struct IndexEntry { title, plainText, links, tags, icon: String?, pinned: Bool, summary: String? }

// EasyNotesCore: Vault, Index and Sync know only this table (Sendable, immutable after launch)
struct KindRegistry {
    init(_ kinds: [any DocumentKind.Type]) throws  // registering the same extension twice throws
    func kind(for path: String) -> (any DocumentKind.Type)?  // unregistered → nil
}

// EasyNotesUI: entry point of each plugin, called in order at app launch
protocol EasyNotesPlugin {
    @MainActor static func register(in registry: PluginRegistry)
}

// EasyNotesUI: editors get the Vault through the environment; implemented by the App's VaultStore
@MainActor protocol DocumentSession {
    func readData(_ path: String) -> Data
    func write(_ data: Data, to path: String)
    func openLink(_ target: String)
    func search(_ query: String)
    func modified(_ path: String) -> Date?          // the header's "edited N minutes ago"
    func importAttachment(_ url: URL) async -> String?  // copies into the vault's `Attachments/`, returns the vault path
    var resourceReader: @Sendable (String) async -> Data? { get }  // `vault://` images, read in the background
}

// EasyNotesUI: VaultStore notifies editors through it instead of calling WebEditorHost directly
@MainActor protocol EditorController {             // default implementations do nothing
    func attach(_ session: any DocumentSession)     // called once after the App creates VaultStore
    func flush() async                              // before rename, delete, going to background
    func externalChange(path: String, data: Data)   // external edit or sync
    func close(path: String)
    func linkTargetsChanged(_ targets: [LinkTarget])  // [[ autocomplete and link cards: name, kind, summary, mtime, tint, icon
}

// PluginRegistry (@MainActor) extension points; a point is extracted only when a second plugin really needs it
registry.addKind(MarkdownKind.self, name: "Notes", symbol: "doc.text", tint: .neutral)  // the first registered Kind is the type created when a [[link]] is not found; name = filter chip; tint = type color
registry.addPreview(for: MarkdownKind.id, MarkdownPreview())   // list card thumbnail (native render); `DocumentPreview.image` (PNG) also serves ![[x]] embeds (`embed://`) and whiteboard note cards
registry.addEditor(for: MarkdownKind.id) { path in MarkdownEditorView(path: path) }
registry.addNewFile("New Note", kind: MarkdownKind.self, symbol: "square.and.pencil", shortcut: "n", defaultName: "Untitled")
registry.addController(MarkdownEditor.shared)
registry.addMenu("Format", sections: [[...], [...]])          // shown by the App as Commands, at most 4 top-level menus
registry.addImport("Import PDF…", kind: PDFKind.self, symbol: "doc.richtext", shortcut: "o")  // import entry in the New menu; the file is copied into the current folder
registry.addCompanionKind(PDFInkKind.self)                    // companion type: enters KindRegistry and is indexed and synced as usual, but is not a filter chip
registry.addPanel(id: "review", title: "Review", symbol: "rectangle.stack", badge: { dueCount }) { ReviewView() }  // sidebar item
registry.kinds                                                // → KindRegistry, handed to VaultFS and VaultIndex
registry.addIndexContributor(CardIndexer())                    // Flashcards: extracts cards from md, stored as index records
registry.addContentFixer(CardIDFixer())                         // Flashcards: adds ids to cards missing `^id`
registry.addVaultGuide(guide)                                   // a section of the vault-root CLAUDE.md (Markdown: note conventions; Flashcards: card syntax)
registry.addSyncedMetaFolder("srs")                             // Flashcards: `.easynotes/srs/` takes part in sync (the rest of `.easynotes/` does not)

// EasyNotesUI: non-editor plugins (Flashcards) also reach the Vault through DocumentSession / EditorController
session.vault                       // VaultFS: reads and writes the plugin's own `.easynotes/<name>/`
session.index                       // VaultIndex?: records, file tags
session.open(path, line: 84)        // opens a file and scrolls to the line (review's "Edit note")
session.metaChanged()               // a plugin wrote a synced meta file → schedule upload
session.fileMoved(from:, to:)       // a plugin moved a vault file itself (PDF adopting an orphan sidecar) → sync keeps the file id, index updates
controller.vaultChanged(paths)      // after the index updates (in-app edit, external edit, sync, including downloads of `.easynotes/srs/`)
controller.moved(from:, to:)        // in-app rename or move (file or folder)
controller.reveal(path:, line:)     // Markdown: scrolls to the line and puts the cursor at its start

// EasyNotesCore: this device's identity, stored in `.easynotes/device-id` (not synced); shared by SyncEngine and Flashcards
vaultFS.deviceID() -> String
```

**How Flashcards uses the extension points**:

- No "service"-style extension point is added: Flashcards registers an `EditorController` (`ReviewStore`), gets the session in `attach`, and learns about changes through `vaultChanged` / `moved`. `EditorController` widens from "editor" to "App → plugin notifications".
- `vaultChanged(paths)` carries only paths; the plugin decides whether to re-read (Flashcards: md changed → re-read card records; `.easynotes/srs/` changed → re-read logs and replay only cards with new entries).
- `open(path, line:)` has the App navigate to the file and then call each controller's `reveal`; it is not the typing hot path and may cross the Bridge.
- `VaultIndex.fileTags()`: path → tags (a card's tags are its note's tags).

**Syncing plugin data**:

- `addSyncedMetaFolder`: `.easynotes/` is not synced by default (index, cache and sync state are local). A plugin that needs to sync its own data registers a subfolder under `.easynotes/` and the App hands the list to `SyncEngine`. An allowlist is used instead of "sync everything except cache" so local markers such as `seeded` never travel to other devices. These files have no registered `DocumentKind`, so merging treats them as opaque (different content → conflict copy); a plugin must design itself to avoid conflicts (for example one file per device).
- `VaultFS.deviceID()`: generates a UUID on first call and writes it to `.easynotes/device-id` (not synced). A device id stored in `sync.sqlite` by older versions is migrated first and keeps its value. If the file is deleted only a new id appears; data keyed by it (for example review logs) just gains one new file and loses nothing.

**Index and content fixing**:

- `IndexContributor` (Core, no UI): a plugin extracts its own data from file content; Core stores it in a generic `records(contributor, path, key, value)` table where `value` is a plugin-defined JSON string that Core never interprets. When the plugin's `version` changes the whole index is rebuilt. Queries are only "all records of a contributor" and "which files contain a key"; anything more complex is done in memory by the plugin (a personal vault has thousands of cards).
- `ContentFixer` (Core, no UI): a plugin rewrites file content in the background, and the App indexes and syncs the write-back as usual. The App calls it only for **locally produced** changes (in-app edits, external tools), never for content pulled by sync; **open files are not rewritten** until the user leaves them, so text is never inserted during typing or Zhuyin composition and nothing crosses the Bridge. Consecutive changes are coalesced (about 1.5 s) so that when Claude Code moves content both files are written before the decision.
- `addVaultGuide`: when the vault root has no `CLAUDE.md`, the App creates it from the sections each plugin provides; an existing one is never rewritten (the user may edit it).

**Companion files**: a companion is a file whose `companionOf` returns a main-file path (for example `x.pdf.ink`). `KindRegistry.mainFile(ofCompanion:)` / `companionPath(_:from:to:)`, `VaultFS.companions(of:)` / `companionMoves(from:to:)` are the shared queries. The file tree (`VaultFS.scan`), `allFiles`, `VaultIndex.files` / `search` and `SyncEngine.recentlyDeleted` exclude companions by default; `VaultFS.fileStats` includes them (indexed and synced as usual). `VaultFS.rename` / `trash` handle companions together; when `SyncEngine` infers an external rename it moves the companion, and restoring a main file restores its companion.

**Two-layer registry**: Core has only the UI-free KindRegistry, used by Vault, Index and Sync; PluginRegistry needs SwiftUI (`addEditor` returns a View) and therefore lives in EasyNotesUI. Plugins cannot import the App, so Markdown-specific logic in VaultStore (updating links on rename, pushing external edits to the editor, the autocomplete list) goes through `DocumentKind.renameLinks` and `EditorController`.

**Graphical previews and embeds**:

- `DocumentPreview` (EasyNotesUI) has `image: Data?` (PNG): graphical plugins (whiteboard, PDF) draw a thumbnail in the background inside `makePreview`, cached by hash as `<hash>.png` next to `<hash>.json` (the JSON records only `hasImage`, never base64); Core does not understand the image. The whiteboard thumbnail's default white background is drawn transparent, and dark mode is inverted at display time (`invert` + `hue-rotate(180deg)`, the same as Excalidraw's dark theme).
- `embed:///<vault-relative path>` (each segment percent-encoded, same as `vault://`): a `WKURLSchemeHandler` in WebEditorHost that returns the file preview's `image` through `DocumentSession.embedImageReader` (implemented by the App's VaultStore, default nil), cached by content hash; it answers 404 when the file has no registered preview or no image. Markdown's `![[x.excalidraw]]` emits only `<img src="embed://…?h=<hash>">` and never crosses the Bridge; when the hash changes the URL changes and the WebView reloads automatically. `![[x.csv]]` uses the same scheme.

**Previews**: `DocumentPreviewProvider` has two stages. `makePreview(Data) -> DocumentPreview` runs in the background; its result is serializable and cached by content hash at `.easynotes/cache/preview/<kind>-v<version>/<hash>.json`. `view(_:)` renders with native SwiftUI on the main thread. Types without a registered preview show a skeleton placeholder.

To extract later: Core contains no file types, but the snippet cleanup in `VaultIndex.clean()` is still Markdown syntax; it becomes an extension point when a second text plugin needs it.

## Sync design

The sync layer sees only file id, path, content hash and version; it knows no file types, and merging is delegated to each `DocumentKind`.

Three key decisions:

1. **Stable file id**: a file's identity is its id and the path is just an attribute. Rename and move only update the path instead of becoming "delete one, add one", so history and the merge base are preserved.
2. **Version check on the server**: a Postgres function (RPC) compares and increments the version in one transaction, so two devices uploading at the same time cannot overwrite each other.
3. **Three-way merge is part of sync**: Markdown diff3 is a requirement. Claude Code writing a file on the Mac while the iPad is editing it is the normal case, and conflict copies alone are not enough.

Implementation decisions:

- **The sync engine is in Core, the network is in the App**: `SyncEngine`, `sync.sqlite` and the upload queue live in EasyNotesCore and depend only on the `SyncBackend` protocol; the standalone package `Packages/SupabaseSync` implements it as `SupabaseBackend` (depends on Core + supabase-swift, with RPC-concurrency and RLS integration tests against a local Supabase) and the App only assembles. Core never imports supabase-swift, and the engine is unit-tested with an in-memory fake backend.
- **diff3 is a generic Core utility**: line-based three-way text merge that knows no file types. Markdown and Sheets `merge` both call it; plugins cannot import each other, so it lives in Core. The generic `Diff3.merge(base:local:remote:resolve:)` lets the plugin choose the unit (Sheets uses records); when both sides changed the same hunk it first calls `resolve` (default nil = conflict) so a plugin can merge more finely than Core, which knows no file types (Sheets merges per cell).
- **Folder backend for E2E**: the `EasyNotesTestSupport` target of the `EasyNotesCore` package provides `FolderSyncBackend` (not Core itself; Core still has only the `SyncBackend` protocol). The App uses it only in DEBUG test mode; see README "Testing".
- **Sign in with Apple**: Supabase Auth's Apple provider with the native ID-token flow (AuthenticationServices); no web redirect.
- **Migrations live in the repo's `supabase/migrations/`**: RPC-concurrency and RLS tests run on a local Supabase (CLI + Docker); once they pass, `supabase db push` applies them to the cloud project.

### Supabase tables

```sql
create table files (
  id          uuid primary key,          -- stable file id, generated by the device that created the file
  user_id     uuid not null references auth.users,
  path        text not null,             -- relative path in the vault, just an attribute
  hash        text not null,             -- SHA-256 of content
  size        bigint not null,
  version     bigint not null,           -- incremented only by commit_file
  deleted     boolean not null default false,
  device_id   text not null,
  updated_at  timestamptz not null default now()
);
create unique index files_live_path on files (user_id, path) where not deleted;
-- RLS: user_id = auth.uid(); the Storage bucket is restricted by user_id the same way

-- In one transaction: compare base_version, write, increment version
-- Returns the new version; null = the remote changed, merge needed
create function commit_file(p_id uuid, p_base_version bigint, p_path text,
  p_hash text, p_size bigint, p_deleted boolean, p_device text) returns bigint;
```

File content is stored in Storage keyed by hash (`vault/<user_id>/<hash>`): append-only, deduplicated automatically, old versions double as history, and an interrupted upload can be retried without corrupting data. The publishable key may live in the repo as long as every table and bucket has RLS enabled.

### Local sync state

- `.easynotes/sync.sqlite` (not synced): one row per file with `file_id`, `path`, `base_version`, `base_hash` and upload-queue state.
- `.easynotes/device-id` (not synced): this device's id (`VaultFS.deviceID()`), used by `commit_file`'s `device_id` and by review-log file names.
- Only subfolders that plugins register with `addSyncedMetaFolder` take part in sync (currently Flashcards' `srs/`); everything else (`cache/`, `sync.sqlite`, `device-id`) is local.
- `.easynotes/cache/base/<hash>`: the content at the last sync, used as the three-way merge base.
- An in-app rename updates the path directly. When an external tool (Finder, Claude Code's `mv`) renames, VaultWatcher sees "delete + add"; if both have the same hash it infers a rename and keeps the file id. A failed inference at worst loses history, never content. When a main file is inferred to be renamed, a companion left behind moves with it (the App is notified through `Hooks.didChange`).

### Flow

1. **Local change**: a file is written (in-app or by an external tool such as Claude Code) → VaultWatcher compares the hash → the index updates → the file enters the upload queue.
2. **Upload**: content goes to Storage first, then `commit_file(id, base_version, …)` is called. Null means the remote changed and a merge starts.
3. **Pull**: Realtime subscribes to `files` changes; on returning to the foreground it pulls rows with `updated_at` after the last cursor. Only the path changing = rename, so the local file is moved directly. When the target path of a remote new file or rename already has a local file (including one created after the scan and without a sync record), the local file is never overwritten: identical content adopts the remote id, otherwise it yields to a conflict copy.
4. **Merge**: remote content and base are downloaded first (network), then the editor is asked to write back (`Hooks.willChange`), local content is read, and `DocumentKind.merge` runs. There is no `await` between reading local and writing back, so edits saved during the download are included in the merge instead of being overwritten. Success → write back locally and upload the merged result; nil → create `Note (conflict iPad 2026-10-01).md`. An open document gets the remote change through its editor (Markdown uses `applyRemote`).
5. **Delete**: soft delete (`deleted = true`), kept for 30 days. Content stays in Storage (append-only), so restoring works for 30 days.
6. **Restore**: the sync panel's "Recently Deleted" lists files deleted within 30 days that also do not exist locally (`SyncBackend.deletedFiles`). Restore = download that hash's content to the original path (using conflict-copy naming if occupied), then commit `deleted = false` with the same file id, preserving history and merge base.
7. **Purge**: pg_cron deletes rows that have been `deleted` for over 30 days every day. Storage content is kept (content-addressed, possibly shared by other versions); garbage collection can be added later if needed.

### Merge strategy per type

| Type | Strategy |
| --- | --- |
| `.md` | diff3 per line; overlapping edits → conflict copy |
| `.excalidraw` | Merge by element `id` + `version` (same as Excalidraw's official collaboration) |
| `.pdf.ink` | Grouped by page, each page merged by element `id` + `version`; `pdfHash` stays local |
| `.csv`, `.tsv` | diff3 per record; different cells of the same record are merged three-way; adding or removing columns → conflict copy |
| `.csv.meta.json` | Per-field LWW |
| `.easynotes/srs/*.jsonl` | Each device writes only its own file, so no conflicts by construction |
| `.easynotes/srs/*.config.json` | Each device writes only its own file; reading merges per field with LWW |
| Others (`.pdf`, images) | Different content → conflict copy |

## Claude Code integration

- **`CLAUDE.md` at the vault root**: explains frontmatter conventions, card syntax, folder conventions, and files not to edit by hand (`.easynotes/srs/*.jsonl`, `.easynotes/srs/*.config.json`, `.easynotes/cache/`, `sync.sqlite`).
- **External edits are first-class**: Claude Code writing a file takes the same path as an in-app edit (watch → index → upload).
- **Saving never overwrites external edits**: file watching has latency (FSEvents about 0.3 s), so the App may save before it hears about an external write. Every App save goes through `VaultFS.write(_:to:expecting:deviceName:)`: `expecting` is what the App last wrote or read on open; if the disk already differs, it is used as the base for `DocumentKind.merge`, the merged result is written and pushed back to the editor (`externalChange`); if it cannot merge, the external version stays in place and the App's version is saved as a conflict copy (same naming as sync, `VaultFS.conflictPath`).
- **Creating cards only needs md**: Claude writes the `::` syntax and the App adds `^id`.
- **No recognition of handwriting for Claude**: ink is brainstorming, not the body of the knowledge base.

## Non-functional budgets

Measure with a Release build at the end of each phase of work; if over budget, fix first.

| Item | Budget | How to measure |
| --- | --- | --- |
| App size | < 100 MB (estimated 15–30 MB) | `.app` size of a Release build |
| Memory | iPhone idle with one md open: App + WebContent < 150 MB | Xcode Memory gauge, Instruments Allocations |
| Energy | Energy gauge Low when idle; no network connection in the background | Xcode Energy gauge, Instruments |
| Switching notes | < 50 ms | JS-side load time reported to the host |

### App size composition (estimated)

| Component | Size |
| --- | --- |
| Early Debug build (measured, without Supabase) | 1.8 MB |
| supabase-swift | about 3–8 MB |
| CM6 bundle (measured) | 0.5 MB |
| RevoGrid bundle | about 0.5–1 MB |
| fsrs-rs static library (UniFFI) | about 2–5 MB |
| PencilKit, PDFKit, WebKit | 0 (system frameworks) |

Vault content lives in Documents and does not count toward the app size. Measured release sizes: v1.1.0 DMG 10.6 MB, `.app` 36.7 MB, executable 33.9 MB (`EasyNotesTestSupport` is compiled only in DEBUG).

### Memory practices

- **Markdown**: one shared, pre-warmed WebView; `EditorState` keeps only the 20 most recent (LRU) and drops those not on screen on a memory warning. Tabs (Mac / iPad) add no resident cost: background tabs store only position and history while the editor stays the same one, so memory is governed by the LRU regardless of tab count.
- **CSV**: RevoGrid's WebView is created when a file opens and released when it closes; never resident.
- **PDF**: a `PKCanvasView` exists only for visible pages and is recycled when scrolled away; each page's strokes load on demand.
- **Images**: ImageIO generates thumbnails at display size; originals are not decoded.
- **Embedded previews and note cards**: rendered natively (CoreGraphics `SceneRenderer` for the whiteboard), the result stored as PNG in the preview cache (by content hash) and read by the WebView through `embed://`.
- **Whiteboard**: layers exist only for on-screen elements; images get thumbnails at display size.

### Energy practices

- **Realtime**: connected only in the foreground and dropped in the background; catch up on return to the foreground. No background refresh task (`BGAppRefreshTask`).
- **Upload**: the sync queue coalesces consecutive changes and uploads in a batch after a few idle seconds.
- **Hash**: computed only when mtime or size changes; large PDFs are hashed as a stream.
- **File watching**: FSEvents rescans only the paths in the event. The whole vault is never stat'ed, so when Claude Code changes many files only those paths are processed.
- **No polling**: no timer polling on the Swift side; no interval or rAF loops in JS; the whiteboard redraws only when content changes and does not use `TimelineView`.
- **Threads**: indexing and hashing use `.utility` QoS.

### Acceptance scenarios (Instruments)

1. Type continuously for 5 minutes (memory does not keep growing, CPU returns to idle after typing stops)
2. Flip through a 200-page PDF quickly (memory stays stable)
3. Claude Code changes 50 files at once (only those 50 are re-indexed; the whole vault is not rescanned)
