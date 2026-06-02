# Drive grouping/reordering + drive-type (hardware) info

**Date:** 2026-06-02
**Status:** Approved (sections 1–3 reviewed with user; user redirected to implementation)
**Scope:** One combined spec covering two user requests:

1. Drag-reorder drives and organize them into named, collapsible groups.
2. Show each drive's hardware type — bus (USB/Thunderbolt/SATA/internal), SSD-vs-HDD,
   internal/external, vendor/brand, model, and negotiated link speed — to help plan transfers.

Both ship together: one DB migration (v5) and one pass over both sidebars.

---

## 1. Data model & migration (v5)

### New `driveGroup` table

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK autoincrement | |
| `name` | TEXT NOT NULL | user-editable label |
| `sortIndex` | INTEGER NOT NULL | order of the group sections |
| `isCollapsed` | BOOL NOT NULL DEFAULT 0 | persisted collapse state |

### New columns on `volume`

| column | type | notes |
|---|---|---|
| `groupId` | INTEGER NULL → `driveGroup(id)` `ON DELETE SET NULL` | null = ungrouped. Deleting a group orphans its drives back to ungrouped; never deletes catalog data. |
| `sortIndex` | INTEGER NOT NULL DEFAULT 0 | order of the drive within its group (or within ungrouped) |
| `hardware` | TEXT NULL | JSON-encoded `DriveHardware` snapshot; null = not captured yet |

### `DriveHardware` — Codable struct stored as JSON (raw facts only, no presentation)

```swift
public struct DriveHardware: Codable, Sendable, Equatable {
    public enum Bus: String, Codable, Sendable {
        case usb, thunderbolt, sata, pcie, sd, virtual, unknown
    }
    public enum Medium: String, Codable, Sendable {
        case ssd, hdd, unknown
    }
    public var bus: Bus
    public var isInternal: Bool?
    public var medium: Medium?
    public var vendor: String?
    public var model: String?
    public var linkSpeedMbps: Int?   // negotiated speed, raw (480 = USB2, 5000, 10000, 40000 = TB3…)
    public var capturedAt: Date      // "as of last time the drive was connected"
}
```

GRDB auto-encodes the nested Codable property to a JSON text column. Badge/label text
("USB 3.2 Gen 2 · 10 Gb/s · SSD") is **derived at display time** from these raw facts by a
presentation-layer formatter — never stored — so the marketing-name mapping can improve
without a migration.

### Migration v5 (in `Migrations.makeMigrator()`)

1. Create `driveGroup`.
2. `ALTER TABLE volume` add `groupId`, `sortIndex` (default 0), `hardware`.
3. Backfill `volume.sortIndex` from the **current alphabetical order** so existing drives keep
   their present visual order on first launch:
   `UPDATE volume SET sortIndex = (SELECT COUNT(*) FROM volume v2 WHERE v2.name < volume.name COLLATE NOCASE)`
   (or equivalent row-number assignment). `groupId` and `hardware` start null.

### Deliberate choices

- Deleting a group keeps its drives (fall back to ungrouped). No catalog data lost.
- New scans append to the bottom of ungrouped (`MAX(sortIndex)+1` among ungrouped) so a new
  catalog never jumps to the top of the user's arrangement.

---

## 2. Drive-type detection

**New component: `DriveHardwareProbe`** (`DiskGalleryCore/Scanning/DriveHardwareProbe.swift`).
Input: a mounted volume URL. Output: `DriveHardware?`. Pure reads — never opens the device for
writing. **Added to `MutationGuardTests`' guarded-source list** to reinforce the read-only invariant.

**How it reads (two sources, best-effort):**

1. Resolve the BSD device node (`/dev/disk3s2`) from the volume URL via `statfs` `f_mntfromname`
   (same statfs path `VolumeMetadata` already uses). Strip `/dev/`.
2. **DiskArbitration** (`DASessionCreate` → `DADiskCreateFromBSDName` → `DADiskCopyWholeDisk` →
   `DADiskCopyDescription`) for reliable facts:
   - `DADiskDescriptionDeviceProtocolKey` → `bus` (USB / Thunderbolt / SATA / PCI-Express →
     `.pcie` / Secure Digital → `.sd` / Disk Image → `.virtual`)
   - `DeviceVendorKey` → `vendor`, `DeviceModelKey` → `model`, `DeviceInternalKey` → `isInternal`
