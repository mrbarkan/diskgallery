# Spec — "All Drives" Unified Browser with Coverage + Comparison (M2)

**Date:** 2026-06-06
**Status:** Approved in brainstorming (scope confirmed); pending spec review.
**Depends on:** M1 Organize workspace + M1.5 drive roles — shipped/committed.
**Precedes:** drift-diff and one-click→Organize bulk actions (deferred follow-ups); M3 infinite-zoom map.

## Context

DiskGallery's founding purpose is a birds-eye view of a sprawling multi-drive archive: browse every drive's files **as if they were one disk**, see where the same folder lives across drives, compare backups, and turn decisions into a non-destructive Organize plan. The catalog already persists every scanned drive (so offline drives are browsable), and M1 turns Move/Backup/Delete tags into an ordered transfer plan. What's missing is the cross-drive *view* that feeds it.

This sprint builds the **"All Drives"** workspace. Beyond merged browsing, it answers the three questions a multi-drive owner actually loses sleep over:
1. **What would I lose if a drive died?** → a **backup-coverage lens** surfacing items that exist on only one drive.
2. **Which of these copies is the real one?** → **copy comparison** flagging the reference (largest/newest) copy and stale/partial ones.
3. (Deferred) bulk "back up all at-risk" / "delete stale copies" one-click actions, and file-level folder drift diff.

Strictly **non-destructive** — the view only reads the catalog and writes Finder-tag annotations (which feed Organize).

## Scope (confirmed)

