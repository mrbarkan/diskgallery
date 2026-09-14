# Drive Map Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export one scanned drive as a single self-contained HTML map anyone can open in a browser.

**Architecture:** `DriveMapExporter` in Core folds one cursor pass over the latest complete snapshot into a `DriveMap` value, JSON-encodes it, and substitutes it into a fixed HTML template held in a Swift raw string. The page renders the tree lazily with vanilla JS: sort, search, expand. The app adds a sidebar menu item and a save panel with a SwiftUI accessory for the options.

**Tech Stack:** Swift 6, GRDB 7, XCTest, SwiftUI/AppKit (`NSSavePanel`, `NSHostingView`), vanilla HTML/CSS/JS.

**Spec:** `docs/superpowers/specs/2026-09-14-drive-map-export-design.md`

## Global Constraints

- Core stays free of AppKit/SwiftUI. The app never imports GRDB.
- The exported file loads no external resources and must open offline.
- No licensing gate. Do not add a `Feature` case.
- Never touch the source drive. The only write is the output file the user chose.
- New source files require `xcodegen generate` (the `.xcodeproj` is committed).
- Deviation from spec, deliberate: the template lives in `DriveMapTemplate.swift` as a raw string instead of a bundle resource `DriveMap.html`. Same output, no bundle lookup, nothing to misconfigure in `project.yml`. `render` is `static` because it needs no database.
- Deviation from spec, deliberate: the menu item is disabled only when the drive has never been scanned (`latestSnapshotId == nil`). A drive whose latest scan is paused may still have an older complete snapshot, and the exporter throws a readable error when it has none.

Commands used throughout:

```sh
# Core tests (all)
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug \
  -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/DriveMapExporterTests
# App build
xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

---

### Task 1: Build the drive map model from the catalog

**Files:**
- Create: `DiskGalleryCore/Export/DriveMapExporter.swift`
- Modify: `DiskGalleryCore/Catalog.swift` (add `driveMaps`)
- Test: `DiskGalleryCoreTests/DriveMapExporterTests.swift`

**Interfaces:**
- Consumes: `Fixture.makeTree()`, `Fixture.writeFile`, `Fixture.makeCatalog()`, `Fixture.scan` (in `DiskGalleryCoreTests/Support.swift`); `PathVisibility.isHidden(relPath:)`; `FileCategory.category(forExtension:)`, `FileCategory.extensions(for:)`.
- Produces: `DriveMap` (Codable), `DriveMapOptions`, `DriveMapError.noCompleteSnapshot`, `DriveMapExporter.build(volumeId:options:) async throws -> DriveMap`, `Catalog.driveMaps`.

- [ ] **Step 1: Write the failing tests**

`DiskGalleryCoreTests/DriveMapExporterTests.swift`:

```swift
import XCTest
import GRDB
@testable import DiskGalleryCore

final class DriveMapExporterTests: XCTestCase {
    /// Scans `root` into a fresh catalog and returns it with the new drive's id.
    private func scanned(_ root: URL) async throws -> (Catalog, Int64) {
        let catalog = try Fixture.makeCatalog()
        try await Fixture.scan(catalog, root)
        let id = try XCTUnwrap(try await catalog.library.volumes().first?.id)
        return (catalog, id)
    }

    func testBuildProducesNestedFoldersWithSizesAndCounts() async throws {
        let (catalog, id) = try await scanned(try Fixture.makeTree())
        let map = try await catalog.driveMaps.build(volumeId: id)

        XCTAssertEqual(map.root.bytes, 450)
        XCTAssertEqual(map.root.fileCount, 4)
        XCTAssertEqual(map.root.folders.map(\.name), ["empty", "sub"])
        let sub = try XCTUnwrap(map.root.folders.first { $0.name == "sub" })
        XCTAssertEqual(sub.relPath, "sub")
        XCTAssertEqual(sub.bytes, 150)
        XCTAssertEqual(sub.fileCount, 2)
        XCTAssertEqual(map.root.folders.first?.bytes, 0)
        XCTAssertEqual(map.drive.fileCount, 4)
        XCTAssertEqual(map.drive.folderCount, 2)
        XCTAssertEqual(map.categories, [DriveMap.CategoryTotal(name: "Documents", bytes: 450, count: 4)])
        XCTAssertEqual(map.extensionCategories["mov"], "Video")
    }

