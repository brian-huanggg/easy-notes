# Security Design and Threat Model

This document holds: assets, trust boundaries, the threat model, the protections each boundary uses today and why, and the security invariants that must never be violated. Open security work is tracked in [Status](../Status.md); version changes live in [Changelog](../Changelog.md).

EasyNotes is a personal, unpublished app (see [README](./README.md)), so the threat model centers on "my data is not obtained, rewritten or damaged by other people or malicious files"; multi-tenancy and compliance are out of scope.

## Assets

| Asset | Location | Why it matters |
| --- | --- | --- |
| Note content | `.md` / `.excalidraw` / `.pdf` / `.csv` inside the vault | May contain passwords, personal data, work content; it is the only truth |
| Login state (Supabase session) | Keychain (supabase-swift default) | Whoever has it can read and write the cloud vault |
| Index database | SQLite inside `.easynotes/` (rebuildable) | Contains full text, equivalent to a copy of the notes |
| Sync metadata | `files` table, Storage `vault` bucket | Cloud copy of the notes |
| Signing identity and TestFlight credentials | Dev machine Keychain, Apple account | Forging app releases |

## Trust boundaries and attackers

```
Malicious file (md / pdf / csv / excalidraw, from others or downloaded)
        │ parse, render
        ▼
  ┌── App ───────────────────────────────┐
  │ WebView (JS) ──Bridge──► Swift shell  │
  │ Plugins (native parsing) ──► Vault    │
  └──────────────┬───────────────────────┘
                 │ HTTPS (supabase-swift)
                 ▼
        Supabase (Auth · Postgres · Storage · Realtime)
```

| Attacker | What they can do | Main defenses |
| --- | --- | --- |
| Malicious content (notes, PDFs, import files sent by others) | Make a renderer run script, read or write files outside the vault, crash or hang the app | WebView isolation, Bridge allowlist, parser robustness |
| Other programs on the same machine | Read the vault, index, logs, clipboard | File permissions, FileVault, logs contain no content |
| Network man-in-the-middle | Eavesdrop on or tamper with sync traffic | TLS (ATS default), content-addressed hash verification |
| Other Supabase users | Read or write other people's rows and blobs | RLS, Storage policy |
| Compromised cloud or account | Tamper with paths, content, delete | The client does not trust remote data: validates paths and hashes |
| Supply chain | Malicious SPM / npm packages | Pinned versions, audits, minimal dependencies |
| Lost device | Read the vault | Full-disk encryption (FileVault / iOS data protection); the app adds no encryption of its own |

**Not defended against**: malware that already holds the user's login session, a fully compromised operating system, external links the user deliberately opens and trusts. Files as truth and plaintext on disk are a deliberate trade-off (Claude Code and other tools must read and write directly), so encryption at rest is left to the system layer.

## Security invariants

These rules are the yardstick for review and changes; violating one is a vulnerability:

1. **Vault paths are always relative and always stay inside the vault.** For a path from any source (Bridge, remote sync, `vault://`, file names), before it becomes a file URL, reject absolute paths, `..`, `.` segments and results that leave the vault after resolving symlinks.
2. **Do not trust remote data.** A `path` obtained from Supabase must be validated before it can be written; a downloaded blob's SHA-256 must be compared with its `hash` before it can be applied or cached.
3. **The WebView has no generic native capability.** The Bridge exposes only the named messages each plugin defines; there is no generic entry such as "read any file", "open any URL" or "run a command". Every field from JS is treated as untrusted input.
4. **The WebView loads only in-app resources and custom schemes.** No remote pages or scripts; external links in a page are handed to the system browser and never navigated inside the WebView.
5. **Credentials live only in the Keychain; code and the repo hold only public keys.** Only the Supabase publishable (anon) key is allowed in the app; `service_role` or any private key must not appear; `.env*` is not under version control.
6. **Cloud writes always go through `commit_file` or `purge_files`.** Tables have no insert / update / delete policy. Storage never overwrites; an owner may delete a blob only when no row of `files` or `file_blobs` references its hash (a policy on `storage.objects`, so a buggy or hostile client cannot delete content a live or restorable file needs).
7. **Logs and crash information contain no note content.** Outside DEBUG no message content is printed; `os_log` user data is marked `.private`.
8. **Test hooks exist only in DEBUG.** Release ignores launch arguments such as `-EasyNotesVaultRoot` (see "Testing" in the [README](./README.md)).

