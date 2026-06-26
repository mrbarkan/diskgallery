# Gallery — Stage 0: Modern Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Physically remove the frozen Modern UI so Classic is the sole interface — making the navigation switch Classic-only so the Gallery destination (and future destinations) add cleanly, with **no behavior change to Classic**.

**Architecture:** Relocate the one Modern-housed view Classic still uses (`UnifiedComparePanel`), then delete `DiskGallery/Views/Modern/` + the OLED hero + Modern tokens, simplify `ContentView` to the Classic split only, collapse the now-dead `if modern { … } else { … }` branches in the 7 shared Classic views (keeping the Classic branch), and remove the `Skin`/`OLEDLayout`/pane-toggle concepts. Verified by build + the existing test suite staying green + a Classic smoke pass.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 15+, XcodeGen, XCTest.

## Global Constraints

- Swift 6.0, macOS 15.0.
- **No behavior change to Classic.** This is a pure removal of the unreachable Modern skin; every Classic view must look and act exactly as before.
- **Keep** `DiskGallery/Support/AccentPalette.swift` (the accent applies to Classic), the `Accent` enum, and `ThemeMigration` (legacy accent migration).
- New/renamed files require `xcodegen generate` (XcodeGen, explicit file refs; installed). Commit `DiskGallery.xcodeproj` when the file set changes.
- `MutationGuardTests` is unaffected (no scanning/execution change).
- Verification commands (from repo root):
  - App build: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
  - Core tests: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test`
  - Baseline: build green, **168** Core tests pass. Task 3 removes `Skin`/`OLEDLayout` tests, so the final count drops slightly — treat **"all green, 0 failures"** as the gate.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Branch: `feature/gallery` (spec already committed there).

## File Structure (net effect)

- **Relocated:** `Views/Modern/UnifiedCompare.swift` → `Views/UnifiedComparePanel.swift` (no Modern dependencies; defines `extension Coverage` + `UnifiedComparePanel`).
- **Deleted:** all other files in `DiskGallery/Views/Modern/` (20 files incl. `ModernWorkspace`, `ModernSidebar`, `ModernGlass`, the Modern pages, `ModernBackdrop`, `WindowAccessor`, `RevealInFinder`, `StatTiles`, `CoverageOLED`, `ModernControls`, `ModernTopbar`, `ModernPathBar`, `ModernBento`, `ModernInspector`, `ModernBrowser`); `DiskGallery/Views/OLEDDisplayView.swift`; `DiskGallery/Support/ModernTokens.swift`.
- **Edited:** `App/DiskGalleryApp.swift` (ContentView), the 7 shared views, `Theme/ThemeModel.swift`, `App/ThemeStore.swift`, `App/AppEnvironment.swift`, `App/ShortcutStore.swift`, `Support/AccentPalette.swift`, `DiskGalleryCoreTests/ThemeModelTests.swift`.

---

## Task 1: Relocate `UnifiedComparePanel` out of `Modern/`

**Files:**
- Rename: `DiskGallery/Views/Modern/UnifiedCompare.swift` → `DiskGallery/Views/UnifiedComparePanel.swift`

**Interfaces:**
- Produces: `UnifiedComparePanel` (unchanged) at a non-Modern path, so it survives the `Modern/` deletion. It's used by Classic's detail column (`DiskGalleryApp.swift:200`).

- [ ] **Step 1: Move the file (preserve history)**

```bash
git mv DiskGallery/Views/Modern/UnifiedCompare.swift DiskGallery/Views/UnifiedComparePanel.swift
```

(The file's contents need no change — it imports only SwiftUI + DiskGalleryCore and uses only Core types + `env`; it has zero Modern-helper dependencies.)

- [ ] **Step 2: Regenerate + build**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (the panel now lives outside `Modern/`; everything else still compiles).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(ui): relocate UnifiedComparePanel out of Modern/ (Classic uses it)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Delete the Modern UI; collapse dead branches in shared views

**Files:**
- Delete: everything under `DiskGallery/Views/Modern/` (UnifiedCompare already moved); `DiskGallery/Views/OLEDDisplayView.swift`; `DiskGallery/Support/ModernTokens.swift`
- Modify: `App/DiskGalleryApp.swift`; `Views/VolumeBrowserView.swift`; `Views/ActionPlanView.swift`; `Views/DuplicatesView.swift`; `Views/EntryDetailView.swift`; `Views/LibrarySidebarView.swift`; `Views/TransferPlannerView.swift`; `Views/SearchResultsView.swift`

**Interfaces:**
- Consumes: `UnifiedComparePanel` (relocated in Task 1).
- After this task, no file references `SpatialBackdrop`, `modernWindowChrome`, `modernListChrome`, `glassCard`, `modernRowTint`, `modernRowBackground`, or `ModernInspectorSection`. (`Skin`/`ThemeStore.skin`/`handlePaneToggle` remain temporarily — removed in Task 3.)

- [ ] **Step 1: Delete the Modern view files**

```bash
git rm DiskGallery/Views/Modern/*.swift DiskGallery/Views/OLEDDisplayView.swift DiskGallery/Support/ModernTokens.swift
```

- [ ] **Step 2: Simplify `ContentView` to the Classic split only**

In `DiskGallery/App/DiskGalleryApp.swift`, replace `ContentView.body`, `classicSplit`, `modernSplit`, and the `modern` computed property with a single Classic body. The new `ContentView` is:

```swift
struct ContentView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var systemAppearance = SystemAppearance()

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } content: {
            ContentColumn()
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        } detail: {
            detailColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        }
        .sheet(isPresented: Binding(get: { env.activeScan != nil }, set: { _ in })) {
            ScanProgressView()
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { env.errorMessage != nil },
                                    set: { if !$0 { env.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(env.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { env.upgradeFeature.map { FeatureBox($0) } },
                             set: { env.upgradeFeature = $0?.feature })) { box in
            UpgradeSheet(feature: box.feature).environment(env)
        }
        .sheet(item: Binding(get: { env.executionPrompt }, set: { env.executionPrompt = $0 })) { prompt in
            ExecutionConfirmView(prompt: prompt).environment(env)
        }
        .sheet(isPresented: Binding(get: { env.executionProgress != nil }, set: { _ in })) {
            if let p = env.executionProgress { ExecutionProgressView(progress: p).environment(env) }
        }
        .tint(env.theme.accent.palette.accent)
        .preferredColorScheme(env.theme.mode.resolvedScheme(systemAppearance))
        .frame(minWidth: 1040, minHeight: 680)
    }

    @ViewBuilder private var detailColumn: some View {
        if case .allDrives = env.selection {
            if let node = env.selectedUnifiedNode {
                ScrollView { UnifiedComparePanel(node: node) }
            } else {
                ContentUnavailableView("Compare copies", systemImage: "rectangle.on.rectangle",
                                       description: Text("Select an item to compare its copies across drives."))
            }
        } else {
            EntryDetailView()
        }
    }
}
```

> Verify against the current file before pasting: keep any sheet/alert that exists today and drop only the Modern bits (`if modern { modernSplit } else { classicSplit }`, `.background { if modern { SpatialBackdrop(...) } }`, `.modernWindowChrome(modern)`, the `modern` property, and `modernSplit`). The set of `.sheet`/`.alert` modifiers above reflects the scan + error + upgrade + execution sheets added across prior milestones — match the file's actual current set.

- [ ] **Step 3: Collapse the dead Modern branches in the 7 shared views**

Build will now fail with references to deleted Modern helpers. In each file below, remove the `modern` plumbing, **keeping the Classic branch** (these branches are already dead — `modern` is always false). Use the compiler to find every site; the known sites are:

- `Views/VolumeBrowserView.swift` — remove `private var modern` (line ~140) and `.modernListChrome(modern)` (line ~152).
- `Views/ActionPlanView.swift` — remove `private var modern` (line ~8), `.modernListChrome(modern)` (line ~38), and collapse `if modern { pills.glassCard(...) } else { pills }` (line ~54) to just `pills`.
- `Views/DuplicatesView.swift` — remove `private var modern` (line ~6), the two `.glassCard()` calls (lines ~16, ~21 — keep the underlying `setsList`/`membersPanel`), and the two `.modernListChrome(modern)` (lines ~69, ~112).
- `Views/EntryDetailView.swift` — remove both `private var modern` (lines ~30, ~147); collapse the `if modern { … ModernInspectorSection … glassCard }` inspector branches to their Classic equivalents (lines ~89-104, ~156-163); and delete the `ModernInspectorSection` struct definition (line ~184, now unused).
- `Views/LibrarySidebarView.swift` — remove `private var modern` (line ~17), the `.modernRowTint(...)`/`.listRowBackground(modern ? … : nil)` on rows (e.g. lines ~26, ~28, ~148), the `.modernListChrome(modern)` (line ~68), the `let modern = …` in `DriveRow` (line ~303), and the `modernRowBackground(for:)` (line ~107) + `modernRowTint(...)` (line ~368) helper definitions.
- `Views/TransferPlannerView.swift` — remove `private var modern` (line ~35) and `.modernListChrome(modern)` (line ~129).
- `Views/SearchResultsView.swift` — remove `private var modern` (line ~9) and `.modernListChrome(modern)` (line ~26).

Method: after Step 1–2, run the build repeatedly; each error points at a Modern reference — delete the modifier/branch (keep Classic) until it compiles. Do **not** touch `ThemeStore.skin`, `AppEnvironment.handlePaneToggle`, or the `Skin` enum yet (Task 3).

- [ ] **Step 4: Regenerate, build, test, smoke**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.
Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 168 tests (unchanged — Core not touched yet).
Smoke: launch the app; confirm it opens in the unchanged Classic 3-column layout, the sidebar/browser/duplicates/search/organize/all-drives/tagging all work, and there is no visual change.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(ui): remove the frozen Modern skin; Classic is the sole UI

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Remove the `Skin` / `OLEDLayout` / pane-toggle concepts

**Files:**
- Modify: `DiskGalleryCore/Theme/ThemeModel.swift`; `App/ThemeStore.swift`; `App/AppEnvironment.swift`; `App/ShortcutStore.swift`; `Support/AccentPalette.swift`; Test: `DiskGalleryCoreTests/ThemeModelTests.swift`

**Interfaces:**
- After this task, `Skin`, `OLEDLayout`, `OLEDColor`, `ThemeStore.skin`, `ThemeStore.oledLayout`, `cycleOLEDLayout`, `AppEnvironment.handlePaneToggle`, and `ShortcutStore.paneToggle*` no longer exist. `Accent`, `AccentPalette`, `ThemeMigration`, and `ThemeStore.{accent,mode}` remain.

- [ ] **Step 1: Remove `Skin` and `OLEDLayout` from Core**

In `DiskGalleryCore/Theme/ThemeModel.swift`, delete the `Skin` enum (lines 3-9) and the `OLEDLayout` enum (lines 18-35). Keep `Accent` and `ThemeMigration`.

- [ ] **Step 2: Trim `ThemeModelTests`**

In `DiskGalleryCoreTests/ThemeModelTests.swift`: in `testRawValuesAreStableForPersistence`, delete the `Skin.allCases` and `OLEDLayout.allCases` assertions (keep the `Accent` one); delete `testGaugeLayoutRemoved` entirely; in `testDisplayNames`, delete the `Skin.*.name` and `OLEDLayout.*.name` assertions (keep `Accent.violet.name`). The migration tests stay unchanged.

- [ ] **Step 3: Remove skin/OLED from `ThemeStore`**

In `DiskGallery/App/ThemeStore.swift`: delete the `skin` property (line 24), the `oledLayout` property (line 27), the `skin = .classic` init line (~32), the `oledLayout = …` init line (~34), and the `cycleOLEDLayout()` method (lines 45-50). Update the header comment (line 5) to drop the Skin/OLEDLayout mention. Keep `accent` + `mode` + the accent migration.

- [ ] **Step 4: Remove the pane-toggle (Modern focus-mode) plumbing**

In `DiskGallery/App/AppEnvironment.swift`: in `installKeyboardMonitor` (line ~151), change `self.handlePaneToggle(characters: characters) || self.handleShortcut(characters: characters)` to just `self.handleShortcut(characters: characters)`; delete the `handlePaneToggle(characters:)` method (lines ~160-163, which referenced `theme.skin == .modern`).
In `DiskGallery/App/ShortcutStore.swift`: delete the pane-toggle members — `paneToggleKeyKey` (line ~78), `paneToggleKey` (lines ~83-88), `paneToggleDisplay` (~95), `setPaneToggleKey` (~97-102), `setPaneToggleToTab` (~105), `matchesPaneToggle` (~108-109), and the `paneToggleKey = "tab"` reset line (~126).

- [ ] **Step 5: Remove the orphaned `OLEDColor`**

In `DiskGallery/Support/AccentPalette.swift`, delete the `OLEDColor` enum (line ~31, only used by the now-deleted OLED view). Keep the `AccentPalette` struct and the `Accent.palette` mapping.

- [ ] **Step 6: Regenerate, build, test, smoke**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.
Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green (count drops by the removed Skin/OLED assertions — confirm 0 failures).
Smoke: launch; Settings → Appearance shows Mode + Accent (no Skin/OLED); the app is visually unchanged.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: remove the vestigial Skin/OLED/pane-toggle concepts (Classic-only)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Stage 0):** delete `Modern/` + OLED + ModernTokens (Task 2); relocate `UnifiedComparePanel` (Task 1); keep `AccentPalette` (Global Constraints + Task 3 keeps it); collapse Modern branches in shared views (Task 2 Step 3); remove the `Skin` concept (Task 3); `ContentColumn` becomes the sole router (Task 2 Step 2 leaves `ContentColumn` intact and removes `ModernWorkspace`). ✓ The "no behavior change to Classic" requirement is the gate (build + tests + smoke each task).

**Placeholder scan:** the deletion lists and edit sites are concrete (file:line from the current grep). Task 2 Step 3 explicitly uses compiler-driven removal for the long tail — that's the correct method for a pure removal, not a placeholder; every known site is enumerated. The ContentView body is shown in full with a "match the file's actual current sheet set" caveat (sheets were added across milestones; the implementer reconciles against the live file).

**Type consistency:** `UnifiedComparePanel` (Task 1) is referenced by the new `ContentView.detailColumn` (Task 2). After Task 2, only `ThemeStore.skin`/`AppEnvironment.handlePaneToggle` reference `Skin`, both removed in Task 3 — so Task 3's `Skin` enum deletion compiles. `Accent`/`AccentPalette`/`ThemeMigration` are preserved throughout.

**Note (subagent-driven):** Tasks 2 and 3 are each "green at the end" units (intermediate states won't compile mid-deletion); dispatch each as one implementer task. Task 1 is independently green.
