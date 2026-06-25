# Classic-Only & Navigation Declutter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Classic the only UI (freeze Modern) and cut the Classic sidebar from 11 non-drive rows to 5 by folding the three Plan surfaces into one Organize home and the five tag-lists into one filtered Tagged view.

**Architecture:** Force `skin = .classic` at the `ThemeStore` source so every shared-view `if modern` check resolves uniformly; remove Modern-only Settings controls. Add one combined-tags query in Core (the only unit-testable change). Build a Classic `OrganizeHomeView` with a `[Plan · By drive]` segmented toggle that hosts the existing Organize plan list and Action-Plan per-drive list (extracted into reusable subviews). Generalize `TaggedListView` into a single filtered list. Rewire the sidebar + router. **No Modern source file is edited.**

**Tech Stack:** Swift 6.0, SwiftUI, macOS 15+, GRDB 7 (via `DiskGalleryCore` only), XCTest.

## Global Constraints

- Platform/lang: macOS deployment target **15.0**, **Swift 6.0** (from `project.yml`).
- **Read-only identity preserved:** no file-mutating APIs on user drives anywhere; `MutationGuardTests` must stay green. None of these tasks touch file I/O.
- **Do NOT edit any file** under `DiskGallery/Views/Modern/`, nor `DiskGallery/Views/OLEDDisplayView.swift`, `DiskGallery/Support/ModernTokens.swift`, `DiskGalleryCore/Licensing/Feature.swift`, or `DiskGalleryCoreTests/FeatureTests.swift`.
- **No new `SidebarItem` enum case** (it would break Modern's no-`default` switch). Use `.tagged(.none)` via the `taggedAll` convenience.
- **Testing reality:** there is **no app-level unit-test target** (only `DiskGalleryCoreTests` for the framework and `DiskGalleryUITests` for XCUITest). App/SwiftUI changes are verified by **build success + manual smoke**, not unit tests. Only Core logic gets a unit test (Task 1).
- **Verification commands** (run from repo root):
  - Build app: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
  - Core tests: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test`
  - Baseline at plan time: build SUCCEEDS, **152/152** Core tests pass.
- **Commit trailer:** end every commit message with
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Branch: `feature/classic-only-declutter` (already created; spec already committed there).

---

## Task 1: Core — combined `taggedEntries(in:)` query

**Files:**
- Modify: `DiskGalleryCore/Annotations/AnnotationStore.swift` (add method ~after line 143; refactor existing `taggedEntries(_:)` at lines 119-143)
- Test: `DiskGalleryCoreTests/AnnotationListTests.swift` (append a test)

**Interfaces:**
- Produces: `public func taggedEntries(in tags: [Tag]) async throws -> [TaggedEntry]` — returns annotated entries whose decision tag is any of `tags`, resolved against each volume's latest snapshot, ordered by volume name then relPath; returns `[]` for an empty `tags`.
- Consumes: existing `TaggedEntry` struct, `AnnotationStore.volumeKey(uuid:name:)`, `Fixture` test helpers.

- [ ] **Step 1: Write the failing test**

Append to `DiskGalleryCoreTests/AnnotationListTests.swift` (inside the `AnnotationListTests` class):

```swift
    func testTaggedEntriesInReturnsOnlyRequestedTags() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volume = try XCTUnwrap(try await catalog.library.volumes().first)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.setDecision(.move, volumeKey: key, relPath: "b.txt")
        try await catalog.annotations.setDecision(.keep, volumeKey: key, relPath: "sub/c.txt")

        let deleteAndMove = try await catalog.annotations.taggedEntries(in: [.delete, .move])
        XCTAssertEqual(Set(deleteAndMove.map(\.relPath)), ["a.txt", "b.txt"])

        let keepOnly = try await catalog.annotations.taggedEntries(in: [.keep])
        XCTAssertEqual(keepOnly.map(\.relPath), ["sub/c.txt"])

        let empty = try await catalog.annotations.taggedEntries(in: [])
        XCTAssertTrue(empty.isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "taggedEntries\(in|error:|Compiling"`
Expected: FAIL — compile error, `value of type 'AnnotationStore' has no member 'taggedEntries(in:)'`.

- [ ] **Step 3: Implement the method and refactor the single-tag one**

In `DiskGalleryCore/Annotations/AnnotationStore.swift`, **replace** the existing `taggedEntries(_:)` (lines 119-143) with the delegating version plus the new multi-tag method:

```swift
    public func taggedEntries(_ tag: Tag) async throws -> [TaggedEntry] {
        try await taggedEntries(in: [tag])
    }

    /// Annotated entries whose decision tag is any of `tags` (for the combined Tagged
    /// list). Same resolution as the single-tag path: joins each volume's latest snapshot
    /// so the row can show the file's current name/size. Empty `tags` → no rows.
    public func taggedEntries(in tags: [Tag]) async throws -> [TaggedEntry] {
        guard !tags.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: tags.count).joined(separator: ",")
        return try await db.writer.read { db in
            try TaggedEntry.fetchAll(db, sql: """
                WITH latest AS (
                    SELECT s.id, s.volumeId FROM snapshot s
                    WHERE s.id = (
                        SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                        ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
                    )
                )
                SELECT a.id AS annotationId, a.volumeUuid AS volumeUuid, v.name AS volumeName,
                       a.relPath AS relPath, a.tag AS tag, a.color AS color, a.note AS note,
                       e.name AS name, e.isDir AS isDir, e.logicalSize AS logicalSize,
                       e.subtreeLogicalSize AS subtreeLogicalSize,
                       e.id AS entryId, e.snapshotId AS snapshotId
                FROM annotation a
                LEFT JOIN volume v
                    ON (v.uuid = a.volumeUuid OR (v.uuid IS NULL AND v.name = a.volumeUuid))
                LEFT JOIN latest l ON l.volumeId = v.id
                LEFT JOIN entry e ON e.snapshotId = l.id AND e.relPath = a.relPath
                WHERE a.tag IN (\(placeholders))
                ORDER BY v.name COLLATE NOCASE, a.relPath COLLATE NOCASE
                """, arguments: StatementArguments(tags.map(\.rawValue)))
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, executed **153** tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Annotations/AnnotationStore.swift DiskGalleryCoreTests/AnnotationListTests.swift
git commit -m "feat(core): combined taggedEntries(in:) query for the unified Tagged view

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Force Classic skin (freeze Modern, part 1)

**Files:**
- Modify: `DiskGallery/App/ThemeStore.swift:30` (the `skin` init line)

**Interfaces:**
- Consumes: `Skin` (Core enum). Produces: `ThemeStore.skin` always `.classic` at launch.

- [ ] **Step 1: Coerce the skin to Classic**

In `DiskGallery/App/ThemeStore.swift`, in `init()`, replace line 30:

```swift
        skin = Skin(rawValue: defaults.string(forKey: "skin") ?? "") ?? .modern
```

with:

```swift
        // Classic is the only shipping skin. Coerce unconditionally so every shared-view
        // `skin == .modern` check resolves to Classic (Modern stays compiled but frozen).
        skin = .classic
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Smoke-check (manual)**

Launch the built app (`open ~/Library/Developer/Xcode/DerivedData/DiskGallery-*/Build/Products/Debug/DiskGallery.app`). Expected: opens in the native Classic three-column layout (no glass/spatial backdrop), regardless of any prior Modern preference.

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/App/ThemeStore.swift
git commit -m "feat(app): force Classic skin; freeze Modern at the source

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Remove Modern-only Settings controls (freeze Modern, part 2)

**Files:**
- Modify: `DiskGallery/Views/SettingsView.swift` — `AppearanceSettings` (remove the "Look"/Skin section lines 104-110 and the "OLED Display" section lines 135-147) and `ShortcutSettings` (remove the "View"/"Toggle side panes" section lines 170-192)

**Interfaces:** none produced/consumed beyond existing `ThemeStore`/`ShortcutStore` (left intact).

- [ ] **Step 1: Remove the Skin picker section**

In `AppearanceSettings.body`, delete the entire `Section("Look") { … }` block (lines 104-110):

```swift
            Section("Look") {
                Picker("Skin", selection: $theme.skin) {
                    ForEach(Skin.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
```

- [ ] **Step 2: Remove the OLED Display section**

In `AppearanceSettings.body`, delete the entire OLED `Section { … } header: { Text("OLED Display") } footer: { … }` block (lines 135-147):

```swift
            Section {
                Picker("Layout", selection: $theme.oledLayout) {
                    ForEach(OLEDLayout.userSelectable) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(theme.skin == .classic)
            } header: {
                Text("OLED Display")
            } footer: {
                Text("The OLED drive display appears in the Modern look.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Remove the "Toggle side panes" shortcut section**

In `ShortcutSettings.body`, delete the entire `Section { HStack { … "Toggle side panes" … } } header: { Text("View") } footer: { … }` block (lines 170-192):

```swift
            Section {
                HStack {
                    Image(systemName: "sidebar.right").foregroundStyle(.secondary).frame(width: 14)
                    Text("Toggle side panes")
                    Spacer()
                    Button("Tab") { env.shortcuts.setPaneToggleToTab() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(env.shortcuts.paneToggleKey == "tab" ? Color.secondary : Color.accentColor)
                    TextField("", text: Binding(
                        get: { env.shortcuts.paneToggleDisplay },
                        set: { newValue in
                            if let ch = newValue.last, ch.isLetter || ch.isNumber {
                                env.shortcuts.setPaneToggleKey(String(ch))
                            }
                        }))
                    .frame(width: 48).multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("View")
            } footer: {
                Text("Collapses the Reclaimable, Action plan and Inspector panes to enlarge the browser (Modern skin). Type a letter to rebind, or click Tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (note: `theme.oledLayout`, `ShortcutStore.paneToggle*` remain defined and used by frozen Modern, so no unused-symbol errors).

- [ ] **Step 5: Smoke-check (manual)**

Open Settings (⌘,). Expected: **Appearance** tab shows only **Mode** and **Accent**; **Shortcuts** tab shows only **Action Tags**, **Finder Colors**, and **Reset to Defaults**. No Skin, OLED, or Toggle-side-panes controls.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/Views/SettingsView.swift
git commit -m "feat(app): drop Modern-only Settings controls (Skin/OLED/pane-toggle)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `SidebarItem.taggedAll` convenience + token migration

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` — `SidebarItem` (add convenience after line 52; edit `init?(token:)` lines 38-39)

**Interfaces:**
- Produces: `static var taggedAll: SidebarItem { .tagged(.none) }`; legacy tokens `"plan"`/`"transfer"` decode to `.organize`.
- Consumes: existing `Tag` (Core), `SidebarItem` enum.

- [ ] **Step 1: Add the `taggedAll` convenience**

In `DiskGallery/App/AppEnvironment.swift`, immediately after the `SidebarItem` enum's closing brace (after line 52), add:

```swift
extension SidebarItem {
    /// The single "Tagged" sidebar destination = all action tags. Encoded as
    /// `.tagged(.none)` so no new enum case is needed (keeps Modern's switch compiling).
    static var taggedAll: SidebarItem { .tagged(.none) }
}
```

- [ ] **Step 2: Migrate legacy `plan`/`transfer` tokens to `.organize`**

In `SidebarItem.init?(token:)`, change lines 38-39 from:

```swift
        case "plan":       self = .plan
        case "transfer":   self = .transfer
```

to:

```swift
        // Merged into Organize — restore old selections onto the Organize home.
        case "plan":       self = .organize
        case "transfer":   self = .organize
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (`.plan`/`.transfer` cases still exist for Modern; only their *token decoding* changed.)

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift
git commit -m "feat(app): SidebarItem.taggedAll convenience + migrate plan/transfer tokens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Unified Tagged list with filter chips

**Files:**
- Modify: `DiskGallery/Views/TaggedListView.swift` (full rewrite of the view)

**Interfaces:**
- Consumes: `AnnotationStore.taggedEntries(in:)` (Task 1), `Tag.actionTags`, `env.tagCounts`, `env.dataVersion`, `TaggedEntry`.
- Produces: `TaggedListView(initialFilter: Tag?)` — `nil`/`.none` opens on "All"; a specific tag opens pre-filtered. Used by the router in Task 7.

- [ ] **Step 1: Rewrite `TaggedListView`**

Replace the entire contents of `DiskGallery/Views/TaggedListView.swift` with:

```swift
import SwiftUI
import DiskGalleryCore

/// Every action-tagged file/folder in one place, with a decision filter.
/// `initialFilter == nil` (or `.none`) shows all action tags; a specific tag pre-filters.
struct TaggedListView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var filter: Tag?            // nil == All
    @State private var entries: [TaggedEntry] = []

    init(initialFilter: Tag? = nil) {
        _filter = State(initialValue: (initialFilter == Tag.none) ? nil : initialFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            List(entries) { entry in row(entry) }
                .overlay { if entries.isEmpty { emptyState } }
        }
        .navigationTitle("Tagged")
        .task(id: reloadKey) { await load() }
    }

    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            Text("All").tag(Tag?.none)
            ForEach(Tag.actionTags) { t in
                Text("\(t.label) (\(env.tagCounts[t] ?? 0))").tag(Tag?.some(t))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(8)
    }

    private func row(_ entry: TaggedEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir == true ? "folder.fill" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).lineLimit(1)
                Text("\(entry.volumeName ?? entry.volumeUuid) · \(entry.relPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.caption2).italic().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: entry.tag.symbol).foregroundStyle(entry.tag.swiftUIColor)
                .help(entry.tag.label)
            if let size = entry.displaySize {
                Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView("Nothing tagged",
                               systemImage: "tag",
                               description: Text("Select files or folders while browsing a drive and mark them Keep, Delete, Review, Move, or Backup — they collect here."))
    }

    private var reloadKey: String { "\(filter?.rawValue ?? -1)-\(env.dataVersion)" }

    private func load() async {
        let tags = filter.map { [$0] } ?? Tag.actionTags
        entries = (try? await env.catalog.annotations.taggedEntries(in: tags)) ?? []
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (Note: the old `TaggedListView(tag:)` call site in Classic `ContentColumn` is updated in Task 7; until then it still references `tag:` — so **build this task together with Task 7 if executing inline**, or accept that Step 1's compile is verified as part of Task 7. If executing strictly one task at a time, temporarily keep an `init(tag: Tag)` shim — but the cleaner path is to run Tasks 5+7 back-to-back.)

> **Sequencing note:** `TaggedListView` is constructed in two places — Classic `ContentColumn` (`DiskGalleryApp.swift:236-237`, updated in Task 7) and Modern's `ModernWorkspace` does **not** use it (it uses `ModernActionPlanPage`). So the only caller to update is the Classic router. Execute Task 5 and Task 7 as a pair; the build gate for Task 5 is satisfied at the end of Task 7.

- [ ] **Step 3: Commit**

```bash
git add DiskGallery/Views/TaggedListView.swift
git commit -m "feat(app): unified Tagged list with decision filter chips

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Organize home with `[Plan · By drive]` toggle

**Files:**
- Modify: `DiskGallery/Views/OrganizeView.swift` (extract the list into `OrganizePlanList`; add `OrganizeHomeView`; keep `OrganizeStepRow`)
- Modify: `DiskGallery/Views/ActionPlanView.swift` (extract its content into `OrganizeByDriveList`; keep `DrivePlanRow`)

**Interfaces:**
- Produces: `OrganizeHomeView()` (the Classic `.organize` route — owns title, the toggle, and the export toolbar); `OrganizePlanList(plan:loaded:)`; `OrganizeByDriveList()`.
- Consumes: `env.organizationPlan() -> OrganizationPlan`, `env.exportOrganizationReport(_:)`, `env.copyOrganizationReport(_:)`, `env.catalog.planning.driveStats()`, existing `OrganizeStepRow`, `DrivePlanRow`, `StatPill`, `DriveStats`.

- [ ] **Step 1: Extract the per-drive list in `ActionPlanView.swift`**

In `DiskGallery/Views/ActionPlanView.swift`, rename the `ActionPlanView` struct to **`OrganizeByDriveList`** and **remove** its `.navigationTitle("Action Plan")` (the parent `OrganizeHomeView` owns the title). Keep everything else (the `header` pills, the `List` of `DrivePlanRow`, `load()`, the `planned`/`total`/`drivesToConnect` helpers, and the `DrivePlanRow` struct) unchanged. The result's `body` is:

```swift
struct OrganizeByDriveList: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stats: [DriveStats] = []

    private var modern: Bool { env.theme.skin == .modern }

    private var planned: [DriveStats] {
        stats.filter(\.hasPending).sorted { lhs, rhs in
            if lhs.pendingCount != rhs.pendingCount { return lhs.pendingCount > rhs.pendingCount }
            return lhs.deleteBytes > rhs.deleteBytes
        }
    }

    private func total(for tag: Tag) -> Int64 { stats.reduce(0) { $0 + $1.bytes(for: tag) } }
    private var drivesToConnect: Int {
        planned.filter { !env.volumes.isConnected(key: $0.volumeKey) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if planned.isEmpty {
                ContentUnavailableView("Nothing tagged yet",
                                       systemImage: "checklist",
                                       description: Text("Mark files or folders Keep, Delete, or Review while browsing a drive — they’ll be collected here into a plan."))
            } else {
                List {
                    Section("Plug in these drives, in this order") {
                        ForEach(Array(planned.enumerated()), id: \.element.id) { index, drive in
                            DrivePlanRow(order: index + 1, drive: drive)
                        }
                    }
                }
                .modernListChrome(modern)
            }
        }
        .task(id: env.dataVersion) { await load() }
    }

    private var header: some View {
        let pills = HStack(spacing: 10) {
            ForEach([Tag.move, .backup, .keep, .delete]) { tag in
                StatPill(title: "To \(tag.label.lowercased())", value: Format.bytes(total(for: tag)),
                         tint: tag.swiftUIColor)
            }
            StatPill(title: "Drives to connect", value: "\(drivesToConnect)", tint: env.theme.accent.palette.accent)
        }
        .padding(12)
        return Group {
            if modern { pills.glassCard(radius: 14).padding(.horizontal, 12) } else { pills }
        }
    }

    private func load() async {
        stats = (try? await env.catalog.planning.driveStats()) ?? []
    }
}
```

Leave the existing `private struct DrivePlanRow: View { … }` (lines 71-128) untouched below it.

- [ ] **Step 2: Extract the plan list + add the home in `OrganizeView.swift`**

In `DiskGallery/Views/OrganizeView.swift`, rename `OrganizeView` → **`OrganizePlanList`**, make `plan`/`loaded` **inputs** (not `@State`/`@task`), and remove its `.navigationTitle`/`.toolbar`/`.task` (the home owns them). Then add the new `OrganizeHomeView` above it. Keep `OrganizeStepRow` (lines 81-151) unchanged.

Replace lines 1-79 of `OrganizeView.swift` with:

```swift
import SwiftUI
import DiskGalleryCore

/// Classic Organize home: the cross-drive plan, with a [Plan · By drive] toggle.
/// `Plan` = the auto run-order list; `By drive` = pending decisions grouped per drive.
struct OrganizeHomeView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case plan = "Plan", byDrive = "By drive"
        var id: String { rawValue }
    }

    @Environment(AppEnvironment.self) private var env
    @State private var mode: Mode = .plan
    @State private var plan: OrganizationPlan = .empty
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch mode {
            case .plan:    OrganizePlanList(plan: plan, loaded: loaded)
            case .byDrive: OrganizeByDriveList()
            }
        }
        .navigationTitle("Organize")
        .toolbar {
            if mode == .plan {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Export Plan…") { env.exportOrganizationReport(plan) }
                        Button("Copy Plan") { env.copyOrganizationReport(plan) }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(plan.steps.isEmpty)
                }
            }
        }
        .task(id: env.dataVersion) {
            plan = await env.organizationPlan()
            loaded = true
        }
    }
}

/// The numbered run-order plan list (formerly `OrganizeView`'s body).
struct OrganizePlanList: View {
    let plan: OrganizationPlan
    let loaded: Bool

    var body: some View {
        Group {
            if loaded && plan.steps.isEmpty {
                ContentUnavailableView(
                    "Nothing to organize",
                    systemImage: "wand.and.stars",
                    description: Text("Tag items Move, Backup, or Delete across your drives and a step-by-step transfer plan appears here."))
            } else {
                List {
                    Section { summary } header: { Text("Plan") }
                    Section {
                        ForEach(plan.steps) { OrganizeStepRow(step: $0) }
                    } header: { Text("Run order") }
                    if !plan.unassigned.isEmpty {
                        Section {
                            ForEach(plan.unassigned) { item in
                                Label("\(item.name) — \(Format.bytes(item.bytes)) won’t fit anywhere",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        } header: { Text("Couldn’t place — free space or add a drive") }
                    }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                stat("To move", Format.bytes(plan.totalBytesToMove))
                stat("To back up", Format.bytes(plan.totalBytesToCopy))
                stat("Frees", Format.bytes(plan.totalBytesToFree))
                if plan.estTotalDuration > 0 { stat("Est. time", Format.duration(plan.estTotalDuration)) }
            }
            if !plan.drivesToConnect.isEmpty {
                Label("Connect to run: \(plan.drivesToConnect.joined(separator: ", "))", systemImage: "powerplug")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("Non-destructive — DiskGallery never moves files. This is your playbook.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

(Leave `private struct OrganizeStepRow: View { … }` at the bottom of the file unchanged.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: FAIL — Classic `ContentColumn` still references `OrganizeView()` and `ActionPlanView()` (renamed). This is expected; the router is fixed in Task 7. If executing inline, proceed to Task 7 before re-running the build. (Strict one-task-at-a-time runners should execute Tasks 6+7 as a pair.)

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/Views/OrganizeView.swift DiskGallery/Views/ActionPlanView.swift
git commit -m "feat(app): OrganizeHomeView with Plan / By-drive toggle (extract list views)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Rewire the sidebar and router (the declutter)

**Files:**
- Modify: `DiskGallery/Views/LibrarySidebarView.swift` (sidebar sections, lines 31-68)
- Modify: `DiskGallery/App/DiskGalleryApp.swift` (`ContentColumn`, lines 226-254)

**Interfaces:**
- Consumes: `SidebarItem.taggedAll` (Task 4), `TaggedListView(initialFilter:)` (Task 5), `OrganizeHomeView()` (Task 6), `env.tagCounts`, `Tag.actionTags`.

- [ ] **Step 1: Collapse the sidebar's Library + Plan + Action-Tags sections**

In `DiskGallery/Views/LibrarySidebarView.swift`, replace the three `Section` blocks spanning lines 31-68 (the `Library` section, the `Plan` section, and the `Action Tags` section) with:

```swift
            Section {
                Label("Duplicates", systemImage: "doc.on.doc")
                    .badge(env.totalReclaimable > 0 ? Text(Format.bytes(env.totalReclaimable)) : nil)
                    .tag(SidebarItem.duplicates)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Tagged", systemImage: "tag")
                    .badge(plannedItemCount)
                    .tag(SidebarItem.taggedAll)
            } header: { sectionHeader("Library") }

            Section {
                Label("Organize", systemImage: "wand.and.stars")
                    .badge(organizeItemCount)
                    .tag(SidebarItem.organize)
            } header: { sectionHeader("Plan") }
```

(`plannedItemCount` and `organizeItemCount` already exist at lines 117-123. The Modern-only `.modernRowTint`/`.listRowBackground` modifiers are dropped here since `modern` is always false now; leaving them would be harmless no-ops, but removing keeps Classic rows clean.)

- [ ] **Step 2: Update the Classic router**

In `DiskGallery/App/DiskGalleryApp.swift`, in `ContentColumn.body`, replace the `.tagged`, `.plan`, `.transfer`, and `.organize` cases (lines 236-245) with:

```swift
        case .tagged(let tag):
            TaggedListView(initialFilter: tag == .none ? nil : tag)
        case .plan, .transfer:
            OrganizeHomeView()        // merged into Organize; kept for Modern compatibility
        case .organize:
            OrganizeHomeView()
```

- [ ] **Step 3: Build to verify everything compiles (closes Tasks 5, 6, 7)**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Smoke-check (manual)**

Launch the app. Expected sidebar (top to bottom): **All Drives**, **Library** {Duplicates, Search, Tagged}, **Plan** {Organize}, then your drive groups. Click **Organize** → segmented **[Plan · By drive]** toggles between the run-order plan and the per-drive rollup; **Export** appears only in Plan mode. Click **Tagged** → segmented **All / Keep / Move / Backup / Review / Delete** filter; "All" lists every action-tagged item.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/LibrarySidebarView.swift DiskGallery/App/DiskGalleryApp.swift
git commit -m "feat(app): declutter sidebar to 5 rows; route Organize home + unified Tagged

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Full regression + smoke close-out

**Files:** none (verification only).

- [ ] **Step 1: Full app build**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Full Core test suite (incl. read-only guard)**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -6`
Expected: `** TEST SUCCEEDED **`, **153** tests, 0 failures (152 baseline + Task 1). Confirm `MutationGuardTests` is among the passing suites.

- [ ] **Step 3: Manual smoke checklist**

Launch the app and confirm:
- Opens in Classic (no glass/backdrop), even if Modern was previously selected.
- Settings: Appearance = Mode + Accent only; Shortcuts = Action Tags + Finder Colors + Reset only.
- Sidebar = All Drives · Library{Duplicates, Search, Tagged} · Plan{Organize} · Drives.
- Organize [Plan · By drive] toggle works; Export only in Plan mode.
- Tagged filter chips work; counts match the previous per-tag sidebar badges.
- Existing drive browsing, Duplicates, Search, All Drives, tagging, drive roles all still work.

- [ ] **Step 4: Final commit (if any smoke fixes were needed; otherwise skip)**

```bash
git add -A
git commit -m "chore(app): close out Classic-only + nav declutter milestone

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Part 1 (freeze Modern): Task 2 (force Classic) + Task 3 (remove Settings controls). ✓
- Part 2 (declutter): Task 4 (`taggedAll` + token migration) + Task 5 (Tagged list) + Task 6 (Organize home) + Task 7 (sidebar + router). ✓ Transfer Planner dropped (Task 7 removes its row/route; file left orphaned per spec). ✓
- Part 3 (stabilize): Task 1 (new Core test) + every task's build gate + Task 8 (full regression + smoke). ✓
- Core all-tags query (spec §2.3): Task 1. ✓
- `.tagged(.none)` encoding honoring the freeze (spec §2.3 refinement): Task 4. ✓
- Non-goals respected: no Modern source edited; `Feature.transfer`/`FeatureTests` untouched; `TransferPlannerView.swift` left in tree; no file mutation. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. The two "build fails as expected until Task 7" notes (Tasks 5, 6) are explicit sequencing facts, not placeholders. ✓

**Type consistency:** `taggedEntries(in:)` signature matches Task 1 → Task 5 usage. `OrganizeHomeView`/`OrganizePlanList(plan:loaded:)`/`OrganizeByDriveList` defined in Task 6 match Task 7 usage. `TaggedListView(initialFilter:)` defined in Task 5 matches Task 7 usage. `SidebarItem.taggedAll` defined in Task 4 matches Tasks 5/7 usage. ✓

**Known coupling:** Tasks 5–7 form one compile unit (renames + router). A strict one-task-at-a-time runner should treat 5→6→7 as a back-to-back group; the first green app build lands at the end of Task 7. Task 1, 2, 3, 4 are each independently green.
