# Gallery Stage B — Contact-sheet grid Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a top-level **Gallery** destination — a cross-drive, offline contact sheet of media tiles (cached thumbnail or type glyph + Keep/Delete/Review dot + duplicate ×N badge + drive provenance) with inline keyboard tagging.

**Architecture:** A new read-only Core query (`GalleryService` → flat media list across each drive's latest complete snapshot, with volume provenance), vended as `catalog.gallery`. A Classic-native `GalleryView` (`LazyVGrid`) routed from a new `SidebarItem.gallery`. Tiles lazily load HEIC sidecars from the Stage-A cache; decision dots and dup badges come from bulk preloads. Inline tagging reuses the existing annotation + Finder-tag write primitives, generalized to be **cross-drive correct** (each tile carries its own volume key) since the Gallery spans drives.

**Tech Stack:** Swift 6.0 / macOS 15.0, SwiftUI (`@Observable` + `@Environment`), DiskGalleryCore (GRDB behind a facade), QuickLook sidecar cache (Stage A).

## Global Constraints

- Swift 6.0, macOS 15.0, strict concurrency. Mirror existing isolation patterns; do not invent new ones.
- The **app target never imports GRDB** — all DB access goes through `env.catalog.*`.
- **Read-only cataloging preserved:** the Gallery only reads drive files (for thumbnails, already done in Stage A) and writes annotations + Finder tags exactly as the existing tagging path does. Do NOT touch any file `MutationGuardTests` scans (Scanner, VolumeMetadata, DriveHardwareProbe, ScanProgress, HashVerifier).
- DB column/alias names equal the decoding property names (camelCase).
- Baseline: 169 Core tests green. After Task 1: 170 green. App must reach `** BUILD SUCCEEDED **` after every app task.
- New files must be added to the Xcode project via `xcodegen generate` before building/testing; include `DiskGallery.xcodeproj` in that task's commit.
- Every commit message ends with exactly:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- No app unit-test target exists: app tasks are gated by build success + self-review of runtime logic. The manual smoke (needs drives + GUI) is deferred to the owner.

---

### Task 1: `GalleryService` — flat cross-drive media query (Core)

**Files:**
- Create: `DiskGalleryCore/Gallery/GalleryService.swift`
- Modify: `DiskGalleryCore/Catalog.swift` (vend `gallery`)
- Test: `DiskGalleryCoreTests/GalleryTests.swift` (new)

**Interfaces:**
- Consumes: `AppDatabase`, `FileCategory.extensions(for:)` (Stage A), the `entry`/`snapshot`/`volume` tables.
- Produces (on `catalog.gallery`): `func items(categories: [FileCategory], limit: Int = 2000) async throws -> [GalleryEntry]` and the `GalleryEntry` struct (fields below; `volumeKey` computed = `volumeUuid ?? volumeName`).

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/GalleryTests.swift`:

```swift
import XCTest
import GRDB
@testable import DiskGalleryCore

final class GalleryTests: XCTestCase {
    /// Seeds a synthetic volume + complete snapshot + entries (mirrors ExecutionTests.seedVolume),
    /// with an explicit `ext` so the gallery's category filter can match.
    private func seedVolume(_ catalog: Catalog, uuid: String, name: String,
                            files: [(name: String, ext: String?, size: Int64, isDir: Bool)]) async throws {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: uuid, name: name, createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 500_000, isComplete: true)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            for f in files {
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: nil, name: f.name,
                          relPath: f.name, isDir: f.isDir, logicalSize: f.size, allocSize: f.size,
                          ext: f.ext).insert(db)
                nextId += 1
            }
        }
    }

    func testGalleryItemsFlattenMediaAcrossDrivesWithProvenance() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-A", name: "Alpha", files: [
            ("a.jpg", "jpg", 100, false),
            ("clip.mov", "mov", 200, false),
            ("notes.txt", "txt", 50, false),
            ("folder", nil, 0, true),            // excluded: directory
            ("archive.zip", "zip", 999, false),  // excluded: not a media category
        ])
        try await seedVolume(catalog, uuid: "UUID-B", name: "Bravo", files: [
            ("b.png", "png", 300, false),
        ])

        // Photos only → a.jpg (Alpha) + b.png (Bravo), with provenance.
        let photos = try await catalog.gallery.items(categories: [.photos])
        XCTAssertEqual(photos.map(\.relPath).sorted(), ["a.jpg", "b.png"])
        let alpha = photos.first { $0.relPath == "a.jpg" }
        XCTAssertEqual(alpha?.volumeName, "Alpha")
        XCTAssertEqual(alpha?.volumeKey, "UUID-A")
        XCTAssertEqual(alpha?.ext, "jpg")
        XCTAssertEqual(alpha?.logicalSize, 100)

        // Photos + video + documents → 4 files; zip + folder excluded.
        let media = try await catalog.gallery.items(categories: [.photos, .video, .documents])
        XCTAssertEqual(Set(media.map(\.relPath)), ["a.jpg", "clip.mov", "notes.txt", "b.png"])
        XCTAssertFalse(media.contains { $0.relPath == "archive.zip" })
        XCTAssertFalse(media.contains { $0.isDirNamePlaceholder })   // see note below

        // `.all` owns no extensions → empty.
        let none = try await catalog.gallery.items(categories: [.all])
        XCTAssertTrue(none.isEmpty)
    }
}

