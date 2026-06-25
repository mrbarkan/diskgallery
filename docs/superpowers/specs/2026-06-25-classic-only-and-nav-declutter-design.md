# DiskGallery — Classic-Only & Navigation Declutter ("Simplify" milestone)

**Date:** 2026-06-25
**Status:** Approved design — ready for implementation plan
**Implement on:** a dedicated branch off the current `feature/gallery-view`

## Background & motivation

DiskGallery ships two UI skins — **Classic** (native macOS) and **Modern** (bento /
glass / OLED). Modern is ~4,000 LOC (~44% of the app UI layer) but carries **zero unique
business logic**: every feature also exists in Classic, and `DiskGalleryCore` /
`AppEnvironment` are entirely theme-agnostic. After living with it, the owner finds the
Modern interface gets in the way of real work and wants to focus on Classic.

Separately, the **Classic navigation has grown cluttered**. The sidebar carries **11
non-drive rows**: the "Plan" section alone holds three overlapping surfaces — **Action
Plan** (a per-drive rollup of pending tags), **Transfer Planner** (a manual one-pair
"will it fit?" check), and **Organize** (the real capacity- and role-aware run-order
plan, which subsumes the other two) — plus **five** standalone tag-list rows.

This milestone (a) **hides and freezes Modern** so all future work happens once, in
Classic, and (b) **declutters the Classic navigation** from 11 non-drive rows to 5. It is
deliberately scoped to *not* build the execution engine (the next milestone), and to
avoid redesigning surfaces that the execution engine will rebuild.

**Baseline at design time:** `xcodebuild` build **SUCCEEDS**; **152/152** `DiskGalleryCore`
tests pass.

## Goals

1. Force the app to the Classic skin and remove Modern-only Settings controls. Modern code
   remains **compiled but unreachable** (frozen) — fully reversible, no logic lost.
2. Consolidate the three Plan surfaces into a single **Organize** home with a
   **[Plan · By drive]** toggle. **Drop** the Transfer Planner surface.
3. Collapse the five tag-list rows into a single **Tagged** destination with an in-view
   filter (All / Keep / Delete / Review / Move / Backup).
4. Keep the build green and all tests passing; add focused tests for new Core behavior.

## Non-goals (explicitly out of scope)

- **No execution / file operations.** No `TransferService`. The read-only identity
  (enforced by `MutationGuardTests`) is preserved; the only drive write remains explicit
  Finder tags.
- **No physical removal of `Modern/`.** We freeze, not strip. (A later milestone may strip
  it; relocating `UnifiedComparePanel` out of `Modern/UnifiedCompare.swift` is deferred to
  then — Classic keeps importing it from there for now.)
- **No change to the licensing `Feature.transfer` flag.** That gates the *future execution
  engine*, not the dropped Transfer **Planner** UI. `Feature.swift` and `FeatureTests`
  are untouched.
- No redesign of drive browsing, Duplicates, Search, or All Drives.

## Key constraint: Modern stays compiled

Because `Modern/` is frozen but **still compiled**, the `SidebarItem` enum **must keep all
its current cases** (`.plan`, `.transfer`, `.tagged(Tag)`): `ModernWorkspace` and
`ModernSidebar` switch on them, and removing a case would break the build. Therefore the
declutter is achieved by **changing what the Classic sidebar surfaces and routes**, not by
deleting enum cases. The freeze itself touches **no Modern source file**.

## Part 1 — Hide & freeze Modern

**1.1 Force Classic at the source.** In `DiskGallery/App/ThemeStore.swift`:
- Change the `skin` default from `.modern` to `.classic`.
- In `init()`, **coerce** `skin = .classic` unconditionally (ignore any persisted
  `"skin"` value), so every scattered `env.theme.skin == .modern` check across the shared
  Classic views resolves to Classic *consistently* (not just the top-level `ContentView`
  fork). This avoids a broken hybrid where shared views render Modern styling.

**1.2 Remove Modern-only Settings controls.** In `DiskGallery/Views/SettingsView.swift`
→ `AppearanceSettings`:
- Remove the **"Look" / Skin picker** section (lines ~104–110).
- Remove the **"OLED Display"** section (lines ~135–147).
In `ShortcutSettings`:
- Remove the **"View" / "Toggle side panes"** section (lines ~170–192).
- **Keep** Accent and Mode (they apply to Classic too).

