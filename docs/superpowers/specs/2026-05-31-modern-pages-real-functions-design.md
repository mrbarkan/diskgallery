# Design — Modern Pages: Make the Rendered-Only Bits Real (Launch Slice)

> Companion to `docs/superpowers/plans/future-modern-pages-real-functions.md`.
> This spec turns on four of the five backlog items for launch — all **non-destructive**.
> §4 (the destructive copy/move/delete `TransferService`) is **deferred past launch**; this
> spec only makes the Transfer page *honest* about that.

## Scope

In scope (all non-destructive — the app never moves or deletes files):

- **§1** Duplicates file-type filter chips actually filter the list.
- **§2** Duplicates keep-rule engine picks the right copy to keep (Newest / Largest drive / Fastest→Largest).
- **§3** Action Plan "Run plan" performs a real **Finder-tag sync** to connected drives.
- **§5** Search recent persistence + standalone saved-search scopes.
- **§4 (polish only)** Transfer page disables "Start transfer" with a "coming soon" note; the engine is deferred.

Out of scope: real copy/move/delete (`TransferService`), drive speed-class signal, queue persistence.

## Guiding constraints

- DiskGallery stays read-only except for Finder-tag writes — the existing `FinderTagWriter`
  is still the **only** component that writes to a scanned drive.
- No visual redesign. Only behavior turns on; layouts and styling are unchanged.
- Core logic (categories, keep-rule, search filters) lives in `DiskGalleryCore` and is unit-tested.

---

## Shared foundation — `FileCategory` (new)

**File:** `DiskGalleryCore/Data/FileCategory.swift`

```
public enum FileCategory: String, CaseIterable, Sendable {
    case all, photos, video, raw, documents

    public var label: String   // "All", "Photos", "Video", "RAW", "Documents"
    public static func category(forExtension ext: String) -> FileCategory   // .all if unmatched
    public func matches(filename: String) -> Bool   // .all matches everything
}
```

Extension groups (lowercased, from the backlog):

- RAW: `cr2 cr3 nef arw dng raf orf rw2 srw`
- Photos: `jpg jpeg png heic heif tiff tif gif webp`
- Video: `mov mp4 m4v avi mkv mts m2ts prores`
- Documents: `pdf doc docx txt md rtf pages key numbers xlsx csv`

`category(forExtension:)` returns `.all` for anything unmatched (so an "unknown" file only ever shows
under "All"). Reused by §1 (Duplicates chips) and §5 (Photos·RAW saved search).

**Tests** (`DiskGalleryCoreTests/FileCategoryTests.swift`): representative extensions per group, case
insensitivity, no-extension and unknown-extension → `.all`-only membership.

---

## §1 — Duplicates file-type filter chips

**File:** `DiskGallery/Views/Modern/ModernDuplicatesPage.swift` → `DupSetsCard`.

- Map the chip label (`All/Photos/Video/RAW/Documents`) to a `FileCategory`.
- Compute `visibleSets = sets.filter { category.matches(filename: $0.name) }` (`.all` → all sets).
- Drive the `List` and the card header meta (`"N sets · X reclaimable"`) from `visibleSets`
  (header reclaimable = `visibleSets.reduce(0){ $0 + $1.reclaimable }`).
- The bottom-left "Reclaimable across all drives" tile keeps using `env.totalReclaimable`
  (it is explicitly a global figure — unchanged).
- Selection (`selectedSetID`) persists across filtering; a hidden selected set simply isn't shown.
  The Resolve card continues to show whatever is selected.

**Acceptance:** selecting a chip narrows the list; the card header counts reflect the filtered subset.

---

## §2 — Duplicates keep-rule engine

**New (Core):** `DiskGalleryCore/Duplicates/KeepRule.swift`

```
public enum KeepRule: String, CaseIterable, Sendable {
    case fastestDrive, newest, largestDrive
    public var label: String   // "Fastest drive", "Newest", "Largest drive"
}

// Pure, testable. `capacities` maps volumeKey -> totalCapacity.
// Returns the entryId of the member to KEEP (others get tagged Delete).
public func keptMemberID(members: [DuplicateMember],
                         rule: KeepRule,
                         capacities: [String: Int64]) -> Int64?
```

Rules:

