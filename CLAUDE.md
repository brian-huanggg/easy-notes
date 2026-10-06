# EasyNotes

## Language

- **en-US** for everything in the repository except product strings: docs, code comments, script output, commit messages, test names, identifiers.
- Product strings (UI text, the zh-Hant source keys in `L("…")` / `t(…)`, `.xcstrings`, Chinese and Zhuyin test data, sample notes, the in-app "What's New" content) stay Traditional Chinese for now. Do not translate them as part of unrelated changes.

## Docs (local md under `docs/`, no duplicated content)

- [Architecture](./docs/architecture/README.md): the current design and its reasons (no progress, no dates). The README holds cross-feature principles and dependency rules; each feature has one file. Read the matching file before implementing.
- Open work (unfinished items, device verification pending, risks) lives in GitHub Issues (`gh issue`), not in repo files. Never claim verification that was not actually done.
- [Changelog](./docs/Changelog.md): user-facing version changes, generated from commit messages; never edit by hand.
- [README](./README.md): project overview and developer setup.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), format `type: subject`, enforced by `.githooks/commit-msg`; subject ≤ 100 characters, details in the body.
- In the Changelog: `feat` (Added), `fix` (Fixed), `perf` (Changed), `security` (Security). **The subject is the line users read**: en-US, describing what users can see ("Tables can be reordered by dragging"), not implementation ("Refactor X").
- Not in the Changelog: `docs`, `refactor`, `test`, `chore`, `build`, `ci`, `style`, `revert`. Fixes users cannot see use these, not `fix`.
- Stage only the files you changed (never `git add -A`; other sessions may have files in the tree). Never push, never amend.

## Invariants

- Core (`Packages/EasyNotesCore`) knows no file types; every feature is a compile-time plugin. Plugins depend only on EasyNotesCore / EasyNotesUI (and shared libraries such as ExcalidrawKit); never on each other.
- The typing hot path never crosses the Swift ⇄ JS Bridge.
- Zhuyin (Bopomofo) input compatibility is a hard requirement.
- No hardcoded UI text: Chinese literals go through the module's `L("…")`; path, file-name and sync-protocol strings are collected into constants marked `// l10n:fixed`. Run `./scripts/check-l10n.py` before committing.
