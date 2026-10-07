# DiskGallery — Find copies of a folder on other drives

**Date:** 2026-10-07
**Status:** Approved design — awaiting implementation plan

## Background

Duplicates today are per-file (`DuplicateEngine` groups files by name + size,
optionally SHA-256 verified). The Unified browser aligns items across drives by
identical relative path, never by content. There is no way to ask "does this
folder exist, intact, somewhere on another drive?" — the question you need
answered before trusting a backup or freeing space.

## Decisions (from brainstorming)

1. **Match rule — same files, anywhere.** A candidate is a folder on a
   *different* drive, under any name/path, whose files have the same relative
   paths (inside the folder) and sizes as the selected folder.
2. **Supersets are shown, labeled.** Exact matches first; folders that contain
   every source file *plus* extras are listed as "Contains all + N extra files".
   Folders missing any source file, or with a size mismatch, are not matches.
   No near-miss / percentage matching.
3. **Verification — catalog match + Verify button.** Matching is catalog-only
   (instant, works offline) and labeled "Likely identical". A per-match Verify
   button SHA-256-hashes both sides when both drives are mounted, upgrading to
   "Verified identical" or listing differing files. Hashes are cached in
   `entry.contentHash` (shared with Duplicates).
4. **Entry point — context menu → sheet.** "Find Copies on Other Drives…" on a
   single selected folder in the drive browser opens a results sheet. On-demand
   only; no inspector section.
5. **Algorithm — anchor-file lookup** (no schema change, no rescan).
6. **Finder junk ignored** on both sides (`.DS_Store`, `._*`, etc.).
7. **Gating:** free (no `Feature` case).
8. **Out of scope:** MCP tool, inspector summary, "duplicate folders" browse
   view, same-drive matches.

## Core: `FolderMatchService`

New file `DiskGalleryCore/Duplicates/FolderMatchService.swift`, vended by
`Catalog` as `let folderMatches`. Read-only (catalog queries only); added to
`MutationGuardTests`' guarded file list.

### Types

```swift
public struct FolderMatch: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case exact
        case superset(extraFiles: Int, extraBytes: Int64)
    }
    public enum Verification: Sendable, Equatable {
        case unverified                 // at least one pair lacks a cached hash
        case verified                   // every pair hashed, all equal
        case mismatched([String])       // folder-relative paths whose hashes differ
    }
    public var volumeId: Int64
    public var volumeKey: String        // AnnotationStore.volumeKey(uuid:name:)
    public var volumeName: String
    public var snapshotId: Int64
    public var scannedAt: Date
    public var relPath: String          // candidate folder's path on its drive ("" = drive root)
    public var kind: Kind
    public var fileCount: Int           // comparable (non-junk) files in the candidate
    public var totalBytes: Int64
    public var verification: Verification
    public var id: String { "\(volumeId)|\(relPath)" }
}

public enum FolderMatchResult: Sendable, Equatable {
    case empty                          // source has no comparable files
    case matches([FolderMatch])         // may be an empty array = no copies found
}

public struct FolderMatchPair: Sendable, Equatable {
    public var relativePath: String     // path inside the folder
    public var sourceEntryId: Int64
    public var sourceRelPath: String    // path on the source drive
    public var sourceHash: String?
    public var targetEntryId: Int64
    public var targetRelPath: String    // path on the target drive
    public var targetHash: String?
}

public func findMatches(snapshotId: Int64, folderRelPath: String) async throws -> FolderMatchResult
public func pairs(sourceSnapshotId: Int64, sourceFolder: String,
                  targetSnapshotId: Int64, targetFolder: String) async throws -> [FolderMatchPair]
```

### Algorithm

1. **Source manifest.** All non-directory entries under `folderRelPath/` in the
   given snapshot (`relPath LIKE SQLPattern.childrenPrefix(of:) ESCAPE '\'`),
   keyed by path relative to the folder → (size, entryId, hash). Junk filtered
   out. If empty → `.empty`.
2. **Anchor.** Largest source file (tie-break: relative path ascending). Query
   the *latest* snapshot of every volume except the source's volume for
   non-dir entries with the anchor's `name` and `logicalSize` (uses
   `idx_entry_dupe`), using the same latest-snapshot CTE as `DuplicateEngine`.
