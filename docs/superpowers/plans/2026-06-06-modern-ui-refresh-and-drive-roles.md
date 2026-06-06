# Modern UI Refresh + Drive Roles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline, chosen) to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Polish the Modern shell (remove OLED Gauge, fold drive info into the OLED, relocate the path bar, make the side panes collapsible) and add a non-destructive **drive-roles** system that makes the Organize plan reflect intent.

**Architecture:** Items 1–4 are Modern-skin view edits. Item 5 adds a pure `DriveRole` enum + role-aware ranking in `OrganizationPlanner` (Core, TDD), a GRDB `DriveRolesService` mirroring `AnnotationStore`, an app-layer label store, and Settings/right-click surfaces. Verify Core via `xcodebuild test -scheme DiskGalleryCore`; verify app via `xcodebuild -scheme DiskGallery build`. Regenerate the project with `xcodegen generate` whenever files are added.

**Tech Stack:** Swift 6, SwiftUI (macOS 15), GRDB (behind `Catalog`), XcodeGen.

---

## Phase A — Modern UI (items 1–4)

### Task A1: Remove OLED Gauge layout (item 1)

**Files:**
- Modify: `DiskGalleryCore/Theme/ThemeModel.swift` (`OLEDLayout`)
- Modify: `DiskGallery/Views/OLEDDisplayView.swift` (delete `gauge`, `gaugeSubtitle`, switch arm, Gauge preview)
- Modify: `DiskGalleryCoreTests/ThemeModelTests.swift`

- [ ] **Step 1 (RED):** Update `ThemeModelTests` to expect `OLEDLayout.allCases == [.telemetry, .minimal, .actionDetail]` and names "Telemetry"/"Minimal"/"Action". Add a test that `OLEDLayout(rawValue: "gauge") == nil`.
- [ ] **Step 2:** Run `xcodebuild test -scheme DiskGalleryCore -destination 'platform=macOS' -only-testing:DiskGalleryCoreTests/ThemeModelTests` — expect FAIL.
- [ ] **Step 3:** In `ThemeModel.swift` change `case telemetry, gauge, minimal` → `case telemetry, minimal, actionDetail` (actionDetail already exists — ensure no duplicate; if `actionDetail` is a separate case keep order `telemetry, minimal, actionDetail`). Remove `case .gauge:` from the `name` switch. Ensure `cycleOLEDLayout()` skips `.actionDetail` on drive pages exactly as today (it cycles the non-actionDetail set) — confirm by reading the method.
- [ ] **Step 4:** In `OLEDDisplayView.swift` remove the `case .gauge: gauge` arm, the `gauge` computed view, `gaugeSubtitle`, and the `#Preview("Gauge · …")` blocks. Add a decode guard where layout is loaded from prefs: unknown/`gauge` → `.telemetry` (find where `oledLayout` is persisted in `ThemeModel`; map missing case to `.telemetry`).
- [ ] **Step 5:** Run the Core test (PASS) and `xcodebuild -scheme DiskGallery build` (BUILD SUCCEEDED).
- [ ] **Step 6:** Commit `feat(oled): remove Gauge layout`.

### Task A2: Fold drive info into the OLED Telemetry layout (item 2)

**Files:**
- Modify: `DiskGallery/Views/OLEDDisplayView.swift` (add hardware row)
- Modify: `DiskGallery/Views/Modern/ModernWorkspace.swift` (`VolumeBentoWorkspace`: stop rendering strip, pass hardware)
- Delete: `DiskGallery/Views/Modern/ModernHardwareStrip.swift`

- [ ] **Step 1:** Add to `OLEDDisplayView` a property `var hardware: DriveHardwareDisplay? = nil`. After `OLEDBottomBar(...)` in the `telemetry` view, add (only when `hardware != nil`):
  - a 1px hairline `Rectangle().fill(OLEDColor.ink.opacity(0.10)).frame(height: 1)`
  - an `HStack` of plain monospace text (no Capsule/material): `Image(systemName: hw.busIcon)`, then `Text(hw.oledLine)` styled `font(.system(size: 10, design: .monospaced)).foregroundStyle(OLEDColor.ink2)`, `Spacer()`, `Text("detected \(Format.relativeDate(hw.hardware.capturedAt))")` in `OLEDColor.ink3`.
  - Add a computed `oledLine` to `DriveHardwareDisplay` (or inline here) joining `[generationLabel, speedText, mediumText, connectionText, brandModel].compactMap{$0}` with " · ".
