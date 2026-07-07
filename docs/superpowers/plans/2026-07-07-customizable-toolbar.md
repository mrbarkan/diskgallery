# Finder-style Customizable Toolbar + Hidden-Files Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give DiskGallery a global, native macOS customizable toolbar (Finder's "Customize Toolbar…" — reorder, add/remove, icon/label/size, persisted) hosting the app's common actions, and fix the "Hide hidden files" toggle so it actually filters everywhere it claims to.

**Architecture:** One `.toolbar(id:)` declared on the `NavigationSplitView` in `ContentView`; items are `ToolbarItem(id:)` with stable ids that grey out when off-view. Gallery display state and the two new prefs move into the existing `ViewPrefsStore` so the toolbar and grid share them. The hidden-files fix threads a `hideHidden` flag into the four Core queries that ignore it today, filtering via the `PathVisibility` dot rule.

**Tech Stack:** SwiftUI (macOS), GRDB/SQLite (Core), `@Observable` view-model, XCTest.

## Global Constraints

- **Two-target split:** `DiskGallery` (app) imports only `DiskGalleryCore`, never GRDB directly. Query/SQL changes live in Core; UI wiring lives in the app.
- **Read-only invariant untouched:** the hidden-files change only *adds read filters*. Files stay catalogued — nothing is un-scanned or deleted. Do not touch `Scanning/`, `VolumeMetadata.swift`, `DriveHardwareProbe.swift`, `ScanProgress.swift`, `HashVerifier.swift` (guarded by `MutationGuardTests`).
- **Hidden rule = `PathVisibility`:** a path is hidden iff any `/`-separated component begins with `.`. For a single directory level (`library.children`) the immediate `name` check suffices; for flat cross-depth queries use both `relPath NOT LIKE '.%'` and `relPath NOT LIKE '%/.%'`.
- **`hideHidden` defaults to `false`** on every new Core parameter, so existing callers/tests are unaffected until they opt in.
- **Verify before commit:** build (`xcodebuild … DiskGallery … build`) + Core tests (`xcodebuild … DiskGalleryCore … test`) green. Commit only files relevant to the task; leave the untracked `CLAUDE.md` and any other pre-existing work alone.

---

## File map

- `DiskGalleryCore/Library/LibraryService.swift` — add `hideHidden` to `children`.
- `DiskGalleryCore/Gallery/GalleryService.swift` — add `hideHidden` to `items`.
- `DiskGalleryCore/Search/SearchService.swift` — add `hideHidden` to `search`.
- `DiskGalleryCore/Duplicates/DuplicateEngine.swift` — add `hideHidden` to `duplicateSets`.
- `DiskGalleryCoreTests/HiddenFilesTests.swift` — **create**, regression guard for all four.
- `DiskGallery/App/ViewPrefsStore.swift` — add gallery display prefs.
- `DiskGallery/Views/GalleryView.swift` — consume shared prefs; tile size + label toggle; trim `controlBar`.
- `DiskGallery/Views/VolumeBrowserView.swift` — pass `hideHidden`; trim `DriveHeaderBar`.
- `DiskGallery/Views/SearchResultsView.swift`, `DiskGallery/Views/DuplicatesView.swift` — pass `hideHidden` + reload on it.
- `DiskGallery/App/AppEnvironment.swift` — `chooseAndScan()`, `currentVolumeSummary`, `changesVolume` trigger.
- `DiskGallery/Views/MainToolbar.swift` — **create**, the toolbar content.
- `DiskGallery/App/DiskGalleryApp.swift` — attach the toolbar + Changes sheet in `ContentView`.

---

## Task 1: Hidden-files filter in `library.children` (per-drive browser)

**Files:**
- Modify: `DiskGalleryCore/Library/LibraryService.swift:164-172`
- Modify: `DiskGallery/Views/VolumeBrowserView.swift:163-213`
- Test: `DiskGalleryCoreTests/HiddenFilesTests.swift` (create)

**Interfaces:**
- Produces: `LibraryService.children(parentId:snapshotId:hideHidden:) async throws -> [Entry]` (new trailing `hideHidden: Bool = false`).

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/HiddenFilesTests.swift`:

```swift
import XCTest
import GRDB
@testable import DiskGalleryCore