3. **IOKit registry walk** (`IOBSDNameMatching` → `IOServiceGetMatchingService` → recursive
   `IORegistryEntrySearchCFProperty` toward parents) for what DA omits:
   - "Device Characteristics" → "Medium Type" → `.ssd` ("Solid State") / `.hdd` ("Rotational")
   - "Device Speed" (USB speed enum 0–5) → `linkSpeedMbps` (1.5/12/480/5000/10000/20000).
     Thunderbolt/NVMe leave `linkSpeedMbps` nil (negotiated figure not reliably exposed).

Any field the OS won't give us stays `nil` → renders as "Unknown"/omitted, never guessed.
`io_object_t` handles are released with `IOObjectRelease`. Runs off the main actor.

**When we capture:**

- **At scan time** — in `Scanner` (`run`), probe `scanRoot` and persist via `findOrCreateVolume`.
  Scanner stays MutationGuard-clean (calling `DriveHardwareProbe.read` introduces no forbidden token).
- **On connect** — `AppEnvironment` observes the same NSWorkspace mount notifications behind
  `VolumeService`. When a cataloged drive becomes connected, re-probe (off-main) and persist if the
  result differs from what's stored. This backfills the existing catalog (all hardware starts null)
  and keeps the negotiated speed current (same drive in a USB-2 vs USB-3 port updates).
- **Disconnected** drives show their last-known snapshot.

---

## 3. Persistence & service API (`LibraryService`)

`VolumeSummary` gains `groupId: Int64?`, `sortIndex: Int`, `hardware: DriveHardware?`
(decoded from the `v.hardware` JSON column). `volumes()` ordering changes from
`ORDER BY v.name` to: order by the drive's group sortIndex (ungrouped last), then the drive's
`sortIndex`, then name as a stable tiebreaker.

New methods (all via `db.writer`):

- `groups() -> [DriveGroup]` — ordered by `sortIndex`.
- `createGroup(name:) -> DriveGroup` — appended at `MAX(sortIndex)+1`.
- `renameGroup(id:name:)`
- `deleteGroup(id:)` — relies on `ON DELETE SET NULL` to orphan drives to ungrouped.
- `setGroupCollapsed(id:collapsed:)`
- `reorderGroups(orderedIds: [Int64])` — set each group's `sortIndex` to its position.
- `reorderDrives(orderedVolumeIds: [Int64], inGroup: Int64?)` — the single primitive for both
  move and reorder: set each listed drive's `groupId = inGroup` and `sortIndex = position`.
- `updateHardware(volumeId:hardware:)` — fetch + set + update (keeps GRDB JSON handling).

These are vended through `Catalog.library` (already constructed with `db` write access).

---

## 4. Sidebar UX (both Modern and Classic)

**Structure.** The flat "Drives" list becomes named **group sections** (by `sortIndex`) followed
by an **Ungrouped** section. Each group is a collapsible header — name · drive count · chevron —
with its ordered drives beneath. When there are no groups, the ungrouped drives render as today's
plain list (no header chrome), just reorderable.

`AppEnvironment` exposes a computed `[DriveGroupSection]` (each = optional `DriveGroup` + its
ordered `[VolumeSummary]`), built from `volumeSummaries` + a loaded `groups` array. Both sidebars
consume that same structure and call the same `AppEnvironment` operations; only visual treatment
differs.

**Four drag interactions** via SwiftUI `.draggable` / `.dropDestination(for:)` with small
`Codable & Transferable` payloads (`DriveDragPayload{volumeId}`, `GroupDragPayload{groupId}`):

1. Reorder a drive within its group — drop on a row inserts before it.
2. Move a drive to another group — drop on a different group's row/area reassigns `groupId`.
3. Move a drive to Ungrouped — drop on the Ungrouped area clears `groupId`.
4. Reorder group sections — drag a group header onto another.

Each drop recomputes the affected group's ordered id list and calls
`AppEnvironment.reorderDrives(...)` / `reorderGroups(...)`.

**Group lifecycle.** A "+" affordance in the Drives section header creates a new group ready for
inline rename. A drive's context menu gains "New Group from Drive…" and a "Move to ▸" submenu of
existing groups (plus "Ungrouped"). Rename = double-click header or context menu. "Delete Group"
drops its drives back to Ungrouped.

