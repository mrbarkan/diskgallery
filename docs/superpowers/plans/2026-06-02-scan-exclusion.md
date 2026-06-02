# Scan Exclusion (Firmlink Double-Count Fix) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When scanning the boot volume (`/`), skip the `/System/Volumes` re-mount so APFS firmlinked files are counted once instead of twice.

**Architecture:** Add a pure, unit-testable `ScanExclusion` policy enum in DiskGalleryCore (mirroring the existing `VolumeFilter` / `PathVisibility` helpers), then wire it into `Scanner.execute` with a one-time boot-volume check and an early `continue` that omits the excluded node before it is recorded, descended, or counted.

**Tech Stack:** Swift 6, DiskGalleryCore framework, XCTest (DiskGalleryCoreTests), XcodeGen (`project.yml` → generated `.xcodeproj`).

**Reference spec:** `docs/superpowers/specs/2026-06-02-scan-exclusion-design.md`

---

## Background the engineer needs

- **APFS volume group:** macOS boots from `Macintosh HD` (system, at `/`) + `Macintosh HD – Data` (at `/System/Volumes/Data`), joined by **firmlinks**. `/Applications`, `/Users`, `/Library` at root resolve into the Data volume. Firmlinks are NOT symlinks, so the scanner's existing `isSymbolicLink` skip does not catch them. Walking `/` therefore visits every user file twice — once via the root firmlink and once via `/System/Volumes/Data/…`.
- **The scanner** (`DiskGalleryCore/Scanning/Scanner.swift`) is a breadth-first directory work-queue. `execute(...)` derives `scanRoot`, then loops over `pendingDir` batches; for each child it builds a root-relative `rel` path, appends an `Entry` to `toInsert`, and (if it is a non-package, non-symlink directory) enqueues it for later descent.
- **`rel` is root-relative** (no leading slash): e.g. the folder at `/System/Volumes` has `rel == "System/Volumes"`.
- **Existing sibling helpers** to copy the style from: `DiskGalleryCore/Scanning/VolumeFilter.swift` and `DiskGalleryCore/Data/PathVisibility.swift`. Their tests: `DiskGalleryCoreTests/VolumeFilterTests.swift`, `DiskGalleryCoreTests/PathVisibilityTests.swift`.
- **Adding a new source file** to the Core target requires regenerating the Xcode project: `xcodegen generate` (run from repo root). The `.xcodeproj` is committed.
- **Running Core tests:** `xcodebuild test -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -40` (single build at a time — never run parallel xcodebuild against shared DerivedData).

---

## File Structure

- **Create** `DiskGalleryCore/Scanning/ScanExclusion.swift` — pure policy: is a given root-relative path excluded when scanning the boot volume? Sole responsibility: the exclusion decision.
- **Create** `DiskGalleryCoreTests/ScanExclusionTests.swift` — unit tests for the policy.
- **Modify** `DiskGalleryCore/Scanning/Scanner.swift` — compute `isBootVolume` once; `continue` on excluded paths before recording them.
- **Regenerate** `DiskGallery.xcodeproj` via `xcodegen generate` (picks up the two new files).

---

## Task 1: `ScanExclusion` policy (Core + tests)

**Files:**
- Create: `DiskGalleryCore/Scanning/ScanExclusion.swift`
- Test: `DiskGalleryCoreTests/ScanExclusionTests.swift`

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/ScanExclusionTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class ScanExclusionTests: XCTestCase {
    func testSystemVolumesExcludedOnBootVolume() {
        XCTAssertTrue(ScanExclusion.isExcluded(relPath: "System/Volumes", isBootVolume: true))
    }

    func testSystemVolumesNotExcludedOffBootVolume() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "System/Volumes", isBootVolume: false))
    }

    func testSystemFolderItselfIsKept() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "System", isBootVolume: true))
    }

    func testDescendantOfExcludedNodeIsNotMatched() {
        // Descendants are never generated in practice (parent is omitted), but the
        // policy matches the exact node only.
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "System/Volumes/Data/x", isBootVolume: true))
    }

    func testNonRootNodeOfSameNameIsKept() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "Users/me/System/Volumes", isBootVolume: true))
    }

    func testOrdinaryUserPathIsKept() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "Users/me/Photos/IMG.jpg", isBootVolume: true))
    }
}
```

- [ ] **Step 2: Add the new file to the test target and run to verify it fails**

Run:
```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate >/dev/null && \
xcodebuild test -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: FAIL — compile error `cannot find 'ScanExclusion' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `DiskGalleryCore/Scanning/ScanExclusion.swift`:

```swift
import Foundation

/// Decides whether a root-relative path should be skipped entirely during a scan.
/// Pure so the policy is unit-testable; the scanner supplies the boot-volume fact.
///
/// `/System/Volumes` re-mounts the APFS Data volume that the boot volume's firmlinks
/// (`/Applications`, `/Users`, `/Library`, …) already expose. Walking it double-counts
/// roughly half the disk. Excluding the single node prevents the entire subtree from
/// being recorded or descended.
public enum ScanExclusion {
    /// Root-relative paths skipped when scanning the boot volume. Exact match: once the
    /// node is omitted, no descendant path is ever generated.
    static let bootVolumeExclusions: Set<String> = ["System/Volumes"]