- [ ] **Step 2:** In `VolumeBentoWorkspace.body` remove the `if let hardware = … ModernHardwareStrip(...)` block; pass `hardware: summary.hardware.map(DriveHardwareDisplay.init)` into `OLEDDisplayView(...)`.
- [ ] **Step 3:** Delete `ModernHardwareStrip.swift`; run `xcodegen generate`.
- [ ] **Step 4:** `xcodebuild -scheme DiskGallery build` → SUCCEEDED.
- [ ] **Step 5:** Commit `feat(oled): show drive info inside the OLED`.

### Task A3: Relocate the path bar above the browser (item 3)

**Files:**
- Create: `DiskGallery/Views/Modern/ModernPathBar.swift`
- Modify: `DiskGallery/Views/Modern/ModernTopbar.swift` (drop breadcrumbs)
- Modify: `DiskGallery/Views/Modern/ModernWorkspace.swift` (insert path bar; topbar no crumbs)

- [ ] **Step 1:** Create `ModernPathBar` — a thin glass bar: `HStack` with leading `Image(systemName:"externaldrive")`, then the navigable crumb buttons (move the existing `crumbBar` logic from `ModernTopbar` here, including `onCrumb`). Props: `crumbs: [String]`, `onCrumb: (Int)->Void`. Style: `.regularMaterial` capsule/rounded-rect, height ~30, matching the deleted hardware strip's chrome.
- [ ] **Step 2:** In `ModernTopbar`, remove `crumbBar`, `leadingIcon`, `crumbs`, `onCrumb` (and their usage in `body`); body becomes `HStack { Spacer(); searchPill; if showVolumeActions { cluster } }`. Update all call sites that pass `crumbs:`/`onCrumb:`/`leadingIcon:` — for the volume workspace, stop passing them here.
- [ ] **Step 3:** In `VolumeBentoWorkspace.body`, after the OLED + IncompleteBanner and before `bento`, insert `ModernPathBar(crumbs: crumbs, onCrumb: { i in nav.path = Array(nav.path.prefix(i)) })`. The drive name is `crumbs[0]` (already `[summary.name] + nav.path…`), so the name lives only here.
- [ ] **Step 4:** Other `ModernTopbar` call sites (`ModernActionPlanPage`, `ModernDuplicatesPage`, `ModernTransferPage`, `ModernOrganizePage`, `ModernSearchPage`) go through `ModernPageScaffold`. Decide: keep their crumbs by giving `ModernPageScaffold` its own lightweight crumb display (it already shows crumbs) — confirm those pages don't break. If `ModernTopbar` is only used by the scaffold + volume workspace, ensure the scaffold renders crumbs itself (it may already). Read `ModernBento.swift`/`ModernPageScaffold` and adjust so library pages still show their title crumbs.
- [ ] **Step 5:** `xcodegen generate`; `xcodebuild -scheme DiskGallery build` → SUCCEEDED.
- [ ] **Step 6:** Commit `feat(modern): move path bar above the browser`.

### Task A4: Collapsible side panes / focus mode (item 4)

**Files:**
- Modify: `DiskGallery/App/ViewPrefsStore.swift` (persist collapse flags)
- Modify: `DiskGallery/App/ShortcutStore.swift` (add `focusBrowser` command + default Tab) OR add a dedicated key pref
- Modify: `DiskGallery/App/AppEnvironment.swift` (keyboard monitor: Tab toggles focus, ignore in text fields)
- Modify: `DiskGallery/Views/Modern/ModernWorkspace.swift` (`bento` recomputes from visibility)
- Modify: tiles/inspector to add a collapse chevron (`StatTiles.swift`, `ModernInspector.swift`)
- Modify: `DiskGallery/Views/SettingsView.swift` (Shortcuts tab shows the focus binding)

