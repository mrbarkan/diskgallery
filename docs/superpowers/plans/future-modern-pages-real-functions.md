# Future Sprint — Modern Pages: Make the Rendered-Only Bits Real

> Companion to `2026-05-31-modern-pages-faithful.md`. That plan shipped the four Modern
> pages (Duplicates, Action Plan, Transfer Planner, Search) **visually complete** and bound
> every value to real data, with action buttons wired to real *non-destructive* operations.
> This backlog covers the mockup elements that are currently **rendered but not yet functional**,
> with a concrete approach for each so they can be picked up next sprint.

**Context for a fresh engineer:** DiskGallery is a read-only macOS catalog of external drives.
Today the app never deletes, moves, or copies files — it scans, indexes, finds duplicates, and
writes **Finder tags** (color labels) onto files. The Modern pages live in
`DiskGallery/Views/Modern/`; Core services live in `DiskGalleryCore/`. Each item below names the
exact file(s) and the smallest real capability that makes the rendered element honest.

---

## 1. Duplicates — file-type filter chips

**Where:** `ModernDuplicatesPage.swift` → `DupSetsCard` (`@Binding var filter` / `chips`).
**Now:** Chips All / Photos / Video / RAW / Documents render and toggle, but don't filter the list.
**Make it real:**
- Add a `category` derivation by extension. Suggested groups:
  - RAW: `cr2 cr3 nef arw dng raf orf rw2 srw`
  - Photos: `jpg jpeg png heic heif tiff tif gif webp`
  - Video: `mov mp4 m4v avi mkv mts m2ts prores`
  - Documents: `pdf doc docx txt md rtf pages key numbers xlsx csv`
- Filter `sets` in `DupSetsCard` by `(set.name as NSString).pathExtension.lowercased()` membership; "All" = no filter.
- Optional (cleaner): add `var category: FileCategory` to `DuplicateSet` in `DuplicateEngine.swift` so the grouping is computed once at query time and reusable by other views.
**Acceptance:** selecting a chip narrows the list; counts in the header reflect the filtered subset.

## 2. Duplicates — keep-rule engine

**Where:** `ModernDuplicatesPage.swift` → `ResolveSetCard` (`keepRule` chips) + `tagRedundant`.
**Now:** "Fastest drive / Newest / Largest drive" chips render; the keep-rule is hard-coded to "keep the first sorted copy."
**Make it real:** choose which `DuplicateMember` to keep based on the selected rule, then tag the rest Delete:
- **Newest:** keep `max(by: modifiedAt)`.
- **Largest drive:** keep the copy whose drive has the greatest `DriveStats.totalCapacity` (join member → drive).
- **Fastest drive:** needs a drive-speed signal. Either (a) infer from `fsType`/connection bus if exposed by `VolumeService`, or (b) add a per-drive "speed class" the user sets once. Until then, treat "Fastest" as "Largest drive" and note it.
**Acceptance:** changing the rule re-marks which copyrow shows the green **Keep** badge, and "Delete N" tags the correct redundant copies.

## 3. Action Plan — execute the plan

**Where:** `ModernActionPlanPage.swift` → `ExecutePlanCard` (`onRun`, the "Run order" steps).
**Now:** "Run plan" renders; the run-order steps show real amounts but do nothing.
**Make it real (staged, safest first):**
1. **Write Finder tags** (already supported, non-destructive): wire step 1 to `Catalog.finderTags` (`FinderTagWriter`) to push the planned color tags onto connected drives. This is the natural first real action and matches the app's core purpose.
2. **Move / Backup** require a new `TransferService` (see §4). Sequence: verify checksums → move (`.move` items) → back up (`.backup` items) → delete confirmed duplicates (`.delete`).
3. Gate each destructive step behind an explicit confirmation sheet and the existing "N drives must be connected" guard (`PlanAggregate.disconnected`).
**Acceptance:** "Run plan" runs at least the Finder-tag sync against connected drives with progress + a result summary; destructive steps remain opt-in.

## 4. Transfer Planner — real engine + time estimate

**Where:** `ModernTransferPage.swift` → `TransferSummaryTile` (`onStart`, the "est. — over USB-C" line) and the queue.
**Now:** Queue, destination picker, and capacity projections are **real**. "Start transfer" is a no-op and the time estimate shows `—`.
**Make it real:**
- New `TransferService` in `DiskGalleryCore/` performing copy (Backup) / move (Move) with `FileManager`, progress reporting, checksum verification, and cancellation. Update the catalog/annotations on completion.
- **Time estimate:** measure sustained throughput at the start of a transfer (or keep a rolling per-bus average) and compute `estimate = queueBytes / throughput`. Replace the `—` with the live estimate. Avoid hard-coding "USB-C"; derive the bus/label from the destination volume if available, else say "estimated".
- Persist the queue so it survives navigation/relaunch (small Core table or `UserDefaults`).
**Acceptance:** "Start transfer" copies/moves the queued items to the chosen destination with a progress UI; the summary shows a real time estimate; projections match the post-transfer reality.

## 5. Search — persistent recent + saved-search scopes

**Where:** `ModernSearchPage.swift` → `recent` (in-session `[RecentSearch]`) and `scopeChips`.
**Now:** Recent is real but **in-session only**; scopes are All-drives + per-volume (real).
**Make it real:**
- Persist recent searches (query + last result count + timestamp) in `UserDefaults` or a `recent_searches` Core table; cap and de-dupe; clearable.
- Add **saved-search scopes** the mockup hints at — "Tagged: Delete", "Photos · RAW", "Duplicates only" — backed by real predicates:
  - "Tagged: <tag>" → filter results to entries with that annotation.
  - "Duplicates only" → intersect with `DuplicateEngine` membership.
  - "Photos · RAW" → the file-type categories from §1.
  This needs `SearchService.search` (or a wrapper) to accept post-filters / a richer `SearchScope`.
**Acceptance:** recent searches survive relaunch; the saved-search chips return correctly filtered results.

---

## Sequencing suggestion

1. **§1 file-type filter** and **§5 recent persistence** — small, self-contained, no new services.
2. **§2 keep-rule** — pure logic on existing data.
3. **§3 step 1 (Finder-tag sync)** — uses the existing `FinderTagWriter`.
4. **§4 `TransferService`** — the big one; unblocks §3 steps 2–4 and the transfer estimate.

Each is independently shippable and leaves the visuals unchanged — only behavior turns on.
