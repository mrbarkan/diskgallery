# DiskGallery

A read-only macOS app that catalogs external drives so their contents stay
**browsable while disconnected** — a "GPS for digital archives." Plug in a backup
drive, scan it once, and DiskGallery records every file and folder with its size.
Keep all your drives mapped in one place to compare them, find duplicate copies
across backups, and mark what to keep vs delete.

**Cataloging is strictly read-only** — scanning and hashing never modify your
drives (enforced by `MutationGuardTests`). The *only* thing DiskGallery writes to a
drive is the **Finder tags you explicitly apply**; everything else lives in its own
local catalog database.

## Features

- **Library of drives** — each identified by volume UUID, with live connected /
  disconnected badges.
- **Instant offline browsing** — Finder-like tree with folder sizes pre-computed
  and stored, so it's fast even with the drive unplugged. Single-click selects
  (⌘/⇧ for multi-select); double-click opens a folder.
- **Duplicate finder** — groups files by name + size across all drives (works
  offline), with an optional on-demand SHA-256 "verify by content" when a drive is
  connected, plus reclaimable-space totals.
- **Two tag dimensions** — a Keep / Delete / Review decision *and* a Finder color
  (the 7 standard colors). Decisions survive re-scans; both are written to the
  file as real **macOS Finder tags** when the drive is connected, so they show up
  in Finder too.
- **Keyboard tagging** — Q/W/E for Keep/Delete/Review, 1–7 for colors, all
  rebindable in Settings. Acts on the whole multi-selection at once.
- **Themes** — six accent themes with light / dark / system mode, in Settings.
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