    func testFileSampleIsLargestNAndReportsRemainder() async throws {
        let root = try Fixture.makeTree()
        for (i, size) in [10, 20, 30, 40, 50, 60, 70].enumerated() {
            try Fixture.writeFile(root, "clips/f\(i).mov", bytes: size)
        }
        let (catalog, id) = try await scanned(root)
        let map = try await catalog.driveMaps.build(volumeId: id, options: DriveMapOptions(filesPerFolder: 3))

        let clips = try XCTUnwrap(map.root.folders.first { $0.name == "clips" })
        XCTAssertEqual(clips.files.map(\.name), ["f6.mov", "f5.mov", "f4.mov"])
        XCTAssertEqual(clips.moreFiles, 4)
        XCTAssertEqual(clips.fileCount, 7)
        XCTAssertEqual(clips.bytes, 280)
    }

    func testIncludeFilesFalseOmitsFiles() async throws {
        let (catalog, id) = try await scanned(try Fixture.makeTree())
        let map = try await catalog.driveMaps.build(volumeId: id, options: DriveMapOptions(includeFiles: false))

        XCTAssertFalse(map.includesFiles)
        XCTAssertTrue(map.root.files.isEmpty)
        XCTAssertEqual(map.root.moreFiles, 0)
        let sub = try XCTUnwrap(map.root.folders.first { $0.name == "sub" })
        XCTAssertTrue(sub.files.isEmpty)
        XCTAssertEqual(sub.moreFiles, 0)
        XCTAssertEqual(map.root.fileCount, 4)
    }

    func testHideHiddenDropsDotEntries() async throws {
        let root = try Fixture.makeTree()
        try Fixture.writeFile(root, ".secret.txt", bytes: 10)
        try Fixture.writeFile(root, ".cache/blob.bin", bytes: 20)
        let (catalog, id) = try await scanned(root)

        let hidden = try await catalog.driveMaps.build(volumeId: id)
        XCTAssertEqual(hidden.root.folders.map(\.name), ["empty", "sub"])
        XCTAssertFalse(hidden.root.files.contains { $0.name == ".secret.txt" })
        XCTAssertEqual(hidden.root.bytes, 450)

        let shown = try await catalog.driveMaps.build(volumeId: id, options: DriveMapOptions(hideHidden: false))
        XCTAssertTrue(shown.root.folders.contains { $0.name == ".cache" })
        XCTAssertEqual(shown.root.bytes, 480)
        XCTAssertEqual(shown.root.fileCount, 6)
    }

