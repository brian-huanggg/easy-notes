# EasyNotes

## Language

- **en-US** for everything in the repository except product strings: docs, code comments, script output, commit messages, test names, identifiers.
- Product strings (UI text, the zh-Hant source keys in `L("…")` / `t(…)`, `.xcstrings`, Chinese and Zhuyin test data, sample notes, the in-app "What's New" content) stay Traditional Chinese for now and are translated later. Do not translate them as part of unrelated changes.

## Docs (local md under `docs/`, no duplicated content)

- [Architecture](./docs/architecture/README.md): the current design and its reasons (no progress, no dates). The README holds cross-feature principles and dependency rules; each feature has one file (`core` / `ui` / `markdown` / `whiteboard` / `pdf` / `sheets` / `flashcards` / `translation` / `security`).
- [Status](./docs/Status.md): only what is still open (device verification pending, unfinished work, security review, risks). No design reasons. Completed work is deleted, not checked off; git history keeps it.
- [Changelog](./docs/Changelog.md): user-facing version changes, generated from commit messages; never edit by hand.
- [README](./README.md): project overview and developer setup.

## Workflow

- **Before implementing**: read the matching file in `docs/architecture/` in full (no offset / limit); read the README and `core.md` only for cross-plugin work or Core changes; read each file once per session. Check [Status](./docs/Status.md) for related open items.
- **After implementing**: update [Status](./docs/Status.md) (delete verified items, add anything newly left unverified), commit after tests pass, with Status and code in the same commit. Never claim verification that was not actually done.
- **Commits**: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), format `type: subject`, enforced by `.githooks/commit-msg` (commitlint); malformed commits are rejected. The type decides the Changelog:
  - In the Changelog: `feat` (Added), `fix` (Fixed), `perf` (Changed), `security` (Security). **The subject is the line users read**: en-US, describing what users can see ("Tables can be reordered by dragging"), not implementation details ("Refactor X", "Add tests for Y").
  - Not in the Changelog: `docs`, `refactor`, `test`, `chore`, `build`, `ci`, `style`, `revert`. Fixes users cannot see (scripts, tests, internal refactors) use these types, not `fix`.
  - Subject ≤ 100 characters; details go in the body. Stage only the files you changed (never `git add -A`; other sessions may have files in the tree); never push, never amend.
- **Releasing** (design in "Release flow" of the [README](./docs/architecture/README.md)):
  1. `./scripts/release.sh`: runs tests, generates the Changelog from commits, updates `MARKETING_VERSION` and the "What's New" content, and creates the `chore(release): vX.Y.Z` commit and tag (local, no push; `--dry-run` previews first).
  2. `./scripts/publish-release.sh`: builds the DMG, signs the appcast, pushes, creates the GitHub Release, and uploads iOS / iPadOS to TestFlight (`--skip-testflight` publishes the Mac release only). Pushing and creating a Release are outward-facing: **ask the user first**, and never add `--yes` to skip the confirmation.
  - The version lives only in `MARKETING_VERSION` in `project.yml` (changed by `release.sh`); never edit it or tag by hand.

## Rules that must not be broken

- Core (`Packages/EasyNotesCore`) knows no file types; every feature is a compile-time plugin.
- Plugins depend only on EasyNotesCore / EasyNotesUI (and shared libraries such as ExcalidrawKit); plugins never import each other.
- The typing hot path never crosses the Swift ⇄ JS Bridge.
- Zhuyin (Bopomofo) input compatibility is a hard requirement; the UI language is Traditional Chinese first.
- No hardcoded UI text: Chinese literals always go through the module's `L("…")` (see [translation.md](./docs/architecture/translation.md)); path, file-name-convention and sync-protocol strings are the exception, collected into constants marked `// l10n:fixed`. Run `./scripts/check-l10n.py` before committing.

