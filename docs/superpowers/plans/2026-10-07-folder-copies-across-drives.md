# Find Copies of a Folder on Other Drives — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Right-click a folder → "Find Copies on Other Drives…" → a sheet listing folders on other drives holding the same files (exact or superset), with SHA-256 Verify.

**Architecture:** A read-only Core service (`FolderMatchService`) finds candidates via an anchor-file lookup over each other drive's latest complete snapshot and diffs (path-inside-folder, size) manifests. The app adds a context-menu item, an `AppEnvironment` target + verify method (mirrors `verify(set:)`), and a `FolderCopiesSheet`.

**Tech Stack:** Swift 6, SwiftUI (macOS), GRDB/SQLite, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-07-folder-copies-across-drives-design.md`

## Global Constraints

- Core must not import AppKit/SwiftUI; the app must not import GRDB.
- `FolderMatchService.swift` is read-only (catalog queries only) and is added to `MutationGuardTests`.
- Only *other* drives are searched; same-drive copies are excluded.
- Finder junk is ignored on both sides: `.DS_Store`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`, `.DocumentRevisions-V100`, `Thumbs.db`, `desktop.ini`, any `._*`.
- Candidate cap: **50**.
- Free feature — no `Feature` case.
- New source files require `xcodegen generate` (the `.xcodeproj` is committed).

**Spec amendment:** `FolderMatchResult` is a struct (`sourceFileCount`, `sourceBytes`, `matches`, `isEmpty`) instead of an enum, so the sheet header can show the source folder's comparable file count and size.

**Spec refinement:** "latest snapshot" means latest *complete* snapshot (`isComplete = 1`), so a paused/in-progress rescan can't make a superset look exact.

## Review Focus

1. Sibling folders with similar names (`2024_trip` vs `2024Xtrip`, `Photos` vs `photos`) — SQLite `LIKE` is ASCII case-insensitive and `_` is a wildcard; manifests must contain only the folder's true descendants. → Task 1 test `testSimilarlyNamedSiblingFoldersDontLeakIntoManifest`.
2. A drive mid-rescan (incomplete latest snapshot) — results must come from its latest complete scan. → Task 1 test `testIncompleteLatestSnapshotIsIgnored`.
3. A copy sitting at a drive's root (candidate root `""`) — must be found and revealable. → Task 1 test `testCopyAtDriveRoot`.
4. A source folder containing only Finder junk — must report "nothing to compare", not "no copies". → Task 1 test `testJunkOnlyFolderIsEmpty`.
5. Unreadable / vanished files during Verify — must surface as "couldn't verify", never as a mismatch or as verified. → Task 2 (app logic: unreadable files leave no hash, so verification stays `.unverified`; count shown in the row).

---

### Task 1: Core — `JunkFiles` + `FolderMatchService`

**Files:**
- Modify: `DiskGalleryCore/Data/PathVisibility.swift` (append `JunkFiles`)
- Create: `DiskGalleryCore/Duplicates/FolderMatchService.swift`
- Modify: `DiskGalleryCore/Catalog.swift` (add `public let folderMatches: FolderMatchService`)
- Modify: `DiskGalleryCoreTests/MutationGuardTests.swift` (guard the new file)
- Modify: `DiskGalleryCoreTests/PathVisibilityTests.swift` (add `JunkFilesTests`)
- Create: `DiskGalleryCoreTests/FolderMatchServiceTests.swift`

**Interfaces:**
- Produces:
  - `JunkFiles.isJunk(relPath: String) -> Bool`
  - `FolderMatch` (`volumeId`, `volumeKey`, `volumeName`, `snapshotId`, `scannedAt`, `relPath`, `kind: Kind`, `fileCount`, `totalBytes`, `verification: Verification`, `id`), `FolderMatch.Kind { exact, superset(extraFiles:extraBytes:) }`, `FolderMatch.Verification { unverified, verified, mismatched([String]) }`
  - `FolderMatchResult` (`sourceFileCount`, `sourceBytes`, `matches`, `isEmpty`)
  - `FolderMatchPair` (`relativePath`, `sourceEntryId`, `sourceRelPath`, `sourceHash`, `targetEntryId`, `targetRelPath`, `targetHash`)
  - `catalog.folderMatches.findMatches(snapshotId: Int64, folderRelPath: String) async throws -> FolderMatchResult`
  - `catalog.folderMatches.pairs(sourceSnapshotId: Int64, sourceFolder: String, targetSnapshotId: Int64, targetFolder: String) async throws -> [FolderMatchPair]`