private extension GalleryEntry {
    // Folders are excluded by the query; this guards that none leaked in by name.
    var isDirNamePlaceholder: Bool { name == "folder" }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "gallery|GalleryEntry|error:" | head`
Expected: FAIL — `value of type 'Catalog' has no member 'gallery'` / cannot find `GalleryEntry`.

- [ ] **Step 3: Implement `GalleryService`**

Create `DiskGalleryCore/Gallery/GalleryService.swift`:

```swift
import Foundation
import GRDB

/// One displayable file in the Gallery contact sheet, carrying its owning drive's provenance.
/// A read-projection (not a table record): decoded from the gallery query's columns.
public struct GalleryEntry: Codable, Sendable, Identifiable, FetchableRecord {
    public var id: Int64            // entry id (stable within its snapshot)
    public var name: String
    public var relPath: String
    public var ext: String?
    public var logicalSize: Int64
    public var modifiedAt: Date?
    public var volumeId: Int64
    public var volumeUuid: String?
    public var volumeName: String

    /// The annotation/thumbnail key for this file's drive (uuid when known, else name) —
    /// matches how Stage A keyed thumbnails and how annotations are keyed.
    public var volumeKey: String { volumeUuid ?? volumeName }
}

/// Read query powering the Gallery: a flat, cross-drive list of media files drawn from each
/// volume's latest COMPLETE snapshot. Strictly read-only.
public struct GalleryService: Sendable {
    let db: AppDatabase

    /// Media files across all drives' latest complete snapshots, ordered drive-name then path.
    /// `categories` selects which file types to include; an empty extension set yields no rows.
    public func items(categories: [FileCategory], limit: Int = 2000) async throws -> [GalleryEntry] {
        let exts = FileCategory.extensions(for: categories)
        guard !exts.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: exts.count).joined(separator: ",")
        let args = exts.map { $0 as DatabaseValueConvertible } + [limit as DatabaseValueConvertible]
        return try await db.writer.read { db in
            try GalleryEntry.fetchAll(db, sql: """
                SELECT e.id AS id, e.name AS name, e.relPath AS relPath, e.ext AS ext,
                       e.logicalSize AS logicalSize, e.modifiedAt AS modifiedAt,
                       v.id AS volumeId, v.uuid AS volumeUuid, v.name AS volumeName
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE s.isComplete = 1
                  AND s.id = (SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId AND s2.isComplete = 1
                              ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1)
                  AND e.isDir = 0
                  AND LOWER(e.ext) IN (\(placeholders))
                ORDER BY v.name COLLATE NOCASE, e.relPath
                LIMIT ?
                """, arguments: StatementArguments(args))
        }
    }
}
```

> Note: the "latest complete snapshot per volume" subquery mirrors the established pattern in `UnifiedBrowserService`/`ChangeService`. `.all` returns no extensions by design (it is the universal matcher) — a future Stage C "All" chip will pass the concrete media categories, not `.all`.

- [ ] **Step 4: Vend `gallery` from `Catalog`**

In `DiskGalleryCore/Catalog.swift`, add after `public let thumbnails: ThumbnailService`:

```swift
    public let gallery: GalleryService
