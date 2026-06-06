# Spec — Modern UI Refresh + Drive Roles (Polish round, "M1.5")

**Date:** 2026-06-06
**Status:** Approved in brainstorming; pending spec review.
**Depends on:** M1 (Organize workspace) — shipped.
**Precedes:** M2 (birds-eye "all drives as one" view) — not started; this round comes first by user decision.

## Context

DiskGallery is a non-destructive cross-drive command center. M1 shipped the Organize workspace (capacity-aware transfer plan/report). After living with it, the user found the **Modern** interface cluttered and asked for a focused polish round plus a new **drive-roles** system that makes the Organize plan reflect *intent* (which drive is the backup, which is cold storage, …) rather than raw capacity/speed heuristics.

This spec covers five changes. Items 1–4 are **Modern-skin only** (they touch the OLED hero, topbar, hardware strip, and bento — UI that exists only in the Modern shell; Classic's `NavigationSplitView` is unchanged). Item 5 (drive roles) is **cross-cutting**: a Core data model + solver change plus settings/right-click surfaces in both skins.

The app stays **strictly non-destructive** — nothing here moves, copies, or deletes files.

---

## 1. Remove the OLED "Gauge" layout

The OLED hero (Modern only) currently cycles three layouts: Telemetry, Gauge, Minimal. Remove **Gauge**.

- `DiskGalleryCore/Theme/ThemeModel.swift` — drop `.gauge` from `OLEDLayout` (cases become `telemetry, minimal, actionDetail`). `cycleOLEDLayout()` then cycles Telemetry ↔ Minimal on drive pages; `actionDetail` remains auto-selected on the Organize page.
- `DiskGallery/Views/OLEDDisplayView.swift` — delete the `gauge` view, `gaugeSubtitle`, and the Gauge `#Preview`. Remove the `.gauge` switch arm.
- Tests/Settings — update `ThemeModelTests` raw-value/`name` expectations; the Appearance settings `OLEDLayout` picker auto-updates (it iterates `allCases`).
- Migration: if a user's persisted layout was `gauge`, decode-fail falls back to the default (`telemetry`). Add a tiny guard so an unknown stored value maps to `.telemetry`.

## 2. Move drive info **into** the OLED, under the volume bar

Today a separate `ModernHardwareStrip` (bus · speed · medium · connection · brand/model · "detected …") sits as its own glass card below the OLED. Move that content **inside** the OLED panel, as a row directly beneath the capacity/volume bar (`OLEDBottomBar`), and remove the standalone strip from `VolumeBentoWorkspace`.

**Visual treatment — "simple OLED, not HD":** no material card, no dotted frame, no grey background. A thin hairline (the existing `OLEDColor.ink.opacity(0.10)` divider) above a single line of plain monospace text in muted OLED ink (`OLEDColor.ink2`/`ink3`), matching `OLEDKey`/`OLEDPill` styling. The "detected …" timestamp sits right-aligned on the same line.

- `OLEDDisplayView` — the **Telemetry** layout gains a hardware row after `OLEDBottomBar`. Add an optional `hardware: DriveHardwareDisplay?` (or the raw `DriveHardware`) parameter; render the row only when present. Keep `Minimal` clean (no hardware row).
- `DriveHardwareDisplay` already exists (used by `ModernHardwareStrip`); reuse its computed labels so we don't duplicate formatting.
- `ModernWorkspace.swift` (`VolumeBentoWorkspace`) — stop rendering `ModernHardwareStrip`; pass `summary.hardware` into the OLED instead. `ModernHardwareStrip.swift` can be deleted (or kept unused — prefer delete).

## 3. Relocate the path bar to directly above the browser

The breadcrumb path nav currently lives in `ModernTopbar` (top of the workspace). Move it down to where the hardware strip used to be — a dedicated **path bar** immediately above the browser card.

- **Topbar after the change:** left side is empty of breadcrumbs; it keeps only the Search pill + the action cluster (Display / Check changes / Re-scan). Remove the `crumbs`/`onCrumb`/`leadingIcon` breadcrumb rendering from `ModernTopbar` (or stop passing crumbs to it).
- **New path bar:** a thin glass bar showing the **drive name as the root crumb** followed by the navigable path (`Archive Vault / Photography / 2024`). The **drive name appears only here** (not duplicated in the topbar). Clicking a crumb navigates (`nav.path = Array(prefix(i))`), preserving today's behavior.
- Placement in `VolumeBentoWorkspace`: `Topbar → OLED → [IncompleteBanner] → PathBar → bento`. The path bar belongs to the volume/browser pages; library pages (Duplicates, Action Plan, Organize, Search) keep their existing scaffold crumbs as-is for now.
- New view: `DiskGallery/Views/Modern/ModernPathBar.swift`.

## 4. Collapsible panes ("focus mode") — grow the browser

In the Modern bento, the three boxes **Reclaimable**, **Action plan**, and **Inspector** become collapsible so the browser can take their space.

- **`Tab` toggles all three at once** (focus mode): collapsed → browser expands to fill the full bento width/height. `Tab` again restores them. (Chosen: option B = global toggle **plus** per-box control.)
- **Per-box chevron:** each of the three boxes gets a small ▸/▾ control to collapse/expand it independently. Bento layout recomputes from which boxes are visible:
  - Inspector hidden → left column widens to full width.
  - Both bottom tiles hidden → browser grows to the bottom of the left column.
  - All hidden (or `Tab`) → browser fills the entire bento.
- **OLED, path bar, and topbar stay visible** (only the three named boxes collapse).
- **Shortcut:** default `Tab`, **customizable in Settings → Shortcuts**. Tab is a non-character key, so add a dedicated bindable command (e.g. `focusBrowser`) rather than overloading the single-char tagging `ShortcutAction` set. The keyboard monitor must **ignore Tab when a text field is first responder** (so Search/rename fields keep normal focus traversal).
- **Persistence:** focus-mode flag and per-box collapse states persist across launches in `ViewPrefsStore` (UserDefaults). Default = all expanded.

## 5. Drive roles & priority

Each drive carries one **role** plus a position in a **priority order**. Roles tell the Organize solver where data *should* flow; priority breaks ties; capacity+speed remain the final fallback. **Strictly non-destructive** — roles only influence the suggested plan.

### Roles (7)

| Role | Meaning | Solver behavior |
|---|---|---|
| **Local / System** | Mac internal boot disk | Source only — **never a destination**. Auto-assigned to the boot volume by default. |
| **Main** | Primary external library / working drive | Kept healthy; may receive consolidations. |
| **Work / Scratch** | Fast SSD/NVMe, active work | Source for Moves; not a backup target. |
| **Main Backup** | Primary backup target | First destination for `Backup`-tagged items. |
| **Fallback Backup** | Secondary backup target | Used when Main Backup is full/offline (or 2nd copy). |
| **Archive / Cold** | Big slow storage | First destination for `Move`-tagged items. |
| **Neutral** *(default)* | No role | Capacity/speed ranked; used only if no roled drive fits. |

### Routing rules
- `Backup` → **Main Backup** → **Fallback Backup** → any drive with room. Never Local/System, never Work.
- `Move` → **Archive** → **Main/Work** with room. Never a Backup drive, never Local/System.
- **Local/System is never a destination** — only a source to free up.
- **Priority order** breaks ties and decides which same-role drive fills first (e.g. two archive HDDs).
- When roles don't decide it, fall back to today's capacity + link-speed `driveScore`.

### Customization
- **Labels are renameable** (all 7). Behaviors stay fixed (chosen: option A). "Reset to defaults" restores stock names. No user-defined routing in this round (B/C deferred).

### Surfaces
- **Right-click** a drive in either sidebar (`ModernSidebar`, `LibrarySidebarView`) → "Set role ▸" submenu (+ a quick priority bump/reorder affordance).
- **Settings → Drives** (new tab in `SettingsView`): list drives with a role picker each, drag-to-reorder for priority, inline label rename, and Reset to defaults.

### Architecture & persistence
- **Core:** add `public enum DriveRole` (Sendable, `CaseIterable`) in `DiskGalleryCore` with stock default labels. Add `role: DriveRole` and `priority: Int` to `PlanDrive`. Extend `OrganizationPlanner`'s candidate selection/`driveScore` to honor routing rules + priority **before** the existing HDD/SSD/speed heuristics; the heuristics remain the tiebreaker/fallback. This is pure and unit-testable — no DB/IO in the planner.
- **Role assignment persistence:** mirror the existing annotations pattern — a small Core store keyed by **volume key** (`uuid ?? name`), e.g. `catalog.driveRoles` with `role(forKey:)` / `setRole(_:forKey:)` / `priority(forKey:)` / `setPriority(_:forKey:)`. Drives without an assignment default to `.neutral`; the boot volume defaults to `.localSystem`.
- **Custom labels persistence:** app-layer `DriveRoleLabelsStore` (`@Observable`, UserDefaults) mapping `DriveRole → custom name`. Labels are display-only; the Core planner never needs them (the report uses **drive names**, not role names), so this keeps Core free of UI strings.
- **Wiring:** `AppEnvironment.organizationPlanInputs()` already builds `[PlanDrive]`; extend it to attach each drive's role + priority from `catalog.driveRoles`. The Organize plan + canvas then reflect roles automatically.

---

## Components touched (summary)

**Core**
- `Theme/ThemeModel.swift` — remove `OLEDLayout.gauge`; unknown-value guard.
- `Planning/OrganizationPlanner.swift` — `DriveRole` enum; `role`/`priority` on `PlanDrive`; role-aware routing in the solver.
- New role store (e.g. `Catalog/DriveRolesService.swift`) + `Catalog` wiring.
- `DiskGalleryCoreTests` — extend `OrganizationPlannerTests` (role routing, priority tiebreak, Local/System never-destination, fallback), `ThemeModelTests` (layout cases), new `DriveRolesServiceTests`.

**App (Modern)**
- `Views/OLEDDisplayView.swift` — drop Gauge; add hardware row to Telemetry.
- `Views/Modern/ModernWorkspace.swift` — remove hardware strip; pass hardware to OLED; insert path bar; collapsible bento.
- `Views/Modern/ModernTopbar.swift` — remove breadcrumbs.
- `Views/Modern/ModernPathBar.swift` — **new**.
- `Views/Modern/ModernBento.swift` / inspector / `StatTiles.swift` — per-box collapse + chevrons.
- Delete `Views/Modern/ModernHardwareStrip.swift`.

**App (cross-cutting)**
- `App/ViewPrefsStore.swift` — focus-mode + per-box collapse flags.
- `App/ShortcutStore.swift` (or a sibling) — bindable `focusBrowser` command (default Tab); `AppEnvironment` keyboard monitor handling + text-field guard.
- `App/AppEnvironment.swift` — role/priority into `[PlanDrive]`; role set/get actions for context menus.
- `Views/SettingsView.swift` — new **Drives** tab; **Shortcuts** tab gains the focus-mode binding.
- `Views/Modern/ModernSidebar.swift`, `Views/LibrarySidebarView.swift` — drive right-click "Set role" menus.
- New `App/DriveRoleLabelsStore.swift`.

## Testing
- **Unit (Core, TDD):** role routing for Backup/Move; Local/System excluded as destination; priority tiebreak among same-role drives; rename doesn't affect routing; fallback to capacity/speed when no role applies; role store get/set/default(`.neutral`)/boot-default(`.localSystem`).
- **Build:** `xcodebuild -scheme DiskGallery -destination 'platform=macOS' build` confirms both exhaustive switches and the reduced `OLEDLayout` compile.
- **Manual:** Gauge gone from Display cycle; drive info renders inside OLED as a bare line; path bar sits above browser with the drive name; Tab collapses/restores all three boxes and per-box chevrons work, persisting across relaunch and not firing while typing in Search; assign roles via right-click + Settings → Drives, rename a label, reorder priority, and confirm the Organize plan's destinations/order change accordingly; nothing is moved.

## Out of scope (YAGNI / later)
- User-defined roles or user-defined routing (options B/C) — labels-only this round.
- One-click role presets (photographer / 3-2-1 / archivist / minimal) — possible follow-up.
- Collapsing the OLED itself for true full-screen browser — only the three named boxes collapse.
- Birds-eye "all drives as one" view (M2) and infinite-zoom map (M3).

## Flagged defaults (say the word to change)
1. Items 1–4 are Modern-only; Classic is untouched this round.
2. Move routing prefers Archive, then Main/Work; never Backup/Local-System drives.
3. Backup produces **one** copy (Main Backup, else Fallback) — not two copies automatically.
4. Boot volume auto-defaults to Local/System; all other unassigned drives default to Neutral.
5. Collapse states persist across launches.
6. Priority is a single global ordering of drives (drag to reorder), used as a tiebreak.