**Drive-type badge in the row.** Each drive row gains a compact badge line: **bus icon + speed +
medium** (e.g. Thunderbolt glyph · "40 Gb/s" · "SSD"). Unknown facts are omitted (no clutter in
the tight row). Modern places it as a thin micro-pill row under the name, above the capacity
minibar; the existing "{bytes} · {count} files" subtitle stays. Classic places the same facts in
its caption styling. Full hover tooltip shows vendor/model.

A presentation helper `DriveHardwareDisplay` (app `Support/`) derives from `DriveHardware`:
- `busIcon` (SF Symbol), `busLabel`
- `speedLabel` ("10 Gb/s") and a `generationLabel` ("USB 3.2 Gen 2") best-effort from bus+speed
- `mediumLabel` ("SSD"/"HDD"), `connectionLabel` ("Internal"/"External")
- `badgeText` (compact, for the row) and ordered `detailRows` (for the detail panel)

---

## 5. Drive detail view (hardware panel)

Both detail surfaces gain a "Drive" info panel populated from `summary.hardware`:

- **Classic** — `DriveHeaderBar` in `VolumeBrowserView`: add a compact spec line / panel
  (Bus · Generation · Speed · Medium · Internal/External · Vendor · Model · "updated <relativeDate>").
- **Modern** — `VolumeBentoWorkspace`: a small hardware card (or rows in the OLED hero area),
  matching the bento/glass styling.

When `hardware` is nil (never connected since the feature shipped) the panel shows
"Connect this drive to detect its type." Disconnected drives show last-known values with the
`capturedAt` relative date.

---

## 6. Error handling & edge cases

- **Probe failure / partial data:** every field is optional; a failed probe yields `nil`
  hardware and the UI degrades to "Unknown"/omitted. Never blocks a scan.
- **No-UUID drives:** identity still falls back to name (existing behavior); grouping/order/hardware
  all key off the `volume.id`, so they're unaffected.
- **Re-probe loop safety:** on-connect capture persists only when the probed hardware differs from
  the stored snapshot, then reloads summaries once — no notification feedback loop.
- **Concurrent reorder + scan:** reorder/group writes touch only `volume.groupId/sortIndex` and
  `driveGroup`; scans touch `snapshot`/`entry` and `volume` identity — no contention beyond GRDB's
  serialized writer.
- **Migration idempotency:** v5 is additive; existing rows get sortIndex from current name order,
  null group/hardware. All existing tests run v1–v5 via `Fixture.makeCatalog()`.
- **Empty groups:** allowed (a group with zero drives still renders its header).

---

## 7. Testing

- **`MutationGuardTests`**: add `DriveHardwareProbe.swift` to the guarded source list; assert it
  contains no mutating tokens.
- **Migration/grouping test** (new, `DiskGalleryCoreTests`): create groups, assign + reorder drives
  via `LibraryService`, assert `volumes()` returns the expected group-then-drive order; assert
  `deleteGroup` orphans drives to ungrouped; assert v5 backfill preserves alphabetical order.
- **`DriveHardware` codec round-trip**: encode/decode through the `volume.hardware` JSON column.
- The probe's live IOKit/DA output is environment-dependent, so it is exercised manually
  (no deterministic unit test); its *purity* is covered by MutationGuard.

---

## 8. File-level change list

**Core (`DiskGalleryCore/`):**
- `Data/Models.swift` — add `DriveHardware`, `DriveGroup`; extend `Volume` (groupId, sortIndex, hardware).
- `Data/Migrations.swift` — v5.
- `Scanning/DriveHardwareProbe.swift` — NEW probe.
- `Scanning/Scanner.swift` — probe at scan; `findOrCreateVolume` takes hardware + sets sortIndex.
- `Library/LibraryService.swift` — VolumeSummary fields, query ordering, group/reorder/hardware API.

**App (`DiskGallery/`):**
- `App/AppEnvironment.swift` — load groups, `[DriveGroupSection]`, group/drive ops, on-connect hardware capture.
- `Support/DriveHardwareDisplay.swift` — NEW presentation helper.
- `Views/Modern/ModernSidebar.swift` — grouped sections, drag, group lifecycle, row badge.
- `Views/LibrarySidebarView.swift` — same for Classic.
- `Views/Modern/…Workspace` + `Views/VolumeBrowserView.swift` — hardware detail panel.

**Tests (`DiskGalleryCoreTests/`):**
- `MutationGuardTests.swift` — add probe to guarded list.
- NEW grouping/migration + hardware-codec tests.