final class HiddenFilesTests: XCTestCase {
    /// Seeds one volume + complete snapshot. Returns (rootId, snapshotId).
    /// Files are (name, relPath, parentIsRoot). Root dir has parentId nil.
    @discardableResult
    private func seed(_ catalog: Catalog, uuid: String = "UUID-H", name: String = "Hdrive",
                      children: [(name: String, relPath: String, ext: String?, dir: Bool)])
        async throws -> (rootId: Int64, snapshotId: Int64) {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: uuid, name: name, createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 500_000, isComplete: true)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            let rootId = nextId
            try Entry(id: rootId, snapshotId: snapshot.id!, parentId: nil, name: name,
                      relPath: "", isDir: true, logicalSize: 0, allocSize: 0, ext: nil).insert(db)
            nextId += 1
            for c in children {
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: rootId, name: c.name,
                          relPath: c.relPath, isDir: c.dir, logicalSize: 10, allocSize: 10,
                          ext: c.ext).insert(db)
                nextId += 1
            }
            return (rootId, snapshot.id!)
        }
    }

    func testChildrenHideDotfilesWhenHideHiddenOn() async throws {
        let catalog = try Fixture.makeCatalog()
        let (rootId, snapshotId) = try await seed(catalog, children: [
            ("a.jpg", "a.jpg", "jpg", false),
            (".DS_Store", ".DS_Store", nil, false),
            (".hidden", ".hidden", nil, true),
        ])

        let shown = try await catalog.library.children(parentId: rootId, snapshotId: snapshotId, hideHidden: true)
        XCTAssertEqual(shown.map(\.name).sorted(), ["a.jpg"])

        let all = try await catalog.library.children(parentId: rootId, snapshotId: snapshotId, hideHidden: false)
        XCTAssertEqual(all.count, 3)   // default false → nothing filtered
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/HiddenFilesTests/testChildrenHideDotfilesWhenHideHiddenOn`
Expected: FAIL — compile error, `children` has no `hideHidden:` parameter.

- [ ] **Step 3: Add the parameter + filter**

In `LibraryService.swift`, replace the `children` method:

```swift
    /// Direct children of a folder, folders first then alphabetical. When `hideHidden`,
    /// dotfiles (names beginning with ".") are excluded — see `PathVisibility`.
    public func children(parentId: Int64, snapshotId: Int64, hideHidden: Bool = false) async throws -> [Entry] {
        let hiddenClause = hideHidden ? "AND name NOT LIKE '.%'" : ""
        return try await db.writer.read { db in
            try Entry.fetchAll(db, sql: """
                SELECT * FROM entry
                WHERE snapshotId = ? AND parentId = ?
                \(hiddenClause)
                ORDER BY isDir DESC, name COLLATE NOCASE
                """, arguments: [snapshotId, parentId])
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Wire the caller (per-drive browser honors the toggle)**

In `VolumeBrowserView.swift`, the `FolderView.load()`:

```swift
    private func load() async {
        children = (try? await env.catalog.library.children(
            parentId: folder.id, snapshotId: snapshotId,
            hideHidden: env.viewPrefs.hideHidden)) ?? []
        if let key = env.selectedVolumeKey {
            annotations = (try? await env.catalog.annotations.annotations(
                volumeKey: key, relPaths: children.map(\.relPath))) ?? [:]
        }
    }
```

And make the view reload when the toggle flips — add to `FolderView.body`, right after the existing `.onChange(of: env.dataVersion)` (line 164):

```swift
        .onChange(of: env.viewPrefs.hideHidden) { _, _ in Task { await load() } }
```

- [ ] **Step 6: Build the app to confirm the caller compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add DiskGalleryCore/Library/LibraryService.swift DiskGallery/Views/VolumeBrowserView.swift DiskGalleryCoreTests/HiddenFilesTests.swift
git commit -m "fix(core): hide hidden files in the per-drive browser"
```

---

## Task 2: Hidden-files filter in `gallery.items`, `search`, `duplicateSets`

**Files:**
- Modify: `DiskGalleryCore/Gallery/GalleryService.swift:30-68`
- Modify: `DiskGalleryCore/Search/SearchService.swift:46-143`
- Modify: `DiskGalleryCore/Duplicates/DuplicateEngine.swift:54-73`
- Modify callers: `DiskGallery/Views/GalleryView.swift:175`, `DiskGallery/Views/SearchResultsView.swift:35,41`, `DiskGallery/Views/DuplicatesView.swift:21,139`
- Test: `DiskGalleryCoreTests/HiddenFilesTests.swift` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `GalleryService.items(categories:volumeId:limit:hideHidden:)` (new trailing `hideHidden: Bool = false`).
  - `SearchService.search(_:scope:filter:limit:hideHidden:)` (new trailing `hideHidden: Bool = false`).
  - `DuplicateEngine.duplicateSets(minCopies:limit:crossDriveOnly:hideHidden:)` (new trailing `hideHidden: Bool = false`).

- [ ] **Step 1: Write the failing tests**

Append to `HiddenFilesTests.swift`:

```swift
    func testGalleryItemsHideHiddenAcrossDepth() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seed(catalog, children: [
            ("a.jpg", "a.jpg", "jpg", false),
            ("t.jpg", ".Trashes/t.jpg", "jpg", false),   // inside a hidden folder
            ("b.jpg", ".b.jpg", "jpg", false),           // dot-prefixed file
        ])
        let shown = try await catalog.gallery.items(categories: [.photos], hideHidden: true)
        XCTAssertEqual(shown.map(\.relPath), ["a.jpg"])
        let all = try await catalog.gallery.items(categories: [.photos], hideHidden: false)
        XCTAssertEqual(Set(all.map(\.relPath)), [".Trashes/t.jpg", ".b.jpg", "a.jpg"])
    }

    func testSearchHidesHidden() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seed(catalog, children: [
            ("report.jpg", "report.jpg", "jpg", false),
            ("report.jpg", ".Trashes/report.jpg", "jpg", false),
        ])
        let hidden = try await catalog.search.search("report", hideHidden: true)
        XCTAssertEqual(hidden.map(\.relPath), ["report.jpg"])
        let all = try await catalog.search.search("report", hideHidden: false)
        XCTAssertEqual(all.count, 2)
    }

    func testDuplicateSetsHideHidden() async throws {
        let catalog = try Fixture.makeCatalog()
        // Two visible copies + one hidden copy of the same (name,size).
        try await seed(catalog, uuid: "UUID-D1", name: "D1", children: [
            ("dup.jpg", "dup.jpg", "jpg", false),
        ])
        try await seed(catalog, uuid: "UUID-D2", name: "D2", children: [
            ("dup.jpg", "dup.jpg", "jpg", false),
            ("dup.jpg", ".Trashes/dup.jpg", "jpg", false),
        ])
        let hidden = try await catalog.duplicates.duplicateSets(hideHidden: true)
        XCTAssertEqual(hidden.first(where: { $0.name == "dup.jpg" })?.copies, 2)
        let all = try await catalog.duplicates.duplicateSets(hideHidden: false)
        XCTAssertEqual(all.first(where: { $0.name == "dup.jpg" })?.copies, 3)
    }
```

> Note: `seed` inserts each child with `logicalSize: 10`, so the three `dup.jpg` rows share `(name, size)` and form one duplicate set.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test -only-testing:DiskGalleryCoreTests/HiddenFilesTests`
Expected: FAIL — the three new methods lack a `hideHidden:` parameter.

- [ ] **Step 3a: `GalleryService.items`**

Add the parameter and a clause. Change the signature (line 30):

```swift
    public func items(categories: [FileCategory], volumeId: Int64? = nil,
                      limit: Int = 2000, hideHidden: Bool = false) async throws -> [GalleryEntry] {
```

Add, just below the `volumeClause`/`volumeArg` block (after line 42):

```swift
        let hiddenClause = hideHidden ? "AND e.relPath NOT LIKE '.%' AND e.relPath NOT LIKE '%/.%'" : ""
```

Insert `\(hiddenClause)` into the SQL, right after the `\(volumeClause)` line (line 63):

```swift
                  \(volumeClause)
                  \(hiddenClause)
                ORDER BY v.name COLLATE NOCASE, e.relPath
```

(The clause carries no `?`, so `sqlArgs` is unchanged.)

- [ ] **Step 3b: `SearchService.search`**

Change the signature (line 46):

```swift
    public func search(_ query: String, scope: SearchScope = .all,
                       filter: SearchFilter = .none, limit: Int = 1000,
                       hideHidden: Bool = false) async throws -> [SearchResult] {
```

Add the clause immediately before the ORDER BY line (line 130), so it lands after all scope/filter clauses and before `LIMIT ?` (no argument, so ordering is safe):

```swift
        if hideHidden {
            sql += " AND e.relPath NOT LIKE '.%' AND e.relPath NOT LIKE '%/.%'"
        }
        sql += " ORDER BY e.isDir DESC, e.name COLLATE NOCASE LIMIT ?"
```

- [ ] **Step 3c: `DuplicateEngine.duplicateSets`**

Change the signature (line 54):

```swift
    public func duplicateSets(minCopies: Int = 2, limit: Int = 500,
                              crossDriveOnly: Bool = false, hideHidden: Bool = false) async throws -> [DuplicateSet] {
```

Add the clause into the WHERE (line 66), which uses alias `e`:

```swift
                WHERE e.isDir = 0 AND e.logicalSize > 0 AND e.snapshotId IN (SELECT id FROM latest)
                  \(hideHidden ? "AND e.relPath NOT LIKE '.%' AND e.relPath NOT LIKE '%/.%'" : "")
                GROUP BY e.name, e.logicalSize
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same as Step 2.
Expected: PASS (all four `HiddenFilesTests`).

- [ ] **Step 5: Wire the callers + their reload triggers**

`GalleryView.swift` `load()` (line 175):

```swift
        let items = (try? await env.catalog.gallery.items(
            categories: filter.categories, volumeId: driveFilter,
            hideHidden: env.viewPrefs.hideHidden)) ?? []
```

And add `hideHidden` to its reload id (line 96):

```swift
        .task(id: "\(env.dataVersion)-\(filter.rawValue)-\(driveFilter ?? -1)-\(env.viewPrefs.hideHidden)") { await load() }
```

(Leave the `duplicateSets` call at line 178 as-is — it only feeds count badges, and hidden files never appear in the filtered `items` anyway.)

`SearchResultsView.swift` — pass the flag (line 41) and add it to the `.task` id (line 35):

```swift
        results = (try? await env.catalog.search.search(trimmed, hideHidden: env.viewPrefs.hideHidden)) ?? []
```
```swift
        .task(id: "\(query)-\(env.viewPrefs.hideHidden)") { await run() }
```

`DuplicatesView.swift` — pass the flag (line 139) and add it to `reloadKey` (line 21):

```swift
        sets = (try? await env.catalog.duplicates.duplicateSets(
            crossDriveOnly: crossDriveOnly, hideHidden: env.viewPrefs.hideHidden)) ?? []
```
```swift
    private var reloadKey: String { "\(env.dataVersion)-\(crossDriveOnly)-\(env.viewPrefs.hideHidden)" }
```

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add DiskGalleryCore/Gallery/GalleryService.swift DiskGalleryCore/Search/SearchService.swift DiskGalleryCore/Duplicates/DuplicateEngine.swift DiskGalleryCoreTests/HiddenFilesTests.swift DiskGallery/Views/GalleryView.swift DiskGallery/Views/SearchResultsView.swift DiskGallery/Views/DuplicatesView.swift
git commit -m "fix(core): honor hide-hidden in gallery, search, and duplicates"
```

> At this point the reported bug is fully fixed: the Settings toggle now filters the browser, Gallery, search, and duplicates — matching its own help text.

---

## Task 3: Lift Gallery display prefs into `ViewPrefsStore`

Gallery filter/grouping are `@State` in the view today, so a global toolbar can't drive them. Move them into the shared store and add the two new prefs. (No unit test — `ViewPrefsStore` is trivial `UserDefaults` glue in the untested app target, consistent with the existing `hideHidden`/`restoreLastView` properties.)

**Files:**
- Modify: `DiskGallery/App/ViewPrefsStore.swift`

**Interfaces:**
- Consumes: `GalleryFilter`, `GalleryGrouping` (enums in `GalleryView.swift`, same target).
- Produces on `ViewPrefsStore`: `galleryFilter: GalleryFilter`, `galleryGrouping: GalleryGrouping`, `galleryTileSize: GalleryTileSize`, `galleryShowLabels: Bool`, and a new enum `GalleryTileSize { case small, large }`.

- [ ] **Step 1: Add the tile-size enum**

Add near the top of `ViewPrefsStore.swift` (below `import`s):

```swift
/// Gallery thumbnail tile size — the "large or small icons" control.
enum GalleryTileSize: String, CaseIterable, Identifiable {
    case small, large
    var id: String { rawValue }
    /// Adaptive grid min/max for `GridItem(.adaptive(...))`.
    var gridMin: CGFloat { self == .small ? 96 : 150 }
    var gridMax: CGFloat { self == .small ? 130 : 220 }
}
```

- [ ] **Step 2: Add the four persisted properties**

Add keys alongside the existing ones and properties in the pattern of `hideHidden`:

```swift
    private let galleryFilterKey = "view.galleryFilter"
    private let galleryGroupingKey = "view.galleryGrouping"
    private let galleryTileSizeKey = "view.galleryTileSize"
    private let galleryShowLabelsKey = "view.galleryShowLabels"

    var galleryFilter: GalleryFilter {
        didSet { defaults.set(galleryFilter.rawValue, forKey: galleryFilterKey) }
    }
    var galleryGrouping: GalleryGrouping {
        didSet { defaults.set(galleryGrouping.rawValue, forKey: galleryGroupingKey) }
    }
    var galleryTileSize: GalleryTileSize {
        didSet { defaults.set(galleryTileSize.rawValue, forKey: galleryTileSizeKey) }
    }
    var galleryShowLabels: Bool {
        didSet { defaults.set(galleryShowLabels, forKey: galleryShowLabelsKey) }
    }
```

And initialize them in `init` (after the existing assignments):

```swift
        galleryFilter = (defaults.string(forKey: galleryFilterKey)).flatMap(GalleryFilter.init(rawValue:)) ?? .all
        galleryGrouping = (defaults.string(forKey: galleryGroupingKey)).flatMap(GalleryGrouping.init(rawValue:)) ?? .none
        galleryTileSize = (defaults.string(forKey: galleryTileSizeKey)).flatMap(GalleryTileSize.init(rawValue:)) ?? .large
        galleryShowLabels = defaults.object(forKey: galleryShowLabelsKey) as? Bool ?? true
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
Expected: BUILD SUCCEEDED. (`GalleryFilter`/`GalleryGrouping` already declare `String` raw values in `GalleryView.swift`.)

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/App/ViewPrefsStore.swift
git commit -m "feat(app): gallery display prefs (filter, group, tile size, labels) in ViewPrefsStore"
```

---

## Task 4: GalleryView consumes shared prefs + tile size + label toggle

**Files:**
- Modify: `DiskGallery/Views/GalleryView.swift`

**Interfaces:**
- Consumes: `env.viewPrefs.galleryFilter/galleryGrouping/galleryTileSize/galleryShowLabels`.

- [ ] **Step 1: Replace the local filter/grouping state with the store**

Delete these two `@State` lines (lines 47-48):

```swift
    @State private var filter: GalleryFilter = .all
    @State private var grouping: GalleryGrouping = .none
```

Add computed read accessors so the file's `filter`/`grouping` *reads* keep working (`sections`, `grouped`, `handleTap`, the `.task` id):

```swift
    private var filter: GalleryFilter { env.viewPrefs.galleryFilter }
    private var grouping: GalleryGrouping { env.viewPrefs.galleryGrouping }
```

These are read-only, so the two *write* sites in `controlBar` must go through the store directly (they're deleted in Task 6, but must stay green until then). In `controlBar`, change the filter chip's action (line 152) from `filter = f` to:

```swift
                        Button { env.viewPrefs.galleryFilter = f } label: {
```

and the group `Picker` (line 166) from `selection: $grouping` to:

```swift
            Picker("Group", selection: $env.viewPrefs.galleryGrouping) {
```

(`env` in `controlBar` is `@Bindable`-free — `$env.viewPrefs.galleryGrouping` works because `AppEnvironment` is `@Observable` and `viewPrefs` is a reference type; if the compiler rejects the binding, add `@Bindable var env = env` as the first line of `controlBar`, matching SwiftUI's `@Observable` binding idiom.)

- [ ] **Step 2: Make the grid columns react to tile size**

Replace the fixed `columns` (line 52) with a computed property:

```swift
    private var columns: [GridItem] {
        let size = env.viewPrefs.galleryTileSize
        return [GridItem(.adaptive(minimum: size.gridMin, maximum: size.gridMax), spacing: 12)]
    }
```

- [ ] **Step 3: Gate the tile labels**

In `GalleryTile.body`, wrap the name + drive rows (lines 279-284) so they only show when labels are on. `GalleryTile` needs the env (it already has `@Environment(AppEnvironment.self) private var env`). Replace those lines with:

```swift
            if env.viewPrefs.galleryShowLabels {
                Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive").font(.system(size: 9))
                    Text(entry.volumeName).font(.system(size: 9)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Build + manual smoke**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
Expected: BUILD SUCCEEDED.

Manual (via the `run` skill or a debug build): open the Gallery. It still loads and groups. (Tile size / labels have no UI control yet — that arrives in Task 5; verify no regression here.)

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/GalleryView.swift
git commit -m "feat(app): Gallery reads tile size + label + filter prefs from the shared store"
```

---

## Task 5: The native customizable toolbar

**Files:**
- Create: `DiskGallery/Views/MainToolbar.swift`
- Modify: `DiskGallery/App/AppEnvironment.swift` (add `chooseAndScan()`, `currentVolumeSummary`, `changesVolume`)
- Modify: `DiskGallery/App/DiskGalleryApp.swift` (attach toolbar + Changes sheet on `ContentView`)

**Interfaces:**
- Consumes: everything above (`viewPrefs` prefs, `hideHidden`, `rescan`, `startScan`).
- Produces on `AppEnvironment`: `func chooseAndScan()`, `var currentVolumeSummary: VolumeSummary?`, `var changesVolume: VolumeSummary?`.

- [ ] **Step 1: AppEnvironment — reusable scan picker, current-drive helper, Changes trigger**

Factor the sidebar's scan panel into `AppEnvironment` (so both the sidebar and toolbar call one thing) and add the two lookups. Add to `AppEnvironment` (near `startScan`, line 465):

```swift
    /// Presents the read-only folder/drive picker and scans the choice.
    /// Shared by the sidebar's Scan button and the toolbar's New Scan item.
    func chooseAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a drive or folder to catalog. DiskGallery only reads — it never changes anything."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url { startScan(url: url) }
    }
```

Add these stored/computed members near the other selection state (after `selectedGalleryItems`, line 131):

```swift
    /// Non-nil drives the global Changes… sheet (set by the toolbar item).
    var changesVolume: VolumeSummary?

    /// The drive summary for the current sidebar selection, or nil off a drive view.
    var currentVolumeSummary: VolumeSummary? {
        if case .volume(let id) = selection { return volumeSummaries.first { $0.id == id } }
        return nil
    }
```

Point the sidebar at the shared method — in `LibrarySidebarView.swift`, replace the body of `private func scan()` (lines 109-120) with a single call:

```swift
    private func scan() { env.chooseAndScan() }
```

- [ ] **Step 2: Create the toolbar content**

Create `DiskGallery/Views/MainToolbar.swift`. It's a `ToolbarContent` builder keyed by stable ids; contextual items disable when they don't apply. `New Scan` and `Show Labels` default to hidden (available via Customize); the rest default visible.

```swift
import SwiftUI
import DiskGalleryCore

/// The app-wide, user-customizable toolbar (Finder's "Customize Toolbar…" gives
/// reorder / add-remove / icon+label / small-size / persistence for free — we just
/// declare the items). Contextual items grey out when they don't apply.
struct MainToolbar: ToolbarContent {
    @Bindable var env: AppEnvironment

    private var isGallery: Bool { if case .gallery = env.selection { return true }; return false }

    var body: some ToolbarContent {
        ToolbarItem(id: "scan", placement: .primaryAction) {
            Button { env.chooseAndScan() } label: { Label("New Scan", systemImage: "externaldrive.badge.plus") }
                .help("Catalog a new drive or folder")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "rescan", placement: .primaryAction) {
            Button { if let v = env.currentVolumeSummary { env.rescan(volume: v) } }
                label: { Label("Re-scan", systemImage: "arrow.clockwise") }
                .disabled(!(env.currentVolumeSummary != nil && env.isSelectedVolumeConnected))
                .help("Scan the selected drive again")
        }

        ToolbarItem(id: "changes", placement: .primaryAction) {
            Button { env.changesVolume = env.currentVolumeSummary }
                label: { Label("Changes…", systemImage: "clock.arrow.2.circlepath") }
                .disabled(env.currentVolumeSummary?.latestSnapshotId == nil)
                .help("Compare this drive's scans")
        }

        ToolbarItem(id: "filter", placement: .primaryAction) {
            Picker("Filter", selection: $env.viewPrefs.galleryFilter) {
                ForEach(GalleryFilter.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!isGallery)
            .help("Filter the Gallery by media type")
        }

        ToolbarItem(id: "group", placement: .primaryAction) {
            Picker("Group", selection: $env.viewPrefs.galleryGrouping) {
                ForEach(GalleryGrouping.allCases) { Text($0.label).tag($0) }
            }
            .disabled(!isGallery)
            .help("Group the Gallery")
        }

        ToolbarItem(id: "tileSize", placement: .primaryAction) {
            Picker("Size", selection: $env.viewPrefs.galleryTileSize) {
                Image(systemName: "square.grid.3x3").tag(GalleryTileSize.small)
                Image(systemName: "square.grid.2x2").tag(GalleryTileSize.large)
            }
            .pickerStyle(.segmented)
            .disabled(!isGallery)
            .help("Large or small tiles")
        }

        ToolbarItem(id: "labels", placement: .primaryAction) {
            Toggle(isOn: $env.viewPrefs.galleryShowLabels) { Label("Labels", systemImage: "textformat") }
                .disabled(!isGallery)
                .help("Show file names under tiles")
        }
        .defaultCustomization(.hidden)

        ToolbarItem(id: "hidden", placement: .primaryAction) {
            Toggle(isOn: $env.viewPrefs.hideHidden) { Label("Hide Hidden", systemImage: "eye.slash") }
                .help("Hide dotfiles from the browser, Gallery, search, and duplicates")
        }
    }
}
```

> Notes: the `sidebar` toggle is provided free by `NavigationSplitView` and isn't declared here. A `search` field is intentionally omitted from v1 — the app already has a dedicated Search destination in the sidebar; add a toolbar search item later if wanted (spec "our options" set is satisfied by the above). `@Bindable` gives `$env.viewPrefs.*` bindings from the `@Observable` env.

- [ ] **Step 3: Attach the toolbar + Changes sheet in ContentView**

In `DiskGalleryApp.swift`, in `ContentView.body`, add the customizable toolbar and the global Changes sheet to the `NavigationSplitView`. Add these modifiers alongside the existing `.sheet`/`.alert` chain (e.g. right after the `NavigationSplitView { … }` closing brace, before `.sheet(isPresented:` at line 156):

```swift
        .toolbar(id: "dg.main") { MainToolbar(env: env) }
        .sheet(item: Binding(get: { env.changesVolume },
                             set: { env.changesVolume = $0 })) { summary in
            ChangesView(summary: summary).environment(env)
        }
```

`env` here is the `AppEnvironment` from `@Environment(AppEnvironment.self)`; pass it to `MainToolbar(env:)`. `VolumeSummary` is `Identifiable` (used already in `ForEach(env.volumeSummaries)`), so `.sheet(item:)` works.

- [ ] **Step 4: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Manual smoke (verify the native customization actually appears)**

Launch the app (via the `run` skill). Confirm:
1. A toolbar renders at the top (alongside the hidden title bar). If it does **not** appear, remove `.windowStyle(.hiddenTitleBar)` from `DiskGalleryApp.swift:75` (keep `.windowToolbarStyle(.unified)`) and rebuild — this is the spec's flagged fallback.
2. Right-click the toolbar → **Customize Toolbar…** opens the native sheet with drag-reorder, add/remove, **Show: Icon and Text / Icon Only / Text Only**, and **Use small size**. Change a couple, quit, relaunch → the customization persists.
3. On a drive view, Re-scan/Changes are enabled and Gallery items greyed; on the Gallery, the reverse. Filter/Group/Size/Labels drive the grid; Hide Hidden live-updates the browser/Gallery/search/duplicates.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/Views/MainToolbar.swift DiskGallery/App/AppEnvironment.swift DiskGallery/App/DiskGalleryApp.swift DiskGallery/Views/LibrarySidebarView.swift
git commit -m "feat(app): native customizable app toolbar (Finder-style)"
```

---

## Task 6: Trim the now-duplicated in-view controls

The toolbar now owns Re-scan/Changes and the Gallery filter/group, so remove them from the in-view bars to avoid two copies. Keep each bar's informational content.

**Files:**
- Modify: `DiskGallery/Views/VolumeBrowserView.swift` (`DriveHeaderBar`)
- Modify: `DiskGallery/Views/GalleryView.swift` (`controlBar`)

- [ ] **Step 1: DriveHeaderBar — drop the two action buttons**

In `VolumeBrowserView.swift`, remove the `Changes…` and `Re-scan` `Button`s from `DriveHeaderBar.body` (lines 81-90) and the now-unused `onShowChanges` closure param + its `showChanges` state/sheet plumbing (lines 9, 37, 46). `DriveHeaderBar` keeps the name, info line, hardware badge, and `CapacityBar`. Update the call site at line 37:

```swift
                DriveHeaderBar(summary: summary)
```

and change `DriveHeaderBar`'s declaration to drop `let onShowChanges: () -> Void`. Remove `@State private var showChanges = false` (line 9) and the `.sheet(isPresented: $showChanges)` (line 46) — Changes is now the global toolbar sheet.

- [ ] **Step 2: Gallery controlBar — drop the filter chips + group picker**

In `GalleryView.swift`, replace the `controlBar` body (lines 148-172) so it keeps only the cached-count readout (filter + group now live in the toolbar):

```swift
    @ViewBuilder private var controlBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 8)
            Text("\(cachedCount) of \(entries.count) cached")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
```

- [ ] **Step 3: Build + manual smoke**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
Expected: BUILD SUCCEEDED.

Manual: drive view shows one Re-scan/Changes (toolbar only); Gallery shows one filter/group (toolbar only); the drive capacity gauge and the Gallery cached-count still render.

- [ ] **Step 4: Run the full Core suite (regression)**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test`
Expected: all tests pass (existing suite + the new `HiddenFilesTests`).

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/VolumeBrowserView.swift DiskGallery/Views/GalleryView.swift
git commit -m "refactor(app): move drive + gallery actions into the toolbar, slim the in-view bars"
```

---

## Self-review notes (author)

- **Spec coverage:** native toolbar (Task 5) · global scope with contextual greying (Task 5) · toggle labels + small/large via native sheet *and* Gallery tile controls (Tasks 4-5) · customize add/remove + reorder + persistence (native, Task 5) · hidden-files fix across browser/gallery/search/duplicates (Tasks 1-2) · migrate duplicated controls (Task 6). All covered.
- **Types consistent:** `hideHidden: Bool = false` trailing param on all four Core methods; `GalleryTileSize` defined in Task 3 and consumed in Tasks 4-5; `chooseAndScan()`, `currentVolumeSummary`, `changesVolume` defined in Task 5 Step 1 and consumed in Step 2-3.
- **Known verify-at-runtime point:** whether a native toolbar renders under `.hiddenTitleBar` (Task 5 Step 5 carries the fallback). This is the one item that can't be settled by reading code.
- **Deliberately out of scope:** a toolbar search field (sidebar Search already exists), list/column view switching.
```