```

and in `init`, after `self.thumbnails = …`:

```swift
        self.gallery = GalleryService(db: db)
```

- [ ] **Step 5: Regenerate + test**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 170 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add DiskGalleryCore/Gallery/GalleryService.swift DiskGalleryCore/Catalog.swift DiskGalleryCoreTests/GalleryTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): GalleryService — flat cross-drive media query

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `SidebarItem.gallery` wiring + reachable stub view (app)

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` (`SidebarItem` enum + `token` + `init?(token:)`)
- Modify: `DiskGallery/App/DiskGalleryApp.swift` (`ContentColumn` router)
- Modify: `DiskGallery/Views/LibrarySidebarView.swift` (sidebar row)
- Create: `DiskGallery/Views/GalleryView.swift` (stub, replaced in Task 3)

**Interfaces:**
- Consumes: the existing `SidebarItem` routing machinery.
- Produces: a top-level `.gallery` destination selectable from the sidebar that renders `GalleryView()`.

- [ ] **Step 1: Add the enum case + token round-trip**

In `DiskGallery/App/AppEnvironment.swift`, in `enum SidebarItem`, add a case after `case organize`:

```swift
    case gallery       // Gallery: cross-drive contact sheet
```

In `var token`, add an arm:

```swift
        case .gallery:        "gallery"
```

In `init?(token:)`, add a case alongside the other literal tokens:

```swift
        case "gallery":    self = .gallery
```

- [ ] **Step 2: Route it in `ContentColumn`**

In `DiskGallery/App/DiskGalleryApp.swift`, in the `ContentColumn` switch, add an arm (next to `.allDrives`):

```swift
        case .gallery:       GalleryView()
```

> Also grep for any OTHER exhaustive `switch` over a `SidebarItem` value and add a `.gallery` arm so the app stays compiling: `grep -rn "case .allDrives" DiskGallery --include=*.swift`. (After the Modern strip, `ContentColumn` should be the only routing switch, but verify.)

- [ ] **Step 3: Add the sidebar row**

In `DiskGallery/Views/LibrarySidebarView.swift`, add a Gallery row as the FIRST entry of the "Library" `Section` (before "Duplicates"):

```swift
    Label("Gallery", systemImage: "square.grid.3x3.fill")
        .tag(SidebarItem.gallery)
```

- [ ] **Step 4: Create the stub view**

Create `DiskGallery/Views/GalleryView.swift`:

```swift
import SwiftUI

struct GalleryView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ContentUnavailableView("Gallery", systemImage: "square.grid.3x3.fill",
                               description: Text("Your cross-drive contact sheet."))
            .navigationTitle("Gallery")
    }
}
```

- [ ] **Step 5: Regenerate + build**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift DiskGallery/App/DiskGalleryApp.swift DiskGallery/Views/LibrarySidebarView.swift DiskGallery/Views/GalleryView.swift DiskGallery.xcodeproj
git commit -m "feat(app): Gallery sidebar destination + routing (stub view)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Gallery grid + tiles + selection (app)

**Files:**
- Modify: `DiskGallery/Views/GalleryView.swift` (replace the stub with the real grid; add `GalleryTile` in the same file)
- Modify: `DiskGallery/App/AppEnvironment.swift` (add `GalleryItemRef` + `var selectedGalleryItems`)

**Interfaces:**
- Consumes: `env.catalog.gallery.items`, `env.catalog.duplicates.duplicateSets`, `env.catalog.annotations.annotations(volumeKey:relPaths:)`, `env.catalog.thumbnails.thumbnailURL`, `env.dataVersion`, `env.theme.accent.palette.accent`, `FileCategory.category(forExtension:)`, `Tag.swiftUIColor`.
- Produces: `AppEnvironment.GalleryItemRef` and `env.selectedGalleryItems: [GalleryItemRef]` (consumed by Task 4); a populated contact-sheet grid.

- [ ] **Step 1: Add the selection ref to `AppEnvironment`**