**In:**
- Merged "browse all drives as one" tree (merge by relative path across each drive's latest snapshot).
- **Backup-coverage lens:** per-node coverage classification + color/badge + an "at-risk only" filter + a headline summary.
- **Copy comparison:** per-node reference-copy selection, stale/partial flags, file-level identical/differs (via content hash), reclaimable-redundancy figure.
- **Per-item tagging** of a specific drive's copy (reuses the existing annotation flow; feeds Organize).
- Both skins (Modern page + Classic view).

**Deferred (follow-up sprints):**
- Bulk one-click → Organize ("back up all at-risk", "tag stale duplicate copies for delete").
- Folder drift diff (file-level "what copy A has that copy B doesn't").
- Cross-drive coverage OLED layout; conflict-resolution UI for name file/dir clashes.

---

## Architecture — the cross-drive data layer (M0)

A new Core service, **`UnifiedBrowserService`** (in `DiskGalleryCore/Unified/`), encapsulating the merge query. GRDB stays behind it; the app consumes value types. The merge math (reference selection, coverage, redundancy) is split into a **pure, unit-testable function** so it needs no DB.

### Types
```
public enum Coverage: String, Sendable { case atRisk, backedUp, protected }   // 1 / 2 / 3+ drives

public struct UnifiedCopy: Sendable, Identifiable, Equatable {
    public var id: String            // "volumeKey|relPath"
    public var volumeKey: String
    public var volumeName: String
    public var isConnected: Bool
    public var size: Int64           // entry.displaySize (subtree for dirs, logical for files)
    public var modifiedAt: Date?
    public var contentHash: String?  // files only
    public var entryId: Int64
    public var snapshotId: Int64
    public var isReference: Bool     // the "best" copy (computed)
    public var isPartial: Bool       // < 90% of reference size (computed)
    public var matchesReference: Bool? // files: hash == reference hash; nil for dirs/unknown
}

public struct UnifiedNode: Sendable, Identifiable, Equatable {
    public var id: String            // relPath (stable)
    public var relPath: String
    public var name: String
    public var isDir: Bool           // dir if any copy is a dir
    public var copies: [UnifiedCopy] // sorted: reference first, then size desc, then name
    public var referenceSize: Int64  // the reference copy's size (the "one disk" size)
    public var redundantSize: Int64  // Σ copy sizes − referenceSize (reclaimable if de-duped)
    public var driveCount: Int
    public var coverage: Coverage
}

public struct CoverageSummary: Sendable, Equatable {
    public var atRiskBytes: Int64; public var atRiskCount: Int     // top-level granularity
    public var redundantBytes: Int64
    public var driveCount: Int; public var scannedDriveCount: Int
}
```

### Methods
- `children(ofPath parentPath: String, hideHidden: Bool) async throws -> [UnifiedNode]`
  - `parentPath == ""` → root (top-level entries of every drive).
  - For each volume's **latest snapshot**, fetch the **direct children** at `parentPath` (entries whose parent path equals `parentPath`). Reuse the existing "latest snapshot per volume" CTE; select direct children by `parentId` of the path's entry, or by `relPath` being a single segment under `parentPath`.
  - Group children by `name`; build one `UnifiedNode` per name with its `copies`. `hideHidden` drops dotfiles (consistent with `ViewPrefsStore.hideHidden`).
  - Sort nodes: directories first, then by `referenceSize` desc, then name (case-insensitive).
- `summary(hideHidden: Bool) async throws -> CoverageSummary`
  - Computes coverage over **top-level** merged nodes (cheap, meaningful: "these whole folders have no backup"). `atRiskBytes/Count` from nodes with `coverage == .atRisk`; `redundantBytes` = Σ node.redundantSize. Finer per-subtree at-risk is a noted future enhancement.

### Pure analysis (testable without a DB)
`static func analyze(copies:) -> (reference: index, isPartial flags, matchesReference flags, referenceSize, redundantSize, coverage)`:
- **Reference** = largest `size`; tie → newest `modifiedAt`; tie → connected; tie → smallest `volumeKey`.
- **isPartial** = `size < referenceSize * 0.9`.
- **matchesReference** (files only, when both hashes present) = `contentHash == reference.contentHash`; nil otherwise.
- **redundantSize** = `Σ size − referenceSize`.
- **coverage** from `copies.count` (1 → atRisk, 2 → backedUp, ≥3 → protected).

### Catalog wiring
`Catalog` vends `public let unified: UnifiedBrowserService`.

### Edge cases
- Volumes with **no latest snapshot** are excluded (nothing catalogued to merge). Offline-but-scanned volumes **are** included (the whole point) — their copies are marked `isConnected == false`.
- **name file/dir clash** across drives: node `isDir = true` if any copy is a dir; mixed copies still listed. (No special conflict UI this sprint.)
- Empty catalog / no scanned drives → empty result; UI shows an empty state.

---

## Navigation

- `AppEnvironment.SidebarItem`: add `case allDrives` (no associated value) + `token`/`init?(token:)`.
- Two exhaustive switches: `ContentColumn` (Classic, `DiskGalleryApp.swift`) → `AllDrivesView`; `ModernWorkspace` → `ModernAllDrivesPage`.
- Both sidebars (`ModernSidebar`, `LibrarySidebarView`): a **top-level "All Drives"** entry above the per-drive list (icon `square.stack.3d.up.fill`), with a small at-risk badge (count) from the coverage summary.

## Modern UI (`Views/Modern/ModernAllDrivesPage.swift`)

Because "All Drives" isn't a single drive, it does **not** use the per-drive OLED scaffold. Layout, top→bottom:
- **Topbar:** Search pill + (no per-drive actions).
- **Merged path bar:** `All Drives / ARCHIVE / Arduino` (reuses `ModernPathBar`, navigable; root crumb = "All Drives").
- **Coverage banner:** a glass strip with the headline — `⚠ {atRiskBytes} at risk across {atRiskCount} folders · {redundantBytes} redundant · {scannedDriveCount} drives` + an **"At-risk only"** toggle.
- **Bento:** left = merged browser list; right = **comparison inspector** for the selected node.
  - **Browser rows:** coverage dot (🔴 atRisk / 🟡 backedUp / 🟢 protected), name, reference size, an "on N drives" chip, and a partial/stale hint. Folders drill in (update path bar). Honor `hideHidden`.
  - **Comparison inspector:** the selected node's copies — each with drive name, size bar (relative to reference), modified date, badges (Reference ✓ / Partial ⚠ / Offline / Identical-or-Differs for files), and the reclaimable-redundancy figure. Per-copy **tag menu** (Move/Backup/Delete) writing to that drive's copy.

## Classic UI (`Views/AllDrivesView.swift`)

Fits the existing `NavigationSplitView`: content column = merged list (coverage dot + name + size + "on N" + at-risk filter in a toolbar); detail column (`EntryDetailView`-style) = the comparison panel for the selected node with per-copy tag actions. Minimal but functional; same data, same coverage/comparison.

## App glue (`AppEnvironment.swift`)
- `unifiedChildren(path:) async -> [UnifiedNode]` and `unifiedCoverage() async -> CoverageSummary` wrappers (pass `viewPrefs.hideHidden`), with the standard `report(error)` handling.
- `tagCopy(_ tag: Tag, copy: UnifiedCopy)` → `catalog.annotations.setDecision(tag, volumeKey:relPath:)` + `dataVersion += 1` (so Organize and badges refresh).
- Coverage summary cached/observable for the sidebar badge, refreshed on `dataVersion`/`refresh()`.

## Testing

**Unit (Core, TDD) — `UnifiedBrowserServiceTests` + pure-analysis tests:**
- merge: two drives sharing a top-level folder name → one node, two copies, `driveCount == 2`; distinct names → separate nodes.
- reference selection: largest wins; equal size → newest `modifiedAt`; then connected; deterministic final tie-break.
- `isPartial`: a copy < 90% of reference flagged; ≥ 90% not.
- `matchesReference`: file copies with equal/!= `contentHash`; nil for dirs.
- `redundantSize` and `referenceSize` math.
- coverage classification 1/2/3 → atRisk/backedUp/protected.
- `hideHidden` drops dotfiles; offline scanned drive still contributes a copy (marked disconnected).
- nested path children; root children; volume with no snapshot excluded.
- `summary`: at-risk top-level totals + redundant bytes.

**Build:** `xcodebuild test -scheme DiskGalleryCore` + `xcodebuild -scheme DiskGallery build` (both exhaustive switches + new sidebar item compile).

**Manual:** scan ≥2 drives (some sharing folders, one offline); open All Drives; confirm merged tree, coverage dots + headline + at-risk filter, comparison inspector (reference/partial/offline/identical), drill-down, hideHidden, tagging a copy shows up in Organize; nothing is moved.

## Build order
1. Core `UnifiedBrowserService` + pure analysis + tests (TDD) — green in isolation.
2. Nav: `SidebarItem.allDrives`, both switches (placeholders), both sidebars' top entry.
3. Classic `AllDrivesView` (fastest real end-to-end consumer).
4. Modern page: path bar + coverage banner + merged browser.
5. Modern comparison inspector + per-copy tagging.
6. Sidebar at-risk badge + coverage summary wiring.
7. Adversarial review; fix confirmed findings.

## Flagged defaults (say the word to change)
1. Merge key = **relative path** (name-based), not content hash. Same path on N drives = "same logical item, possibly different copies."
2. Reference copy = **largest**, then newest — size is the most reliable "most complete" signal for folders (folder mtime is shallow).
3. Coverage thresholds: 1 = at-risk, 2 = backed up, 3+ = protected.
4. Headline coverage computed at **top-level-folder** granularity (cheap, meaningful); finer per-subtree at-risk is a future enhancement.
5. Per-item tagging is in; **bulk** smart-suggestion buttons are deferred.
6. All-Drives Modern page replaces the per-drive OLED hero with a coverage banner.