**1.3 Leave frozen plumbing in place.** `ThemeStore.oledLayout` / `cycleOLEDLayout`, the
`OLEDLayout` enum, `ShortcutStore.paneToggle*`, and `AppEnvironment.handlePaneToggle`
(Modern focus-mode, already guarded by `skin == .modern`) are **left as-is** — removing
them would break Modern's compile for no user-visible benefit. They are dead in Classic.

## Part 2 — Navigation declutter

### 2.1 Target sidebar structure

```
Before  (11 non-drive rows)            After  (5 non-drive rows)
──────────────────────────            ─────────────────────────
All Drives                             All Drives
Library                                Library
  Duplicates                             Duplicates
  Search                                 Search
Plan                                     Tagged          ← 5 rows → 1 (+ filter)
  Action Plan                          Plan
  Transfer Planner                       Organize        ← 3 surfaces → 1 (+ toggle)
  Organize                             Drives
Action Tags                              …groups + drives…
  Keep·Delete·Review·Move·Backup
Drives
  …groups + drives…
```

All edits in **`DiskGallery/Views/LibrarySidebarView.swift`**:
- Remove the **Action Plan** and **Transfer Planner** rows from the "Plan" section; the
  section retains only **Organize**.
- Remove the **"Action Tags"** section (5 rows) and add a single **Tagged** row under
  "Library" (selecting `.taggedAll`, see 2.3). Its badge shows the total action-tagged
  count.

### 2.2 Organize home with a [Plan · By drive] toggle

Classic's `OrganizeView` and `ActionPlanView` are **Classic-only** (Modern uses
`ModernOrganizePage` / `ModernActionPlanPage`), so they can be refactored freely.

- Introduce **`OrganizeHomeView`** (the Classic route for `.organize`). It owns the
  `.navigationTitle("Organize")`, the export toolbar, and a segmented control
  `Picker` bound to `@State private var mode: OrganizeMode` (`enum OrganizeMode { case plan, byDrive }`,
  default `.plan`).
  - **Plan mode** renders the existing run-order plan (today's `OrganizeView` body):
    summary stats, numbered run order, "couldn't place" section. Export / Copy Plan
    toolbar items appear in this mode.
  - **By drive mode** renders the existing per-drive pending rollup (today's
    `ActionPlanView` body): the "plug in these drives, in this order" list with per-tag
    counts and tap-to-open-drive.
  - **Implementation note:** extract the inner list of each into reusable subviews
    (e.g. `OrganizePlanList`, `OrganizeByDriveList`) so `OrganizeHomeView` composes them
    without nested navigation titles/toolbars. The standalone `OrganizeView` /
    `ActionPlanView` Classic types are then no longer routed directly (see 2.4).

### 2.3 Single Tagged destination with a filter

- Encode the combined view's selection as **`.tagged(.none)`** (the `.none` decision means
  "all"), exposed via a readable convenience `static var taggedAll: SidebarItem { .tagged(.none) }`.
  This adds **no new enum case**, so Modern's exhaustive `switch` (verified to have no
  `default`) compiles untouched — honoring the freeze. The existing `.tagged` token already
  round-trips (`"tagged:0"`), so no token changes are needed for it.
- Generalize `DiskGallery/Views/TaggedListView.swift` to take an **optional initial
  filter** and always show filter chips **All / Keep / Delete / Review / Move / Backup**
  with per-tag counts. Default selection: **All**.
  - `.taggedAll` opens it on **All**.
  - `.tagged(tag)` (deep-links, e.g. from Modern search or future Organize links) opens it
    **pre-filtered** to `tag` — preserving existing behavior.
- **Core support:** add an all-action-tags query to `AnnotationStore` (e.g.
  `taggedEntries(in tags: [Tag])` or `allTaggedEntries()`), since today
  `taggedEntries(_:)` is single-tag. The "All" filter uses it; per-tag chips can reuse the
  existing single-tag path or filter the combined result in-memory.

### 2.4 Routing & persistence (`DiskGalleryApp.swift`, `AppEnvironment.swift`)