## Current design per boundary

### Vault (file system)

- macOS: `~/Documents/EasyNotes`, **not sandboxed** (reasons in "Vault location" of the [README](./README.md): Finder and Claude Code must read and write directly). Without a sandbox there is no OS-level file isolation, so the path rules (invariant 1) rest entirely on code.
- Writes are atomic (write a temp file, then replace), never leaving half a file.
- The `vault://` scheme answers only vault-relative paths, rejects `..`, `.` and empty paths, and strips query and fragment first; `embed://` applies the same rules; `symbol://` returns only SF Symbol images.
- `.easynotes/device-id` is not synced.

### WebView and Bridge

- Only the Markdown and Sheets plugins use a WebView, sharing `WebEditorHost`: one `bridge` message handler, messages are `{type, …}` and the plugin's `onMessage` dispatches by `type`.
- Pages load with `loadFileURL(_, allowingReadAccessTo:)`, with read access limited to the folder holding that page inside the plugin bundle; vault images do not use `file://` but only `vault://` (with the path checks above).
- **Navigation**: `WebEditorHost`'s navigation delegate lets only the page itself through; any other navigation is cancelled, and an `http(s)` / `mailto` the user clicked is handed to the system to open.
- **CSP**: both pages set `default-src 'none'` through `<meta>`, allowing only scripts from the same folder (`'self'`), styles and fonts from the same folder (KaTeX), inline styles (needed by CodeMirror and the injected theme), and `vault:` / `embed:` / `symbol:` / `data:` images; `connect-src 'none'`, with no remote resources and no inline script. A WebView page of a new plugin must apply the same CSP.
- Swift → JS uses `callAsyncJavaScript` with named parameters and never concatenates strings; the injected language and theme are JSON-encoded as literals.
- No path from the Bridge is used directly as a write target: Markdown's `changed` accepts only document ids that editor has loaded and that pass `VaultFS.isSafe`; `VaultStore.write` checks again. When a link title creates a new file it goes through `VaultFS.safeFileName` and can only be a single path segment.
- The Bridge is not on the typing hot path (see [markdown.md](./markdown.md)), so message validation does not affect feel.
- Note content renders in the WebView with CodeMirror decorations and user text is never inserted as HTML; `innerHTML` is used only for the app's built-in SVG icon constants.

### Sync (Supabase)

- **Identity**: Supabase Auth; `files` RLS allows only `select` on one's own rows (`user_id = auth.uid()`).
- **Writes**: only by calling `commit_file` or `purge_files` (`security definer`, `search_path = ''`); `anon` and `public` have no execute permission; the row's owner is decided by `auth.uid()` and the client cannot specify `user_id`. `purge_files` touches only the caller's own rows, ignores unknown ids and is idempotent.
- **Blobs**: the Storage bucket `vault` is private with path `<user_id>/<hash>`, the policy matches the folder name against `auth.uid()`; `select` and `insert` exist, there is no `update`, so uploaded content cannot be overwritten, and `delete` is allowed only for the caller's own blobs that nothing references (see invariant 6). An upload happens before its commit, so a blob is briefly unreferenced; a permanent delete of another file with identical content in that window could remove it (accepted, the next edit uploads it again).
- **Content addressing**: the hash is SHA-256 and re-uploading the same hash counts as success; so downloaded content must have its hash verified by the client (invariant 2).
- **Soft delete**: rows are purged by `pg_cron` after 30 days; Storage content is not deleted (it may be shared by other versions).
- **Permanent delete**: the row stays as a tombstone (path, hash and size cleared, so it reveals nothing about the file) for 365 days so every device learns about it; the content the file alone used is deleted from Storage. Design in "Permanent delete" of [core.md](./core.md).
- **Key**: the app holds a publishable key, and permissions are decided entirely by RLS and RPC.
- **Transport**: default ATS (HTTPS) with no exception domains.

### Plugins and file parsing

