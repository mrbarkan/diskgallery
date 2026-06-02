# Local-Drive Filtering & Hide-Hidden-Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) Stop listing network/cloud volumes as local external drives; (2) add a "Hide hidden files" view option (on by default) that hides dotfiles in the browser, search, and duplicates.

**Architecture:** Two pure, unit-tested Core helpers — `VolumeFilter.shouldList(...)` (the drive-inclusion decision) and `PathVisibility.isHidden(relPath:)` (any path component starting with "."). The app's `VolumeService` uses `VolumeFilter` + the `volumeIsLocalKey` resource value to drop non-local mounts. A `@MainActor @Observable ViewPrefsStore` holds `hideHidden` (persisted, default true); the browser, search, and duplicates views filter their rows through `PathVisibility` when it's on. A Settings toggle controls it.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), AppKit, GRDB, XCTest, XcodeGen.

**Conventions:**
- Core tests: `xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/<Class>`.
- App build: `xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS'`.
- `xcodegen generate` after adding files.
- Branch: `feat/local-drives-and-hidden` off `main` before Task 1.

---

## File Structure
- **Create** `DiskGalleryCore/Scanning/VolumeFilter.swift` — pure drive-inclusion decision.
- **Create** `DiskGalleryCore/Data/PathVisibility.swift` — pure dotfile check.
- **Create** `DiskGalleryCoreTests/VolumeFilterTests.swift`, `DiskGalleryCoreTests/PathVisibilityTests.swift`.
- **Modify** `DiskGallery/Volumes/VolumeService.swift` — add `volumeIsLocalKey`, filter via `VolumeFilter`.
- **Create** `DiskGallery/App/ViewPrefsStore.swift` — `hideHidden` persisted pref.
- **Modify** `DiskGallery/App/AppEnvironment.swift` — add `let viewPrefs = ViewPrefsStore()`.
- **Modify** `DiskGallery/Views/SettingsView.swift` — a "Files" tab with the toggle.
- **Modify** `DiskGallery/Views/Modern/ModernBrowser.swift`, `ModernSearchPage.swift`, `ModernDuplicatesPage.swift` — filter rows.

---

## Task 0: Branch

- [ ] **Step 1**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
git checkout main && git checkout -b feat/local-drives-and-hidden && git status
```

Expected: on `feat/local-drives-and-hidden`, clean tree.

---

## Task 1: Core — `VolumeFilter` drive-inclusion decision

**Files:**
- Create: `DiskGalleryCore/Scanning/VolumeFilter.swift`
- Test: `DiskGalleryCoreTests/VolumeFilterTests.swift`

The app should list a volume only when it is **local** (drops SMB/AFP/NFS network mounts and most cloud file-providers, which report `isLocal == false`) AND it is an external drive (removable, or not internal). The internal boot disk is excluded (local but internal & non-removable).

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/VolumeFilterTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class VolumeFilterTests: XCTestCase {
    func testExternalUSBDriveIsListed() {
        // local, removable, not internal → yes
        XCTAssertTrue(VolumeFilter.shouldList(isLocal: true, isRemovable: true, isInternal: false))
    }

    func testExternalNonRemovableLocalDriveIsListed() {
        // e.g. an external SSD that isn't "removable" but is external (not internal)
        XCTAssertTrue(VolumeFilter.shouldList(isLocal: true, isRemovable: false, isInternal: false))
    }

    func testNetworkDriveIsExcluded() {
        // not local → never listed, even though it's "external"
        XCTAssertFalse(VolumeFilter.shouldList(isLocal: false, isRemovable: false, isInternal: false))
    }

    func testInternalBootDiskIsExcluded() {
        // local but internal & non-removable → not an external drive
        XCTAssertFalse(VolumeFilter.shouldList(isLocal: true, isRemovable: false, isInternal: true))
    }

    func testRemovableInternalIsListed() {
        // local, removable (e.g. an internal SD reader slot) → treat as external
        XCTAssertTrue(VolumeFilter.shouldList(isLocal: true, isRemovable: true, isInternal: true))
    }
}
```

- [ ] **Step 2: Run, expect FAIL ("cannot find 'VolumeFilter'")**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/VolumeFilterTests 2>&1 | tail -15
```

- [ ] **Step 3: Implement**

Create `DiskGalleryCore/Scanning/VolumeFilter.swift`:

```swift
import Foundation

/// Decides whether a mounted volume should appear as a catalog-able external drive.
/// Pure so the policy is unit-testable; the app supplies the resource-value facts.
public enum VolumeFilter {
    /// List a volume only when it is **local** (excludes network shares and most cloud
    /// file-providers, which report `isLocal == false`) AND it is external — i.e.
    /// removable, or simply not the internal disk.
    public static func shouldList(isLocal: Bool, isRemovable: Bool, isInternal: Bool) -> Bool {
        guard isLocal else { return false }
        return isRemovable || !isInternal
    }
}
```

- [ ] **Step 4: Run, expect PASS (5 tests)**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/VolumeFilterTests 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Scanning/VolumeFilter.swift DiskGalleryCoreTests/VolumeFilterTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): add VolumeFilter (local + external) drive-inclusion rule"
```