- **newest** → member with the greatest `modifiedAt` (a `nil` date sorts oldest).
- **largestDrive** → member whose drive (`volumeUuid ?? volumeName` → `capacities`) has the greatest
  `totalCapacity`. Missing capacity sorts smallest.
- **fastestDrive** → **maps to `largestDrive`** (no drive-speed signal exists yet).
- Deterministic tie-breaker: fall back to current order (first by `volumeName`, then `relPath`),
  so results are stable. Empty members → `nil`.

**File:** `ModernDuplicatesPage.swift`

- Add `@State private var capacities: [String: Int64] = [:]`, populated in `loadSets()` from
  `catalog.planning.driveStats()` (`[volumeKey: totalCapacity ?? 0]`).
- Convert the `keepRule` chip `String` to `KeepRule`.
- Compute `keptID = keptMemberID(members:rule:capacities:)`; pass it into `ResolveSetCard`
  so `CopyRow`'s green **KEEP** badge marks the member whose `entryId == keptID`
  (replacing the hard-coded `idx == 0`).
- `tagRedundant(_ ms:)` tags every member **except** `keptID` as `.delete`
  (was: `ms.dropFirst()`). `deleteRedundant()` and `autoResolveAll()` both route through it;
  `autoResolveAll()` recomputes the kept member per set using the same rule + capacities.
- When `fastestDrive` is selected, show a `ModernNote`: "No drive-speed data yet — keeping the copy on
  the largest drive."

**Acceptance:** changing the rule re-marks which copy shows the green **KEEP** badge, and "Delete N"
tags the correct redundant copies.

---

## §3 — Action Plan "Run plan" = Finder-tag sync

**Insight:** `AppEnvironment.apply()` already writes Finder tags to disk *at tag time* when the drive
is connected. So when an item is tagged while its drive is offline, the catalog holds the annotation
but the file on disk does not. "Run plan" reconciles that: it **pushes every catalogued annotation
onto its drive, for all connected drives**. This is the same non-destructive write the app already
performs, just batched — the natural first real action.

**New (Core):** `AnnotationStore.all() async throws -> [Annotation]` — every annotation row
(`volumeUuid` [= volume key], `relPath`, `tag`, `color`). Includes color-only annotations so the sync
is complete.

**New (App):** `AppEnvironment.syncFinderTags() async -> TagSyncResult`

```
struct TagSyncResult {
    var drivesSynced: Int
    var filesWritten: Int
    var drivesSkipped: Int   // offline
    var filesSkipped: Int    // on offline drives
    var failures: Int        // write errors
}
```

- Fetch `catalog.annotations.all()`, group by `volumeUuid` (the volume key).
- For each group: resolve the mount via `volumes.mountURL(forKey:)`.
  - Connected → write each annotation's `tag` + `color` to `mount/relPath` via
    `catalog.finderTags.apply(decision:color:to:)` on a detached utility task; count written/failures.
  - Offline → count as skipped (drive + files).

**File:** `ModernActionPlanPage.swift` → `ExecutePlanCard`

