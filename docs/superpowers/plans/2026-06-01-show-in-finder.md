# "Show in Finder" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a free "Show in Finder" action that reveals a catalogued file in Finder, keeping the app fully read-only (Finder performs any real move/delete, by the user).

**Architecture:** A pure Core helper resolves `(mountURL, relPath)` → on-disk `URL` and confirms existence (unit-tested). `SearchResult` gains `volumeUuid` so search rows can resolve their drive. `AppEnvironment.revealInFinder(volumeKey:relPath:)` calls `NSWorkspace.activateFileViewerSelecting`. A reusable `.revealInFinder(...)` view modifier adds a context-menu item + ⌘R, disabled when the drive is offline. Wired into duplicates, search, tagged, and browser rows.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), AppKit (`NSWorkspace`), GRDB, XCTest, XcodeGen.

**Conventions:**
- Volume key = `uuid ?? name` (matches `VolumeService.mountURL(forKey:)` and `AnnotationStore.volumeKey`).
- Core tests: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/<Class>`.
- App build: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS'`.
- Run `xcodegen generate` after adding files.
- Branch: `feat/show-in-finder` off `main` before Task 1.

---

## File Structure

- **Create** `DiskGalleryCore/FinderTags/RevealTarget.swift` — pure URL-resolution helper (lives near other file-location code).
- **Modify** `DiskGalleryCore/Search/SearchService.swift` — add `volumeUuid` to `SearchResult` + the SELECT.
- **Create** `DiskGalleryCoreTests/RevealTargetTests.swift`.
- **Modify** `DiskGalleryCoreTests/SearchTests.swift` — assert `volumeUuid` populated.
- **Modify** `DiskGallery/App/AppEnvironment.swift` — `revealInFinder(volumeKey:relPath:)` + an `canReveal(volumeKey:)` helper.
- **Create** `DiskGallery/Views/Modern/RevealInFinder.swift` — `.revealInFinder(volumeKey:relPath:)` view modifier (context menu + ⌘R, disabled offline).
- **Modify** 4 row sites: `ModernDuplicatesPage.swift` (CopyRow), `ModernSearchPage.swift` (SearchResultRow), `ModernActionPlanPage.swift` (PlanItemRow), `ModernBrowser.swift` (ModernFrow).

---

## Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
git checkout main && git checkout -b feat/show-in-finder && git status
```

Expected: on `feat/show-in-finder`, clean tree.

---

## Task 1: Core — `RevealTarget` URL resolver

**Files:**
- Create: `DiskGalleryCore/FinderTags/RevealTarget.swift`
- Test: `DiskGalleryCoreTests/RevealTargetTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/RevealTargetTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class RevealTargetTests: XCTestCase {
    func testResolvesExistingFileURL() throws {
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        // mountURL is the tree root; relPath "a.txt" exists in the fixture.
        let url = RevealTarget.url(mountURL: root, relPath: "a.txt")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "a.txt")
    }

    func testReturnsNilWhenFileMissing() throws {
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertNil(RevealTarget.url(mountURL: root, relPath: "does/not/exist.txt"))
    }

    func testReturnsNilWhenMountIsNil() {
        XCTAssertNil(RevealTarget.url(mountURL: nil, relPath: "a.txt"))
    }

    func testHandlesNestedRelPath() throws {
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = RevealTarget.url(mountURL: root, relPath: "sub/c.txt")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "c.txt")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/RevealTargetTests 2>&1 | tail -15
```

Expected: FAIL — "cannot find 'RevealTarget' in scope".

- [ ] **Step 3: Write the implementation**

Create `DiskGalleryCore/FinderTags/RevealTarget.swift`:

```swift
import Foundation

