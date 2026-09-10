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
- **Themes** — six accent colors and light / dark / system mode, all in Settings.
- **Full-text name search** across every cataloged drive.
- **AI agent access (MCP)** — connect Claude or any Model Context Protocol client
  to the catalog so it can look through your drives and propose an organization.
  See [AI agents](#ai-agents).

## Install

Grab the latest signed `.dmg` from the
[Releases](https://github.com/mrbarkan/diskgallery/releases) page and drag
DiskGallery to Applications. The app checks for updates itself (Sparkle); you can
also pick **DiskGallery → Check for Updates…** at any time.

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

## AI agents

DiskGallery speaks [Model Context Protocol](https://modelcontextprotocol.io) over
stdio, so an AI agent can read your catalog — drives, folders, file names, sizes,
dates, cached thumbnails and duplicate sets — and **propose an organization** by
tagging files.

Add this to your MCP client's config (Settings → Agents has a Copy button with the
right path filled in), then restart the client:

```json
{
  "mcpServers": {
    "diskgallery": {
      "command": "/Applications/DiskGallery.app/Contents/MacOS/DiskGallery",
      "args": ["--mcp"]
    }
  }
}
```

For Claude Code:

```sh
claude mcp add diskgallery -- /Applications/DiskGallery.app/Contents/MacOS/DiskGallery --mcp
```

**Tools:** `list_drives`, `browse_folder`, `search`, `get_file`, `list_duplicates`,
`get_thumbnail`, `list_annotations`, `set_annotations`.

**How proposing works.** There is no separate plan object: an agent proposes by
writing the same annotations you write yourself — Keep / Delete / Review / Move /
Backup, a Finder color, and a note explaining why. Those land in your Tagged lists,
you change what you disagree with, and Organize turns what survives into a plan.

**What an agent cannot do.** Move, copy, rename or delete anything on a drive. The
server only ever reads the filesystem and writes annotations to the app's own
catalog database; `MutationGuardTests` enforces that statically. Execution stays
behind the app's existing copy → verify → delete gates, which need your approval.

The server reads the same catalog as the running app, so tags an agent writes show
up in the UI within a couple of seconds. Thumbnails are served from the local cache,
which means an agent can look at your photos with the drive unplugged — but only for
files whose previews you generated in the app.

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

## License

Released under the [MIT License](LICENSE). © 2026 Mr. Barkan.