---

## Task 2: Core — `PathVisibility.isHidden`

**Files:**
- Create: `DiskGalleryCore/Data/PathVisibility.swift`
- Test: `DiskGalleryCoreTests/PathVisibilityTests.swift`

A relPath is hidden if ANY of its components starts with ".". This catches both a dotfile (`.DS_Store`) and a file inside a hidden folder (`.Trash/x.jpg`).

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/PathVisibilityTests.swift`:

```swift
import XCTest
@testable import DiskGalleryCore

final class PathVisibilityTests: XCTestCase {
    func testPlainFileIsVisible() {
        XCTAssertFalse(PathVisibility.isHidden(relPath: "Photos/IMG_0001.jpg"))
    }

    func testDotfileIsHidden() {
        XCTAssertTrue(PathVisibility.isHidden(relPath: ".DS_Store"))
    }

    func testFileInsideHiddenFolderIsHidden() {
        XCTAssertTrue(PathVisibility.isHidden(relPath: ".Trashes/old.jpg"))
        XCTAssertTrue(PathVisibility.isHidden(relPath: "Docs/.git/config"))
    }

    func testEmptyPathIsVisible() {
        XCTAssertFalse(PathVisibility.isHidden(relPath: ""))
    }

    func testLeadingSlashHandled() {
        XCTAssertTrue(PathVisibility.isHidden(relPath: "/.config/x"))
        XCTAssertFalse(PathVisibility.isHidden(relPath: "/Movies/clip.mov"))
    }
}
```

- [ ] **Step 2: Run, expect FAIL ("cannot find 'PathVisibility'")**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/PathVisibilityTests 2>&1 | tail -15
```

- [ ] **Step 3: Implement**

Create `DiskGalleryCore/Data/PathVisibility.swift`:

```swift
import Foundation

/// Decides whether a path is "hidden" in the macOS sense — any component begins with a
/// dot. Pure so it's testable and reusable by every view that filters hidden files.
public enum PathVisibility {
    public static func isHidden(relPath: String) -> Bool {
        relPath.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
```

- [ ] **Step 4: Run, expect PASS (5 tests)**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/PathVisibilityTests 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Data/PathVisibility.swift DiskGalleryCoreTests/PathVisibilityTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): add PathVisibility.isHidden dotfile check"
```

---

## Task 3: App — apply `VolumeFilter` + `volumeIsLocalKey` in VolumeService

**Files:**
- Modify: `DiskGallery/Volumes/VolumeService.swift`

- [ ] **Step 1: Add the local key and use VolumeFilter**

In `DiskGallery/Volumes/VolumeService.swift`, update the resource keys to include `.volumeIsLocalKey`:

```swift
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeNameKey,
        ]
```

Then replace the inclusion test in the `for url in urls` loop. Change:

```swift
            let removable = (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false)
            let isInternal = values?.volumeIsInternal ?? true
            if removable || !isInternal {
                mounted.append(Mounted(url: url, info: info))
            }
```

to:

```swift
            let removable = (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false)
            let isInternal = values?.volumeIsInternal ?? true
            let isLocal = values?.volumeIsLocal ?? true
            if VolumeFilter.shouldList(isLocal: isLocal, isRemovable: removable, isInternal: isInternal) {
                mounted.append(Mounted(url: url, info: info))
            }
```

Note: `byKey` (the `urlByKey` lookup used to resolve a stored drive's mount point) should keep mapping ALL volumes — do NOT filter it — so reveal/scan-resume of an already-known drive still resolves. Only the `mounted` list (the user-facing external-drive list) is filtered. Leave the `byKey[info.uuid ?? info.name] = url` line as-is.

- [ ] **Step 2: Build**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add DiskGallery/Volumes/VolumeService.swift DiskGallery.xcodeproj
git commit -m "fix(app): exclude non-local (network/cloud) volumes from the drive list"
```

---

## Task 4: App — `ViewPrefsStore` + wire into AppEnvironment

**Files:**
- Create: `DiskGallery/App/ViewPrefsStore.swift`
- Modify: `DiskGallery/App/AppEnvironment.swift`

- [ ] **Step 1: Create the store**

Create `DiskGallery/App/ViewPrefsStore.swift`:

```swift
import Foundation
import Observation

/// User view preferences that affect what the catalog shows (not what it scans).
/// Persisted across launches. `hideHidden` defaults to ON so dotfiles/.folders don't
/// clutter the browser, search, and duplicate views.
@MainActor
@Observable
final class ViewPrefsStore {
    private let defaults: UserDefaults
    private let hideHiddenKey = "view.hideHidden"

    var hideHidden: Bool {
        didSet { defaults.set(hideHidden, forKey: hideHiddenKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default ON when unset.
        hideHidden = defaults.object(forKey: hideHiddenKey) as? Bool ?? true
    }
}
```

- [ ] **Step 2: Wire into AppEnvironment**