/// Resolves a catalogued file (its drive's live mount point + path-relative-to-root)
/// to a real on-disk `URL`, but only when the file actually exists right now. Pure and
/// side-effect-free so the path logic is unit-testable; the app calls `NSWorkspace` with
/// the result. Returns nil when the drive is offline (`mountURL == nil`) or the file is
/// gone (moved/deleted since the last scan).
public enum RevealTarget {
    public static func url(mountURL: URL?, relPath: String) -> URL? {
        guard let mountURL else { return nil }
        let candidate = mountURL.appendingPathComponent(relPath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/RevealTargetTests 2>&1 | tail -15
```

Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/FinderTags/RevealTarget.swift DiskGalleryCoreTests/RevealTargetTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): add RevealTarget file-URL resolver"
```

---

## Task 2: Core — add `volumeUuid` to `SearchResult`

**Files:**
- Modify: `DiskGalleryCore/Search/SearchService.swift`
- Test: `DiskGalleryCoreTests/SearchTests.swift`

Search rows currently only have `volumeName`; to resolve the drive key (`uuid ?? name`) reliably they need `volumeUuid`. Add the column to the struct and both SELECTs.

- [ ] **Step 1: Write the failing test**

Add to `DiskGalleryCoreTests/SearchTests.swift` (inside the class):

```swift
    func testResultIncludesVolumeUuid() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await Fixture.scan(catalog, root)

        let results = try await catalog.search.search("a")
        XCTAssertFalse(results.isEmpty)
        // The fixture volume has no UUID (temp dir), so volumeUuid is nil but the
        // property must exist and decode without error.
        _ = results.first?.volumeUuid
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/SearchTests/testResultIncludesVolumeUuid 2>&1 | tail -15
```

Expected: FAIL — "value of type 'SearchResult' has no member 'volumeUuid'".

- [ ] **Step 3: Add the property and SELECT column**

In `DiskGalleryCore/Search/SearchService.swift`, add `volumeUuid` to the struct (after `volumeName`):

```swift
public struct SearchResult: Codable, Sendable, Identifiable, FetchableRecord {
    public var entryId: Int64
    public var snapshotId: Int64
    public var name: String
    public var relPath: String
    public var isDir: Bool
    public var logicalSize: Int64
    public var subtreeLogicalSize: Int64?
    public var volumeName: String
    public var volumeUuid: String?

    public var id: Int64 { entryId }
    public var displaySize: Int64 { isDir ? (subtreeLogicalSize ?? 0) : logicalSize }
}
```

And add the column to the shared `selectCols` (after `v.name AS volumeName`):

```swift
        let selectCols = """
            SELECT e.id AS entryId, e.snapshotId AS snapshotId, e.name AS name, e.relPath AS relPath,
                   e.isDir AS isDir, e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize,
                   v.name AS volumeName, v.uuid AS volumeUuid
            """
```

- [ ] **Step 4: Run to verify it passes (and no regressions in SearchTests)**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/SearchTests 2>&1 | tail -8
```

Expected: PASS — all SearchTests (existing + the new one).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Search/SearchService.swift DiskGalleryCoreTests/SearchTests.swift
git commit -m "feat(core): expose volumeUuid on SearchResult"
```

---

## Task 3: App — `revealInFinder` on AppEnvironment + the view modifier

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift`
- Create: `DiskGallery/Views/Modern/RevealInFinder.swift`

- [ ] **Step 1: Add the action + connectivity helper to AppEnvironment**

In `DiskGallery/App/AppEnvironment.swift`, add these methods inside the `AppEnvironment` class (near the other functions). Note `AppKit` is already imported in this file.

```swift
    /// Is the drive holding this file currently connected? Drives the enabled state of
    /// the "Show in Finder" controls.
    func canReveal(volumeKey: String?) -> Bool {
        guard let volumeKey else { return false }
        return volumes.mountURL(forKey: volumeKey) != nil
    }

    /// Reveals a catalogued file in Finder (selected, not just its folder). No-op when the
    /// drive is offline or the file no longer exists — the app never modifies files.
    func revealInFinder(volumeKey: String?, relPath: String) {
        guard let volumeKey else { return }
        let mountURL = volumes.mountURL(forKey: volumeKey)
        guard let url = RevealTarget.url(mountURL: mountURL, relPath: relPath) else {
            errorMessage = "That file isn’t available — its drive may be disconnected or the file was moved."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
```

- [ ] **Step 2: Create the view modifier**

Create `DiskGallery/Views/Modern/RevealInFinder.swift`:

```swift
import SwiftUI
import DiskGalleryCore

/// Adds a "Show in Finder" context-menu item (and ⌘R when the row is focused/hovered)
/// to any row that represents a single concrete file. Disabled when the file's drive is
/// offline. Reveals via `AppEnvironment.revealInFinder` — Finder performs any real action,
/// so the app stays read-only.
private struct RevealInFinderModifier: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let volumeKey: String?
    let relPath: String
    let isDir: Bool

    func body(content: Content) -> some View {
        let enabled = !isDir && env.canReveal(volumeKey: volumeKey)
        content.contextMenu {
            Button {
                env.revealInFinder(volumeKey: volumeKey, relPath: relPath)
            } label: {
                Label("Show in Finder", systemImage: "magnifyingglass")
            }
            .disabled(!enabled)
        }
    }
}

extension View {
    /// Marks a row as a revealable single file. `isDir` rows and offline drives disable it.
    func revealInFinder(volumeKey: String?, relPath: String, isDir: Bool = false) -> some View {
        modifier(RevealInFinderModifier(volumeKey: volumeKey, relPath: relPath, isDir: isDir))
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift DiskGallery/Views/Modern/RevealInFinder.swift DiskGallery.xcodeproj
git commit -m "feat(app): revealInFinder action + context-menu modifier"
```

---

## Task 4: Wire the modifier into the four row surfaces

**Files:**
- Modify: `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` (CopyRow)
- Modify: `DiskGallery/Views/Modern/ModernSearchPage.swift` (SearchResultRow)
- Modify: `DiskGallery/Views/Modern/ModernActionPlanPage.swift` (PlanItemRow)
- Modify: `DiskGallery/Views/Modern/ModernBrowser.swift` (ModernFrow)

Each row already has the data it needs. Apply `.revealInFinder(...)` to the **outermost view** each row body returns. The exact data field per surface:

| Row | volumeKey expression | relPath | isDir |
|-----|----------------------|---------|-------|
| CopyRow (`m: DuplicateMember`) | `m.volumeUuid ?? m.volumeName` | `m.relPath` | `false` (copies are files) |
| SearchResultRow (`result: SearchResult`) | `result.volumeUuid ?? result.volumeName` | `result.relPath` | `result.isDir` |
| PlanItemRow (`item: TaggedEntry`) | `item.volumeUuid` | `item.relPath` | `item.isDir ?? false` |
| ModernFrow (`entry: Entry`) | `env.selectedVolumeKey` | `entry.relPath` | `entry.isDir` |

- [ ] **Step 1: CopyRow (duplicates)**

In `ModernDuplicatesPage.swift`, find the `CopyRow` struct's `var body`. The row has a `let m: DuplicateMember` (or similar — confirm the member property name; it is the `DuplicateMember` the row renders). Append to the outermost view it returns:

```swift
        .revealInFinder(volumeKey: m.volumeUuid ?? m.volumeName, relPath: m.relPath, isDir: false)
```

If the stored property is named differently (e.g. `member`), use that name. Confirm by reading the struct's stored `let` of type `DuplicateMember`.

- [ ] **Step 2: SearchResultRow**

In `ModernSearchPage.swift`, find `private struct SearchResultRow` with `let result: SearchResult`. Append to the outermost view in its `body`:

```swift
        .revealInFinder(volumeKey: result.volumeUuid ?? result.volumeName, relPath: result.relPath, isDir: result.isDir)
```

- [ ] **Step 3: PlanItemRow (tagged)**

In `ModernActionPlanPage.swift`, find `private struct PlanItemRow` with `let item: TaggedEntry`. Append to the outermost view in its `body`:

```swift
        .revealInFinder(volumeKey: item.volumeUuid, relPath: item.relPath, isDir: item.isDir ?? false)
```

- [ ] **Step 4: ModernFrow (browser)**

In `ModernBrowser.swift`, find `struct ModernFrow` with `let entry: Entry`. It needs the selected volume key from the environment. If `ModernFrow` does not already have `@Environment(AppEnvironment.self) private var env`, add it. Then append to the outermost view in its `body`:

```swift
        .revealInFinder(volumeKey: env.selectedVolumeKey, relPath: entry.relPath, isDir: entry.isDir)
```

- [ ] **Step 5: Build to verify**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(app): wire Show in Finder into duplicate, search, tagged, and browser rows"
```

---

## Task 5: Final verification

- [ ] **Step 1: Full Core test suite**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | grep -aE "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -2
```

Expected: `** TEST SUCCEEDED **`, 71 + 5 new = 76 tests, 0 failures.

- [ ] **Step 2: App build**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

## Manual verification (after merge)
- Right-click a duplicate copy / search result / tagged item / browser row whose drive is connected → "Show in Finder" opens Finder with the file selected.
- The same item with its drive disconnected → the menu item is disabled.
- Folders (in search/browser) → menu item disabled (`isDir`).
