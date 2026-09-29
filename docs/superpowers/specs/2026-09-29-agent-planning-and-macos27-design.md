# DiskGallery — agent planning tools, named plans, and a macOS 27 UI pass

**Date:** 2026-09-29
**Status:** Draft design — awaiting review before the implementation plan

## Background & motivation

A separate Claude Code session used the MCP server (`DiskGallery --mcp`, see
`2026-09-09-mcp-agent-access-design.md`) for a real task: *free one whole 4 TB
drive using only the ungrouped drives*. It picked BARKAN_2 (volumeId 12), planned
moves to MODESTMOUSE (11) and THEWHO (10), and tagged 8 folders. Most of the
analysis had to fall back to raw SQL against `catalog.sqlite` because the MCP
tools could not answer:

- which drives are ungrouped, and what role each drive has;
- how many **bytes** each folder holds, and how much of it already exists on
  other drives;
- *where* a Move should go — the destination had to be written into the note
  text ("→ THEWHO"), and the tags mixed with unrelated tags.

That session's retrospective produced eight suggestions. This spec takes the
subset the user chose — #1 (group/role in `list_drives`), #6 (scan staleness),
#8 (onboarding/`resources/list`), #2 (folder sizes + copy coverage), #3
(structured destinations + named plans) — and adds two user requests: a
right-click menu on the Plan page with *Open in Finder*, and a macOS 27 pass over
the UI. Deferred to a later release: #4 plan simulation, #5 content-hash
duplicates, #7 consolidation solver (they build on this work).

**Success criterion:** the "free BARKAN_2" session could be repeated entirely
through MCP tools — no SQLite — and its result reviewed, filtered, and executed
as one named plan in the Organize view.

## Decisions

1. **Tags stay the proposal channel.** Destinations and plan names are new
   optional columns on `annotation`, not a new plan/operation-approval model.
   The planner and executor already exist; this feeds them better input. (The
   alternative — agents writing `proposed` rows to `operation` — duplicates the
   planner and needs a new approval UI; rejected.)
2. **The MCP server still never touches a drive or starts execution.** Its only
   write stays `set_annotations`, now with more fields.
3. **Pinned destinations are honoured but still capacity-checked.** A pinned
   item that doesn't fit shows *exceeds capacity*; it is never silently
   re-routed.
4. **Copy coverage is name+size**, labelled as such (`matchBasis`) so a later
   content-hash tier (#5) can upgrade the label without breaking agents.
5. **Deployment target stays macOS 15.** New-design APIs are used behind
   `#available`, with today's styling as the fallback.
6. **Licensing unchanged.** Browsing, tagging, plans and MCP are free;
   executing remains behind `Feature.transfer`.

## Part A — MCP read surface (#1, #6, #8, #2)

### `list_drives`

Each drive gains:

| Field | Source |
|---|---|
| `groupId`, `groupName` | `volume.groupId` → `driveGroup.name`; both null = ungrouped |
| `role`, `priority` | `driveRole` by volume key (default `neutral`, `0`) |
| `scanAgeDays` | whole days since the latest snapshot's `scannedAt`; null if never scanned |
| `usedBytes` | latest snapshot `totalLogical` (was only implicit via capacity) |

Optional arguments: `groupId` (int) **or** `ungrouped: true`. Both given → error.

### `folder_summary` (new)

Args: `volumeId`, `relPath` (default root), `hideHidden` (default true),
`limit`/`offset` over children (default 200).

Returns, for the folder itself and for each direct child folder, plus one
synthetic `"(files here)"` row for loose files at that level:

```
name, relPath, totalBytes, fileCount,
bytesWithCopyElsewhere, bytesUnique,
copiesOn: [{volumeId, name, groupName, role, bytes}],   // sorted by bytes desc
matchBasis: "name+size"
```

- A file "has a copy elsewhere" when another volume's **latest** snapshot has a
  non-directory entry with the same `name` and `logicalSize` (uses
  `idx_entry_dupe`). Zero-byte files are excluded from matching (counted in
  `totalBytes`/`fileCount`, never as covered).
- `bytesWithCopyElsewhere` counts each file once even if several drives hold it;
  `copiesOn[].bytes` is per drive, so those can sum to more than the total.
- `totalBytes` uses `subtreeLogicalSize`; the coverage aggregate is one grouped
  SQL query over the folder's subtree (relPath-prefix range on
  `idx_entry_snapshot_relpath`), not per-file round trips.
- Implemented as a Core service method (`CoverageService` or a method on the
  existing duplicates area) so it is unit-testable and reusable by the UI later.

### `browse_folder`

Each subfolder gains `subtreeBytes`.

### Protocol / onboarding

