# EasyNotes

A local-first, files-are-the-truth notes app for iOS, iPadOS and macOS. Design: [Architecture](./docs/architecture/README.md). Open work: [Status](./docs/Status.md). Release history: [Changelog](./docs/Changelog.md).

## Layout

| Path | Contents |
| --- | --- |
| `App/` | SwiftUI shell, store, sync wiring, resources |
| `Packages/EasyNotesCore/` | Core (Vault, index, sync engine, DocumentKind) and EasyNotesUI (plugin registry, design system, WebView host) |
| `Packages/Kind*`, `Packages/Flashcards` | Compile-time plugins: Markdown, Whiteboard, PDF, Sheets, Flashcards |
| `Packages/ExcalidrawKit`, `SupabaseSync`, `AppUpdater` | Shared Excalidraw model / renderer, Supabase backend, Sparkle wrapper |
| `web/` | TypeScript sources of the WebView editors (CodeMirror 6, RevoGrid); bundled into the plugins |
| `supabase/` | Database migrations |
| `scripts/` | Test, build and release scripts |
| `Tests/E2E/` | XCUITest end-to-end tests |
| `project.yml` | XcodeGen configuration (`EasyNotes.xcodeproj` is generated from it) |

## Development

```sh
brew install xcodegen
pnpm install && (cd web && pnpm build)     # rebuild after changing web/src
xcodegen generate && open EasyNotes.xcodeproj
(cd Packages/EasyNotesCore && swift test)  # Core unit tests; run `swift test` in each package
```

Vault location: macOS `~/Documents/EasyNotes`; iOS uses the app's Documents (visible in the Files app).
Debug builds can be inspected with Safari → Develop → the WebView. See [CLAUDE.md](./CLAUDE.md) for the full command list and contribution rules.