- [ ] **Step 1:** In `ViewPrefsStore` add persisted `Bool`s: `showReclaimable`, `showActionPlan`, `showInspector` (default true) with UserDefaults keys `view.show.reclaimable` etc., and a derived helper `focusMode` (all three false) plus `toggleFocusMode()` that flips them together (remembering prior state to restore: store `preFocusVisibility`). Simpler: add `focusMode: Bool` + the three individual flags; `Tab` sets `focusMode.toggle()` which hides all three when true; when false, restore the three individual flags. Persist `focusMode` and the three flags.
- [ ] **Step 2:** Add a bindable focus shortcut. Since `ShortcutAction` is single-character/tagging, add a separate stored key in `ShortcutStore`: `var paneToggleKey: String` default `"\t"` representation — but Tab isn't a printable char. Instead store an enum `PaneToggleKey` (tab/other) or just handle Tab in the monitor and expose a read-only "Tab" row in Settings → Shortcuts marked customizable later. **Decision for this plan:** add `focusShortcut` to `ShortcutStore` as a `KeyEquivalent`-style record persisted as a string token ("tab", or a letter). Default "tab". Settings shows a row "Toggle side panes" with the current binding.
- [ ] **Step 3:** In `AppEnvironment` keyboard monitor, when the pressed key matches the focus shortcut (Tab) AND the first responder is not an `NSTextView`/`NSTextField` (check `NSApp.keyWindow?.firstResponder`), call `viewPrefs.toggleFocusMode()` and consume the event.
- [ ] **Step 4:** In `VolumeBentoWorkspace.bento`, compute the layout from `env.viewPrefs` flags:
  - `showInspector` false → right column width 0; left column full width.
  - both bottom tiles hidden → browser fills the left column height.
  - Use conditional `if env.viewPrefs.showInspector { ModernInspectorCard()… }`, and for the bottom `HStack` include only visible tiles; if none visible, give the browser the full height.
- [ ] **Step 5:** Add a small chevron button to `ReclaimableTile`, `ActionPlanTile` (in `StatTiles.swift`) and `ModernInspectorCard` that sets the corresponding `env.viewPrefs.show* = false`. Provide a way to bring hidden ones back: a thin "show panes" affordance when collapsed (e.g. a small overlay button), plus Tab. Keep minimal.
- [ ] **Step 6:** Settings → Shortcuts: add a row for "Toggle side panes" showing the focus binding (read/edit) using the same `ShortcutRow` pattern.
- [ ] **Step 7:** `xcodegen generate` (if files added); `xcodebuild -scheme DiskGallery build` → SUCCEEDED. Manual: Tab collapses/restores; chevrons hide individually; survives relaunch; Tab does nothing while typing in Search.
- [ ] **Step 8:** Commit `feat(modern): collapsible side panes with Tab focus mode`.

---

## Phase B — Drive roles (item 5)

### Task B1: `DriveRole` enum (Core, TDD)

**Files:**
- Create: `DiskGalleryCore/Planning/DriveRole.swift`
- Create: `DiskGalleryCoreTests/DriveRoleTests.swift`