In `DiskGallery/App/AppEnvironment.swift`, add this struct just below the `SidebarItem` extension (top-level in the file):

```swift
/// A lightweight reference to a gallery tile, carrying its own drive key so cross-drive
/// selections can be tagged correctly (the Gallery spans drives, unlike the .volume browser).
struct GalleryItemRef: Identifiable, Hashable {
    let id: Int64            // entry id
    let relPath: String
    let name: String
    let logicalSize: Int64
    let volumeKey: String    // uuid ?? name
}
```

and add the property to `AppEnvironment` near `selectedEntries`/`selectedVolumeKey`:

```swift
    var selectedGalleryItems: [GalleryItemRef] = []
```

- [ ] **Step 2: Replace the stub with the real grid**

Replace the entire body of `DiskGallery/Views/GalleryView.swift` with:

```swift
import SwiftUI

struct GalleryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var entries: [GalleryEntry] = []
    @State private var dupCounts: [String: Int] = [:]            // "name\u{1}size" -> copies
    @State private var annotations: [String: Annotation] = [:]   // "volumeKey\u{1}relPath" -> annotation
    @State private var selectedIds: Set<Int64> = []
    @State private var loaded = false

    private static let mediaCategories: [FileCategory] = [.photos, .raw, .video, .documents]
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            if loaded && entries.isEmpty {
                ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle.angled",
                    description: Text("Scan a drive and generate previews to see your photos here."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { entry in
                        GalleryTile(entry: entry,
                                    dupCount: dupCounts["\(entry.name)\u{1}\(entry.logicalSize)"] ?? 0,
                                    annotation: annotations["\(entry.volumeKey)\u{1}\(entry.relPath)"],
                                    isSelected: selectedIds.contains(entry.id))
                            .contentShape(Rectangle())
                            .onTapGesture { handleTap(entry) }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Gallery")
        .task(id: env.dataVersion) { await load() }
    }

    private func load() async {
        let items = (try? await env.catalog.gallery.items(categories: Self.mediaCategories)) ?? []

        // Duplicate counts: one bulk query, keyed exactly like DuplicateSet.id ("name\u{1}logicalSize").
        let sets = (try? await env.catalog.duplicates.duplicateSets(minCopies: 2, limit: 2000)) ?? []
        var dups: [String: Int] = [:]
        for s in sets { dups["\(s.name)\u{1}\(s.logicalSize)"] = s.copies }

        // Annotations: bulk per drive.
        var annos: [String: Annotation] = [:]
        for (key, group) in Dictionary(grouping: items, by: \.volumeKey) {
            let map = (try? await env.catalog.annotations.annotations(
                volumeKey: key, relPaths: group.map(\.relPath))) ?? [:]
            for (relPath, anno) in map { annos["\(key)\u{1}\(relPath)"] = anno }
        }

        entries = items
        dupCounts = dups
        annotations = annos
        selectedIds = selectedIds.intersection(Set(items.map(\.id)))   // drop ids that vanished
        syncSelectionToEnv()
        loaded = true
    }

    private func handleTap(_ entry: GalleryEntry) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selectedIds.contains(entry.id) { selectedIds.remove(entry.id) } else { selectedIds.insert(entry.id) }
        } else if mods.contains(.shift), let anchor = selectedIds.first,
                  let a = entries.firstIndex(where: { $0.id == anchor }),
                  let b = entries.firstIndex(where: { $0.id == entry.id }) {
            let range = a <= b ? a...b : b...a
            selectedIds.formUnion(entries[range].map(\.id))
        } else {
            selectedIds = [entry.id]
        }
        syncSelectionToEnv()
    }

    private func syncSelectionToEnv() {
        env.selectedGalleryItems = entries.filter { selectedIds.contains($0.id) }.map {
            GalleryItemRef(id: $0.id, relPath: $0.relPath, name: $0.name,
                           logicalSize: $0.logicalSize, volumeKey: $0.volumeKey)
        }
    }
}

private struct GalleryTile: View {
    @Environment(AppEnvironment.self) private var env
    let entry: GalleryEntry
    let dupCount: Int
    let annotation: Annotation?
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var triedLoad = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                thumbnail
                if let tag = annotation?.tag, tag != .none {
                    decisionDot(tag).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                }
                if dupCount >= 2 {
                    Text("×\(dupCount)").font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? env.theme.accent.palette.accent : .clear, lineWidth: 3))

            Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Image(systemName: "externaldrive").font(.system(size: 9))
                Text(entry.volumeName).font(.system(size: 9)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .task(id: entry.id) { await loadThumbnail() }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay(Image(systemName: glyph).font(.system(size: 28)).foregroundStyle(.secondary))
        }
    }

    private func decisionDot(_ tag: Tag) -> some View {
        Circle().fill(tag.swiftUIColor).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
    }

    private var glyph: String {
        switch FileCategory.category(forExtension: entry.ext ?? "") {
        case .photos:    return "photo"
        case .raw:       return "camera.aperture"
        case .video:     return "film"
        case .documents: return "doc.text"
        case .all:       return "doc"
        }
    }

    private func loadThumbnail() async {
        guard image == nil, !triedLoad else { return }
        triedLoad = true
        guard let url = (try? await env.catalog.thumbnails.thumbnailURL(
            volumeKey: entry.volumeKey, relPath: entry.relPath)) ?? nil else { return }
        if let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value {
            image = loaded
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (No new file → no xcodegen needed; `GalleryView.swift` is already in the project from Task 2.)

- [ ] **Step 4: Self-review the runtime logic**

Confirm by reading: tiles only instantiate lazily (LazyVGrid); thumbnail load is off-main (`Task.detached`) and guarded against re-load; dup map + annotation map are bulk-loaded once per `load()`; `selectedIds` is pruned to present ids on reload; `syncSelectionToEnv()` runs on every selection change; `.task(id: env.dataVersion)` reloads after any mutation; no `import GRDB`.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/GalleryView.swift DiskGallery/App/AppEnvironment.swift
git commit -m "feat(app): Gallery contact-sheet grid + tiles + selection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Inline tagging in the Gallery (cross-drive) (app)

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` (gallery tagging methods + extend `handleShortcut`)