- `resources/list` → `{ "resources": [] }` instead of `-32601`.
  (`initialize` does not advertise the resources capability; this is only to be
  polite to clients that ask anyway.)
- Setup docs (README MCP section + in-app "Connect an agent" help text): add
  "Restart Claude Code (or your MCP client) after `claude mcp add`; tools are
  loaded at session start."

## Part B — destinations and named plans (#3)

### Schema (new migration `v10`)

```
ALTER TABLE annotation ADD destVolumeKey TEXT      -- uuid ?? name, like other keys
ALTER TABLE annotation ADD destRelPath  TEXT       -- destination *folder*, relative
ALTER TABLE annotation ADD planName     TEXT
CREATE INDEX idx_annotation_plan ON annotation(planName) WHERE planName IS NOT NULL
```

`Annotation`/`TaggedItem` gain the three optional fields. Changing an item's
tag to something other than move/backup clears `destVolumeKey`/`destRelPath`
(a destination on a Keep tag is meaningless). Clearing the tag (`none`) removes
the row as today.

### MCP

- `set_annotations` items accept `destVolumeId` (int), `destRelPath` (string),
  `plan` (string, trimmed, ≤ 80 chars, empty → null). Validation, per item,
  whole call rejected on the first failure (same as today's behaviour):
  - destination only with `tag` `move` or `backup`;
  - `destVolumeId` exists and differs from the item's drive;
  - `destRelPath` is relative, no `..` components, no leading `/`;
  - `destRelPath` without `destVolumeId` → error.
- `list_annotations` gains a `plan` filter and returns the new fields
  (`destVolumeId`, `destDrive`, `destRelPath`, `plan`).
- `list_plans` (new, read-only): for each distinct `planName` —
  `itemCount`, `bytesByTag`, and per affected drive
  `{volumeId, name, currentFree, projectedFree, projectedFreePct, stale}` where
  projection = run `OrganizationPlanner` over just that plan's items (the same
  code path the UI uses). `stale` = `scanAgeDays > 30`. A `warnings` array lists
  overflow, unassigned, and stale-drive issues in plain sentences.

### Planner

- `PlanItemSource` gains `pinnedDestKey: String?`, `destRelPath: String?`,
  `planName: String?`.
- `PlanningService`'s item loader reads the new columns. Pinned items are passed
  through the existing `overrides` mechanism (id → dest key), so ranking logic is
  untouched. Overflow detection must apply to overrides (verify during
  implementation; add it if the override path currently skips the capacity
  check).
- `PlanStep` gains `destinationPath: String?` and `isPinned` (reuse
  `isOverride`).

### Executor (safety-critical)

- Destination relPath = `destRelPath + "/" + lastPathComponent(sourceRelPath)`
  when set; otherwise the source relPath (unchanged behaviour).
- No change to: never-overwrite (`FileCopier`), SHA-256 verify before any
  delete, delete only after a verified copy on a *different* backup-role drive.
- New test: a pinned `destRelPath` lands where expected and a pre-existing file
  at that path is **not** overwritten (operation fails with the existing
  "destination exists" reason).

### Organize view

- **Plan picker** in the Organize toolbar: *All items* / each plan name / *No
  plan*. The selection filters the items fed to the planner, so the step list,
  capacity projections, report export **and Execute** all apply to the selected
  plan only. Remembered per window (`@SceneStorage`).
- Step rows for pinned items show `SOURCE → DEST/folder` with a `pin.fill`
  glyph.
- **Discard plan…** (toolbar, enabled when a named plan is selected):
  confirmation dialog "Remove the N tags in *plan*? Files are not touched." →
  deletes those annotation rows. Catalog-only.

## Part C — Plan page right-click menu (user request)

`OrganizeStepRow` gets a `.contextMenu` (and the list gets
`contextMenu(forSelectionType:)` so it works on a multi-selection where
sensible). Items, shown only when applicable:

| Item | When | Action |
|---|---|---|
| **Show in Finder** | move/copy/delete steps | Reveal the source item — reuses the existing reveal helper in `AppEnvironment` (≈ line 275) so a disconnected drive shows the same "drive may be disconnected" message |
| **Show Destination in Finder** | move/copy with a destination | Reveal the destination folder (`destRelPath` or the drive root if the folder doesn't exist yet); disconnected → same message |
| **Copy Path** | any item step | Source absolute path (`/Volumes/NAME/relPath`) to the pasteboard |
| **Show in Library** | any item step | Selects the drive and folder in the main browser |
| **Use Automatic Destination** | pinned steps | Clears `destVolumeKey`/`destRelPath` |
| **Remove from Plan** | steps with a plan | Clears `planName` only (keeps the tag) |
| **Remove Tag** | any item step | Clears the annotation (same as untagging elsewhere) |

The Verify step has no menu. Menu labels follow macOS wording ("Show in
Finder", not "Open in Finder" — Finder's own term for reveal).

## Part D — macOS 27 UI pass (user request)

The app is built with the macOS 27 SDK (Xcode 27) and targets macOS 15. Standard
controls already pick up the new system design; the pass removes what fights it
and adopts what's available. Scope — all 24 files in `DiskGallery/Views/` plus
`ContentView` — checked against this list:

1. **Remove custom materials that clash with the system glass.**
   `.regularMaterial` backgrounds in `GalleryView.swift:118`,
   `LibrarySidebarView.swift:142`, `Components.swift:97`: on macOS 26+ use
   `.glassEffect(...)` (capsules) or no background where the toolbar/sidebar
   already provides one; keep `.regularMaterial` in the `else` branch.
2. **Toolbars.** Group related toolbar items and separate groups with
   `ToolbarSpacer` (26+); drop manual `Divider()`/padding hacks in toolbars;
   use `.sharedBackgroundVisibility(.hidden)` for items that shouldn't sit in a
   glass pill (e.g. status text).
3. **Content under glass.** Scroll views under the toolbar use
   `.scrollEdgeEffectStyle` where the default edge effect is wrong; gallery
   hero/thumbnail areas adjacent to the sidebar use `.backgroundExtensionEffect()`.
4. **Pickers.** Organize's segmented `Picker("View")` → `.pickerStyle(.tabs)`
   on macOS 27 (new `TabsPickerStyle`), segmented otherwise.
5. **Reordering.** Sidebar drive/group reordering currently uses hand-rolled
   `draggable`/`dropDestination` with string IDs. On macOS 27 evaluate the new
   `reorderable()` / `reorderContainer(...)` APIs; adopt only if they support
   cross-group moves, otherwise leave as is (note the outcome in the plan).
6. **Context menus & labels.** Every list with selectable items has a context
   menu with the standard verbs (Show in Finder, Copy Path, Get Info-style
   actions) and `Label` + SF Symbols so menu icons render per system settings.
7. **Buttons.** Prominent actions (Scan, Execute) use
   `.buttonStyle(.glassProminent)` on 26+ (`.borderedProminent` fallback);
   secondary toolbar buttons use plain `Label`s (system renders the glass).
8. **Hard-coded colors/corner radii.** Replace fixed `cornerRadius` values on
   cards with `ContainerRelativeShape`/concentric shapes where they sit in
   system containers; replace literal colors with semantic ones so dark mode and
   the six accents stay correct.
9. **Accessibility.** Reduce Transparency and Increase Contrast checked on each
   changed surface (glass falls back automatically; custom overlays must too).

**Method.** All macOS-26/27-only calls go through small view-modifier helpers
(e.g. `View.dgGlassCapsule()`), one `#available` per helper, so views don't
fill up with availability branches. APIs are verified against the installed
SDK's SwiftUI interface, not from memory. Out of scope: redesigning layouts,
changing navigation structure, raising the deployment target.

**Verification.** Build, then screenshot every sidebar destination in light and
dark mode on macOS 27 (before/after), plus a smoke run on a macOS 15 target to
confirm the fallbacks compile and render.

## Testing

Core (`DiskGalleryCoreTests`, using the existing `Fixture`):

- Migration adds the columns; existing annotations survive with nulls.
- `list_drives`: group/role/priority/scanAgeDays; `ungrouped` and `groupId`
  filters; both → error.
- `folder_summary`: two-drive fixture — totals, loose-files row, covered vs
  unique bytes, a file present on two other drives counted once, zero-byte files
  never covered, pagination.
- `set_annotations`: every destination validation rule; tag change clears the
  destination.
- `list_plans`: projection matches the planner; stale and overflow warnings.
- Planner: pinned destination honoured; pinned + too big → overflow, not
  re-routed; plan filter limits items.
- Executor: `destRelPath` placement; no overwrite of an existing destination.
- `MutationGuardTests` and existing `MCPTests` stay green.

App: build, plus the screenshot pass above.

**Manual check with real data:** the 8 annotations on BARKAN_2 (PROJECTS,
DIRETORIO, PHOTOGRAPHY, PERSONAL PROJECTS, PERSONAL FILES, PICTURES BACKUP, WORK
EXPORTS, AUDIO) — re-tag them via MCP with structured destinations and
`plan: "Free BARKAN_2"`, then review that plan in Organize and exercise the
right-click menu. No execution against real drives as part of verification.

## Delivery

One release, implemented in this order so each part is independently shippable
and testable: A → B → C → D. D touches many view files but no logic; it lands
last so it doesn't conflict with B/C's Organize changes.