- Plugins are compile-time SPM modules; no code is loaded at run time and there is no third-party plugin interface.
- Every parser (Markdown, Excalidraw JSON, `.pdf.ink`, CSV / TSV, Anki import / export, `.jsonl` review logs) faces files that may have been tampered with: it must tolerate malformed input, never crash, never loop forever, and never exhaust memory through nesting or size; unknown fields are preserved as is and never treated as instructions.
- **Cost caps**: any processing of file content must be linear (or have an explicit cap). The sync merge `Diff3` caps on an estimated diff cost and treats exceeding it as a conflict leaving a conflict copy; the `[[…]]` regex does not allow the target or alias to contain `[`, avoiding quadratic cost from `[[[[…`.
- **Numeric values from the Bridge**: integers from JS such as column indexes and row ids are always range-checked (`SheetDocument.maxColumns`, row ids limited to 53 bits), and out-of-range values are rejected and must never be used to index arrays or allocate memory.
- PDF is rendered by PDFKit; the app never modifies the original file and annotations go into the sidecar.

### Diagnostics (logs and crash reports)

Design: find bugs and crashes across devices without any telemetry service; nothing leaves the device unless the user exports it.

- **Logging**: every module makes its logger through `DiagnosticsLog.logger(category)` (subsystem `app.easynotes`), so the export can filter to our own entries. Vault paths and anything that may be note content are interpolated `.private`; an error is logged as `DiagnosticsLog.describe(error)` (`domain:code`), never `localizedDescription` or `"\(error)"`, which can embed a file name. The only `print` left is the Bridge trace inside `#if DEBUG`.
- **Crashes and hangs**: MetricKit (`MXMetricManager`, subscribed at launch in `App/Support/Diagnostics.swift`, skipped in UI tests) delivers diagnostic and metric payloads, at most daily and on the launch after the crash. `DiagnosticsStore` keeps the newest 30 as JSON in Application Support (`<bundle id>/Diagnostics`), not in the vault: the vault is watched, indexed and handed to other tools, and diagnostics are not note data. They are never synced and never uploaded. MetricKit stacks hold symbols and addresses, no note content.
- **Export**: Settings > Diagnostics > "Export Diagnostics…" writes one JSON file (recent log lines of our subsystem, the stored payloads, app version, build, OS version, hardware model) to a location the user picks (`fileExporter`). Reading the log store is the only moment content-adjacent data is touched, and `.private` values stay redacted in it.
- **Log store scope**: macOS reads the system-wide store (`OSLogStore(scope: .system)`), which needs no entitlement for an admin user (checked on macOS 15), and falls back to this process only for a non-admin user; iOS has no system scope, so an export there holds the current launch only and relies on the MetricKit payloads for earlier crashes. The report records which scope it read.
- **No third-party SDK** and no network code in this path. Adding any uploader later changes the threat model: it needs its own entry here first.

### Distribution and signing

- iOS / iPadOS: TestFlight (Apple signing and review).
- macOS: DMG install, updated afterwards by Sparkle. The update channel is a new attack surface, so both the appcast and the DMG are EdDSA-signed and verified by the public key built into the app (`SPARKLE_PUBLIC_ED_KEY`), only an HTTPS `SUFeedURL` is allowed, and the private key lives only in the release Mac's keychain, never in the repo or CI.
- macOS currently has neither Hardened Runtime nor the sandbox enabled; it is for personal use and not notarized. Before anyone else installs it, Hardened Runtime must be enabled with notarization, and the needed exception entitlements inventoried.
- Entitlements stay minimal: currently only Sign in with Apple.

### Supply chain

- Swift: `Package.resolved` pins versions; npm packages (pnpm): `pnpm-lock.yaml` pins, installation uses `pnpm install --frozen-lockfile`, only `onlyBuiltDependencies` in `pnpm-workspace.yaml` may run install scripts, and the bundled JS is contained in the app (never downloaded at run time).
- Before adding a dependency, check its license, maintenance status and known vulnerabilities; prefer packages with few dependencies.

## Review method

Review process, tools and findings are tracked in [Status](../Status.md); this document defines only "what counts as secure". Each review verifies the invariants above one by one, and when a new attack surface is found, comes back to update this document's boundaries and invariants.
