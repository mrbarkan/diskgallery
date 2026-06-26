# Gallery Stage C — Filters, grouping, drive shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the Gallery with media-type filter chips (All / Photos / RAW / Video / Docs / Audio) + a live "N of M cached" count, group-by (shoot / drive / type), and a drive-shelf header (drive cards with online/offline + fill + file count) that filters the sheet to one drive.

**Architecture:** Small Core additions (an `.audio` `FileCategory`; an optional `volumeId` filter on `gallery.items`; a bulk `ThumbnailService.cachedRelPaths` for the cached count) feed an enriched `GalleryView`: a control bar (chips + group-by + count) and a drive-shelf header above the existing contact-sheet grid. All grouping/filtering is client-side over the loaded entries except the drive filter (pushed into the query) and the category filter (drives which categories are fetched).

**Tech Stack:** Swift 6.0 / macOS 15.0, SwiftUI, DiskGalleryCore (GRDB behind a facade).

## Global Constraints

- Swift 6.0, macOS 15.0, strict concurrency. Mirror existing patterns.
- The **app target never imports GRDB** — all DB access via `env.catalog.*`.
- **Read-only cataloging preserved**: Stage C only adds read queries + UI. No file `MutationGuardTests` scans may be touched; no new drive writes.
- DB column/alias names equal decoding property names (camelCase).
- Baseline 170 Core tests green. After Task 1: 173 green (3 new tests). App must reach `** BUILD SUCCEEDED **` after every app task.
- New files need `xcodegen generate` before building; include `DiskGallery.xcodeproj` in that commit. (Stage C adds no new files — all edits are to existing files — so no xcodegen is expected.)
- Every commit message ends with exactly:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- No app unit-test target: app tasks are gated by build success + self-review; the visual smoke is deferred to the owner.

---

### Task 1: Core foundation — audio category, drive filter, cached-count query

**Files:**
- Modify: `DiskGalleryCore/Data/FileCategory.swift` (add `.audio`)
- Modify: `DiskGalleryCore/Gallery/GalleryService.swift` (add `volumeId:` param)
- Modify: `DiskGalleryCore/Thumbnails/ThumbnailService.swift` (add `cachedRelPaths`)
- Test: `DiskGalleryCoreTests/GalleryTests.swift` (append) and `DiskGalleryCoreTests/ThumbnailTests.swift` (append)

**Interfaces:**
- Consumes: existing `FileCategory.extensionsByCategory`, the `thumbnail`/`entry`/`snapshot`/`volume` tables.
- Produces: `FileCategory.audio`; `GalleryService.items(categories:volumeId:limit:)`; `ThumbnailService.cachedRelPaths(volumeKey:relPaths:) async throws -> Set<String>`.

- [ ] **Step 1: Write the failing tests**

Append to `DiskGalleryCoreTests/GalleryTests.swift` (inside the `GalleryTests` class):

```swift
    func testAudioCategoryAndPerDriveFilter() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-A", name: "Alpha", files: [
            ("a.jpg", "jpg", 100, false),
            ("song.mp3", "mp3", 400, false),
        ])
        try await seedVolume(catalog, uuid: "UUID-B", name: "Bravo", files: [
            ("b.jpg", "jpg", 100, false),
        ])

        // Audio category classifies mp3.
        XCTAssertEqual(FileCategory.category(forExtension: "mp3"), .audio)
        let audio = try await catalog.gallery.items(categories: [.audio])
        XCTAssertEqual(audio.map(\.relPath), ["song.mp3"])

        // Per-drive filter: only Alpha's photos.
        let alphaId = audio.first?.volumeId ?? -1
        let alphaPhotos = try await catalog.gallery.items(categories: [.photos], volumeId: alphaId)
        XCTAssertEqual(alphaPhotos.map(\.relPath), ["a.jpg"])
        XCTAssertTrue(alphaPhotos.allSatisfy { $0.volumeName == "Alpha" })

        // No filter → both drives' photos.
        let allPhotos = try await catalog.gallery.items(categories: [.photos])
        XCTAssertEqual(Set(allPhotos.map(\.volumeName)), ["Alpha", "Bravo"])
    }
```

Append to `DiskGalleryCoreTests/ThumbnailTests.swift` (inside the test class):