    public static func isExcluded(relPath: String, isBootVolume: Bool) -> Bool {
        isBootVolume && bootVolumeExclusions.contains(relPath)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run:
```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate >/dev/null && \
xcodebuild test -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: PASS — `ScanExclusionTests` all green, no other test regressions.

- [ ] **Step 5: Commit**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
git add DiskGalleryCore/Scanning/ScanExclusion.swift \
        DiskGalleryCoreTests/ScanExclusionTests.swift \
        DiskGallery.xcodeproj
git commit -m "feat(core): add ScanExclusion policy for boot-volume paths

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Wire `ScanExclusion` into the scanner

**Files:**
- Modify: `DiskGalleryCore/Scanning/Scanner.swift` (add `isBootVolume` near line 72; add `continue` guard near line 152)

**Context:** In `execute(...)`, `scanRoot` is created at:
```swift
let scanRoot = volumeURL.resolvingSymlinksInPath()
```
Inside the child loop, `rel` is built right before the `Entry` is appended:
```swift
let rel = pdir.relPath.isEmpty ? name : pdir.relPath + "/" + name
let id = nextId
nextId += 1
let ext = child.pathExtension.lowercased()
toInsert.append(Entry(id: id, snapshotId: snapshotId, parentId: pdir.entryId, name: name,
                      relPath: rel, isDir: isDir, logicalSize: logical, allocSize: alloc,
                      modifiedAt: values?.contentModificationDate, ext: ext.isEmpty ? nil : ext))
```

- [ ] **Step 1: Compute the boot-volume gate once**

In `Scanner.swift`, immediately after the `scanRoot` line, add `isBootVolume`:

Change:
```swift
let scanRoot = volumeURL.resolvingSymlinksInPath()
let now = Date()
```
to:
```swift
let scanRoot = volumeURL.resolvingSymlinksInPath()
let isBootVolume = scanRoot.path == "/"
let now = Date()
```

- [ ] **Step 2: Add the exclusion guard before the entry is recorded**

In the child loop, insert the guard immediately after `let rel = ...` and before `let id = nextId`:

Change:
```swift
let rel = pdir.relPath.isEmpty ? name : pdir.relPath + "/" + name
let id = nextId
```
to:
```swift
let rel = pdir.relPath.isEmpty ? name : pdir.relPath + "/" + name
if ScanExclusion.isExcluded(relPath: rel, isBootVolume: isBootVolume) { continue }
let id = nextId
```

The `continue` runs before insertion, enqueueing, and counting, so the excluded node is omitted entirely (it is never added to `toInsert`, never added to `toEnqueue`, and `filesSeen`/`bytesSeen` are untouched). `isBootVolume` is recomputed on every `run`, so resume is safe.

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
cd /Users/mrbarkan/Development/DISKGALLERY && \
xcodebuild build -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Run the full Core test suite (no regressions)**

Run:
```bash
cd /Users/mrbarkan/Development/DISKGALLERY && \
xcodebuild test -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | tail -40
```
Expected: PASS — all tests green, including `ScanExclusionTests` and `MutationGuardTests`.

- [ ] **Step 5: Commit**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
git add DiskGalleryCore/Scanning/Scanner.swift
git commit -m "fix(core): skip /System/Volumes on boot-volume scan (firmlink double-count)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: App build verification

**Files:** none (verification only)

**Context:** There is no app unit-test target; the app is verified by a clean build. This confirms the Core change links and the app still compiles.

- [ ] **Step 1: Clean-build the app target**

Run:
```bash
cd /Users/mrbarkan/Development/DISKGALLERY && \
xcodebuild build -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Manual rescan acceptance (human-run; record result)**

Run the built app, rescan the boot drive (`Macintosh HD`), and confirm:
- Reported **used bytes ≤ disk capacity** (no longer 611 GB on a 494 GB disk).
- No `System/Volumes` node appears under the drive root in the browser.
- The "duplicates / reclaimable" figure drops sharply (the firmlink twins are gone).

This step is verified by the user on real hardware (the scanner is exercised end-to-end here; the pure policy is already covered by `ScanExclusionTests`).

---

## Self-Review

**Spec coverage:**
- Decision 1 (exclude only `System/Volumes`) → Task 1 `bootVolumeExclusions = ["System/Volumes"]`.
- Decision 2 (gate on boot volume only) → Task 2 `isBootVolume = scanRoot.path == "/"`.
- Decision 3 (no migration) → no migration task exists; Task 3 step 2 is "rescan once."
- Decision 4 (omit entirely) → Task 2 `continue` placed before `toInsert.append`.
- Root cause / proof → Background section.
- Testing plan → Task 1 tests + Task 3 manual acceptance.
- Out of scope (no UI, no external-drive change, DMG rebuild is a separate delivery step) → respected; DMG rebuild intentionally not in this plan.

**Placeholder scan:** none — every code/command step is concrete.

**Type consistency:** `ScanExclusion.isExcluded(relPath:isBootVolume:)` and `bootVolumeExclusions` are used identically in Tasks 1 and 2. `isBootVolume` / `rel` match the exact identifiers in `Scanner.swift`.