    func testBuildThrowsWithoutCompleteSnapshot() async throws {
        let catalog = try Fixture.makeCatalog()
        let id: Int64 = try await catalog.database.writer.write { db in
            var volume = Volume(uuid: "U-BLANK", name: "Blank", createdAt: Date())
            try volume.insert(db)
            return volume.id!
        }
        do {
            _ = try await catalog.driveMaps.build(volumeId: id)
            XCTFail("expected noCompleteSnapshot")
        } catch DriveMapError.noCompleteSnapshot {}
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate` then the Core test command above.
Expected: compile failure, `value of type 'Catalog' has no member 'driveMaps'`.

- [ ] **Step 3: Implement the model and builder**

`DiskGalleryCore/Export/DriveMapExporter.swift`:

```swift
import Foundation
import GRDB

/// A shareable picture of one drive: header facts, category totals, and the folder tree with
/// optional per-folder file samples. Embedded as JSON in the exported HTML so a later
/// "import a map and compare" feature can read the same file. Bump `format` on breaking changes.
public struct DriveMap: Codable, Sendable {
    public var format: Int = 1
    public var generatedAt: Date
    public var appVersion: String
    public var includesFiles: Bool
    public var filesPerFolder: Int?          // nil with includesFiles = every file
    public var drive: Drive
    public var categories: [CategoryTotal]
    /// Lowercased extension → category label, so the page colors files without its own table.
    public var extensionCategories: [String: String]
    public var root: Folder

    public struct Drive: Codable, Sendable {
        public var name: String
        public var uuid: String?
        public var fsType: String?
        public var totalCapacity: Int64?
        public var freeCapacity: Int64?
        public var scannedAt: Date
        public var connection: String?       // DriveHardware.Bus raw value; nil when unknown
        public var model: String?            // "vendor model"; nil when unknown
        public var fileCount: Int64
        public var folderCount: Int64
    }

    public struct CategoryTotal: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        public var count: Int64
    }

    public struct Folder: Codable, Sendable {
        public var name: String
        public var relPath: String
        public var modifiedAt: Date?
        public var bytes: Int64              // every visible file beneath, recursively
        public var fileCount: Int64          // every visible file beneath, recursively
        public var folders: [Folder]
        public var files: [File]             // sample of direct files, largest first
        public var moreFiles: Int64          // direct files left out of `files`
    }

    public struct File: Codable, Sendable {
        public var name: String
        public var bytes: Int64
        public var modifiedAt: Date?
        public var ext: String?
        public var hash: String?
    }
}

public struct DriveMapOptions: Sendable {
    public var includeFiles: Bool
    public var filesPerFolder: Int?          // nil = every file
    public var hideHidden: Bool
    public var appVersion: String

    public init(includeFiles: Bool = true, filesPerFolder: Int? = 20,
                hideHidden: Bool = true, appVersion: String = "") {
        self.includeFiles = includeFiles
        self.filesPerFolder = filesPerFolder
        self.hideHidden = hideHidden
        self.appVersion = appVersion
    }
}

public enum DriveMapError: LocalizedError {
    case noCompleteSnapshot

    public var errorDescription: String? {
        "This drive has no finished scan to export. Scan it, then try again."
    }
}

/// Builds and writes drive maps. Reads the catalog only; the single write is the output file.
public struct DriveMapExporter: Sendable {
    let db: AppDatabase