- [ ] **Step 1 (RED):** Test:
```swift
import XCTest
@testable import DiskGalleryCore
final class DriveRoleTests: XCTestCase {
    func testCasesAndDefaultLabels() {
        XCTAssertEqual(DriveRole.allCases.count, 7)
        XCTAssertEqual(DriveRole.localSystem.defaultLabel, "Local / System")
        XCTAssertEqual(DriveRole.mainBackup.defaultLabel, "Main Backup")
        XCTAssertEqual(DriveRole.neutral.defaultLabel, "Neutral")
    }
    func testDestinationEligibility() {
        // Local/System is never a destination
        XCTAssertFalse(DriveRole.localSystem.canReceive(.backup))
        XCTAssertFalse(DriveRole.localSystem.canReceive(.move))
        // Backup goes to backup roles, not Work
        XCTAssertTrue(DriveRole.mainBackup.canReceive(.backup))
        XCTAssertFalse(DriveRole.work.canReceive(.backup))
        // Move never onto a backup drive
        XCTAssertFalse(DriveRole.mainBackup.canReceive(.move))
        XCTAssertTrue(DriveRole.archive.canReceive(.move))
        XCTAssertTrue(DriveRole.work.canReceive(.move))
    }
    func testRoleRank() {
        XCTAssertGreaterThan(DriveRole.mainBackup.rank(for: .backup), DriveRole.fallbackBackup.rank(for: .backup))
        XCTAssertGreaterThan(DriveRole.archive.rank(for: .move), DriveRole.main.rank(for: .move))
    }
}
```
- [ ] **Step 2:** Run `-only-testing:DiskGalleryCoreTests/DriveRoleTests` → FAIL.
- [ ] **Step 3 (GREEN):** Implement:
```swift
public enum DriveRole: String, CaseIterable, Sendable, Codable {
    case localSystem, main, work, mainBackup, fallbackBackup, archive, neutral
    public var defaultLabel: String {
        switch self {
        case .localSystem: return "Local / System"
        case .main: return "Main"
        case .work: return "Work / Scratch"
        case .mainBackup: return "Main Backup"
        case .fallbackBackup: return "Fallback Backup"
        case .archive: return "Archive / Cold"
        case .neutral: return "Neutral"
        }
    }
    /// Can a drive with this role receive items tagged `tag` as a destination?
    public func canReceive(_ tag: Tag) -> Bool { rank(for: tag) > 0 || self == .neutral }
    /// Higher = more preferred destination for `tag`. 0 = not eligible (except neutral handled in canReceive).
    public func rank(for tag: Tag) -> Int {
        switch (tag, self) {
        case (.backup, .mainBackup): return 3
        case (.backup, .fallbackBackup): return 2
        case (.move, .archive): return 3
        case (.move, .main): return 2
        case (.move, .work): return 1
        default: return 0
        }
    }
    public var neverDestination: Bool { self == .localSystem }
}
```
  Note: `canReceive` returns true for `.neutral` (rank 0) so neutral stays an eligible fallback, but `localSystem.canReceive` must be false — add explicit guard: `if neverDestination { return false }` at the top of `canReceive`. Also Work must NOT receive backup: `work.rank(.backup)==0` and work != neutral → canReceive false. Good. Verify mainBackup.canReceive(.move): rank 0, not neutral → false. Good.
- [ ] **Step 4:** Run test → PASS.
- [ ] **Step 5:** Commit `feat(core): add DriveRole`.

### Task B2: Role-aware ranking in `OrganizationPlanner` (Core, TDD)

**Files:**
- Modify: `DiskGalleryCore/Planning/OrganizationPlanner.swift` (`PlanDrive` gains `role`, `priority`; solver ranks by role then priority then existing score)
- Modify: `DiskGalleryCoreTests/OrganizationPlannerTests.swift`

