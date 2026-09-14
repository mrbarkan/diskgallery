# Drive Map Export — Design

**Date:** 2026-09-14
**Status:** Approved for planning

## Goal

Let a user export one scanned drive as a single self-contained HTML file that anyone can open in a browser, with no DiskGallery installed, and quickly see what is on the drive. Motivating case: two collaborators comparing what each has on their drives while working remotely.

The embedded data is structured so a later "import a map and compare it against my drives" feature can read the same file. That feature is out of scope here.

## Non-goals (this round)

- Thumbnails or previews in the map.
- Importing maps or diffing drives.
- Multi-drive maps.
- Hosting or share links.
- Any licensing gate. The feature is free.

## User flow

1. Right-click a drive in the library sidebar → **Export Drive Map…** (placed after "Scan Cache / Previews…"). Disabled when the drive has no complete snapshot.
2. An `NSSavePanel` opens, default name `<Drive name> map.html`, with an accessory view:
   - **Include file samples** checkbox, default on.
   - **Files per folder** popup: 20 (default), 50, 100, All. Disabled when samples are off.
   - **Hide hidden files and folders** checkbox, default on. Uses the same rule as the Gallery's `hideHidden` (names starting with `.`).
3. Export runs off the main actor, writes the file, and the app reveals it in Finder. Errors surface through the existing `errorMessage` path.

## Map contents

**Header**
- Drive name, filesystem type, capacity used / free / total.
- Hardware bus and brand/model when the catalog has them.
- Scan date, total files, total folders.
- Category breakdown by bytes and count: Photos, Video, RAW, Audio, Documents, Other. Derived from `FileCategory` extension sets; "Other" is everything unmatched.

**Folder tree**
- Every folder in the latest complete snapshot, nested. Each row shows name, subtree size, file count beneath it, and a bar proportional to its share of the parent.
- Top two levels expanded by default, deeper levels collapsed. Expand all / collapse all buttons.
- Search box filters folders and sample files by name substring, case-insensitive, and auto-expands matches.

**File samples (opt-in)**
- Inside each folder, its direct child files up to the chosen limit, plus "…and N more" when truncated. Each shows name, size, modified date, extension.
- Which files make the sample: the largest N by logical size. Rationale: on a media drive the biggest files are the ones that define what the folder is, and "largest" is deterministic.

**Sorting (browser-side)**
- A sort control applies to both folder rows and sample files: **Name**, **Size**, **Date**, **Kind** (extension), each ascending or descending. Default: Size descending for folders, Size descending for files.
- Sorting is per-map, not per-folder, and re-renders the whole tree. Sorting only reorders what is in the file; a truncated sample stays the same N files.

**Footer**
- "Made with DiskGallery <version>" and the export timestamp.

## Architecture

### Core: `DiskGalleryCore/Export/DriveMapExporter.swift`

```swift
public struct DriveMapOptions: Sendable {
    public var includeFiles: Bool = true
    public var filesPerFolder: Int? = 20      // nil = all
    public var hideHidden: Bool = true
}

public struct DriveMap: Codable, Sendable {
    public var format: Int = 1                 // bump on breaking payload changes
    public var generatedAt: Date
    public var appVersion: String
    public var drive: Drive                    // name, uuid, fsType, capacity, free, scannedAt, hardware
    public var categories: [CategoryTotal]     // category, bytes, count
    public var root: Folder
    public struct Folder: Codable, Sendable {
        var name: String, relPath: String, bytes: Int64, fileCount: Int64
        var folders: [Folder], files: [File], moreFiles: Int64   // hidden by truncation
    }
    public struct File: Codable, Sendable {
        var name: String, bytes: Int64, modifiedAt: Date?, ext: String?, hash: String?
    }
}

public final class DriveMapExporter {
    public func build(volumeId: Int64, options: DriveMapOptions) async throws -> DriveMap
    public func render(_ map: DriveMap) throws -> String          // full HTML document
    public func export(volumeId: Int64, options: DriveMapOptions, to url: URL) async throws
}
```

- `build` runs one read transaction: fetch all entries for the latest complete snapshot ordered by `relPath`, then assemble the tree in memory keyed by `parentId`. `subtreeLogicalSize` gives folder bytes; file counts are accumulated bottom-up in the same pass. Hidden filtering drops any entry whose path has a `.`-prefixed component.
- `hash` is included when the catalog has a `contentHash`, so a future compare feature can match by content. It costs nothing now.
- `render` reads `DriveMap.html` from the framework bundle, JSON-encodes the map, and substitutes it into a `<script id="map" type="application/json">` block. JSON is escaped so `</script>` inside a filename cannot break out.
- `Catalog` vends `driveMaps: DriveMapExporter`.
- Read-only: this code only reads the catalog and writes the one output file the user chose. It is not one of the scanner files covered by `MutationGuardTests`, and it never touches the source drive.

### Template: `DiskGalleryCore/Export/DriveMap.html`

One file, inline CSS and JS, no external resources. Vanilla JS, no framework. Renders the tree lazily per expanded folder so a 100k-folder map stays responsive. Uses `Intl.NumberFormat` and `Intl.DateTimeFormat` for sizes and dates. Light and dark via `prefers-color-scheme`. Must be usable at phone width.

Size expectation: folders-only for a large drive is a few MB at most; with "All" files it can reach tens of MB, which the save panel accessory notes in a caption.

### App: `AppEnvironment.exportDriveMap(volume:)`

Mirrors `exportOrganizationReport`: save panel with accessory options, `Task.detached` export, `NSWorkspace.activateFileViewerSelecting` on success.

## Error handling

- No complete snapshot: menu item disabled; exporter also throws a typed error as a guard.
- Write failure: propagated, shown via `errorMessage`.
- Empty drive: exports a valid map with an empty root.

## Testing

`DriveMapExporterTests` in `DiskGalleryCoreTests`, using `Fixture`:

- `testBuildProducesNestedFoldersWithSizesAndCounts` — scan a fixture tree, assert folder bytes, file counts, nesting.
- `testFileSampleIsLargestNAndReportsRemainder` — 5 files, limit 3, assert the 3 largest and `moreFiles == 2`.
- `testIncludeFilesFalseOmitsFiles` — `files` empty and `moreFiles == 0` everywhere.
- `testHideHiddenDropsDotEntries` — a `.DS_Store` and a `.git/` subtree are absent.
- `testRenderEmbedsEscapedJSON` — a filename containing `</script>` survives and the output contains the marker block and the drive name.

Browser sorting and search are verified manually by opening an exported map; no JS test harness is added.

## Open follow-ups (not in this spec)

- Import a map as a virtual drive and diff against local drives by hash and size.
- Thumbnails from the existing thumbnail cache.
