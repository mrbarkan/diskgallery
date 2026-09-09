# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Response Style

Keep responses concise and under the output token limit; summarize long results rather than emitting exhaustive output.

## Commands

Regenerate the Xcode project after editing `project.yml` (the `.xcodeproj` is committed, so this is only needed when project structure/settings change, not for day-to-day source edits):
```sh
xcodegen generate            # brew install xcodegen
```

Build:
```sh
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

Run the full Core test suite (the only real test target — `DiskGalleryUITests` just drives the built app and isn't part of routine iteration):
```sh
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

Run a single test:
```sh
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test \
  -only-testing:DiskGalleryCoreTests/ScannerTests/testScanRecordsEveryEntryWithCorrectSizes
```

Headless scan, for scripting/verification without opening the UI:
```sh
DiskGallery.app/Contents/MacOS/DiskGallery --scan /Volumes/YourDrive
```

Build the signed beta DMG (bump `CURRENT_PROJECT_VERSION` on the `DiskGallery` app target in `project.yml` first — that integer is the beta number shown in-app and gates the 14-day trial window):
```sh
Tools/build-beta-dmg.sh            # full archive + notarize + staple + dmg
SKIP_NOTARIZE=1 Tools/build-beta-dmg.sh   # local-only smoke build
```

## Architecture

Two-target split enforced by `project.yml`:
- **`DiskGalleryCore`** — pure-logic framework: storage, scanning, duplicates, annotations, search, execution, licensing, thumbnails. Fully encapsulates GRDB/SQLite and has no AppKit/SwiftUI dependency, so it's unit-testable in isolation.
- **`DiskGallery`** — the SwiftUI app shell. Imports only `DiskGalleryCore`, never GRDB directly.

`Catalog` (`DiskGalleryCore/Catalog.swift`) is the single facade the app talks to. It owns the `AppDatabase` (a GRDB WAL `DatabasePool`, migrated on init via `Migrations.makeMigrator()`) and vends every service as a `let` property: `library`, `scanner`, `duplicates`, `annotations`, `search`, `hasher`, `finderTags`, `planning`, `changes`, `backup`, `driveRoles`, `unified`, `execution`, `thumbnails`, `gallery`. Construct with `Catalog.makeDefault()` (app default path) or `Catalog(databaseURL:)` (tests, temp file — see `Fixture` in `DiskGalleryCoreTests/Support.swift`).

**Read-only invariant.** Scanning/hashing code (`Scanning/Scanner.swift`, `VolumeMetadata.swift`, `DriveHardwareProbe.swift`, `ScanProgress.swift`, `Duplicates/HashVerifier.swift`) must never touch the filesystem. `MutationGuardTests` enforces this statically — it greps those five files for mutating APIs (`removeItem`, `.write(to:`, `createFile`, etc.) and fails if any appear. The only writes the app makes outside its own catalog DB are Finder tags (`FinderTags/FinderTagWriter.swift`) and the execution engine below.

**Execution engine** (`Execution/`) is the one deliberate exception to read-only: `FileCopier` (copy → SHA-256 verify → atomic rename, never overwrites) and `FileTrasher` (send-to-Trash), orchestrated by `ExecutorService`, which materializes copy/move/delete operations from an Organize plan. Delete only runs after a SHA-256-identical copy is verified on a *different*, backup-role-tagged connected drive — never the last copy. Treat any change here as safety-critical (data-loss risk).

**App shell.** `DiskGalleryApp.swift`'s `Launcher.main()` branches on `--scan <path>` for a headless scan, otherwise boots the SwiftUI `DiskGalleryApp`. `AppEnvironment` (`App/AppEnvironment.swift`) is the app-wide `@Observable` view-model: it owns the `Catalog`, license/scan/execution state, and the sidebar selection (`SidebarItem`). `ContentView` is a three-column `NavigationSplitView` (library sidebar → `ContentColumn`, which switches on `SidebarItem` → detail column); `VolumeService` tracks drive mounts via `NSWorkspace`. The UI is a single native ("Classic") design — six `Accent` colors plus light/dark/system mode; there is no runtime skin switch.

**Licensing** is offline and asymmetric-signature based: `Tools/dgkeygen` signs license payloads with an Ed25519 private key (`DG_PRIVATE_KEY` env var, never committed — see `dg-private-key.txt` in `.gitignore`), and `LicenseVerifier` in Core checks the signature against the public key baked into the app. `Feature` enum lists the Pro-gated capabilities; the gating *policy* (`isUnlocked(_:)`) lives in the app's `LicenseStore`, not in Core. `BetaGate` is a separate, build-scoped concern: active only when compiled with `DG_BETA=BETA`, it self-expires 14 days after first launch, keyed by `CURRENT_PROJECT_VERSION` so each beta bump gives testers a fresh window.

`docs/superpowers/{specs,plans}/` holds the spec/plan-per-feature history (this project is developed brainstorm → spec → plan → implement); check there for the design rationale behind a given area before assuming intent from code alone.

## Debugging

Before fixing a UI or status bug, trace the root cause down to the data/backend layer first; do not assume the UI layer is the problem (e.g., check for orphaned/stuck transactions before editing display logic).

## Editing Conventions

Prefer targeted edits over broad sed/regex rewrites on source files; sed rewrites have caused recursion and unintended replacements.

## UI Edits

When editing a specific on-screen element the user points at (logos, headers, badges), confirm you are targeting the exact component (e.g., footer vs navbar logo) before editing.

## Commits & Verification

Always verify with typecheck, lint, and build before committing, and only commit the files relevant to the current task (preserve pre-existing/untracked work).
