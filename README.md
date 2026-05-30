# DiskGallery

A read-only macOS app that catalogs external drives so their contents stay
**browsable while disconnected** — a "GPS for digital archives." Plug in a backup
drive, scan it once, and DiskGallery records every file and folder with its size.
Keep all your drives mapped in one place to compare them, find duplicate copies
across backups, and mark what to keep vs delete.

**DiskGallery never writes to or deletes anything on a scanned drive.** The only
thing it writes is its own local catalog database. This is enforced in code and by
a unit test (`MutationGuardTests`).

## Features

- **Library of drives** — each identified by volume UUID, with live connected /
  disconnected badges.
- **Instant offline browsing** — Finder-like tree with folder sizes pre-computed
  and stored, so it's fast even with the drive unplugged.
- **Duplicate finder** — groups files by name + size across all drives (works
  offline), with an optional on-demand SHA-256 "verify by content" when a drive is
  connected, plus reclaimable-space totals.
- **Keep / Delete / Review tags + notes** — keyed so your decisions survive
  re-scanning a drive; filter the whole library by tag.
- **Full-text name search** across every cataloged drive.

## Requirements

- macOS 15+, Xcode 26 / Swift 6.

## Build & run

```sh
# Generate the Xcode project (only needed after editing project.yml; the .xcodeproj
# is committed, so you can also just open it directly).
xcodegen generate            # brew install xcodegen

# Build
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build

# Run the tests
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

Or open `DiskGallery.xcodeproj` in Xcode and press Run. In the app, click **Scan…**
and choose a drive (or any folder) to catalog.

### Headless scan

```sh
DiskGallery.app/Contents/MacOS/DiskGallery --scan /Volumes/YourDrive
```

Scans into the default catalog and exits — handy for scripting.

## Architecture

- **`DiskGalleryCore`** (framework) — all logic, fully encapsulating GRDB/SQLite:
  - `Scanning/` — read-only directory enumeration, batched inserts, O(n) folder-size
    rollup, progress + cancellation.
  - `Data/` — GRDB models, schema migrations, WAL-tuned database.
  - `Duplicates/`, `Annotations/`, `Search/`, `Library/` — the query engines.
  - `Catalog` — the single public facade the app talks to.
- **`DiskGallery`** (app) — SwiftUI; imports only `DiskGalleryCore` (never GRDB).
  Three-column `NavigationSplitView`: drives sidebar, tree browser, detail + tag
  editor. `VolumeService` tracks mounts via `NSWorkspace`.

The catalog lives at `~/Library/Application Support/DiskGallery/catalog.sqlite`.

### Known v1 limitation

Duplicate "verify by content" resolves a file as `volumeMount + relativePath`, which
is correct when a drive was scanned from its volume root (the normal case). Scanning
a sub-folder instead of the whole drive can make hash verification unable to locate
files; browsing, duplicate detection, and tagging are unaffected.