- [ ] **Step 1:** Add to `PlanDrive`: `public var role: DriveRole` and `public var priority: Int`, defaulting `role: .neutral, priority: 0` in the initializer (keep existing call sites compiling).
- [ ] **Step 2 (RED):** Add tests:
  - `testBackupPrefersMainBackupOverLargerNeutral`: two destinations, a big Neutral SSD and a smaller `mainBackup` HDD both with room; a Backup item must be assigned to the mainBackup drive.
  - `testMovePrefersArchive`: Move item with an `archive` drive + a `main` drive both fitting → archive wins.
  - `testNeverAssignToLocalSystem`: only candidate with room is `localSystem` → item is `.unassigned`.
  - `testPriorityBreaksTieAmongSameRole`: two `mainBackup` drives, equal capacity/speed; lower `priority` value wins.
  - `testFallsBackToCapacitySpeedWhenAllNeutral`: all neutral → behaves like today (existing heuristic), pick the larger/faster.
  - `testBackupNotPlacedOnWork`: candidates are source + a `work` drive only → `.unassigned` (work can't receive backup).
- [ ] **Step 3:** Run `-only-testing:DiskGalleryCoreTests/OrganizationPlannerTests` → new tests FAIL.
- [ ] **Step 4 (GREEN):** In the candidate-selection code (around lines 228–360), change filtering + ranking:
  - **Filter:** keep a drive as a candidate only if `drive.id != source && drive.role.canReceive(item.tag)` and it stays under the fill threshold (existing capacity check). (Neutral still eligible via `canReceive`.)
  - **Rank:** replace the additive `driveScore` sort with a tuple comparator, sorting candidates by, in order: `role.rank(for: tag)` **desc**, `priority` **asc** (lower first), existing `driveScore(...)` **desc**, free-after **desc**, `id` **asc**. Keep `driveScore` as the 3rd key (don't delete it).
  - Overrides: an explicit `overrides[itemId]` destination is still honored as today even if its role wouldn't normally receive the tag (manual wins), keeping the `.overflow` flag behavior.
- [ ] **Step 5:** Run tests → PASS. Run the full Core suite → all green.
- [ ] **Step 6:** Commit `feat(core): role-aware destination ranking`.

### Task B3: `DriveRolesService` persistence (Core, TDD)

**Files:**
- Create: `DiskGalleryCore/Planning/DriveRolesService.swift`
- Modify: `DiskGalleryCore/Database/AppDatabase.swift` (migration `driveRole` table) — locate the migrator and add a migration
- Modify: `DiskGalleryCore/Catalog/Catalog.swift` (vend `driveRoles`)
- Create: `DiskGalleryCoreTests/DriveRolesServiceTests.swift`

- [ ] **Step 1:** Read `AppDatabase.swift` to find the `DatabaseMigrator` registrations and follow the exact pattern. Add migration `"createDriveRole"`:
```swift
migrator.registerMigration("createDriveRole") { db in
    try db.create(table: "driveRole") { t in
        t.column("volumeKey", .text).primaryKey()
        t.column("role", .text).notNull()
        t.column("priority", .integer).notNull().defaults(to: 0)
    }
}
```
- [ ] **Step 2 (RED):** Test (mirror an existing service test for setup of a temp DB / Catalog):
```swift
func testSetAndGetRole() async throws {
    let svc = catalog.driveRoles
    var all = try await svc.all()
    XCTAssertTrue(all.isEmpty)
    try await svc.setRole(.mainBackup, forKey: "VOL-1")
    try await svc.setPriority(5, forKey: "VOL-1")
    let a = try await svc.assignment(forKey: "VOL-1")
    XCTAssertEqual(a?.role, .mainBackup)
    XCTAssertEqual(a?.priority, 5)
    all = try await svc.all()
    XCTAssertEqual(all["VOL-1"]?.role, .mainBackup)
}
func testUnsetDefaultsToNeutral() async throws {
    let a = try await catalog.driveRoles.assignment(forKey: "missing")
    XCTAssertNil(a)   // caller treats nil as .neutral
}
```
- [ ] **Step 3:** Run → FAIL.
- [ ] **Step 4 (GREEN):** Implement `DriveRolesService` (struct with `let db: AppDatabase`) and a GRDB record `DriveRoleRecord: Codable, FetchableRecord, PersistableRecord { var volumeKey: String; var role: DriveRole; var priority: Int }` with `static let databaseTableName = "driveRole"`. Public type `DriveRoleAssignment { let role: DriveRole; let priority: Int }`. Methods: `all() -> [String: DriveRoleAssignment]`, `assignment(forKey:)`, `setRole(_:forKey:)` (upsert preserving priority), `setPriority(_:forKey:)` (upsert preserving role; default role .neutral), `clear(forKey:)`. Add `public let driveRoles: DriveRolesService` to `Catalog` + init.
- [ ] **Step 5:** Run → PASS; full Core suite green; `xcodegen generate`.
- [ ] **Step 6:** Commit `feat(core): persist drive roles`.

### Task B4: Wire roles into the plan inputs (app)

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` (`organizationPlanInputs()` attaches role+priority; boot volume default; role set/get actions)

- [ ] **Step 1:** In `AppEnvironment.organizationPlanInputs()` (builds `[PlanDrive]`), fetch `let roles = try await catalog.driveRoles.all()` and set each `PlanDrive.role`/`priority` from `roles[key]`, defaulting `.neutral`/`0`. For the boot volume (detect via the volume whose mount is `/` — use existing `volumes`/`VolumeSummary` info; if a `isBootVolume`/`/` indicator isn't available, default any volume named like the startup disk to `.localSystem` only when no explicit assignment exists). Keep it simple: if `roles[key] == nil && env detects boot`, use `.localSystem`.
- [ ] **Step 2:** Add `func setDriveRole(_ role: DriveRole, forKey key: String)` and `func setDrivePriority(_ p: Int, forKey key: String)` that write through `catalog.driveRoles` and bump `dataVersion` so Organize recomputes.
- [ ] **Step 3:** `xcodebuild -scheme DiskGallery build` → SUCCEEDED.
- [ ] **Step 4:** Commit `feat(app): feed drive roles into the Organize plan`.

### Task B5: App-layer label store + Settings → Drives + right-click (app)

**Files:**
- Create: `DiskGallery/App/DriveRoleLabelsStore.swift` (`@Observable`, UserDefaults `role.label.<rawValue>`, `label(for:)`, `setLabel(_:for:)`, `resetToDefaults()`)
- Modify: `DiskGallery/App/AppEnvironment.swift` (own a `DriveRoleLabelsStore`)
- Modify: `DiskGallery/Views/SettingsView.swift` (new `DrivesSettings` tab + tabItem)
- Modify: `DiskGallery/Views/Modern/ModernSidebar.swift`, `DiskGallery/Views/LibrarySidebarView.swift` (drive row `.contextMenu` → "Set role" submenu + priority)

- [ ] **Step 1:** Create `DriveRoleLabelsStore` returning `role.defaultLabel` when no override.
- [ ] **Step 2:** Add to `AppEnvironment`: `let roleLabels = DriveRoleLabelsStore()`.
- [ ] **Step 3:** `DrivesSettings` view: a `Form`/`List` of the user's drives (from `env.volumeSummaries`); each row has a `Picker` bound to that drive's role (calls `env.setDriveRole`), shown using `env.roleLabels.label(for:)`; a section to rename the 7 role labels (TextField per role → `roleLabels.setLabel`); drag-to-reorder list to set priority (write `setDrivePriority` by index); a "Reset labels to defaults" button. Add `.tabItem { Label("Drives", systemImage: "externaldrive.badge.plus") }` in `SettingsView`.
- [ ] **Step 4:** In both sidebars, add `.contextMenu` to each drive row: a `Menu("Set role")` with a `Button` per `DriveRole` (checkmark on the current one) calling `env.setDriveRole($0, forKey: key)`, plus "Increase/Decrease priority". Use `env.roleLabels.label(for:)` for titles.
- [ ] **Step 5:** `xcodegen generate`; `xcodebuild -scheme DiskGallery build` → SUCCEEDED.
- [ ] **Step 6:** Commit `feat(app): drive-role settings + right-click assignment`.

---

## Final verification
- [ ] Full Core suite: `xcodebuild test -scheme DiskGalleryCore -destination 'platform=macOS'` → TEST SUCCEEDED.
- [ ] App build: `xcodebuild -scheme DiskGallery -destination 'platform=macOS' build` → BUILD SUCCEEDED.
- [ ] Adversarial code-review workflow over the full diff; fix confirmed findings.
- [ ] Launch app; smoke-test all five items per the spec's Manual checklist.

## Self-review notes
- Spec coverage: items 1(A1) 2(A2) 3(A3) 4(A4) 5(B1–B5) all mapped. Non-destructive preserved (roles only rank). 
- Type consistency: `DriveRole.canReceive/rank/defaultLabel/neverDestination`, `DriveRoleAssignment{role,priority}`, `PlanDrive.role/priority`, `DriveRolesService.{all,assignment,setRole,setPriority,clear}`, `DriveRoleLabelsStore.{label,setLabel,resetToDefaults}`, `AppEnvironment.{setDriveRole,setDrivePriority}` used consistently.
- Open default honored: Classic untouched for items 1–4; roles surfaced in both sidebars + shared Settings.
