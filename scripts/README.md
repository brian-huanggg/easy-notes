# Scripts

Run from the repository root. Each script's header comment has the full details.

## Release

| Command | What it does |
| --- | --- |
| `./scripts/release.sh [X.Y.Z\|patch\|minor\|major] [--dry-run] [--skip-tests]` | Runs tests, generates the Changelog and "What's New", bumps `MARKETING_VERSION`, commits and tags. Local only. |
| `./scripts/publish-release.sh [--skip-testflight] [--yes]` | Builds the DMG, signs the Sparkle appcast, pushes `main` and the tag, creates the GitHub Release, then uploads iOS / iPadOS to TestFlight. |
| `./scripts/upload-testflight.sh [--export]` | Archives iOS / iPadOS and uploads to TestFlight (`--export` only writes the `.ipa`). Rerun this alone if the upload step of `publish-release.sh` fails. |
| `./scripts/make-dmg.sh` | Builds the macOS Release into `build/EasyNotes-<version>.dmg`. |
| `./scripts/sparkle-tools.sh path\|generate-keys\|export-key <file>` | Downloads Sparkle's CLI tools; creates or backs up the update-signing key. |
| `python3 scripts/changelog.py has-unreleased\|promote\|insert\|show` | Reads and writes `docs/Changelog.md` (used by the release scripts). |

Typical release: `./scripts/release.sh --dry-run` → `./scripts/release.sh` → `./scripts/publish-release.sh`.

## Development

| Command | What it does |
| --- | --- |
| `./scripts/install-mac.sh [--web]` | Builds the macOS Release and replaces `/Applications/EasyNotes.app` (`--web` rebuilds the CM6 bundle first). |
| `./scripts/check-l10n.py [--summary] [--stale]` | Finds UI strings that bypass `L("…")` / `t("…")` and missing English translations. Run before committing. |
| `./scripts/test-e2e.sh [smoke\|sync\|perf\|all] [mac\|ipad] [--ci]` | Runs the XCUITest E2E suites; results in `build/E2E-*.xcresult`. |
| `./scripts/test-sync.sh` | Runs the SupabaseSync integration tests against a local Supabase (needs Docker). |
| `python3 scripts/test_changelog.py` | Unit tests for `changelog.py`. |

## Test fixtures

| Command | What it does |
| --- | --- |
| `./scripts/anki-package.py fixtures` | Regenerates the Anki `.apkg` fixtures (`pack …` packs a real collection). Needs `uv`. |
| `./scripts/fsrs-vectors.py` | Regenerates the FSRS scheduling reference vectors. Needs `uv`. |
| `./scripts/whiteboard-stress.py <count> <out.excalidraw>` | Writes a whiteboard stress-test file. |