- In Classic `ContentColumn` (`DiskGalleryApp.swift`): route `.organize` →
  `OrganizeHomeView`; route `.tagged(tag)` → the generalized `TaggedListView` (this case
  now covers `.tagged(.none)` = all). The now-unreachable `.plan` and `.transfer` cases
  (kept for Modern) route to `OrganizeHomeView` as a safe fallback so any stray selection
  lands somewhere sane.
- **Token migration** in `SidebarItem.init?(token:)`: map legacy persisted tokens
  `"plan"` and `"transfer"` → `.organize`, so a user whose last-selected view was Action
  Plan or Transfer Planner reopens on Organize rather than a removed surface.

## Part 3 — Stabilize

- Re-run **build + the full `DiskGalleryCore` test suite** after each change; the bar is
  **152/152 staying green** plus any new tests.
- Add a unit test for the new `AnnotationStore` all-tags query (mixed tags across volumes →
  correct combined set).
- Optionally add a tiny `SidebarItem` token round-trip test covering the new `.taggedAll`
  case and the `"plan"`/`"transfer"` → `.organize` migration (there are no `SidebarItem`
  tests today; this locks the migration behavior cheaply).
- **Smoke-test the running app in Classic:** launch, confirm it opens in Classic with the
  5-row sidebar, exercise Organize's [Plan · By drive] toggle, the Tagged filter chips,
  and confirm Settings no longer shows Skin / OLED / Toggle-side-panes.

## Files touched

| File | Change |
|---|---|
| `App/ThemeStore.swift` | Default + coerce `skin = .classic` |
| `Views/SettingsView.swift` | Remove Skin picker, OLED section, Toggle-side-panes row |
| `Views/LibrarySidebarView.swift` | Remove Action Plan / Transfer Planner / 5 tag rows; add single Tagged row |
| `App/AppEnvironment.swift` | Add `SidebarItem.taggedAll` convenience (= `.tagged(.none)`); migrate `plan`/`transfer` tokens → `.organize` |
| `App/DiskGalleryApp.swift` | Route `.organize`→`OrganizeHomeView`, `.taggedAll`/`.tagged`→`TaggedListView`, fallback `.plan`/`.transfer` |
| `Views/OrganizeView.swift` + `Views/ActionPlanView.swift` | Extract inner lists; new `OrganizeHomeView` with toggle |
| `Views/TaggedListView.swift` | Filter chips + optional initial filter |
| `DiskGalleryCore/Annotations/AnnotationStore.swift` | All-action-tags query |
| `DiskGalleryCoreTests/AnnotationListTests.swift` (or new) | Test the all-tags query |

## Files explicitly NOT touched

- Anything under `DiskGallery/Views/Modern/`, `OLEDDisplayView.swift`,
  `Support/ModernTokens.swift` (frozen, still compiled).
- `Views/TransferPlannerView.swift` — left orphaned in the tree (no Classic route, still
  referenced by Modern's `ModernWorkspace`); deleting it is deferred to a Modern strip.
- `DiskGalleryCore/Licensing/Feature.swift` + `FeatureTests.swift` (the `transfer`
  feature flag is the future engine's gate).
- `OrganizationPlanner` and its tests (the `.plan(...)` algorithm is unrelated to the
  `.plan` nav case).

## Risks & rollback

- **Hybrid-styling risk** if Modern styling leaked into Classic — mitigated by coercing
  `skin = .classic` at the source (1.1), so all `modern` checks are uniformly false.
- **Lost capability:** Transfer Planner's ad-hoc "will A fit on B?" is dropped. Organize
  already reports global fit/overflow and drives-to-connect; if missed, a lightweight
  inline "test a move" can return later. The per-drive rollup is **preserved** as the
  By-drive toggle.
- **Reversibility:** the entire Modern freeze is reversible by un-coercing `skin` and
  restoring the three Settings controls. No Modern code is deleted.

## Future (sets up, does not build)

- **Execution engine (next milestone):** a persisted, volume-UUID-keyed operation queue +
  verified executor (copy → checksum → move/delete) + a `VolumeService` mount hook that
  drains pending operations on reconnect. Organize becomes **stage → review → commit**;
  the [Plan · By drive] structure introduced here is the natural host for it, and "By
  drive / connect in this order" maps directly onto the reconnect-to-execute flow.
- Later: optional physical strip of `Modern/` (relocate `UnifiedComparePanel`, collapse
  `if modern` branches, drop `modernListChrome`/`glassCard` no-ops).