**Interfaces:**
- Consumes: `selectedGalleryItems` (Task 3), `catalog.annotations`, `volumes.mountURL(forKey:)`, the existing `writeFinderTags(_:)` private helper, `ShortcutAction`, `shortcuts.action(forKey:)`.
- Produces: keyboard tagging (Q/W/E decisions, 1–7 colors) that acts on the gallery selection, applying per-tile volume keys, then reactively re-decorating tiles via `dataVersion`.

- [ ] **Step 1: Add the cross-drive gallery tagging methods**

In `DiskGallery/App/AppEnvironment.swift`, add these methods near the existing `perform`/`apply` tagging functions:

```swift
    /// Tagging entry point for the Gallery: applies the shortcut's decision/color to the
    /// gallery selection, grouped by each item's own drive key (the Gallery spans drives).
    /// Toggle semantics match the .volume browser: clear the tag if every selected item
    /// already has it, otherwise set it.
    func performGallery(_ action: ShortcutAction) async {
        let byKey = Dictionary(grouping: selectedGalleryItems, by: \.volumeKey)
        guard !byKey.isEmpty else { return }
        if let tag = action.decision {
            let allHave = await galleryAllSatisfy(byKey) { $0.tag == tag }
            await applyKeyed(byKey) { store, key, relPath in
                try await store.setDecision(allHave ? .none : tag, volumeKey: key, relPath: relPath)
            }
        } else if let color = action.color {
            let allHave = await galleryAllSatisfy(byKey) { $0.color == color }
            await applyKeyed(byKey) { store, key, relPath in
                try await store.setColor(allHave ? .none : color, volumeKey: key, relPath: relPath)
            }
        }
    }

    private func galleryAllSatisfy(_ byKey: [String: [GalleryItemRef]],
                                   _ predicate: (Annotation) -> Bool) async -> Bool {
        for (key, items) in byKey {
            let map = (try? await catalog.annotations.annotations(
                volumeKey: key, relPaths: items.map(\.relPath))) ?? [:]
            for item in items {
                guard let a = map[item.relPath], predicate(a) else { return false }
            }
        }
        return true
    }

    /// Per-drive variant of `apply(to:_:)`: mutates each item's annotation under its own
    /// volume key, then writes Finder tags for any connected drive. Reuses `writeFinderTags`.
    private func applyKeyed(_ byKey: [String: [GalleryItemRef]],
                            _ mutate: (AnnotationStore, String, String) async throws -> Annotation?) async {
        var writes: [(url: URL, decision: Tag, color: FinderColor)] = []
        for (key, items) in byKey {
            let mount = volumes.mountURL(forKey: key)
            for item in items {
                let annotation = (try? await mutate(catalog.annotations, key, item.relPath)) ?? nil
                if let mount {
                    writes.append((mount.appendingPathComponent(item.relPath),
                                   annotation?.tag ?? .none, annotation?.color ?? .none))
                }
            }
        }
        await writeFinderTags(writes)
        dataVersion += 1
        await refresh()
    }
```

