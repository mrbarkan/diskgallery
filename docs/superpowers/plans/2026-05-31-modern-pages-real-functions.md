# Modern Pages — Real Functions (Launch Slice) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on four non-destructive Modern-page features for launch — Duplicates file-type filter chips (§1), Duplicates keep-rule engine (§2), Action Plan Finder-tag sync (§3), Search persistence + saved searches (§5) — and make the deferred Transfer engine (§4) honest.

**Architecture:** Real logic (file categories, keep-rule, search filters) lands in `DiskGalleryCore` behind small, unit-tested types; the SwiftUI Modern pages wire those types into already-rendered controls. The app stays read-only except for the existing `FinderTagWriter` writes. No visual redesign.

**Tech Stack:** Swift 6, SwiftUI, GRDB (encapsulated behind `Catalog`), XCTest. Tests run under the `DiskGalleryCore` scheme against a temp SQLite DB via the `Fixture` helper.

**Spec:** `docs/superpowers/specs/2026-05-31-modern-pages-real-functions-design.md`

**Conventions used throughout:**
- Core unit test command:
  `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/<Class>/<method> 2>&1 | tail -25`
- App build command (for view-wiring tasks with no unit test):
  `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20` → expect `** BUILD SUCCEEDED **`
- The `Fixture` (in `DiskGalleryCoreTests/Support.swift`) builds a temp drive tree and scans it. `Fixture.writeFile(root, relPath, bytes:)` creates arbitrary files; `Fixture.scan(catalog, root)` returns the snapshot id.

---

## File Structure

**Create:**
- `DiskGalleryCore/Data/FileCategory.swift` — extension→category grouping (§1, §5).
- `DiskGalleryCore/Duplicates/KeepRule.swift` — pure keep-rule selection (§2).
- `DiskGallery/App/RecentSearchStore.swift` — UserDefaults-backed recent searches (§5).
- `DiskGalleryCoreTests/FileCategoryTests.swift`
- `DiskGalleryCoreTests/KeepRuleTests.swift`
- `DiskGalleryCoreTests/AnnotationListTests.swift` (covers `AnnotationStore.all()`)

**Modify:**
- `DiskGalleryCore/Annotations/AnnotationStore.swift` — add `all()`.
- `DiskGalleryCore/Search/SearchService.swift` — add `SearchFilter` + filtered/empty-query search.
- `DiskGalleryCoreTests/SearchTests.swift` — filter tests.
- `DiskGallery/App/AppEnvironment.swift` — add `syncFinderTags()` + hold `RecentSearchStore`.
- `DiskGallery/Views/Modern/ModernControls.swift` — add a `disabled` flag to `CTAButton`.
- `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` — §1 + §2 wiring.
- `DiskGallery/Views/Modern/ModernActionPlanPage.swift` — §3 wiring.
- `DiskGallery/Views/Modern/ModernSearchPage.swift` — §5 wiring.
- `DiskGallery/Views/Modern/ModernTransferPage.swift` — §4 polish.
- `docs/superpowers/plans/future-modern-pages-real-functions.md` — mark shipped items.

**IMPORTANT — Xcode project membership:** New `.swift` files must be added to the right target. `DiskGalleryCore/**` → **DiskGalleryCore** target; `DiskGalleryCoreTests/**` → **DiskGalleryCoreTests** target; `DiskGallery/**` → **DiskGallery** target. This project has no "synchronized folder" auto-membership — add each new file to its target in Xcode (or via the pbxproj) or the build won't see it. Verify with the build/test command at the end of each task; a "cannot find type" error usually means a missing target membership.

---

## Task 1: `FileCategory` (shared foundation for §1 and §5)

**Files:**
- Create: `DiskGalleryCore/Data/FileCategory.swift`
- Test: `DiskGalleryCoreTests/FileCategoryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/FileCategoryTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class FileCategoryTests: XCTestCase {

    func testExtensionMapping() {
        XCTAssertEqual(FileCategory.category(forExtension: "CR2"), .raw)
        XCTAssertEqual(FileCategory.category(forExtension: "jpeg"), .photos)
        XCTAssertEqual(FileCategory.category(forExtension: "MOV"), .video)
        XCTAssertEqual(FileCategory.category(forExtension: "pdf"), .documents)
    }

    func testUnknownAndEmptyExtensionAreAll() {
        XCTAssertEqual(FileCategory.category(forExtension: "xyz"), .all)
        XCTAssertEqual(FileCategory.category(forExtension: ""), .all)
    }

    func testMatchesFilename() {
        XCTAssertTrue(FileCategory.raw.matches(filename: "IMG_0001.NEF"))
        XCTAssertFalse(FileCategory.raw.matches(filename: "IMG_0001.jpg"))
        XCTAssertTrue(FileCategory.photos.matches(filename: "pic.heic"))
        // .all matches everything, including extensionless files.
        XCTAssertTrue(FileCategory.all.matches(filename: "README"))
        XCTAssertTrue(FileCategory.all.matches(filename: "movie.mov"))
        // A specific category never matches an unknown/extensionless file.
        XCTAssertFalse(FileCategory.documents.matches(filename: "README"))
    }

    func testLabels() {
        XCTAssertEqual(FileCategory.allCases.map(\.label),
                       ["All", "Photos", "Video", "RAW", "Documents"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/FileCategoryTests 2>&1 | tail -25`
Expected: FAIL — `cannot find 'FileCategory' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `DiskGalleryCore/Data/FileCategory.swift`:

```swift
import Foundation

/// Coarse file-type grouping by extension, used by the Duplicates filter chips and the
/// Search "Photos · RAW" saved search. `.all` is the catch-all: it matches every file,
/// and any unmatched/extensionless file maps to `.all`.
public enum FileCategory: String, CaseIterable, Sendable {
    case all, photos, video, raw, documents

    public var label: String {
        switch self {
        case .all:       return "All"
        case .photos:    return "Photos"
        case .video:     return "Video"
        case .raw:       return "RAW"
        case .documents: return "Documents"
        }
    }