3. **Candidate roots.** For each hit, if its `relPath` equals the anchor's
   relative path → root `""` (drive root); else if it ends with
   `"/" + anchorRelativePath` → root is the prefix. Otherwise drop. Dedupe by
   (volume, root). Cap at **50** candidates (ordered by volume name, path) so a
   ubiquitous file can't explode the search.
4. **Diff.** Load each candidate's manifest the same way (root `""` = whole
   snapshot) and compare against the source:
   - any source path missing or with a different size → discard;
   - no extras → `.exact`; extras → `.superset(extraFiles, extraBytes)`.
5. **Verification state** from cached `contentHash` across the matched pairs
   (source files only — extras are ignored): any pair with both hashes present
   and unequal → `.mismatched(paths)`; else all pairs hashed → `.verified`;
   else `.unverified`.
6. **Ordering.** Exact before superset; supersets by fewest extra files; then
   volume name, path.

### Junk filter

`JunkFiles.isJunk(relPath:)` — pure, in `Data/PathVisibility.swift`. True if any
path component is one of `.DS_Store`, `.Spotlight-V100`, `.Trashes`,
`.fseventsd`, `.TemporaryItems`, `.DocumentRevisions-V100`, `Thumbs.db`,
`desktop.ini`, or starts with `._`. Other hidden files (e.g. `.git/…`) still
count.

## App

### Entry point

`VolumeBrowserView.tagMenu`: when exactly one target is a directory, add
**"Find Copies on Other Drives…"** (next to "Open in Finder"). Always enabled —
matching works offline.

### `AppEnvironment`

- `folderCopiesTarget: FolderCopiesTarget?` (`volumeKey`, `snapshotId`,
  `folder: Entry`) — non-nil presents the sheet.
- `findFolderCopies(_ target:) async -> FolderMatchResult?` — wraps
  `catalog.folderMatches.findMatches`; errors go through `report(error)`.
- `verifyFolderMatch(_ match:, target:) async -> FolderVerifyOutcome` — loads
  `pairs(...)`, resolves both mounts via `volumes.mountURL(forKey:)`, hashes
  only files without a cached hash in a cancellable `Task.detached` (reports
  "n of N" progress), stores each via `duplicates.recordHash`, bumps
  `dataVersion`. Unreadable files are counted as "couldn't verify", never as a
  mismatch. Mirrors the existing `verify(set:)`.

### `FolderCopiesSheet` (new, `DiskGallery/Views/FolderCopiesSheet.swift`)

- Header: source folder name, comparable file count, total size.
- One row per match: drive name + folder path + drive's last-scan date;
  kind badge (**Identical** / **Contains all + N extra files (size)**);
  trust badge (**Likely identical (catalog)** / **Verified ✓** /
  **N files differ**, expandable to the paths).
- Row actions: **Verify** (enabled only when both drives are mounted; tooltip
  names the drive to connect; shows progress + Cancel while running) and
  **Reveal in Finder** (when the match's drive is mounted).
- Empty states: "No copies found on other scanned drives. Results reflect each
  drive's latest scan." and "This folder has no files to compare."
- After Verify, re-runs `findMatches` so badges reflect the new hashes; shows
  "Couldn't verify N files" if any were unreadable.

## Testing

`DiskGalleryCoreTests/FolderMatchServiceTests.swift` (using `Fixture`):

- exact match under a different name/path on another drive;
- superset with correct extra count and bytes;
- missing file → no match; size mismatch → no match;
- differing junk on each side → still exact;
- copy on the same drive → excluded;
- only the latest snapshot of a drive is considered;
- anchor copy at drive root (candidate root `""`);
- empty / junk-only source → `.empty`; no copies → `.matches([])`;
- folder names containing `_` / `%` don't over-match;
- 50-candidate cap;
- verification state: all hashes equal → `.verified`; one differs →
  `.mismatched`; any missing → `.unverified`;
- `pairs(...)` returns the expected source/target paths.

Plus `JunkFilesTests`, and `FolderMatchService.swift` added to
`MutationGuardTests`. UI verified by building the app and a manual pass.
