# All Drives Unified Browser (M2) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Browse every drive's latest snapshot as one merged tree, with a backup-coverage lens (at-risk / backed-up / protected) and per-folder copy comparison, feeding the existing Organize plan via per-copy tagging.

**Architecture:** A pure-ish Core `UnifiedBrowserService` does the cross-drive merge (children resolved by `parentId` per volume's latest snapshot, grouped by name), plus a pure `UnifiedMerge.node(...)` builder for reference/coverage/redundancy (unit-tested without a DB). Live connection state stays in the app layer. Consumed by a Modern page (path bar → coverage banner → browser + comparison inspector) and a Classic split view.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), GRDB (behind Catalog), XcodeGen. Verify Core via `xcodebuild test -scheme DiskGalleryCore`; app via `xcodebuild -scheme DiskGallery build`; run `xcodegen generate` after adding files.

---

## Phase A — Core data layer (TDD)

### Task A1: Types + pure `UnifiedMerge.node` builder

**Files:**
- Create: `DiskGalleryCore/Unified/UnifiedModels.swift`
- Create: `DiskGalleryCore/Unified/UnifiedMerge.swift`
- Create: `DiskGalleryCoreTests/UnifiedMergeTests.swift`

- [ ] **Step 1 (RED):** Write `UnifiedMergeTests`:
```swift
import XCTest
@testable import DiskGalleryCore
final class UnifiedMergeTests: XCTestCase {
    private func copy(_ key: String, size: Int64, modified: TimeInterval? = nil,
                      hash: String? = nil) -> UnifiedCopy {
        UnifiedCopy(volumeKey: key, volumeName: key, relPath: "ARCHIVE", size: size,
                    modifiedAt: modified.map { Date(timeIntervalSince1970: $0) },
                    contentHash: hash, entryId: 1, snapshotId: 1)
    }
    func testReferenceIsLargestThenNewest() {
        let node = UnifiedMerge.node(relPath: "ARCHIVE", name: "ARCHIVE", isDir: true,
                                     copies: [copy("A", size: 100), copy("B", size: 300), copy("C", size: 300, modified: 999)])
        XCTAssertEqual(node.copies.first?.volumeKey, "C")        // 300 & newest → reference, sorted first
        XCTAssertTrue(node.copies.first?.isReference ?? false)
        XCTAssertEqual(node.referenceSize, 300)
        XCTAssertEqual(node.redundantSize, 100 + 300)            // sum(700) - reference(300)
    }
    func testCoverageByDriveCount() {
        XCTAssertEqual(UnifiedMerge.node(relPath: "x", name: "x", isDir: true, copies: [copy("A", size: 1)]).coverage, .atRisk)
        XCTAssertEqual(UnifiedMerge.node(relPath: "x", name: "x", isDir: true, copies: [copy("A", size: 1), copy("B", size: 1)]).coverage, .backedUp)
        XCTAssertEqual(UnifiedMerge.node(relPath: "x", name: "x", isDir: true, copies: [copy("A", size: 1), copy("B", size: 1), copy("C", size: 1)]).coverage, .protected)
    }
    func testPartialFlag() {
        let node = UnifiedMerge.node(relPath: "x", name: "x", isDir: true,
                                     copies: [copy("A", size: 1000), copy("B", size: 800)])
        XCTAssertEqual(node.copies.first(where: { $0.volumeKey == "B" })?.isPartial, true)   // 800 < 90% of 1000
        XCTAssertEqual(node.copies.first(where: { $0.volumeKey == "A" })?.isPartial, false)
    }
    func testMatchesReferenceForFiles() {
        let node = UnifiedMerge.node(relPath: "f", name: "f", isDir: false,
                                     copies: [copy("A", size: 100, hash: "h1"), copy("B", size: 100, hash: "h1"), copy("C", size: 100, hash: "h2")])
        XCTAssertEqual(node.copies.first(where: { $0.volumeKey == "B" })?.matchesReference, true)
        XCTAssertEqual(node.copies.first(where: { $0.volumeKey == "C" })?.matchesReference, false)
    }
}
```
- [ ] **Step 2:** `xcodegen generate`; run `-only-testing:DiskGalleryCoreTests/UnifiedMergeTests` → FAIL (types missing).
- [ ] **Step 3 (GREEN):** `UnifiedModels.swift`:
```swift
import Foundation

public enum Coverage: String, Sendable, Equatable { case atRisk, backedUp, protected }

public struct UnifiedCopy: Sendable, Identifiable, Equatable {
    public var id: String { "\(volumeKey)|\(relPath)" }
    public var volumeKey: String
    public var volumeName: String
    public var relPath: String
    public var size: Int64
    public var modifiedAt: Date?
    public var contentHash: String?
    public var entryId: Int64
    public var snapshotId: Int64
    public var isReference: Bool = false
    public var isPartial: Bool = false
    public var matchesReference: Bool? = nil
    public init(volumeKey: String, volumeName: String, relPath: String, size: Int64,
                modifiedAt: Date?, contentHash: String?, entryId: Int64, snapshotId: Int64,
                isReference: Bool = false, isPartial: Bool = false, matchesReference: Bool? = nil) {
        self.volumeKey = volumeKey; self.volumeName = volumeName; self.relPath = relPath
        self.size = size; self.modifiedAt = modifiedAt; self.contentHash = contentHash
        self.entryId = entryId; self.snapshotId = snapshotId
        self.isReference = isReference; self.isPartial = isPartial; self.matchesReference = matchesReference
    }
}

public struct UnifiedNode: Sendable, Identifiable, Equatable {
    public var id: String { relPath }
    public var relPath: String
    public var name: String
    public var isDir: Bool
    public var copies: [UnifiedCopy]
    public var referenceSize: Int64
    public var redundantSize: Int64
    public var driveCount: Int
    public var coverage: Coverage
}

public struct CoverageSummary: Sendable, Equatable {
    public var atRiskBytes: Int64
    public var atRiskCount: Int
    public var redundantBytes: Int64
    public var driveCount: Int
    public static let empty = CoverageSummary(atRiskBytes: 0, atRiskCount: 0, redundantBytes: 0, driveCount: 0)
}
```
  `UnifiedMerge.swift`:
```swift
import Foundation

public enum UnifiedMerge {
    /// Builds one merged node from a path's copies across drives — picks the reference
    /// copy (largest, then newest), flags partial/identical copies, computes coverage.
    public static func node(relPath: String, name: String, isDir: Bool, copies: [UnifiedCopy]) -> UnifiedNode {
        // Reference: largest size, then newest modifiedAt, then smallest volumeKey.
        let refIndex = copies.indices.max(by: { a, b in
            let ca = copies[a], cb = copies[b]
            if ca.size != cb.size { return ca.size < cb.size }
            let ma = ca.modifiedAt ?? .distantPast, mb = cb.modifiedAt ?? .distantPast
            if ma != mb { return ma < mb }
            return ca.volumeKey > cb.volumeKey
        })
        guard let ri = refIndex else {
            return UnifiedNode(relPath: relPath, name: name, isDir: isDir, copies: [],
                               referenceSize: 0, redundantSize: 0, driveCount: 0, coverage: .atRisk)
        }
        let refSize = copies[ri].size
        let refHash = copies[ri].contentHash
        var finalized = copies.enumerated().map { (i, c) -> UnifiedCopy in
            var c = c
            c.isReference = (i == ri)
            c.isPartial = !c.isReference && c.size < Int64(Double(refSize) * 0.9)
            if !isDir, let h = c.contentHash, let rh = refHash { c.matchesReference = (h == rh) } else { c.matchesReference = nil }
            return c
        }
        // Sort: reference first, then size desc, then volumeName.
        finalized.sort { a, b in
            if a.isReference != b.isReference { return a.isReference }
            if a.size != b.size { return a.size > b.size }
            return a.volumeName.localizedCaseInsensitiveCompare(b.volumeName) == .orderedAscending
        }
        let total = copies.reduce(0) { $0 + $1.size }
        let coverage: Coverage = copies.count <= 1 ? .atRisk : (copies.count == 2 ? .backedUp : .protected)
        return UnifiedNode(relPath: relPath, name: name, isDir: isDir, copies: finalized,
                           referenceSize: refSize, redundantSize: total - refSize,
                           driveCount: copies.count, coverage: coverage)
    }
}
```
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5:** Commit `feat(core): unified merge models + node builder`.

### Task A2: `UnifiedBrowserService` (DB merge) + Catalog wiring (TDD)

**Files:**
- Create: `DiskGalleryCore/Unified/UnifiedBrowserService.swift`
- Modify: `DiskGalleryCore/Catalog.swift`
- Create: `DiskGalleryCoreTests/UnifiedBrowserServiceTests.swift`

- [ ] **Step 1 (RED):** Test using `Fixture.makeCatalog()` + `Fixture.makeTree()`/`scan`. Build two volumes by scanning two trees with a shared top-level folder name, then assert merge. Minimal version:
```swift
import XCTest
@testable import DiskGalleryCore
final class UnifiedBrowserServiceTests: XCTestCase {
    func testRootMergesSharedFolderAcrossDrives() async throws {
        let catalog = try Fixture.makeCatalog()
        let a = try Fixture.makeTree(name: "tree")          // has top-level: a.txt, b.txt, sub/, empty/
        let b = try Fixture.makeTree(name: "tree")
        _ = try await Fixture.scan(catalog, a)
        _ = try await Fixture.scan(catalog, b)
        let nodes = try await catalog.unified.children(ofPath: "", hideHidden: true)
        let sub = try XCTUnwrap(nodes.first { $0.name == "sub" })
        XCTAssertEqual(sub.driveCount, 2)                   // "sub" exists on both scanned trees
        XCTAssertEqual(sub.coverage, .backedUp)
        XCTAssertTrue(sub.copies.contains { $0.isReference })
    }
    func testChildrenOfNestedPath() async throws {
        let catalog = try Fixture.makeCatalog()
        _ = try await Fixture.scan(catalog, try Fixture.makeTree())
        let kids = try await catalog.unified.children(ofPath: "sub", hideHidden: true)
        XCTAssertEqual(Set(kids.map(\.name)), ["c.txt", "a.txt"])   // sub/c.txt, sub/a.txt
    }
    func testSummaryCountsAtRisk() async throws {
        let catalog = try Fixture.makeCatalog()
        _ = try await Fixture.scan(catalog, try Fixture.makeTree())   // single drive → everything at risk
        let summary = try await catalog.unified.summary(hideHidden: true)
        XCTAssertGreaterThan(summary.atRiskCount, 0)
        XCTAssertEqual(summary.driveCount, 1)
    }
}
```
  Note: the volume key for a scanned temp tree is its uuid-or-name; both scans of name "tree" produce two distinct volumes (distinct uuid/name per scan). If the two scans collapse into one volume, adjust by scanning two differently-named trees and asserting on a folder both create (`sub`). Verify by reading what `Fixture.scan` keys volumes on; if needed, create two trees with the same child folder name but different roots.
- [ ] **Step 2:** `xcodegen generate`; run the test → FAIL (`catalog.unified` missing).
- [ ] **Step 3 (GREEN):** `UnifiedBrowserService.swift`:
```swift
import Foundation
import GRDB

public struct UnifiedBrowserService: Sendable {
    let db: AppDatabase

    /// Direct children at `parentPath` ("" = root), merged across every volume's latest
    /// snapshot. Children resolved by parentId (wildcard-safe — names may contain `_`).
    public func children(ofPath parentPath: String, hideHidden: Bool) async throws -> [UnifiedNode] {
        let rows = try await db.writer.read { db -> [Row] in
            let parentClause = parentPath.isEmpty ? "parent.parentId IS NULL" : "parent.relPath = :p"
            let sql = """
                WITH latest AS (
                    SELECT s.id AS sid, s.volumeId AS vid FROM snapshot s
                    WHERE s.id = (SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                                  ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1)
                )
                SELECT v.uuid AS uuid, v.name AS volumeName, l.sid AS snapshotId,
                       e.id AS entryId, e.name AS name, e.relPath AS relPath, e.isDir AS isDir,
                       e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize,
                       e.modifiedAt AS modifiedAt, e.contentHash AS contentHash
                FROM latest l
                JOIN volume v ON v.id = l.vid
                JOIN entry parent ON parent.snapshotId = l.sid AND \(parentClause)
                JOIN entry e ON e.snapshotId = l.sid AND e.parentId = parent.id
                """
            return try Row.fetchAll(db, sql: sql, arguments: parentPath.isEmpty ? [:] : ["p": parentPath])
        }
        return Self.merge(rows: rows, hideHidden: hideHidden)
    }

    /// Coverage headline computed over top-level folders (cheap, meaningful).
    public func summary(hideHidden: Bool) async throws -> CoverageSummary {
        let top = try await children(ofPath: "", hideHidden: hideHidden)
        let atRisk = top.filter { $0.coverage == .atRisk }
        let drives = Set(top.flatMap { $0.copies.map(\.volumeKey) })
        return CoverageSummary(
            atRiskBytes: atRisk.reduce(0) { $0 + $1.referenceSize },
            atRiskCount: atRisk.count,
            redundantBytes: top.reduce(0) { $0 + $1.redundantSize },
            driveCount: drives.count)
    }

    static func merge(rows: [Row], hideHidden: Bool) -> [UnifiedNode] {
        var byName: [String: (relPath: String, isDir: Bool, copies: [UnifiedCopy])] = [:]
        for row in rows {
            let name: String = row["name"]
            if hideHidden && name.hasPrefix(".") { continue }
            let isDir: Bool = row["isDir"]
            let relPath: String = row["relPath"]
            let size: Int64 = isDir ? (row["subtreeLogicalSize"] ?? 0) : (row["logicalSize"] ?? 0)
            let key = (row["uuid"] as String?) ?? (row["volumeName"] as String)
            let copy = UnifiedCopy(volumeKey: key, volumeName: row["volumeName"], relPath: relPath,
                                   size: size, modifiedAt: row["modifiedAt"], contentHash: row["contentHash"],
                                   entryId: row["entryId"], snapshotId: row["snapshotId"])
            var bucket = byName[name] ?? (relPath: relPath, isDir: isDir, copies: [])
            bucket.isDir = bucket.isDir || isDir
            bucket.copies.append(copy)
            byName[name] = bucket
        }
        let nodes = byName.map { name, b in
            UnifiedMerge.node(relPath: b.relPath, name: name, isDir: b.isDir, copies: b.copies)
        }
        return nodes.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            if a.referenceSize != b.referenceSize { return a.referenceSize > b.referenceSize }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
```
  In `Catalog.swift` add `public let unified: UnifiedBrowserService` and init `self.unified = UnifiedBrowserService(db: db)`.
- [ ] **Step 4:** Run tests → PASS; full Core suite green.
- [ ] **Step 5:** Commit `feat(core): UnifiedBrowserService cross-drive merge`.

---

## Phase B — Navigation + Classic

### Task B1: `SidebarItem.allDrives` + both switches + sidebars

**Files:** `DiskGallery/App/AppEnvironment.swift`, `DiskGallery/App/DiskGalleryApp.swift`, `DiskGallery/Views/Modern/ModernWorkspace.swift`, `DiskGallery/Views/Modern/ModernSidebar.swift`, `DiskGallery/Views/LibrarySidebarView.swift`.

- [ ] **Step 1:** In `SidebarItem` add `case allDrives`; in `token` map it to `"allDrives"`; in `init?(token:)` parse `"allDrives"`.
- [ ] **Step 2:** Add to `AppEnvironment`:
```swift
func unifiedChildren(path: String) async -> [UnifiedNode] {
    do { return try await catalog.unified.children(ofPath: path, hideHidden: viewPrefs.hideHidden) }
    catch { report(error); return [] }
}
func unifiedCoverage() async -> CoverageSummary {
    do { return try await catalog.unified.summary(hideHidden: viewPrefs.hideHidden) }
    catch { report(error); return .empty }
}
func tagCopy(_ tag: Tag, copy: UnifiedCopy) {
    Task { try? await catalog.annotations.setDecision(tag, volumeKey: copy.volumeKey, relPath: copy.relPath); dataVersion += 1 }
}
```
- [ ] **Step 3:** `ContentColumn` (DiskGalleryApp.swift) add `case .allDrives: AllDrivesView()`. `ModernWorkspace` add `case .allDrives: ModernAllDrivesPage()`.
- [ ] **Step 4:** Both sidebars: add a top entry above the drive list — Label "All Drives" / `square.stack.3d.up.fill`, `.tag(.allDrives)` (Classic) or `navItem`/selection (Modern), with an at-risk count badge from a cached `coverageSummary`. (Add `var coverageSummary: CoverageSummary = .empty` to AppEnvironment, refreshed in `refresh()` via `coverageSummary = (try? await catalog.unified.summary(hideHidden: viewPrefs.hideHidden)) ?? .empty`.)
- [ ] **Step 5:** `xcodegen generate`; create temporary stub `AllDrivesView`/`ModernAllDrivesPage` (a `Text("All Drives")`) so it builds; `xcodebuild -scheme DiskGallery build` → SUCCEEDED.
- [ ] **Step 6:** Commit `feat(app): All Drives navigation`.

### Task B2: Classic `AllDrivesView`

**Files:** Create `DiskGallery/Views/AllDrivesView.swift`; the detail comparison reuses a shared `UnifiedComparePanel` (create in same file or `Views/Modern/UnifiedCompare.swift` for reuse).

- [ ] **Step 1:** Implement `AllDrivesView`: `@State path: [String]` (breadcrumb of names) + `@State nodes: [UnifiedNode]` + `@State selected: UnifiedNode?`. A `List` of rows: coverage dot (`Circle().fill(node.coverage.color)`), name, reference size (`Format.bytes`), "on N" chip; folders are buttons that push `path`. A toolbar `Toggle("At-risk only")`. `.task(id: pathKey + dataVersion)` loads `nodes = await env.unifiedChildren(path: pathString)`. Selecting a node sets `selected` → shows `UnifiedComparePanel(node:)`.
- [ ] **Step 2:** `UnifiedComparePanel`: lists `node.copies` — each row: drive name, size bar vs `referenceSize`, modified date, badges (Reference ✓ / Partial ⚠ / Identical·Differs for files / Offline via `env.volumes.isConnected(key:)`), and a tag `Menu` (Move/Backup/Delete → `env.tagCopy`). Header shows reclaimable redundancy (`Format.bytes(node.redundantSize)`).
- [ ] **Step 3:** Add `extension Coverage { var color: Color }` (red/amber/green) in the app layer (e.g. `Views/Modern/UnifiedCompare.swift`).
- [ ] **Step 4:** `xcodegen generate`; `xcodebuild -scheme DiskGallery build` → SUCCEEDED. Manual: All Drives shows merged list + compare.
- [ ] **Step 5:** Commit `feat(app): Classic All Drives view`.

---

## Phase C — Modern

### Task C1: `ModernAllDrivesPage` — path bar + coverage banner + browser

**Files:** Create `DiskGallery/Views/Modern/ModernAllDrivesPage.swift`.

- [ ] **Step 1:** Build the page (no per-drive OLED): `VStack { ModernTopbar(onSearch:…); ModernPathBar(leadingIcon:"square.stack.3d.up.fill", crumbs: ["All Drives"] + path, onCrumb:…); coverageBanner; bento }`. State: `path: [String]`, `nodes`, `selected`, `atRiskOnly: Bool`.
- [ ] **Step 2:** `coverageBanner` — a `GlassCard`/strip showing `⚠ {Format.bytes(summary.atRiskBytes)} at risk · {summary.atRiskCount} folders · {Format.bytes(summary.redundantBytes)} redundant · {summary.driveCount} drives` + a `Toggle`/segmented "At-risk only". Load summary in `.task(id: env.dataVersion)`.
- [ ] **Step 3:** Bento: left = browser list of `UnifiedRow`(coverage dot, name, size, "on N" chip, partial hint), folders drill (append to `path`); right = `UnifiedComparePanel(node: selected)` (reuse from B2). Apply `atRiskOnly` filter to the displayed nodes.
- [ ] **Step 4:** `.task(id: pathKey + "-\(env.dataVersion)")` loads `nodes = await env.unifiedChildren(path: path.joined(separator: "/"))`.
- [ ] **Step 5:** `xcodegen generate`; build → SUCCEEDED. Manual: drill-down, banner, filter, compare, tag.
- [ ] **Step 6:** Commit `feat(app): Modern All Drives page`.

---

## Final
- [ ] Full Core suite + app build green.
- [ ] Adversarial code-review workflow over the diff; fix confirmed findings.
- [ ] Manual smoke test per the spec's checklist.

## Self-review notes
- Spec coverage: merge (A2), coverage lens (A1 coverage + banner C1 + dot B2/C1 + filter), copy comparison (A1 reference/partial/matches + UnifiedComparePanel), per-item tagging (`tagCopy`), both skins (B2/C1), nav (B1). Deferred items (bulk actions, drift diff, coverage OLED) intentionally absent.
- Refinements vs spec: `UnifiedCopy` has **no** `isConnected` (Core stays pure; app derives via `env.volumes.isConnected`); reference tie-break is size→mtime→volumeKey (no "connected"). Children resolved by `parentId` (underscore-safe), not `relPath LIKE`.
- Type consistency: `UnifiedCopy`, `UnifiedNode`, `Coverage`, `CoverageSummary`, `UnifiedMerge.node`, `UnifiedBrowserService.{children(ofPath:hideHidden:),summary(hideHidden:),merge}`, `env.{unifiedChildren,unifiedCoverage,tagCopy,coverageSummary}`, `Coverage.color`, `UnifiedComparePanel` used consistently across tasks.