- Add `@State` for `running` and `lastResult: TagSyncResult?`.
- `onRun` runs `syncFinderTags()`, disabling the button + showing a spinner while running.
- On completion show an inline `ModernNote`: e.g. "Wrote 128 tags across 2 drives · 14 skipped (offline)".
- Keep the existing `agg.disconnected` warning. **No confirmation sheet** — the operation is
  non-destructive (writing Finder tags is the app's core purpose). Move/Backup/Delete steps in the
  run-order list remain visual only (engine deferred).

**Acceptance:** "Run plan" runs the Finder-tag sync against connected drives with progress and a result
summary; nothing is moved or deleted.

---

## §5 — Search persistence + standalone saved-search scopes

### Recent persistence

**New (App):** `DiskGallery/App/RecentSearchStore.swift` (UserDefaults-backed, mirrors `ShortcutStore`/`ThemeStore`).

```
struct StoredRecentSearch: Codable, Identifiable { var query: String; var count: Int; var date: Date; var id: String { query } }

@Observable final class RecentSearchStore {
    private(set) var items: [StoredRecentSearch]      // newest first, capped at 8, de-duped by query
    func record(query: String, count: Int)            // de-dupe, insert front, cap, persist
    func clear()                                       // persist empty
}
```

- Persisted under a single UserDefaults key as JSON.
- `ModernSearchPage` replaces its in-session `@State recent` with the store (held on `AppEnvironment`
  or as a `@State` instance — held on `AppEnvironment` alongside the other stores for consistency).
- The Recent section gets a "Clear" affordance (small button in `SecHeader` row).

### Saved-search scopes (standalone)

A `SearchFilter` layer **orthogonal** to the existing drive `scope`. Saved searches **run with no typed
query** — selecting one lists all matching entries from the latest snapshots; combining with a typed
query intersects the two.

**Core:** extend `SearchService`.

```
public enum SearchFilter: Sendable, Equatable {
    case none
    case category(FileCategory)   // Photos·RAW etc.
    case tagged(Tag)              // e.g. .delete
    case duplicatesOnly
}

public func search(_ query: String,
                   scope: SearchScope = .all,
                   filter: SearchFilter = .none,
                   limit: Int = 1000) async throws -> [SearchResult]
```

Behavior:

- **Query present** (≥2 chars): current FTS path, plus the filter applied as SQL/post-filter.
- **Query empty + filter ≠ none:** skip the FTS `MATCH`; select entries from each volume's latest
  snapshot (reuse the `latest` CTE pattern), apply the filter, same ordering + limit. (Empty query +
  `.none` → no results, as today.)

Filter implementation:

- `category` → post-filter the fetched rows in Swift via `FileCategory.matches(filename:)`
  (results are capped, so this is cheap and reuses §1).
- `tagged(tag)` → SQL `AND EXISTS (SELECT 1 FROM annotation a WHERE a.relPath = e.relPath AND
  (a.volumeUuid = v.uuid OR (v.uuid IS NULL AND a.volumeUuid = v.name)) AND a.tag = ?)`.
- `duplicatesOnly` → SQL: entry's `(name, logicalSize)` appears ≥2× among non-dir entries in the
  latest snapshots (reuse the `latest` CTE + a correlated count ≥ 2).

`SearchResult` gains `volumeUuid: String?` only if needed for matching; tagged/duplicates resolve in
SQL so no new field is required.

**File:** `ModernSearchPage.swift`

- Add a second chip row of saved searches (`Photos·RAW`, `Duplicates only`, `Tagged: Delete`),
  each toggling a `@State filter: SearchFilter` (re-selecting clears to `.none`).
- `showResults` becomes `trimmed.count >= 2 || filter != .none`.
- `runSearch()` passes `scope` + `filter`; `record(...)` only stores entries that have a typed query
  (a pure filter run with empty text isn't a "recent search").

**Tests** (`DiskGalleryCoreTests/SearchTests.swift` additions): category filter, tagged filter,
duplicates-only filter — each with a typed query and standalone (empty query).

**Acceptance:** recent searches survive relaunch and are clearable; each saved-search chip returns
correctly filtered results, including with no typed query.

---

## §4 — Transfer page launch polish (engine deferred)

**File:** `ModernTransferPage.swift` → `TransferSummaryTile`.

- Disable the "Start transfer" `CTAButton` and add a `ModernNote`: "Transfer engine coming soon —
  this page plans the move; files aren't copied yet."
- Replace the `… est. — over USB-C` line with `… est. — · planning only` (drop the hard-coded "USB-C").
- The real queue, destination picker, and projections are unchanged (already real and useful).

**Acceptance:** the Transfer page makes no false promise — Start is clearly disabled and labeled;
queue and projections still work.

---

## Sequencing

1. `FileCategory` (foundation) + tests.
2. §1 filter chips (depends on `FileCategory`).
3. §2 keep-rule (Core `KeepRule` + tests, then page wiring).
4. §3 Finder-tag sync (`AnnotationStore.all()` + `syncFinderTags()` + `ExecutePlanCard`).
5. §5 recent persistence, then saved-search filters (depends on `FileCategory`) + tests.
6. §4 Transfer polish.

Each step is independently shippable and leaves the visuals unchanged — only behavior turns on.

## Testing strategy

- **Core unit tests** for `FileCategory`, `KeepRule`, and the three `SearchFilter` modes (these hold
  the real logic and run offline against a temp DB, matching existing `DuplicateTests`/`SearchTests`).
- **Manual smoke** of each page in the app: chips filter; keep-badge moves with the rule; Run plan
  reports a sync summary; recent searches survive relaunch and saved searches filter; Transfer Start
  is disabled.
- Full build + existing test suite stays green.