```swift
    func testCachedRelPathsReturnsStoredSet() async throws {
        let dbURL = try tempDir().appendingPathComponent("catalog.sqlite")
        let catalog = try Catalog(databaseURL: dbURL)
        try await catalog.thumbnails.store(Data([0x1]), volumeKey: "A", relPath: "x.jpg", srcModifiedAt: nil, srcSize: 1)
        try await catalog.thumbnails.store(Data([0x2]), volumeKey: "A", relPath: "y.jpg", srcModifiedAt: nil, srcSize: 1)

        let cached = try await catalog.thumbnails.cachedRelPaths(volumeKey: "A", relPaths: ["x.jpg", "y.jpg", "z.jpg"])
        XCTAssertEqual(cached, ["x.jpg", "y.jpg"])

        let other = try await catalog.thumbnails.cachedRelPaths(volumeKey: "B", relPaths: ["x.jpg"])
        XCTAssertTrue(other.isEmpty)
        let empty = try await catalog.thumbnails.cachedRelPaths(volumeKey: "A", relPaths: [])
        XCTAssertTrue(empty.isEmpty)
    }
```

> `tempDir()` already exists in `ThumbnailTests` (added in Stage A Task 2). The `seedVolume` helper already exists in `GalleryTests` (Stage B Task 1).

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "audio|cachedRelPaths|volumeId|error:" | head`
Expected: FAIL — `type 'FileCategory' has no member 'audio'` / no `cachedRelPaths` / extra `volumeId:` argument.

- [ ] **Step 3: Add `.audio` to `FileCategory`**

In `DiskGalleryCore/Data/FileCategory.swift`:

Add `audio` to the case list:

```swift
    case all, photos, video, raw, documents, audio
```

Add a `label` arm:

```swift
        case .audio:     return "Audio"