    /// Extensions owned by each specific category (lowercased, no dot). `.all` owns none —
    /// it is the universal matcher.
    private static let extensions: [FileCategory: Set<String>] = [
        .raw:       ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "srw"],
        .photos:    ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp"],
        .video:     ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "prores"],
        .documents: ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers", "xlsx", "csv"],
    ]

    /// The category a bare extension belongs to (`.all` when unmatched or empty).
    public static func category(forExtension ext: String) -> FileCategory {
        let key = ext.lowercased()
        guard !key.isEmpty else { return .all }
        for (category, set) in extensions where set.contains(key) { return category }
        return .all
    }

    /// Whether a filename belongs to this category. `.all` matches everything.
    public func matches(filename: String) -> Bool {
        if self == .all { return true }
        let ext = (filename as NSString).pathExtension
        return Self.category(forExtension: ext) == self
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/FileCategoryTests 2>&1 | tail -25`
Expected: PASS (all 4 tests). If you get "cannot find 'FileCategory'", the new file is missing its target membership — add `FileCategory.swift` to the **DiskGalleryCore** target and re-run.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Data/FileCategory.swift DiskGalleryCoreTests/FileCategoryTests.swift DiskGallery.xcodeproj/project.pbxproj
git commit -m "feat(core): FileCategory extension grouping for filters"
```

---

## Task 2: §1 — Duplicates file-type filter chips actually filter

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` (`DupSetsCard`, lines ~76–127)

No unit test (SwiftUI view wiring); verified by build + manual smoke. The logic it leans on (`FileCategory`) is already tested in Task 1.

- [ ] **Step 1: Filter the list and header by category**

In `DupSetsCard`, replace the `chips` constant and the `body`'s header + list so they derive from a filtered set. Change:

```swift
    private var accent: Color { env.theme.accent.palette.accent }
    private let chips = ["All", "Photos", "Video", "RAW", "Documents"]
```

to:

```swift
    private var accent: Color { env.theme.accent.palette.accent }
    private let chips = FileCategory.allCases

    /// Sets narrowed to the selected file-type chip (`.all` → everything).
    private var visibleSets: [DuplicateSet] {
        let category = FileCategory(rawValue: filter) ?? .all
        return sets.filter { category.matches(filename: $0.name) }
    }
    private var visibleReclaimable: Int64 { visibleSets.reduce(0) { $0 + $1.reclaimable } }
```

Then update the header meta and the chip row and the `List` to use `visibleSets`. Replace the header + chips block:

```swift
                ModernCardHeader(systemImage: "square.on.square", title: "Duplicate Sets",
                                 meta: "\(Format.count(sets.count)) sets · \(Format.bytes(totalReclaimable))",
                                 accent: accent)
                HStack(spacing: 7) {
                    ForEach(chips, id: \.self) { c in
                        ModernFilterChip(label: c, selected: filter == c) { filter = c }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
```

with:

```swift
                ModernCardHeader(systemImage: "square.on.square", title: "Duplicate Sets",
                                 meta: "\(Format.count(visibleSets.count)) sets · \(Format.bytes(visibleReclaimable))",
                                 accent: accent)
                HStack(spacing: 7) {
                    ForEach(chips, id: \.self) { c in
                        ModernFilterChip(label: c.label, selected: filter == c.rawValue) { filter = c.rawValue }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
```

And in the `List`, change `ForEach(sets)` to `ForEach(visibleSets)` and the empty check `if sets.isEmpty` to `if visibleSets.isEmpty`.

- [ ] **Step 2: Update the page's default filter to the enum raw value**

In `ModernDuplicatesPage` the state is `@State private var filter: String = "All"`. `FileCategory.all.rawValue == "all"`, so the chip's `selected` check (`filter == c.rawValue`) would not match the initial `"All"`. Change the default:

```swift
    @State private var filter: String = "All"
```

to:

```swift
    @State private var filter: String = FileCategory.all.rawValue
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Manual smoke (note for the executor)**

Launch the app, open Duplicates. Selecting **Photos / Video / RAW / Documents** narrows the list; the header "N sets · X" reflects the filtered subset; **All** restores everything. (If no real duplicates exist, this can be confirmed visually once data is present — the build + tested `FileCategory` are the gating checks.)

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/Views/Modern/ModernDuplicatesPage.swift
git commit -m "feat(modern): Duplicates file-type filter chips filter the list (§1)"
```

---

## Task 3: `KeepRule` (pure keep-selection logic for §2)

**Files:**
- Create: `DiskGalleryCore/Duplicates/KeepRule.swift`
- Test: `DiskGalleryCoreTests/KeepRuleTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/KeepRuleTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class KeepRuleTests: XCTestCase {

    private func member(_ id: Int64, vol: String, modified: Date?) -> DuplicateMember {
        DuplicateMember(entryId: id, snapshotId: 1, relPath: "f.raw", contentHash: nil,
                        modifiedAt: modified, volumeId: id, volumeUuid: vol, volumeName: vol)
    }

    func testNewestKeepsLatestModified() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 9_000)
        let members = [member(1, vol: "A", modified: old), member(2, vol: "B", modified: new)]
        XCTAssertEqual(keptMemberID(members: members, rule: .newest, capacities: [:]), 2)
    }

    func testNewestTreatsNilDateAsOldest() {
        let some = Date(timeIntervalSince1970: 5_000)
        let members = [member(1, vol: "A", modified: nil), member(2, vol: "B", modified: some)]
        XCTAssertEqual(keptMemberID(members: members, rule: .newest, capacities: [:]), 2)
    }

    func testLargestDriveKeepsBiggestCapacity() {
        let members = [member(1, vol: "Small", modified: nil), member(2, vol: "Big", modified: nil)]
        let caps: [String: Int64] = ["Small": 500, "Big": 2_000]
        XCTAssertEqual(keptMemberID(members: members, rule: .largestDrive, capacities: caps), 2)
    }

    func testFastestDriveFallsBackToLargestDrive() {
        let members = [member(1, vol: "Small", modified: nil), member(2, vol: "Big", modified: nil)]
        let caps: [String: Int64] = ["Small": 500, "Big": 2_000]
        XCTAssertEqual(keptMemberID(members: members, rule: .fastestDrive, capacities: caps), 2)
    }

    func testStableTieBreakKeepsFirst() {
        // Equal capacities and nil dates → keep the first member (current order).
        let members = [member(1, vol: "A", modified: nil), member(2, vol: "B", modified: nil)]
        XCTAssertEqual(keptMemberID(members: members, rule: .largestDrive,
                                    capacities: ["A": 100, "B": 100]), 1)
    }

    func testEmptyMembersReturnsNil() {
        XCTAssertNil(keptMemberID(members: [], rule: .newest, capacities: [:]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/KeepRuleTests 2>&1 | tail -25`
Expected: FAIL — `cannot find 'keptMemberID' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `DiskGalleryCore/Duplicates/KeepRule.swift`:

```swift
import Foundation

/// How the Duplicates resolver chooses which copy to KEEP (the rest get tagged Delete).
public enum KeepRule: String, CaseIterable, Sendable {
    case fastestDrive, newest, largestDrive

    public var label: String {
        switch self {
        case .fastestDrive: return "Fastest drive"
        case .newest:       return "Newest"
        case .largestDrive: return "Largest drive"
        }
    }
}

/// Picks the member to keep. `capacities` maps a member's volume key
/// (`volumeUuid ?? volumeName`) to that drive's total capacity in bytes.
///
/// - `.newest`       → greatest `modifiedAt` (a `nil` date sorts oldest).
/// - `.largestDrive` → greatest capacity (a missing capacity sorts smallest).
/// - `.fastestDrive` → no drive-speed signal exists yet, so it maps to `.largestDrive`.
///
/// Ties fall back to the members' current order (first wins), so results are deterministic.
/// Returns `nil` for an empty list.
public func keptMemberID(members: [DuplicateMember],
                         rule: KeepRule,
                         capacities: [String: Int64]) -> Int64? {
    guard !members.isEmpty else { return nil }

    func capacity(_ m: DuplicateMember) -> Int64 {
        capacities[m.volumeUuid ?? m.volumeName] ?? 0
    }

    let kept: DuplicateMember?
    switch rule {
    case .newest:
        // Keep the max by date; nil dates are oldest. `max(by:)` keeps the first on ties.
        kept = members.max { lhs, rhs in
            (lhs.modifiedAt ?? .distantPast) < (rhs.modifiedAt ?? .distantPast)
        }
    case .largestDrive, .fastestDrive:
        kept = members.max { lhs, rhs in capacity(lhs) < capacity(rhs) }
    }
    return kept?.entryId
}
```

Note: `Array.max(by:)` returns the **last** maximal element, not the first. To honor the "first wins on ties" contract, the implementation above is wrong for ties — fix it by scanning manually:

```swift
    var best = members[0]
    for m in members.dropFirst() {
        let better: Bool
        switch rule {
        case .newest:
            better = (m.modifiedAt ?? .distantPast) > (best.modifiedAt ?? .distantPast)
        case .largestDrive, .fastestDrive:
            better = capacity(m) > capacity(best)
        }
        if better { best = m }
    }
    return best.entryId
```

Use this manual scan as the body (replace the `switch`/`max` block). `>` (strict) means an equal contender does **not** replace the earlier one — first wins on ties.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/KeepRuleTests 2>&1 | tail -25`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Duplicates/KeepRule.swift DiskGalleryCoreTests/KeepRuleTests.swift DiskGallery.xcodeproj/project.pbxproj
git commit -m "feat(core): KeepRule selects which duplicate copy to keep (§2)"
```

---

## Task 4: §2 — Wire the keep-rule into the Duplicates page

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` (`ModernDuplicatesPage`, `ResolveSetCard`)

No unit test (view wiring); `KeepRule` is tested in Task 3. Verified by build.

- [ ] **Step 1: Load drive capacities and compute the kept member**

In `ModernDuplicatesPage`, add capacity state next to the others:

```swift
    @State private var keepRule: String = "Fastest drive"
```

becomes:

```swift
    @State private var keepRule: String = KeepRule.fastestDrive.label
    @State private var capacities: [String: Int64] = [:]
```

Add a computed kept-id and rule:

```swift
    private var rule: KeepRule { KeepRule.allCases.first { $0.label == keepRule } ?? .fastestDrive }
    private var keptID: Int64? { keptMemberID(members: members, rule: rule, capacities: capacities) }
```

In `loadSets()`, after `sets = ...`, populate capacities (driveStats is already used elsewhere):

```swift
    private func loadSets() async {
        sets = (try? await env.catalog.duplicates.duplicateSets()) ?? []
        let stats = (try? await env.catalog.planning.driveStats()) ?? []
        capacities = Dictionary(stats.map { ($0.volumeKey, $0.totalCapacity ?? 0) },
                                uniquingKeysWith: { first, _ in first })
        if selectedSetID == nil || !sets.contains(where: { $0.id == selectedSetID }) {
            selectedSetID = sets.first?.id
        }
        await loadMembers()
    }
```

- [ ] **Step 2: Tag everything except the kept member**

Replace `deleteRedundant()`, `autoResolveAll()`, and `tagRedundant(_:)`:

```swift
    /// Keep-rule (this sprint): keep the first sorted copy, tag the rest Delete.
    private func deleteRedundant() async {
        guard members.count > 1 else { return }
        await tagRedundant(members)
    }

    private func autoResolveAll() async {
        for s in sets {
            let ms = (try? await env.catalog.duplicates.members(name: s.name, logicalSize: s.logicalSize)) ?? []
            await tagRedundant(ms)
        }
    }

    private func tagRedundant(_ ms: [DuplicateMember]) async {
        guard ms.count > 1 else { return }
        var entries: [Entry] = []
        for m in ms.dropFirst() {
            if let e = try? await env.catalog.library.entry(id: m.entryId) { entries.append(e) }
        }
        if !entries.isEmpty { await env.applyDecision(.delete, to: entries) }
    }
```

with:

```swift
    /// Tags every copy except the keep-rule's chosen one as Delete (the current set).
    private func deleteRedundant() async {
        guard members.count > 1 else { return }
        await tagRedundant(members, keepID: keptID)
    }

    /// Applies the keep-rule across every set, recomputing the kept copy per set.
    private func autoResolveAll() async {
        for s in sets {
            let ms = (try? await env.catalog.duplicates.members(name: s.name, logicalSize: s.logicalSize)) ?? []
            let keep = keptMemberID(members: ms, rule: rule, capacities: capacities)
            await tagRedundant(ms, keepID: keep)
        }
    }

    /// Tags everything except `keepID` as Delete. Never touches files (catalog + Finder tags only).
    private func tagRedundant(_ ms: [DuplicateMember], keepID: Int64?) async {
        guard ms.count > 1 else { return }
        var entries: [Entry] = []
        for m in ms where m.entryId != keepID {
            if let e = try? await env.catalog.library.entry(id: m.entryId) { entries.append(e) }
        }
        if !entries.isEmpty { await env.applyDecision(.delete, to: entries) }
    }
```

- [ ] **Step 3: Pass the kept id into `ResolveSetCard` and mark the right KEEP badge**

In `body`, the `ResolveSetCard(...)` call: add `keptID: keptID`:

```swift
                ResolveSetCard(set: selectedSet, members: members, keepRule: $keepRule, keptID: keptID,
                               onDelete: { Task { await deleteRedundant() } },
                               onVerify: { if let s = selectedSet { Task { await env.verify(set: s); await loadMembers() } } })
```

In `ResolveSetCard`, add the property and use it. Add after `@Binding var keepRule: String`:

```swift
    let keptID: Int64?
```

In `copiesSection`, change the `CopyRow` keep flag from `idx == 0` to the kept id:

```swift
                ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                    CopyRow(drive: m.volumeName, path: m.relPath, keep: m.entryId == keptID)
                }
```

In `keepRuleSection`, replace the hard-coded rules array and add the "Fastest" note. Change:

```swift
    private let rules = ["Fastest drive", "Newest", "Largest drive"]
```

to:

```swift
    private let rules = KeepRule.allCases.map(\.label)
```

and replace `keepRuleSection` with:

```swift
    private var keepRuleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SecHeader(title: "Keep rule")
            HStack(spacing: 7) {
                ForEach(rules, id: \.self) { r in
                    ModernFilterChip(label: r, selected: keepRule == r) { keepRule = r }
                }
                Spacer(minLength: 0)
            }
            if keepRule == KeepRule.fastestDrive.label {
                ModernNote(text: "No drive-speed data yet — keeping the copy on the largest drive.",
                           systemImage: "info.circle")
            }
        }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual smoke (note for the executor)**

Open Duplicates, select a set with copies on different drives. Switching **Newest / Largest drive / Fastest drive** moves the green **KEEP** badge to the matching copy; "Delete N" tags the others (verify in Action Plan / Finder). Fastest shows the info note.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/Views/Modern/ModernDuplicatesPage.swift
git commit -m "feat(modern): Duplicates keep-rule engine drives KEEP badge + tagging (§2)"
```

---

## Task 5: `AnnotationStore.all()` (for §3 sync)

**Files:**
- Modify: `DiskGalleryCore/Annotations/AnnotationStore.swift`
- Test: `DiskGalleryCoreTests/AnnotationListTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/AnnotationListTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class AnnotationListTests: XCTestCase {

    func testAllReturnsEveryAnnotationIncludingColorOnly() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volume = try XCTUnwrap(try await catalog.library.volumes().first)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        // One decision tag, one color-only annotation.
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.setColor(.red, volumeKey: key, relPath: "b.txt")

        let all = try await catalog.annotations.all()
        XCTAssertEqual(all.count, 2)
        let byPath = Dictionary(uniqueKeysWithValues: all.map { ($0.relPath, $0) })
        XCTAssertEqual(byPath["a.txt"]?.tag, .delete)
        XCTAssertEqual(byPath["b.txt"]?.color, .red)
        XCTAssertEqual(byPath["b.txt"]?.tag, FinderColorOnlyTagExpectation.none)
    }
}

// Local alias to make the `.none` expectation explicit and readable.
private enum FinderColorOnlyTagExpectation { static let none: Tag = .none }
```

(If `FinderColor.red` is not a valid case, run `grep -n "case " DiskGalleryCore/Data/Models.swift` to find a real color case — e.g. `.gray`/`.green` — and substitute. The test only needs any non-`.none` color.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/AnnotationListTests 2>&1 | tail -25`
Expected: FAIL — `value of type 'AnnotationStore' has no member 'all'`.

- [ ] **Step 3: Write minimal implementation**

In `DiskGalleryCore/Annotations/AnnotationStore.swift`, add to the `// MARK: Lists & counts` section (after `taggedEntries`):

```swift
    /// Every annotation row (decision tags and color-only), for syncing Finder tags
    /// across all drives.
    public func all() async throws -> [Annotation] {
        try await db.writer.read { db in
            try Annotation.fetchAll(db)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/AnnotationListTests 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Annotations/AnnotationStore.swift DiskGalleryCoreTests/AnnotationListTests.swift DiskGallery.xcodeproj/project.pbxproj
git commit -m "feat(core): AnnotationStore.all() lists every annotation (§3)"
```

---

## Task 6: §3 — Action Plan "Run plan" performs a Finder-tag sync

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` (add `TagSyncResult` + `syncFinderTags()`)
- Modify: `DiskGallery/Views/Modern/ModernActionPlanPage.swift` (`ExecutePlanCard` + page state)

No unit test (the write path needs real drives/files; the catalog read it builds on is tested). Verified by build + manual smoke.

- [ ] **Step 0: Add a `disabled` flag to `CTAButton` (shared; also used by §4/§5)**

In `DiskGallery/Views/Modern/ModernControls.swift`, in `CTAButton`, add the property and apply it. Change:

```swift
    var ghost: Bool = false
    var tint: Color? = nil          // override fill (e.g. `.bad` for Delete)
    let action: () -> Void
```

to:

```swift
    var ghost: Bool = false
    var tint: Color? = nil          // override fill (e.g. `.bad` for Delete)
    var disabled: Bool = false
    let action: () -> Void
```

At the end of `body`, change:

```swift
        .buttonStyle(.plain)
    }
```

to:

```swift
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
```

- [ ] **Step 1: Add the sync method to `AppEnvironment`**

In `DiskGallery/App/AppEnvironment.swift`, add a result struct above the class (after the `ScanState` struct) :

```swift
/// Outcome of pushing catalogued annotations onto connected drives as Finder tags.
struct TagSyncResult {
    var drivesSynced = 0
    var filesWritten = 0
    var drivesSkipped = 0   // offline drives
    var filesSkipped = 0    // annotations on offline drives
    var failures = 0        // write errors
}
```

In the `// MARK: Tagging` section of `AppEnvironment` (after `writeFinderTags`), add:

```swift
    /// Pushes every catalogued annotation onto its drive as a Finder tag, for all
    /// connected drives. Non-destructive — the same write the app already performs at
    /// tag time, batched for drives that were offline then. Offline drives are skipped.
    func syncFinderTags() async -> TagSyncResult {
        var result = TagSyncResult()
        let annotations = (try? await catalog.annotations.all()) ?? []
        guard !annotations.isEmpty else { return result }

        // Group by volume key (volumeUuid is the key, or the name when no UUID).
        let byVolume = Dictionary(grouping: annotations, by: { $0.volumeUuid })
        let writer = catalog.finderTags

        for (key, group) in byVolume {
            guard let mount = volumes.mountURL(forKey: key) else {
                result.drivesSkipped += 1
                result.filesSkipped += group.count
                continue
            }
            result.drivesSynced += 1
            let jobs = group.map { (url: mount.appendingPathComponent($0.relPath),
                                    decision: $0.tag, color: $0.color) }
            let failures = await Task.detached(priority: .utility) { () -> Int in
                var failed = 0
                for job in jobs {
                    do { try writer.apply(decision: job.decision, color: job.color, to: job.url) }
                    catch { failed += 1 }
                }
                return failed
            }.value
            result.failures += failures
            result.filesWritten += group.count - failures
        }
        return result
    }
```

- [ ] **Step 2: Build the Core/app so the new API compiles**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Wire `ExecutePlanCard` to run the sync with progress + result**

In `ModernActionPlanPage.swift`, the page passes `onRun: { /* … */ }`. Replace the `ExecutePlanCard` usage in `body`:

```swift
            } right: {
                ExecutePlanCard(agg: agg, onRun: { /* real execution: future-sprint backlog */ })
            }
```

with:

```swift
            } right: {
                ExecutePlanCard(agg: agg)
            }
```

Then change `ExecutePlanCard` to own the run state. Replace its declaration header:

```swift
private struct ExecutePlanCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let agg: PlanAggregate
    let onRun: () -> Void

    private var accent: Color { env.theme.accent.palette.accent }
```

with:

```swift
private struct ExecutePlanCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let agg: PlanAggregate

    @State private var running = false
    @State private var result: TagSyncResult?

    private var accent: Color { env.theme.accent.palette.accent }

    private func run() async {
        running = true
        result = await env.syncFinderTags()
        running = false
    }

    private var resultText: String? {
        guard let r = result else { return nil }
        var parts = ["Wrote \(r.filesWritten) tag\(r.filesWritten == 1 ? "" : "s") across \(r.drivesSynced) drive\(r.drivesSynced == 1 ? "" : "s")"]
        if r.filesSkipped > 0 { parts.append("\(r.filesSkipped) skipped (offline)") }
        if r.failures > 0 { parts.append("\(r.failures) failed") }
        return parts.joined(separator: " · ")
    }
```

In `ExecutePlanCard.body`, replace the CTA + note block:

```swift
                        CTAButton(title: "Run plan", systemImage: "play.fill", action: onRun)
                        if agg.disconnected > 0 {
                            ModernNote(text: "\(agg.disconnected) drive\(agg.disconnected == 1 ? "" : "s") must be connected to run",
                                       systemImage: "exclamationmark.triangle", warn: true)
                        } else {
                            ModernNote(text: "All tagged drives connected", systemImage: "checkmark.shield")
                        }
```

with:

```swift
                        CTAButton(title: running ? "Writing Finder tags…" : "Run plan",
                                  systemImage: "play.fill", disabled: running) {
                            Task { await run() }
                        }
                        if let resultText {
                            ModernNote(text: resultText, systemImage: "checkmark.shield")
                        } else if agg.disconnected > 0 {
                            ModernNote(text: "\(agg.disconnected) drive\(agg.disconnected == 1 ? "" : "s") offline — connected drives will still sync",
                                       systemImage: "exclamationmark.triangle", warn: true)
                        } else {
                            ModernNote(text: "All tagged drives connected", systemImage: "checkmark.shield")
                        }
```

(The `disabled:` parameter on `CTAButton` is added in Step 0 above.)

- [ ] **Step 4: Build**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manual smoke (note for the executor)**

Tag a few items (Keep/Delete/etc.) on a connected drive, open Action Plan, press **Run plan**. The button shows "Writing Finder tags…" then a result note like "Wrote N tags across 1 drive". Confirm in Finder that the files carry the tags. Nothing is moved or deleted.

- [ ] **Step 6: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift DiskGallery/Views/Modern/ModernActionPlanPage.swift
git commit -m "feat(modern): Action Plan Run plan = real Finder-tag sync (§3)"
```

---

## Task 7: `RecentSearchStore` (persistent recent searches for §5)

**Files:**
- Create: `DiskGallery/App/RecentSearchStore.swift`
- Modify: `DiskGallery/App/AppEnvironment.swift` (hold an instance)

No Core unit test (app target, UserDefaults). Verified by build + manual relaunch smoke. Logic is kept small and obviously correct.

- [ ] **Step 1: Create the store**

Create `DiskGallery/App/RecentSearchStore.swift`:

```swift
import Foundation
import Observation

/// A persisted recent search: the query, its last result count, and when it ran.
struct StoredRecentSearch: Codable, Identifiable, Equatable {
    var query: String
    var count: Int
    var date: Date
    var id: String { query }
}

/// Recent searches persisted across launches in UserDefaults. Newest first, de-duped by
/// query, capped. Mirrors the other small app stores (ShortcutStore/ThemeStore).
@MainActor
@Observable
final class RecentSearchStore {
    private static let key = "recentSearches.v1"
    private static let cap = 8

    private(set) var items: [StoredRecentSearch]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([StoredRecentSearch].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    /// Records a search, moving an existing same-query entry to the front with fresh count/date.
    func record(query: String, count: Int) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0.query == trimmed }
        items.insert(StoredRecentSearch(query: trimmed, count: count, date: Date()), at: 0)
        if items.count > Self.cap { items = Array(items.prefix(Self.cap)) }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
```

- [ ] **Step 2: Hold it on `AppEnvironment`**

In `DiskGallery/App/AppEnvironment.swift`, add next to the other stores:

```swift
    let shortcuts = ShortcutStore()
    let theme = ThemeStore()
    let license = LicenseStore()
```

becomes:

```swift
    let shortcuts = ShortcutStore()
    let theme = ThemeStore()
    let license = LicenseStore()
    let recentSearches = RecentSearchStore()
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **` (if "cannot find RecentSearchStore", add the new file to the **DiskGallery** target).

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/App/RecentSearchStore.swift DiskGallery/App/AppEnvironment.swift DiskGallery.xcodeproj/project.pbxproj
git commit -m "feat(app): RecentSearchStore persists recent searches (§5)"
```

---

## Task 8: `SearchFilter` (saved-search predicates for §5)

**Files:**
- Modify: `DiskGalleryCore/Search/SearchService.swift`
- Test: `DiskGalleryCoreTests/SearchTests.swift`

The `Fixture` tree has duplicates of `a.txt` (`a.txt` and `sub/a.txt`, both 100 bytes) and unique `b.txt`/`sub/c.txt` — enough to test duplicates-only. For category/tagged we add a known file/annotation in the test.

- [ ] **Step 1: Write the failing tests**

Append to `DiskGalleryCoreTests/SearchTests.swift` (inside the class):

```swift
    func testDuplicatesOnlyFilterWithQuery() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        // "txt" matches all 4 files; duplicates-only keeps the two a.txt copies.
        let dups = try await catalog.search.search("txt", filter: .duplicatesOnly)
        XCTAssertEqual(Set(dups.map(\.relPath)), ["a.txt", "sub/a.txt"])
    }

    func testTaggedFilterStandalone() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volume = try XCTUnwrap(try await catalog.library.volumes().first)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "b.txt")

        // Empty query + tagged filter lists every .delete-tagged entry.
        let tagged = try await catalog.search.search("", filter: .tagged(.delete))
        XCTAssertEqual(tagged.map(\.relPath), ["b.txt"])
    }

    func testCategoryFilterWithQuery() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        try Fixture.writeFile(root, "holiday.jpg", bytes: 10)
        _ = try await Fixture.scan(catalog, root)

        // Query "h" matches holiday.jpg; category .photos keeps it, .raw drops it.
        let photos = try await catalog.search.search("h", filter: .category(.photos))
        XCTAssertTrue(photos.contains { $0.relPath == "holiday.jpg" })
        let raw = try await catalog.search.search("h", filter: .category(.raw))
        XCTAssertFalse(raw.contains { $0.relPath == "holiday.jpg" })
    }

    func testEmptyQueryNoFilterStillReturnsNothing() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let none = try await catalog.search.search("", filter: .none)
        XCTAssertEqual(none.count, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/SearchTests 2>&1 | tail -30`
Expected: FAIL — `extra argument 'filter' in call` (and `SearchFilter` not found).

- [ ] **Step 3: Implement `SearchFilter` and the filtered search**

In `DiskGalleryCore/Search/SearchService.swift`, add the filter type after `SearchScope`:

```swift
/// A content predicate layered on top of a search, independent of the volume `scope`.
public enum SearchFilter: Sendable, Equatable {
    case none
    case category(FileCategory)   // post-filtered in Swift by extension
    case tagged(Tag)              // entry has this decision tag
    case duplicatesOnly           // (name, logicalSize) appears 2+ times in the latest snapshots
}
```

Replace the whole `search(...)` method with a version that supports a filter and an empty-query-with-filter path:

```swift
    public func search(_ query: String, scope: SearchScope = .all,
                       filter: SearchFilter = .none, limit: Int = 1000) async throws -> [SearchResult] {
        let match = Self.ftsQuery(query)
        // Empty query is only meaningful when a filter narrows the whole catalog.
        if match == nil && filter == .none { return [] }

        // latest-snapshot CTE, reused for duplicates-only and the no-query path.
        let latestCTE = """
            WITH latest AS (
                SELECT s.id FROM snapshot s
                WHERE s.id = (
                    SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                    ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
                )
            )
            """

        let selectCols = """
            SELECT e.id AS entryId, e.snapshotId AS snapshotId, e.name AS name, e.relPath AS relPath,
                   e.isDir AS isDir, e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize,
                   v.name AS volumeName
            """

        var arguments: [(any DatabaseValueConvertible)?] = []
        var sql: String

        if let match {
            sql = """
                \(selectCols)
                FROM entryFts
                JOIN entry e ON e.id = entryFts.rowid
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE entryFts MATCH ?
                """
            arguments.append(match)
        } else {
            // No query: scan the latest snapshots directly (a filter is guaranteed present).
            sql = """
                \(latestCTE)
                \(selectCols)
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE e.snapshotId IN (SELECT id FROM latest)
                """
        }

        switch scope {
        case .all:
            break
        case .snapshot(let snapshotId):
            sql += " AND e.snapshotId = ?"
            arguments.append(snapshotId)
        case .volumeLatest(let volumeId):
            sql += """
                 AND e.snapshotId = (
                    SELECT id FROM snapshot WHERE volumeId = ? ORDER BY scannedAt DESC, id DESC LIMIT 1
                )
                """
            arguments.append(volumeId)
        }

        // SQL-side filters (category is applied in Swift below).
        switch filter {
        case .none, .category:
            break
        case .tagged(let tag):
            sql += """
                 AND EXISTS (
                    SELECT 1 FROM annotation a
                    WHERE a.relPath = e.relPath
                      AND (a.volumeUuid = v.uuid OR (v.uuid IS NULL AND a.volumeUuid = v.name))
                      AND a.tag = ?
                )
                """
            arguments.append(tag.rawValue)
        case .duplicatesOnly:
            // Count copies of this (name, logicalSize) among non-dir entries in the latest snapshots.
            if match != nil { sql = latestCTE + "\n" + sql }   // ensure `latest` is defined
            sql += """
                 AND e.isDir = 0 AND (
                    SELECT COUNT(*) FROM entry e2
                    WHERE e2.name = e.name AND e2.logicalSize = e.logicalSize
                      AND e2.isDir = 0 AND e2.snapshotId IN (SELECT id FROM latest)
                ) >= 2
                """
        }

        sql += " ORDER BY e.isDir DESC, e.name COLLATE NOCASE LIMIT ?"
        arguments.append(limit)

        let finalSQL = sql
        let statementArguments = StatementArguments(arguments)
        var results = try await db.writer.read { db in
            try SearchResult.fetchAll(db, sql: finalSQL, arguments: statementArguments)
        }

        if case .category(let category) = filter, category != .all {
            results = results.filter { category.matches(filename: $0.name) }
        }
        return results
    }
```

Note on the duplicates-only branch: when there **is** a query, the base SQL doesn't yet declare the `latest` CTE, so we prepend `latestCTE`. When there is **no** query, the base SQL already starts with `latestCTE`, so we must **not** prepend it again — the `if match != nil` guard handles exactly that. (A `WITH` clause must appear once at the very start.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/SearchTests 2>&1 | tail -30`
Expected: PASS (existing + 4 new). If the duplicates-only query-path test fails with a SQL `WITH` error, re-check the prepend guard in Step 3.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Search/SearchService.swift DiskGalleryCoreTests/SearchTests.swift
git commit -m "feat(core): SearchFilter (category/tagged/duplicates) + no-query path (§5)"
```

---

## Task 9: §5 — Wire persistence + saved searches into the Search page

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernSearchPage.swift`

(`CTAButton(disabled:)` was added in Task 6, Step 0.)

- [ ] **Step 2: Replace the in-session recent state with the persistent store**

In `ModernSearchPage.swift`, remove the in-session `recent` state and the `RecentSearch` struct usage. Change:

```swift
    @State private var recent: [RecentSearch] = []
```

to: *(delete this line — the store on `env` replaces it)*

Update `recentSection` to read from `env.recentSearches.items` and add a Clear button. Replace `recentSection`:

```swift
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecHeader(title: "Recent")
                if !env.recentSearches.items.isEmpty {
                    Button("Clear") { env.recentSearches.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                }
            }
            if env.recentSearches.items.isEmpty {
                Text("No recent searches yet").font(.system(size: 13)).foregroundStyle(DGToken.ink3(scheme))
                    .padding(.vertical, 9)
            } else {
                ForEach(Array(env.recentSearches.items.enumerated()), id: \.element.id) { idx, r in
                    Button { query = r.query } label: {
                        HStack(spacing: 11) {
                            Image(systemName: "clock").font(.system(size: 15)).foregroundStyle(DGToken.ink3(scheme))
                            Text(r.query).font(.system(size: 13)).foregroundStyle(DGToken.ink2(scheme)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.count(r.count)).font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(DGToken.ink3(scheme))
                        }
                        .padding(.vertical, 9).padding(.horizontal, 6)
                        .overlay(alignment: .bottom) {
                            if idx < env.recentSearches.items.count - 1 { Rectangle().fill(DGToken.hair(scheme)).frame(height: 1) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
```

Delete the now-unused `RecentSearch` struct (lines defining `struct RecentSearch { … }`) and update `remember(...)`/`runSearch()` in Step 4.

- [ ] **Step 3: Add the saved-search filter state and chip row**

In `ModernSearchPage`, add filter state near the other `@State`:

```swift
    @State private var filter: SearchFilter = .none
```

Add a saved-search descriptor and a chip row. Add this computed list and view (place near `scopeChips`):

```swift
    /// The saved searches the mockup hints at, each a real predicate.
    private var savedSearches: [(label: String, filter: SearchFilter)] {
        [("Photos · RAW", .category(.photos)),
         ("Duplicates only", .duplicatesOnly),
         ("Tagged: Delete", .tagged(.delete))]
    }

    private var savedSearchChips: some View {
        HStack(spacing: 7) {
            ForEach(savedSearches, id: \.label) { item in
                ModernFilterChip(label: item.label, selected: filter == item.filter) {
                    filter = (filter == item.filter) ? .none : item.filter
                }
            }
            Spacer(minLength: 0)
        }
    }
```

Note: `("Photos · RAW", .category(.photos))` uses the Photos category as the representative chip (RAW is the related sibling group; keep one predicate per chip for launch). If you want both, add a separate "RAW" chip with `.category(.raw)`.

Add `savedSearchChips` to the hero card. In `heroCard`, after `scopeChips`:

```swift
                searchField
                scopeChips
                if !showResults { recentSection }
```

becomes:

```swift
                searchField
                scopeChips
                savedSearchChips
                if !showResults { recentSection }
```

- [ ] **Step 4: Run search with the filter; show results when a filter is active; persist recents**

Change `showResults` and the `.task` id and `runSearch()`/`remember()`:

```swift
    private var showResults: Bool { trimmed.count >= 2 }
```

to:

```swift
    private var showResults: Bool { trimmed.count >= 2 || filter != .none }
```

Update the `.task` modifier id so a filter change re-runs the search:

```swift
        .task(id: query + "|" + scopeLabel) { await runSearch() }
```

to:

```swift
        .task(id: query + "|" + scopeLabel + "|" + String(describing: filter)) { await runSearch() }
```

Replace `runSearch()` and `remember(...)`:

```swift
    private func runSearch() async {
        guard trimmed.count >= 2 else { results = []; return }
        let found = (try? await env.catalog.search.search(trimmed, scope: scope)) ?? []
        results = found
        remember(trimmed, count: found.count)
    }

    private func remember(_ q: String, count: Int) {
        recent.removeAll { $0.query == q }
        recent.insert(RecentSearch(query: q, count: count), at: 0)
        if recent.count > 5 { recent = Array(recent.prefix(5)) }
    }
```

with:

```swift
    private func runSearch() async {
        // Search when there's a real query OR a saved-search filter is active.
        guard trimmed.count >= 2 || filter != .none else { results = []; return }
        let found = (try? await env.catalog.search.search(trimmed, scope: scope, filter: filter)) ?? []
        results = found
        // Only typed queries become "recent" — a pure filter run isn't a remembered search.
        if trimmed.count >= 2 { env.recentSearches.record(query: trimmed, count: found.count) }
    }
```

- [ ] **Step 5: Build**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manual smoke (note for the executor)**

Type a query → results appear and the query shows under Recent. Quit and relaunch → Recent still lists it; **Clear** empties it. With an empty field, tap **Duplicates only** / **Tagged: Delete** / **Photos · RAW** → results list the correctly filtered entries; tapping the active chip again clears the filter.

- [ ] **Step 7: Commit**

```bash
git add DiskGallery/Views/Modern/ModernControls.swift DiskGallery/Views/Modern/ModernSearchPage.swift
git commit -m "feat(modern): Search persistent recents + saved-search scopes (§5)"
```

---

## Task 10: §4 — Make the deferred Transfer engine honest

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernTransferPage.swift` (`TransferSummaryTile`)

- [ ] **Step 1: Disable Start, drop "USB-C", add a coming-soon note**

In `TransferSummaryTile.body`, replace the est. line + CTA:

```swift
                (Text("\(jobCount)").fontWeight(.bold).foregroundColor(DGToken.ink(scheme))
                 + Text(" jobs · est. ").foregroundColor(DGToken.ink2(scheme))
                 + Text("—").foregroundColor(DGToken.ink3(scheme))
                 + Text(" over USB-C").foregroundColor(DGToken.ink2(scheme)))
                    .font(.system(size: 12)).padding(.top, 8)
                Spacer(minLength: 8)
                CTAButton(title: "Start transfer", systemImage: "arrow.left.arrow.right", action: onStart)
```

with:

```swift
                (Text("\(jobCount)").fontWeight(.bold).foregroundColor(DGToken.ink(scheme))
                 + Text(" jobs · ").foregroundColor(DGToken.ink2(scheme))
                 + Text("planning only").foregroundColor(DGToken.ink3(scheme)))
                    .font(.system(size: 12)).padding(.top, 8)
                Spacer(minLength: 8)
                CTAButton(title: "Start transfer", systemImage: "arrow.left.arrow.right",
                          disabled: true, action: onStart)
                ModernNote(text: "Transfer engine coming soon — this page plans the move; files aren’t copied yet.",
                           systemImage: "info.circle")
                    .padding(.top, 8)
```

The `onStart` closure stays (now a no-op behind a disabled button); the page already passes an empty closure.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Manual smoke (note for the executor)**

Open Transfer Planner: queue + projections still work; **Start transfer** is dimmed/disabled with the coming-soon note; no "USB-C" text remains.

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/Views/Modern/ModernTransferPage.swift
git commit -m "feat(modern): Transfer page honest about deferred engine (§4 launch polish)"
```

---

## Task 11: Final verification + backlog update

**Files:**
- Modify: `docs/superpowers/plans/future-modern-pages-real-functions.md`

- [ ] **Step 1: Run the full Core test suite**

Run: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -30`
Expected: all tests pass (`** TEST SUCCEEDED **`), including the new `FileCategoryTests`, `KeepRuleTests`, `AnnotationListTests`, and the added `SearchTests`.

- [ ] **Step 2: Build the app**

Run: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Mark the shipped items in the backlog**

In `docs/superpowers/plans/future-modern-pages-real-functions.md`, prepend a status line under the title noting what shipped this launch. Add after the opening block:

```markdown
> **Shipped (launch, 2026-05-31):** §1 filter chips, §2 keep-rule, §3 step 1 (Finder-tag sync),
> §5 recent persistence + saved-search scopes. **Still deferred:** §3 steps 2–4 and §4
> `TransferService` (real copy/move/delete) — the Transfer page is marked "coming soon".
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/future-modern-pages-real-functions.md
git commit -m "docs: mark launch-shipped Modern page functions in backlog"
```

---

## Self-Review notes (for the executor)

- **Spec coverage:** §1 (Tasks 1–2), §2 (Tasks 3–4), §3 (Tasks 5–6), §5 persistence (Task 7) + saved searches (Tasks 8–9), §4 (Task 10), `FileCategory` foundation (Task 1). All spec sections map to a task.
- **Cross-task dependency (resolved):** `CTAButton(disabled:)` is added in Task 6 Step 0 (its first user) and reused by Tasks 9 and 10 — every task builds on its own, in order.
- **Type names are consistent across tasks:** `FileCategory`, `KeepRule`/`keptMemberID`, `AnnotationStore.all()`, `TagSyncResult`/`syncFinderTags()`, `SearchFilter`, `RecentSearchStore`/`StoredRecentSearch`.
- **No files are moved or deleted anywhere** — the only disk writes remain `FinderTagWriter.apply`.
```