- [ ] **Step 2: Route gallery shortcuts in `handleShortcut`**

Replace the body of `handleShortcut(characters:)` (currently gated to `.volume`) with a selection-aware switch:

```swift
    private func handleShortcut(characters: String) -> Bool {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return false }  // not while typing
        guard let action = shortcuts.action(forKey: characters) else { return false }
        switch selection {
        case .volume:
            let targets = selectedEntries
            guard !targets.isEmpty else { return false }
            Task { await perform(action, on: targets) }
            return true
        case .gallery:
            guard !selectedGalleryItems.isEmpty else { return false }
            Task { await performGallery(action) }
            return true
        default:
            return false
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm Core still green**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 170 tests (Task 4 is app-only; Core unchanged).

- [ ] **Step 5: Self-review the runtime logic**

Confirm: `performGallery` groups by `volumeKey` so each file is annotated under its OWN drive key (cross-drive correct); toggle semantics span the whole selection; `applyKeyed` writes Finder tags only for connected drives (offline drives get catalog-only annotations, like the existing path); `dataVersion`+`refresh()` fire so the grid re-decorates; the `.volume` path is unchanged; typing into a text field still suppresses shortcuts.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift
git commit -m "feat(app): cross-drive inline tagging in the Gallery

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (plan vs Stage B spec)

**Spec coverage:** top-level Gallery destination routed in Classic (Task 2) ✓; contact-sheet `LazyVGrid` of tiles (Task 3) ✓; tile = thumbnail-or-glyph + Keep/Delete/Review dot + duplicate ×N badge + drive provenance (Task 3) ✓; inline tagging via existing Q/W/E + 1–7 shortcuts, single + ⌘/⇧ multi-select (Task 3 selection + Task 4 tagging) ✓; offline placeholders (glyph tile when no cached thumbnail; the grid renders from the local cache so drives need not be connected) ✓. Filter chips / group-by / drive-shelf are **Stage C** (out of scope here) — Stage B uses a fixed media set `[.photos, .raw, .video, .documents]`.

**Read-only invariant:** the new query is read-only; tagging reuses the exact annotation + `writeFinderTags` path the app already ships (writes Finder tags to connected drives, catalog-only otherwise). No MutationGuard-scanned file is touched. ✓

**Placeholder scan:** Task 1 has complete code + a real cross-drive unit test. Tasks 2–4 have complete code; their gate is build + self-review (no app test target), the established verification.

**Type consistency:** `GalleryEntry` (Task 1) feeds `GalleryView` (Task 3) and `GalleryItemRef` (Task 3) feeds `performGallery` (Task 4). `dupCounts` keying (`"name\u{1}size"`) matches `DuplicateSet.id`. Annotation keying (`volumeKey ?? name`) matches Stage A's thumbnail keying and `AnnotationStore`'s `(volumeUuid, relPath)`. `catalog.gallery`/`catalog.duplicates.duplicateSets`/`catalog.annotations.annotations`/`catalog.thumbnails.thumbnailURL` signatures match their call sites.

**Carry to the end-of-stack final review:** `applyKeyed`/`galleryAllSatisfy` partially duplicate the `.volume` `apply`/`allEntries` logic (justified: cross-drive keying genuinely differs) — flag for a possible later unification. The `duplicateSets`/`gallery.items` limits (2000) silently cap very large libraries — Stage C should surface "showing N of M".