```

Add an entry to the `extensionsByCategory` dictionary:

```swift
        .audio:     ["mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "alac", "ogg"],
```

(No change to `category(forExtension:)` — it iterates `extensionsByCategory`, so audio is classified automatically.)

- [ ] **Step 4: Add the `volumeId` filter to `GalleryService.items`**

In `DiskGalleryCore/Gallery/GalleryService.swift`, replace the `items` method with:

```swift
    /// Media files across drives' latest complete snapshots, ordered drive-name then path.
    /// `categories` selects file types (empty extension set → no rows). `volumeId` (when set)
    /// restricts to one drive.
    public func items(categories: [FileCategory], volumeId: Int64? = nil, limit: Int = 2000) async throws -> [GalleryEntry] {
        let exts = FileCategory.extensions(for: categories)
        guard !exts.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: exts.count).joined(separator: ",")
        var args: [DatabaseValueConvertible] = exts.map { $0 as DatabaseValueConvertible }
        let volumeClause: String
        if let volumeId {
            volumeClause = "AND v.id = ?"
            args.append(volumeId)
        } else {
            volumeClause = ""
        }
        args.append(limit)
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
                  \(volumeClause)
                ORDER BY v.name COLLATE NOCASE, e.relPath
                LIMIT ?
                """, arguments: StatementArguments(args))
        }
    }
```

- [ ] **Step 5: Add `cachedRelPaths` to `ThumbnailService`**

In `DiskGalleryCore/Thumbnails/ThumbnailService.swift`, add:

```swift
    /// Which of `relPaths` (under `volumeKey`) already have a cached thumbnail row.
    /// Used for the Gallery's "N of M cached" indicator.
    public func cachedRelPaths(volumeKey: String, relPaths: [String]) async throws -> Set<String> {
        guard !relPaths.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: relPaths.count).joined(separator: ",")
        let args: [DatabaseValueConvertible] = [volumeKey] + relPaths
        return try await db.writer.read { db in
            Set(try String.fetchAll(db, sql:
                "SELECT relPath FROM thumbnail WHERE volumeKey = ? AND relPath IN (\(placeholders))",
                arguments: StatementArguments(args)))
        }
    }
```

- [ ] **Step 6: Run the tests**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 173 tests, 0 failures.

> If any existing test/UI that switches exhaustively over `FileCategory` fails to compile after adding `.audio`, add an `.audio` arm there. (The app build in Task 2 will also surface any such switch.)

- [ ] **Step 7: Commit**

```bash
git add DiskGalleryCore/Data/FileCategory.swift DiskGalleryCore/Gallery/GalleryService.swift DiskGalleryCore/Thumbnails/ThumbnailService.swift DiskGalleryCoreTests/GalleryTests.swift DiskGalleryCoreTests/ThumbnailTests.swift
git commit -m "feat(core): audio category + per-drive gallery filter + cached-count query

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Filter chips + group-by + "N of M cached" (app)

**Files:**
- Modify: `DiskGallery/Views/GalleryView.swift`

**Interfaces:**
- Consumes: `env.catalog.gallery.items(categories:volumeId:limit:)`, `env.catalog.thumbnails.cachedRelPaths(volumeKey:relPaths:)`, `FileCategory`, `Format`.
- Produces: an in-view control bar (category chips + group-by picker + cached count) and a sectioned grid.

- [ ] **Step 1: Add filter/grouping enums + state**

At the top of `DiskGallery/Views/GalleryView.swift` (file scope, above `struct GalleryView`), add:

```swift
/// Media-type filter chips for the Gallery.
enum GalleryFilter: String, CaseIterable, Identifiable {
    case all, photos, raw, video, docs, audio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"; case .photos: return "Photos"; case .raw: return "RAW"
        case .video: return "Video"; case .docs: return "Docs"; case .audio: return "Audio"
        }
    }
    var categories: [FileCategory] {
        switch self {
        case .all:    return [.photos, .raw, .video, .documents, .audio]
        case .photos: return [.photos]
        case .raw:    return [.raw]
        case .video:  return [.video]
        case .docs:   return [.documents]
        case .audio:  return [.audio]
        }
    }
}

/// How the Gallery grid is grouped into sections.
enum GalleryGrouping: String, CaseIterable, Identifiable {
    case none, shoot, drive, type
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"; case .shoot: return "Shoot"
        case .drive: return "Drive"; case .type: return "Type"
        }
    }
}
```

In `GalleryView`, add state near the existing `@State` properties:

```swift
    @State private var filter: GalleryFilter = .all
    @State private var grouping: GalleryGrouping = .none
    @State private var cachedCount = 0
```

- [ ] **Step 2: Drive `load()` from the filter + compute the cached count**

Replace `GalleryView.load()` with (note: `volumeId` for the drive filter is added in Task 3 — here it stays the all-drives query):

```swift
    private func load() async {
        let items = (try? await env.catalog.gallery.items(categories: filter.categories)) ?? []

        // Duplicate counts (one bulk query), keyed like DuplicateSet.id.
        let sets = (try? await env.catalog.duplicates.duplicateSets(minCopies: 2, limit: 2000)) ?? []
        var dups: [String: Int] = [:]
        for s in sets { dups["\(s.name)\u{1}\(s.logicalSize)"] = s.copies }

        // Annotations + cached-thumbnail counts, bulk per drive.
        var annos: [String: Annotation] = [:]
        var cached = 0
        for (key, group) in Dictionary(grouping: items, by: \.volumeKey) {
            let relPaths = group.map(\.relPath)
            let map = (try? await env.catalog.annotations.annotations(volumeKey: key, relPaths: relPaths)) ?? [:]
            for (relPath, anno) in map { annos["\(key)\u{1}\(relPath)"] = anno }
            let hit = (try? await env.catalog.thumbnails.cachedRelPaths(volumeKey: key, relPaths: relPaths)) ?? []
            cached += hit.count
        }

        entries = items
        dupCounts = dups
        annotations = annos
        cachedCount = cached
        selectedIds = selectedIds.intersection(Set(items.map(\.id)))
        syncSelectionToEnv()
        loaded = true
    }
```

And make the reload re-run when the filter changes — change the view's `.task` modifier to also key on the filter:

```swift
        .task(id: "\(env.dataVersion)-\(filter.rawValue)") { await load() }
```

- [ ] **Step 3: Add the control bar + sectioned grid**

Add this computed grouping helper to `GalleryView`:

```swift
    /// The grid split into titled sections per the current grouping ("" title = no header).
    private var sections: [(title: String, items: [GalleryEntry])] {
        switch grouping {
        case .none:
            return entries.isEmpty ? [] : [("", entries)]
        case .drive:
            return grouped { $0.volumeName }
        case .type:
            return grouped { FileCategory.category(forExtension: $0.ext ?? "").label }
        case .shoot:
            return grouped { shoot(of: $0.relPath) }
        }
    }

    private func grouped(_ key: (GalleryEntry) -> String) -> [(title: String, items: [GalleryEntry])] {
        Dictionary(grouping: entries, by: key)
            .map { (title: $0.key, items: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The "shoot" = the file's parent folder name (or "—" at the volume root).
    private func shoot(of relPath: String) -> String {
        let parent = (relPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "—" : (parent as NSString).lastPathComponent
    }
```

Replace the `body` of `GalleryView` with a version that adds the control bar above the grid and renders sections:

```swift
    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            ScrollView {
                if loaded && entries.isEmpty {
                    ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle.angled",
                        description: Text("Scan a drive and generate previews to see your photos here."))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.title) { section in
                            Section {
                                ForEach(section.items) { entry in
                                    GalleryTile(entry: entry,
                                                dupCount: dupCounts["\(entry.name)\u{1}\(entry.logicalSize)"] ?? 0,
                                                annotation: annotations["\(entry.volumeKey)\u{1}\(entry.relPath)"],
                                                isSelected: selectedIds.contains(entry.id))
                                        .contentShape(Rectangle())
                                        .onTapGesture { handleTap(entry) }
                                }
                            } header: {
                                if !section.title.isEmpty {
                                    HStack {
                                        Text(section.title).font(.headline)
                                        Spacer()
                                        Text("\(section.items.count)").foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4).padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity)
                                    .background(.regularMaterial)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Gallery")
        .task(id: "\(env.dataVersion)-\(filter.rawValue)") { await load() }
    }

    @ViewBuilder private var controlBar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GalleryFilter.allCases) { f in
                        Button { filter = f } label: {
                            Text(f.label).font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(filter == f ? env.theme.accent.palette.accent : Color(.controlBackgroundColor),
                                            in: Capsule())
                                .foregroundStyle(filter == f ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(cachedCount) of \(entries.count) cached")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            Picker("Group", selection: $grouping) {
                ForEach(GalleryGrouping.allCases) { g in Text(g.label).tag(g) }
            }
            .pickerStyle(.menu).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
```

> The `columns`, `GalleryTile`, `handleTap`, `syncSelectionToEnv`, and the `@State` for `entries`/`dupCounts`/`annotations`/`selectedIds`/`loaded` are unchanged from Stage B.

- [ ] **Step 4: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (No new file; no xcodegen.)

- [ ] **Step 5: Self-review**

Confirm: changing `filter` re-runs `load()` (the `.task(id:)` key includes `filter.rawValue`); the cached count sums `cachedRelPaths` per drive group; grouping is client-side over already-loaded `entries` (no extra queries); section headers pin; `.none` grouping renders a single untitled section; selection + tagging from Stage B still work through the sectioned `ForEach`.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/Views/GalleryView.swift
git commit -m "feat(app): Gallery filter chips + group-by + cached count

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Drive-shelf header (app)

**Files:**
- Modify: `DiskGallery/Views/GalleryView.swift`

**Interfaces:**
- Consumes: `env.volumeSummaries` (`VolumeSummary`: id, name, totalCapacity, freeCapacity, fileCount, uuid), `env.volumes.isConnected(key:)`, `Format.bytes`/`Format.count`, `env.catalog.gallery.items(categories:volumeId:limit:)` (the `volumeId` param from Task 1).
- Produces: a horizontal drive-shelf above the control bar; selecting a card filters the grid to that drive.

- [ ] **Step 1: Add the drive filter state + thread it into `load()`**

In `GalleryView`, add:

```swift
    @State private var driveFilter: Int64?    // selected volume id, nil = all drives
```

Update the `gallery.items` call in `load()` to pass it, and key the reload on it too:

```swift
        let items = (try? await env.catalog.gallery.items(categories: filter.categories, volumeId: driveFilter)) ?? []
```

```swift
        .task(id: "\(env.dataVersion)-\(filter.rawValue)-\(driveFilter ?? -1)") { await load() }
```

- [ ] **Step 2: Add the drive shelf + card view**

Add the shelf above `controlBar` in `body` (place `driveShelf` as the first child of the outer `VStack`, before `controlBar`):

```swift
            driveShelf
            Divider()
```

Add the shelf + card to `GalleryView`:

```swift
    @ViewBuilder private var driveShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                driveCard(title: "All Drives", systemImage: "square.grid.2x2",
                          subtitle: "\(env.volumeSummaries.count) drives",
                          fraction: nil, connected: true, selected: driveFilter == nil) {
                    driveFilter = nil
                }
                ForEach(env.volumeSummaries) { summary in
                    let used = (summary.totalCapacity ?? 0) - (summary.freeCapacity ?? 0)
                    let frac = (summary.totalCapacity ?? 0) > 0 ? Double(used) / Double(summary.totalCapacity!) : nil
                    driveCard(title: summary.name, systemImage: "externaldrive.fill",
                              subtitle: Format.count(summary.fileCount),
                              fraction: frac,
                              connected: env.volumes.isConnected(key: summary.uuid ?? summary.name),
                              selected: driveFilter == summary.id) {
                        driveFilter = (driveFilter == summary.id) ? nil : summary.id
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func driveCard(title: String, systemImage: String, subtitle: String,
                           fraction: Double?, connected: Bool, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage).font(.system(size: 11))
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Circle().fill(connected ? .green : .secondary).frame(width: 6, height: 6)
                }
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1)).controlSize(.mini).frame(width: 110)
                }
            }
            .padding(8)
            .frame(width: 150, alignment: .leading)
            .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? env.theme.accent.palette.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm Core still green**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 173 tests (app-only task; Core unchanged).

- [ ] **Step 5: Self-review**

Confirm: selecting a drive card sets `driveFilter` and re-runs `load()` (the `.task(id:)` includes `driveFilter`); re-tapping the selected card or "All Drives" clears it; the online/offline dot uses `isConnected(key: uuid ?? name)` (the same key as everywhere else); the fill bar handles nil/zero capacity; the shelf renders from already-loaded `volumeSummaries` (no extra queries).

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/Views/GalleryView.swift
git commit -m "feat(app): Gallery drive-shelf header with per-drive filtering

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (plan vs Stage C spec)

**Spec coverage:** media-type filter chips All/Photos/RAW/Video/Docs/Audio (Task 2) ✓; live "N of M cached" count (Task 1 `cachedRelPaths` + Task 2) ✓; group-by shoot/drive/type (Task 2) ✓; drive-shelf header with drive cards (name, online/offline dot, file count, fill bar) that filters to one drive (Task 1 `volumeId` + Task 3) ✓. Audio shows as a glyph tile (no real thumbnail — consistent with the spec's QuickLook-audio caveat); audio is a filter chip but is intentionally NOT added to the Stage-A scan-cache preview picker (QuickLook can't render audio, so generating previews for it is pointless).

**Read-only invariant:** Stage C adds only read queries (`volumeId` filter, `cachedRelPaths`) + UI. No drive writes, no MutationGuard-scanned file touched. ✓

**Placeholder scan:** Task 1 has complete code + 2 real tests. Tasks 2–3 have complete code; gate is build + self-review (no app test target).

**Type consistency:** `GalleryFilter.categories` returns `[FileCategory]` (incl. new `.audio`) consumed by `gallery.items`. `driveFilter: Int64?` → `gallery.items(volumeId:)`. `cachedRelPaths(volumeKey:relPaths:)` keyed by the same `volumeKey` (uuid ?? name) as annotations/thumbnails. Drive cards read `VolumeSummary` fields confirmed present (id, name, totalCapacity, freeCapacity, fileCount, uuid) and `env.volumes.isConnected(key:)`.

**Carry to the end-of-stack final review:** the `.task(id:)` reload key is now a composite string (dataVersion + filter + driveFilter) — re-runs `load()` on any of them; acceptable but re-fetches duplicates each time (the 2000 cap still applies — Stage C surfaces "N of M cached" but not a global "showing N of M"; a hard cap on very large libraries remains). The `cachedRelPaths`/`annotations` `IN (…)` lists rely on macOS 15's high SQLite variable limit (≥32766) — fine at the 2000-row cap.