- [ ] **Step 1: Write failing tests** — `FolderMatchServiceTests.swift` (full content as committed): seeds synthetic drives (`Volume`/`Snapshot`/`Entry` rows, as `CrossDriveDuplicateTests` does) via a `seed(_:_:_:scannedAt:isComplete:)` helper, and covers: exact match at a different path; superset counts/bytes; missing file; size mismatch; junk ignored; same drive excluded; latest snapshot only; incomplete latest snapshot ignored; copy at drive root; empty & junk-only source; no copies; similarly-named siblings; 50-candidate cap; exact-before-superset ordering; verified / mismatched from cached hashes; `pairs` paths. Plus `JunkFilesTests` (junk names, `._` prefix, junk folder component, ordinary dotfiles not junk).
- [ ] **Step 2: Add `JunkFiles`, a stub `FolderMatchService`, wire into `Catalog`; `xcodegen generate`; run tests — expect FAILs.**
- [ ] **Step 3: Implement `FolderMatchService`** — `manifest` (LIKE prefix + Swift `hasPrefix` re-check + junk filter, keyed by path inside folder), `anchor` (largest, tie → path ascending), `candidates` (latest-complete-snapshot CTE, `name`+`logicalSize` lookup, suffix-strip to root, dedupe, cap 50), `compare` (missing/size → nil, extras → superset, hashes → verification), `order` (exact, then fewest extras, then drive name, path), `pairs`.
- [ ] **Step 4: Add `FolderMatchService.swift` to `MutationGuardTests`; run the full Core suite — expect PASS.**

```sh
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

- [ ] **Step 5: Commit** — `feat(core): find copies of a folder on other drives`

### Task 2: App — context menu, environment, sheet

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` (`FolderCopiesTarget`, `FolderVerifyOutcome`, `folderCopiesTarget`, `showFolderCopies(_:)`, `findFolderCopies(_:)`, `verifyFolderMatch(_:target:progress:)`)
- Modify: `DiskGallery/App/DiskGalleryApp.swift` (present the sheet)
- Modify: `DiskGallery/Views/VolumeBrowserView.swift` (`FolderView.tagMenu` item)
- Create: `DiskGallery/Views/FolderCopiesSheet.swift`

**Interfaces:**
- Consumes: Task 1's `catalog.folderMatches`, `catalog.duplicates.recordHash`, `catalog.hasher`.
- Produces:
  - `struct FolderCopiesTarget: Identifiable { volumeKey: String; volumeName: String; folder: Entry }`
  - `struct FolderVerifyOutcome { hashed: Int; unreadable: Int }`
  - `AppEnvironment.verifyFolderMatch(_ match: FolderMatch, target: FolderCopiesTarget, progress: @escaping @MainActor @Sendable (Int, Int) -> Void) async -> FolderVerifyOutcome?` — nil when a drive is offline or the catalog errors. Hashes only files lacking a cached hash, records each hash immediately (so Cancel keeps progress), counts unreadable files separately, bumps `dataVersion`. Cancellation propagates to the detached hashing task via `withTaskCancellationHandler`.

- [ ] **Step 1: Environment** — add the types, the `folderCopiesTarget` property beside `changesVolume`, and the three methods next to `verify(set:)`.
- [ ] **Step 2: Sheet** — `FolderCopiesSheet`: header ("Copies of “name”", "N files · size · on Drive"), Done button; states: loading spinner, "Nothing to compare", "No copies found … latest scan", "Couldn't search the catalog"; per-match card: drive name, path (or "Drive root"), "scanned <relative date>", kind badge (Identical / Contains all + N extra files (size)), trust badge (Likely identical (catalog) / Verified ✓ / Differs) + Offline badge, disclosure of differing paths, "Couldn't verify N files" note, Verify (disabled unless both drives mounted, help names the missing drive; while running shows `ProgressView` + "n of N files" + Cancel), Reveal in Finder. Re-runs the search after verifying; cancels any verify on disappear.
- [ ] **Step 3: Wiring** — `.sheet(item:)` in `DiskGalleryApp.swift` next to the Changes sheet; in `FolderView.tagMenu`, when exactly one directory is targeted, add `Label("Find Copies on Other Drives…", systemImage: "square.on.square")` + `Divider()` after the "Open in Finder" block.
- [ ] **Step 4: `xcodegen generate`; build the app; run the Core suite.**

```sh
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

- [ ] **Step 5: Manual check** — right-click a folder known to be backed up on another scanned drive → sheet lists it as Identical; with both drives connected, Verify → "Verified ✓".
- [ ] **Step 6: Commit** — `feat: Find Copies on Other Drives sheet`