    /// The map of `volumeId`'s latest complete snapshot.
    public func build(volumeId: Int64, options: DriveMapOptions = DriveMapOptions()) async throws -> DriveMap {
        try await db.writer.read { db in
            guard let volume = try Volume.fetchOne(db, key: volumeId),
                  let snapshot = try Snapshot
                    .filter(Column("volumeId") == volumeId && Column("isComplete") == true)
                    .order(Column("scannedAt").desc, Column("id").desc)
                    .fetchOne(db),
                  let snapshotId = snapshot.id
            else { throw DriveMapError.noCompleteSnapshot }

            var tree = DriveMapTree(options: options)
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, parentId, name, relPath, isDir, logicalSize, modifiedAt, ext, contentHash
                FROM entry WHERE snapshotId = ?
                """, arguments: [snapshotId])
            while let row = try rows.next() { tree.add(row) }
            return tree.map(volume: volume, snapshot: snapshot, generatedAt: Date())
        }
    }
}

/// One pass over a snapshot's entries, folded into the nested map.
/// ponytail: keeps every folder plus each folder's sample in memory. Fine for millions of
/// entries; stream the JSON if a catalog ever outgrows RAM.
struct DriveMapTree {
    struct Dir {
        var name: String
        var relPath: String
        var modifiedAt: Date?
        var parentId: Int64?
    }

    /// A folder's direct files: totals for all of them, a sample of the largest.
    struct Direct {
        var bytes: Int64 = 0
        var count: Int64 = 0
        var sample: [DriveMap.File] = []

        mutating func add(_ file: DriveMap.File, options: DriveMapOptions) {
            bytes += file.bytes
            count += 1
            guard options.includeFiles else { return }
            sample.append(file)
            // ponytail: trim at 2× the limit instead of keeping a heap; same result, less code.
            if let limit = options.filesPerFolder, sample.count >= max(limit, 1) * 2 {
                sample = DriveMapTree.largest(sample, limit)
            }
        }
    }

    let options: DriveMapOptions
    var dirs: [Int64: Dir] = [:]
    var direct: [Int64: Direct] = [:]
    var rootId: Int64?
    var categories: [FileCategory: DriveMap.CategoryTotal] = [:]

    init(options: DriveMapOptions) { self.options = options }

    mutating func add(_ row: Row) {
        let relPath: String = row["relPath"]
        if options.hideHidden && PathVisibility.isHidden(relPath: relPath) { return }
        let id: Int64 = row["id"]
        let parentId: Int64? = row["parentId"]
        let name: String = row["name"]
        let modifiedAt: Date? = row["modifiedAt"]
        let isDir: Bool = row["isDir"]
        if isDir {
            dirs[id] = Dir(name: name, relPath: relPath, modifiedAt: modifiedAt, parentId: parentId)
            if parentId == nil { rootId = id }
            return
        }
        guard let parentId else { return }
        let ext: String? = row["ext"]
        let file = DriveMap.File(name: name, bytes: row["logicalSize"], modifiedAt: modifiedAt,
                                 ext: ext, hash: row["contentHash"])
        let category = FileCategory.category(forExtension: ext ?? (name as NSString).pathExtension)
        var total = categories[category] ?? DriveMap.CategoryTotal(name: Self.label(category), bytes: 0, count: 0)
        total.bytes += file.bytes
        total.count += 1
        categories[category] = total
        direct[parentId, default: Direct()].add(file, options: options)
    }

    func map(volume: Volume, snapshot: Snapshot, generatedAt: Date) -> DriveMap {
        var children: [Int64: [Int64]] = [:]
        for (id, dir) in dirs {
            if let parent = dir.parentId { children[parent, default: []].append(id) }
        }
        var folderCount: Int64 = 0
        func folder(_ id: Int64) -> DriveMap.Folder {
            let dir = dirs[id]!
            let subfolders = (children[id] ?? []).map(folder)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            folderCount += Int64(subfolders.count)
            let acc = direct[id] ?? Direct()
            let files = Self.largest(acc.sample, options.filesPerFolder)
            return DriveMap.Folder(
                name: dir.name, relPath: dir.relPath, modifiedAt: dir.modifiedAt,
                bytes: acc.bytes + subfolders.reduce(0) { $0 + $1.bytes },
                fileCount: acc.count + subfolders.reduce(0) { $0 + $1.fileCount },
                folders: subfolders, files: files,
                moreFiles: options.includeFiles ? acc.count - Int64(files.count) : 0)
        }
        var root = rootId.map(folder) ?? DriveMap.Folder(
            name: volume.name, relPath: "", modifiedAt: nil, bytes: 0, fileCount: 0,
            folders: [], files: [], moreFiles: 0)
        root.name = volume.name

        let hardware = volume.hardware
        let model = [hardware?.vendor, hardware?.model]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let drive = DriveMap.Drive(
            name: volume.name, uuid: volume.uuid, fsType: snapshot.fsType,
            totalCapacity: snapshot.totalCapacity, freeCapacity: snapshot.freeCapacity,
            scannedAt: snapshot.scannedAt,
            connection: hardware.flatMap { $0.bus == .unknown ? nil : $0.bus.rawValue },
            model: model.isEmpty ? nil : model,
            fileCount: root.fileCount, folderCount: folderCount)
        let order: [FileCategory] = [.photos, .video, .raw, .audio, .documents, .all]
        return DriveMap(
            generatedAt: generatedAt, appVersion: options.appVersion,
            includesFiles: options.includeFiles,
            filesPerFolder: options.includeFiles ? options.filesPerFolder : nil,
            drive: drive, categories: order.compactMap { categories[$0] },
            extensionCategories: Self.extensionCategories, root: root)
    }

    /// Largest first; name breaks ties so the sample is deterministic.
    static func largest(_ files: [DriveMap.File], _ limit: Int?) -> [DriveMap.File] {
        let sorted = files.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    static func label(_ category: FileCategory) -> String {
        category == .all ? "Other" : category.label
    }

    static let extensionCategories: [String: String] = {
        var out: [String: String] = [:]
        for category in FileCategory.allCases where category != .all {
            for ext in FileCategory.extensions(for: [category]) { out[ext] = category.label }
        }
        return out
    }()
}
```

`DiskGalleryCore/Catalog.swift`: add `public let driveMaps: DriveMapExporter` after `gallery`, and `self.driveMaps = DriveMapExporter(db: db)` after `self.gallery = GalleryService(db: db)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate` then the Core test command above.
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Export/DriveMapExporter.swift DiskGalleryCore/Catalog.swift \
  DiskGalleryCoreTests/DriveMapExporterTests.swift DiskGallery.xcodeproj
git commit -m "feat(export): build a drive map model from the catalog"
```

---

### Task 2: Render the map into a self-contained HTML page

**Files:**
- Create: `DiskGalleryCore/Export/DriveMapTemplate.swift`
- Modify: `DiskGalleryCore/Export/DriveMapExporter.swift` (add `render`, `export`)
- Test: `DiskGalleryCoreTests/DriveMapExporterTests.swift` (add two tests)

**Interfaces:**
- Consumes: `DriveMap`, `DriveMapExporter.build` from Task 1.
- Produces: `DriveMapExporter.render(_ map: DriveMap) throws -> String` (static), `DriveMapExporter.export(volumeId:options:to:) async throws`, `DriveMapTemplate.html` with the single placeholder `__DRIVE_MAP_JSON__`.

- [ ] **Step 1: Write the failing tests**

Append inside `DriveMapExporterTests`:

```swift
    func testRenderEmbedsDecodableEscapedJSON() throws {
        let evil = "cut</script><!--.mov"
        let epoch = Date(timeIntervalSince1970: 0)
        let map = DriveMap(
            generatedAt: epoch, appVersion: "9.9", includesFiles: true, filesPerFolder: 20,
            drive: .init(name: "Evil <Drive>", uuid: nil, fsType: "apfs", totalCapacity: 1000,
                         freeCapacity: 500, scannedAt: epoch, connection: nil, model: nil,
                         fileCount: 1, folderCount: 0),
            categories: [], extensionCategories: [:],
            root: .init(name: "Evil", relPath: "", modifiedAt: nil, bytes: 5, fileCount: 1, folders: [],
                        files: [.init(name: evil, bytes: 5, modifiedAt: nil, ext: "mov", hash: nil)],
                        moreFiles: 0))

        let html = try DriveMapExporter.render(map)

        XCTAssertFalse(html.contains("__DRIVE_MAP_JSON__"))
        XCTAssertFalse(html.contains(evil))
        let open = #"<script id="map" type="application/json">"#
        let start = try XCTUnwrap(html.range(of: open)).upperBound
        let end = try XCTUnwrap(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DriveMap.self, from: Data(html[start..<end].utf8))
        XCTAssertEqual(decoded.root.files.first?.name, evil)
        XCTAssertEqual(decoded.drive.name, "Evil <Drive>")
    }

    func testExportWritesHTMLFile() async throws {
        let (catalog, id) = try await scanned(try Fixture.makeTree())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriveMap-\(UUID().uuidString).html")
        try await catalog.driveMaps.export(volumeId: id, to: url)
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains(#""relPath":"sub""#))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: the Core test command above.
Expected: compile failure, `type 'DriveMapExporter' has no member 'render'`.

- [ ] **Step 3: Implement render, export, and the template**

Add inside `DriveMapExporter` in `DriveMapExporter.swift`:

```swift
    /// Writes the map of `volumeId` to `url` as one self-contained HTML file.
    public func export(volumeId: Int64, options: DriveMapOptions = DriveMapOptions(), to url: URL) async throws {
        let map = try await build(volumeId: volumeId, options: options)
        try Data(try Self.render(map).utf8).write(to: url, options: .atomic)
    }

    /// The full HTML document with `map` embedded as JSON.
    public static func render(_ map: DriveMap) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // `<` only ever appears inside JSON strings, so escaping it keeps a filename like
        // "</script>" or "<!--" from ending the data block early.
        let json = String(decoding: try encoder.encode(map), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        return DriveMapTemplate.html.replacingOccurrences(of: "__DRIVE_MAP_JSON__", with: json)
    }
```

`DiskGalleryCore/Export/DriveMapTemplate.swift`: the file content is the `enum DriveMapTemplate { static let html = #"""…"""# }` whose body is the page below, verbatim. The raw string starts at column 0 so indentation stripping leaves it untouched.

Page requirements the template implements (the executed file is the source of truth for markup):

- `<!doctype html>` first, `lang="en"`, viewport meta, no external URLs.
- Light and dark palettes via CSS custom properties and `prefers-color-scheme`. Category colors: Photos green, Video blue, RAW ochre, Audio violet, Documents slate, Other grey.
- Header: drive name as `h1`; a facts list (Files, Folders, Format, Connection, Device, Scanned), each omitted when unknown; a capacity bar with one segment per category over total capacity and hatched free space; a caption with bytes in files and free of total; a legend with each category's bytes and file count.
- Sticky toolbar: search input, sort select (Size, Name, Date modified, Kind), order select whose labels follow the key (Largest first / Smallest first, A to Z / Z to A, Newest first / Oldest first), Expand all, Collapse all.
- Tree: root's children at depth 0. Level-1 folders start expanded. Folder rows show chevron button with `aria-expanded`, folder glyph, name, share-of-parent bar, size, file count, modified date. File rows show category swatch, name, bar, size, extension, date. A "…and N more files" row when `moreFiles > 0`. Children render on first expand.
- Sort applies to folders and files everywhere. Ties fall back to name ascending. Kind sorts folders by name.
- Search debounced 150 ms, case-insensitive substring on folder and sampled file names. Ancestors of matches open. A matching folder keeps its full contents, collapsed. Status line reports match count, and notes when the map lacks files or only has samples.
- Under 640 px wide, bar, file count and date columns hide.
- Footer: "Made with DiskGallery <version>. Exported <date>."
- `<script id="map" type="application/json">__DRIVE_MAP_JSON__</script>` precedes the inline app script.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate` then the Core test command above.
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Export DiskGalleryCoreTests/DriveMapExporterTests.swift DiskGallery.xcodeproj
git commit -m "feat(export): render drive maps as a self-contained HTML page"
```

---

### Task 3: Export Drive Map from the sidebar

**Files:**
- Create: `DiskGallery/Views/DriveMapExportOptionsView.swift`
- Modify: `DiskGallery/App/AppEnvironment.swift` (add `exportDriveMap(volume:)` after `exportLibrary()`)
- Modify: `DiskGallery/Views/LibrarySidebarView.swift` (`driveContextMenu`, after "Scan Cache / Previews…")

**Interfaces:**
- Consumes: `Catalog.driveMaps.export(volumeId:options:to:)`, `DriveMapOptions` from Tasks 1 and 2; `AppInfo.shortVersion`; `VolumeSummary`.
- Produces: `AppEnvironment.exportDriveMap(volume: VolumeSummary)`.

- [ ] **Step 1: Add the save-panel options view**

`DiskGallery/Views/DriveMapExportOptionsView.swift`:

```swift
import SwiftUI
import AppKit
import DiskGalleryCore

/// What the user picked under the Export Drive Map save panel.
@Observable final class DriveMapExportChoices {
    var includeFiles = true
    var filesPerFolder: Int? = 20
    var hideHidden = true

    func options(appVersion: String) -> DriveMapOptions {
        DriveMapOptions(includeFiles: includeFiles, filesPerFolder: filesPerFolder,
                        hideHidden: hideHidden, appVersion: appVersion)
    }
}

/// Accessory controls for the Export Drive Map save panel.
struct DriveMapExportOptionsView: View {
    @Bindable var choices: DriveMapExportChoices

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Include file samples", isOn: $choices.includeFiles)
            Picker("Files per folder", selection: $choices.filesPerFolder) {
                Text("20").tag(Int?.some(20))
                Text("50").tag(Int?.some(50))
                Text("100").tag(Int?.some(100))
                Text("All").tag(Int?.none)
            }
            .pickerStyle(.menu)
            .frame(width: 220)
            .disabled(!choices.includeFiles)
            Text("Each folder lists its largest files. All can make a very large map.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Hide hidden files and folders", isOn: $choices.hideHidden)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    static func accessory(for choices: DriveMapExportChoices) -> NSView {
        let host = NSHostingView(rootView: DriveMapExportOptionsView(choices: choices))
        host.frame.size = host.fittingSize
        return host
    }
}
```

- [ ] **Step 2: Add the export action**

In `AppEnvironment.swift`, after `exportLibrary()`:

```swift
    /// Saves one drive as a self-contained HTML map anyone can open in a browser.
    func exportDriveMap(volume: VolumeSummary) {
        let choices = DriveMapExportChoices()
        let panel = NSSavePanel()
        panel.title = "Export Drive Map"
        panel.message = "Save a map of “\(volume.name)” that anyone can open in a web browser."
        panel.nameFieldStringValue = "\(volume.name.replacingOccurrences(of: "/", with: "-")) map.html"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        panel.accessoryView = DriveMapExportOptionsView.accessory(for: choices)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let exporter = catalog.driveMaps
        let options = choices.options(appVersion: AppInfo.shortVersion)
        let volumeId = volume.id
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await exporter.export(volumeId: volumeId, options: options, to: url)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "Couldn’t export the drive map: \(error.localizedDescription)"
            }
        }
    }
```

- [ ] **Step 3: Add the menu item**

In `LibrarySidebarView.driveContextMenu`, right after `Button("Scan Cache / Previews…") { previewsVolume = summary }`:

```swift
        Button("Export Drive Map…") { env.exportDriveMap(volume: summary) }
            .disabled(summary.latestSnapshotId == nil)
```

- [ ] **Step 4: Build**

Run: `xcodegen generate` then the app build command above.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/DriveMapExportOptionsView.swift DiskGallery/App/AppEnvironment.swift \
  DiskGallery/Views/LibrarySidebarView.swift DiskGallery.xcodeproj
git commit -m "feat(export): Export Drive Map… in the drive context menu"
```

---

### Task 4: Verify a real map in a browser (no commit)

- [ ] **Step 1:** Copy the live catalog with `sqlite3 "$HOME/Library/Application Support/DiskGallery/catalog.sqlite" ".backup <scratch>/catalog.sqlite"`.
- [ ] **Step 2:** Add a throwaway, uncommitted test that, when `DG_MAP_DEMO_DB` and `DG_MAP_DEMO_OUT` are set, opens `Catalog(databaseURL:)` on the copy and exports every drive to `DG_MAP_DEMO_OUT`. Run it with `TEST_RUNNER_DG_MAP_DEMO_DB=… TEST_RUNNER_DG_MAP_DEMO_OUT=… xcodebuild … -only-testing:…`.
- [ ] **Step 3:** Serve the output folder on localhost, open a map in Chrome, check light and dark, sort, search, expand, and phone width. Fix and re-run Task 2 tests for anything broken.
- [ ] **Step 4:** Delete the throwaway test and scratch catalog copy. Run the full Core suite once.