In `DiskGallery/App/AppEnvironment.swift`, add to the stored properties (near `let recentSearches = RecentSearchStore()`):

```swift
    let viewPrefs = ViewPrefsStore()
```

- [ ] **Step 3: Build**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add DiskGallery/App/ViewPrefsStore.swift DiskGallery/App/AppEnvironment.swift DiskGallery.xcodeproj
git commit -m "feat(app): add ViewPrefsStore (hideHidden, default on)"
```

---

## Task 5: App — Settings toggle + wire the filter into the three views

**Files:**
- Modify: `DiskGallery/Views/SettingsView.swift`
- Modify: `DiskGallery/Views/Modern/ModernBrowser.swift`
- Modify: `DiskGallery/Views/Modern/ModernSearchPage.swift`
- Modify: `DiskGallery/Views/Modern/ModernDuplicatesPage.swift`

- [ ] **Step 1: Add a "Files" settings tab with the toggle**

In `DiskGallery/Views/SettingsView.swift`, add a tab to the `TabView` (after the Shortcuts tab):

```swift
            FilesSettings()
                .tabItem { Label("Files", systemImage: "doc") }
```

And add this view (near the other `*Settings` structs in the same file):

```swift
struct FilesSettings: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var prefs = env.viewPrefs
        Form {
            Section {
                Toggle("Hide hidden files and folders", isOn: $prefs.hideHidden)
            } footer: {
                Text("Hides dotfiles (names starting with “.”) such as .DS_Store and .Trashes from the browser, search, and duplicates. Files are still catalogued — only hidden from view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 2: Filter the browser children**

In `DiskGallery/Views/Modern/ModernBrowser.swift`, the list iterates `ForEach(children)`. Add a computed `visibleChildren` to the same struct (it has `@Environment(AppEnvironment.self) private var env`) and use it:

Add the property:

```swift
    private var visibleChildren: [Entry] {
        env.viewPrefs.hideHidden ? children.filter { !PathVisibility.isHidden(relPath: $0.name) } : children
    }
```

(Browser children are direct entries, so `$0.name` is the right component to test.)

Then change `ForEach(children) { entry in` to `ForEach(visibleChildren) { entry in`.

- [ ] **Step 3: Filter search results**

In `DiskGallery/Views/Modern/ModernSearchPage.swift`, the results list iterates `ForEach(results)`. The view has `@Environment(AppEnvironment.self) private var env`. Add a computed property:

```swift
    private var visibleResults: [SearchResult] {
        env.viewPrefs.hideHidden ? results.filter { !PathVisibility.isHidden(relPath: $0.relPath) } : results
    }
```

Change `ForEach(results) { r in` to `ForEach(visibleResults) { r in`. Also update the header count and the empty check to use `visibleResults` (replace `results.count` in the `ModernCardHeader` meta and `results.isEmpty` in the list with `visibleResults.count` / `visibleResults.isEmpty`).

- [ ] **Step 4: Filter duplicate sets**

In `DiskGallery/Views/Modern/ModernDuplicatesPage.swift`, `DupSetsCard` has a `visibleSets` computed property that already filters by file-type category. Extend it to also drop hidden sets. `DupSetsCard` must read `env` — confirm it has `@Environment(AppEnvironment.self) private var env`; if not, add it. Change:

```swift
    private var visibleSets: [DuplicateSet] {
        let category = FileCategory(rawValue: filter) ?? .all
        return sets.filter { category.matches(filename: $0.name) }
    }
```

to:

```swift
    private var visibleSets: [DuplicateSet] {
        let category = FileCategory(rawValue: filter) ?? .all
        return sets.filter {
            category.matches(filename: $0.name)
                && !(env.viewPrefs.hideHidden && PathVisibility.isHidden(relPath: $0.name))
        }
    }
```

(`DuplicateSet.name` is the filename; a hidden dup like `.DS_Store` is dropped when the pref is on.)

- [ ] **Step 5: Build**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. If `DupSetsCard` lacks `env`, add `@Environment(AppEnvironment.self) private var env` to that struct.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(app): Hide hidden files toggle across browser, search, duplicates"
```

---

## Task 6: Final verification

- [ ] **Step 1: Full Core suite**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY && xcodegen generate
xcodebuild test -project DiskGallery.xcodeproj -scheme DiskGalleryCore -destination 'platform=macOS' 2>&1 | grep -aE "Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" | tail -2
```

Expected: `** TEST SUCCEEDED **`, 76 + 10 new = 86 tests, 0 failures.

- [ ] **Step 2: App build**

```bash
cd /Users/mrbarkan/Development/DISKGALLERY
xcodebuild build -project DiskGallery.xcodeproj -scheme DiskGallery -destination 'platform=macOS' 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

## Manual verification (after merge)
- Mount a network share / cloud drive → it no longer appears in the drive list; a USB/Thunderbolt drive still does.
- Settings → Files → toggle "Hide hidden files": browser, search, and duplicates show/hide `.DS_Store` etc. accordingly; default is hidden.
