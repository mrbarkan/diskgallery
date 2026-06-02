# Scan Exclusion (Firmlink Double-Count Fix) — Design

**Date:** 2026-06-02
**Status:** Approved for planning

## Problem

Scanning the boot drive (`/`) reports far more data than the disk physically holds.
On the reporter's Mac, DiskGallery showed **611.86 GB / 3,233,889 files** on a
**494.38 GB** APFS volume — impossible for distinct files.

### Root cause (confirmed from the exported catalog)

macOS (Catalina+) boots from an **APFS volume group**:

- `Macintosh HD` (read-only system) mounted at `/`
- `Macintosh HD – Data` (user data) mounted at `/System/Volumes/Data`

The two are stitched together by **firmlinks** — `/Applications`, `/Users`,
`/Library`, etc. at the root transparently resolve into the Data volume. Firmlinks
are an APFS feature, **not symlinks**.

The scanner (`Scanner.swift:159-163`) descends into any directory that is not a
package or a **symbolic link**:

```swift
let isSymlink = values?.isSymbolicLink ?? false
if isDir && !isPackage && !isSymlink { toEnqueue.append(...) }
```

Firmlinks fail the `isSymbolicLink` test, so starting at `/` the scanner walks every
file **once** via the firmlinks at root (`/Applications`, `/Users`, …) and **a second
time** via `/System/Volumes/Data/…` — counting the same inodes twice.

### Proof (from `DiskGallery Library.diskgallery`, snapshot 11)

| Folder | via root firmlink | via `System/Volumes/Data/…` |
|---|---|---|
| Applications | 6,166 files / 2,333,465,938 B | 6,166 files / 2,333,465,938 B (identical) |
| Library | 129,531 files / 35,497,308,510 B | 129,531 files / 35,497,308,776 B (identical) |
| Users | 1,261,250 files / 214.19 GB | 1,261,957 files / 214.21 GB (live-FS drift) |

The `System/Volumes/Data/` subtree alone holds **1,523,552 files / 277.47 GB** — a
near-exact mirror of the root tree. This phantom duplication also inflates the
"reclaimable duplicates" figure, since every file has an identical twin.

> Note: the read-only / Finder-only design meant this never put real data at risk.
> The existing network/cloud-drive `VolumeFilter` only controls which *drives* are
> listed; it does nothing about *within-drive* firmlink traversal.

## Goal

When scanning the boot volume, do not traverse `/System/Volumes`, so the catalog
reflects each file once. One sentence: **skip the `/System/Volumes` re-mount on the
boot volume so files are counted once.**

## Decisions

1. **Scope:** exclude only `System/Volumes`. This removes the entire 277 GB
   double-count. Other system pseudo-paths (`/dev`, swapfiles, `/.vol`) are tiny and
   left in.
2. **Gating:** apply the exclusion only when the scan root is `/` (the boot volume).
   External drives are never affected, even one that happens to contain a folder
   literally named `System/Volumes`.
3. **Existing data:** no migration / cleanup code. The fix affects future scans only;
   the user rescans once and the new snapshot is correct. Old inflated snapshots sit
   harmlessly in the DB until overwritten.
4. **Excluded node:** omit `System/Volumes` entirely — it is never recorded as an
   entry. The exclusion check runs *before* the entry is inserted.

## Approach

Chosen: **pure path-exclusion helper** (mirrors the existing `VolumeFilter` /
`PathVisibility` pattern in Core), plus a one-line boot-volume check and an early
`continue` in the scanner loop.

Rejected alternatives:

- **Firmlink-aware dedup** (parse `/usr/share/firmlinks`): fragile across OS
  versions, parses a system file, same outcome as skipping `/System/Volumes`.
- **inode/device dedup** (`(st_dev, st_ino)` seen-set): general but requires holding
  ~3.2M identities and stat-ing everything — an architecture change and perf hit for
  no benefit here.

## Components

### New: `DiskGalleryCore/Scanning/ScanExclusion.swift`

Pure, `Sendable`, unit-testable policy:

```swift
public enum ScanExclusion {
    /// Paths skipped entirely when scanning the boot volume. `/System/Volumes`
    /// re-mounts the Data volume that root firmlinks already expose, so walking it
    /// double-counts ~half the disk. Match is exact (the node is omitted, so no
    /// descendant path is ever generated).
    static let bootVolumeExclusions: Set<String> = ["System/Volumes"]

    public static func isExcluded(relPath: String, isBootVolume: Bool) -> Bool {
        isBootVolume && bootVolumeExclusions.contains(relPath)
    }
}
```

### Changed: `DiskGalleryCore/Scanning/Scanner.swift`

1. After `let scanRoot = volumeURL.resolvingSymlinksInPath()` (line 72), derive the
   gate once:

   ```swift
   let isBootVolume = scanRoot.path == "/"
   ```

2. In the child loop, immediately after `rel` is built (line 152) and before
   `toInsert.append(...)`:

   ```swift
   if ScanExclusion.isExcluded(relPath: rel, isBootVolume: isBootVolume) { continue }
   ```

The `continue` runs before insertion, enqueueing, and counting — so `System/Volumes`
is never recorded, never descended, never summed. Resume is safe: `isBootVolume` is
recomputed from `scanRoot` on every `run`, and the excluded subtree never enters
`pendingDir`.

## Data Flow

Scanning `/`:
`root → child "System"` (kept, descended) `→ child "System/Volumes"` →
`ScanExclusion.isExcluded` returns `true` → `continue`.

The 1,523,552 phantom files / 277.47 GB are never walked. The reported total drops to
the real ~334 GB of distinct content reachable from root, and the inflated duplicate
count self-corrects because the twins no longer exist.

## Testing

### `DiskGalleryCoreTests/ScanExclusionTests.swift` (new)

- `isExcluded("System/Volumes", isBootVolume: true)` → `true`
- `isExcluded("System/Volumes", isBootVolume: false)` → `false`
- `isExcluded("System", isBootVolume: true)` → `false` (System volume content kept)
- `isExcluded("System/Volumes/Data/x", isBootVolume: true)` → `false`
  (only the exact node matches; descendants are never generated in practice)
- `isExcluded("Users/me/System/Volumes", isBootVolume: true)` → `false`
  (not the root-relative node)

### Integration

The `scanRoot.path == "/"` gate and the `continue` are trivial glue and are verified
by a manual rescan of the boot volume (consistent with how the queue-based scanner is
otherwise validated — there is no app unit-test target; the app is verified by clean
build). Acceptance: after rescanning `/`, reported used bytes ≤ disk capacity and no
`System/Volumes` node appears under root.

## Out of Scope

- No migration or cleanup of existing snapshots.
- No change to external-drive scanning.
- No UI changes.
- Post-merge: rebuild the notarized beta DMG so testers receive the corrected scanner
  (delivery step, not part of this code change).
