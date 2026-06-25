# DiskGallery — Execution Engine ("stage offline → reconnect → execute")

**Date:** 2026-06-25
**Status:** Approved design — ready for implementation plan(s)
**Implement on:** a dedicated branch off `feature/classic-only-declutter`

## Background & motivation

DiskGallery's #1 goal is to let a user **organize many drives while they're
disconnected, then reconnect a drive and have the planned actions execute** — the
thing that turns the app from an offline catalog into the tool that takes ~30 messy
drives down to 4 backups + 3 daily drivers.

Today the app is **strictly read-only**: it catalogs, finds duplicates, computes a
non-destructive `OrganizationPlanner` plan (ordered `copy/move/delete/verify` steps
with destinations + dependencies), and writes only explicit Finder tags. It never
moves, copies, or deletes a user file. `MutationGuardTests` actively forbids file
mutation in the scanner/hasher. `VolumeService` already detects mount/unmount but
only refreshes the drive list. `Feature.transfer` is a reserved (unbuilt) Pro flag.

This spec adds the missing layer: a **verified file-operation executor** plus a
**persisted operation record** and a **reconnect-driven run flow**. It is the app's
first deliberate file-mutation surface.

## The four decisions this design is built on

1. **Scope:** the full engine — **Copy, Move, and Delete** — in one spec.
2. **Reconnect behavior:** **confirm-once review sheet.** On mount, a sheet
   summarizes the runnable operations; one click runs the batch; destructive ops are
   always behind this gate.
3. **Staging model:** operations are **derived from existing tags + the Organize
   plan** (no separate manual "commit" step); execution keeps an audit log.
4. **Delete safety:** a file may be deleted only once a **SHA-256-verified identical
   copy exists on a backup-role drive**; the last verified copy is never deleted;
   unverifiable deletes are skipped, not guessed.

## Goals

- Execute Copy/Move/Delete on user drives, triggered by reconnect, behind a
  confirm-once sheet, in the planner's dependency order.
- Verify every write by checksum before it's trusted; never lose data.
- Persist operation state so runs are **resumable** and **auditable**.
- Keep cataloging strictly read-only; isolate mutation in a new, well-tested module.
- Classic-native UI; gated behind the `Feature.transfer` Pro flag.

## Non-goals

- No Modern UI work (per the Classic-only direction).
- No new tagging/planning model — reuse `annotation` tags, drive roles, and
  `OrganizationPlanner`.
- No background/daemon execution — operations run only while the app is open and the
  user has confirmed (mount surfaces the sheet; the user clicks Run).
- No cloud/remote destinations — local mounted volumes only.
- No app-sandbox / security-scoped bookmarks in this milestone (the app ships
  Developer-ID, hardened-runtime, non-sandboxed; `Volume.bookmark` stays reserved).

## Architecture & the read-only boundary

A new **`DiskGalleryCore/Execution/`** module — the app's only deliberate
file-mutation surface, separate from `Scanning/`.

- `ExecutorService` (exposed as `catalog.execution`) — materializes operations from
  the plan, runs them with verification, updates their records.
- Reuses `HashVerifier` (SHA-256) for verification — no duplicated hashing.
- Consumes `OrganizationPlanner` `PlanStep`s (operation, sourceDriveKey/sourcePath,
  destinationDriveKey/destinationPath, bytes, dependsOn, orderIndex, feasibility).
- **`MutationGuardTests` stays scoped to `Scanning/` + hashing** (those remain
  read-only). The executor is explicitly allowed to mutate and is covered by its own
  tests against temp fixtures.
- Gated behind `Feature.transfer` (Pro). Free tier still tags, plans, and reviews;
  running operations requires Pro.

## Data model — the `operation` table

A new GRDB table + migration. Operations are **materialized from the live plan at run
time** (decision 3), but each materialized op gets a persisted record so a run is
resumable and becomes history.

`Operation` fields:
- `id`
- `type`: `copy | move | delete`
- `sourceVolumeKey`, `sourceRelPath`
- `destVolumeKey?` (from the plan), `destRelPath?` — the destination path **mirrors
  the source's relative path** on the destination volume (preserving structure);
  collisions are handled by the conflict rule below. Both nil for delete.
- `backupVolumeKey?`, `backupRelPath?` (the verified surviving copy, for delete)
- `bytes`
- `sourceHash?`, `destHash?` (filled during verification)
- `status`: `pending → running → verified → done | failed | skipped`
- `failureReason?`, `skipReason?`
- `dependsOn?` (operation id; from the plan's `dependsOn`)
- `createdAt`, `startedAt?`, `finishedAt?`

Completed/failed/skipped rows are retained as the **audit log / history**. Volume keys
use the same `uuid ?? name` identity as the rest of the catalog, so records survive
re-scans and reconnects.

## Operation lifecycle & safety invariants

The invariants are non-negotiable; the executor enforces them regardless of UI.

- **Copy / Backup:** stream source → a **temp file on the destination volume** →
  SHA-256 verify temp against source (`sourceHash == destHash`) → **atomic rename**
  into the final path → `done`. A failed verify discards the temp and marks `failed`.
- **Move:** perform a verified Copy (above), then **Trash the source**. The source is
  never touched until the destination copy is checksum-verified.
- **Delete:** find the candidate surviving copy (same name+size on a **backup-role**
  drive, per `DriveRole`), require **both files connected**, SHA-256-verify they are
  identical, confirm it is **not the last verified copy**, then **Trash** the target.
  If the backup copy can't be verified (drive offline, hash mismatch, none exists) →
  `skipped` with reason, surfaced in the sheet. Never guessed.
- **Trash, not permanent delete:** all deletes/moves remove the source via the macOS
  Trash (`FileManager.trashItem`), recoverable. *Permanent delete is a future opt-in
  setting, out of scope here.*
- **Conflict at destination:** if an identical (hash-matching) file already exists at
  the destination path → `skipped` (already there). If a **different** file exists →
  `skipped` + flagged; **never silently overwrite**.
- **Resumable / idempotent:** atomic rename + temp files mean an unmount/quit
  mid-operation leaves a clean state (orphan temp discarded on next run); re-running
  continues from `pending`/`failed` without redoing `done` ops.
- **Ordering & dependencies:** execute in the planner's order (deletes-free-space
  first), honoring `dependsOn`. A `failed` op marks its dependents `skipped`
  (dependency unmet); independent ops still run.

## Reconnect flow & multi-drive orchestration

1. `VolumeService`'s existing mount notification fires → refresh (as today).
2. If Pro, compute the **runnable subset**: operations (derived from the current
   plan) whose **every required volume is currently connected** — source +
   destination for copy/move; source + backup-copy drive for delete.
3. Present the **confirm-once sheet**: counts and bytes per type, space freed, and an
   explicit list of **skipped** ops with reasons (offline dependency, conflict,
   unverifiable delete).
4. On **Run**: materialize/refresh `operation` records, execute in order with a
   **progress HUD + Cancel**. Cancel stops cleanly between operations — no partial
   deletes, no half-files.
5. Record every result to history; **clear/update the source annotation** for
   completed move/delete ops. Catalog snapshots reflect the changes after the affected
   drives are **re-scanned** (the run offers to re-scan them); the executor does not
   surgically rewrite snapshot rows.
6. Operations whose drives aren't all present remain pending until a future reconnect
   makes them runnable.

## UI (Classic-native)

- **Organize** home (the existing Plan view) is the **preview** of what will run; the
  reconnect **confirm sheet** is the commit point.
- An **Activity / History** view — shown as a **segment in the Organize home**
  (`[Plan · By drive · Activity]`) rather than a separate sidebar row, since a new
  `SidebarItem` case would force editing the frozen Modern switch — lists running /
  pending / done / failed / skipped operations with reasons and the audit trail; later
  stages add **retry** of failed ops and **cancel** of pending ones.
- A **progress HUD** during a run (current op, throughput, count, Cancel).
- All native SwiftUI; no files under `Views/Modern/`.

## Testing strategy

- The executor is unit-tested in `DiskGalleryCore` against **temp-directory
  fixtures** (real copy/move/trash on throwaway trees): verified-copy success and
  checksum-mismatch failure; Move trashes source only after verify; Delete requires a
  backup-verified copy and refuses the last copy; conflict-skip (identical vs
  differing); resume after simulated interruption (orphan temp + re-run); dependency
  ordering and dependent-skip-on-failure.
- `MutationGuardTests` is unchanged and continues to assert the **scanner/hasher**
  perform no mutation.
- App-layer (reconnect sheet, Activity view, HUD) verified by build + manual smoke
  (no app unit-test target).

## Delivery (staged)

One spec, but the implementation is **staged so each stage lands verified-green and
there is never a half-built destructive path** — likely one implementation plan per
stage:

1. **Infra + Copy** — `operation` table + migration, `ExecutorService` with verified
   copy, the reconnect runnable-subset computation + confirm sheet + progress/cancel,
   Activity/History view, Pro gate. Non-destructive; proves the whole architecture.
2. **Move** — add verified-copy-then-Trash-source.
3. **Delete** — add the backup-role SHA-256 verification + never-last-copy guard +
   Trash.

## Risks & rollback

- **Data loss is the central risk.** Mitigated by: copy→verify-before-trust, Trash
  (recoverable) rather than permanent delete, never-delete-last-verified-copy,
  atomic-rename (no half-files), confirm-once gate, and staged delivery.
- **Stale plan vs reality:** ops validate at run time (source exists, dest has room,
  hashes) and skip safely if reality changed since tagging.
- **Interrupted runs:** resumable by design; orphan temp files are discarded.
- **Reversibility of the feature:** entirely Pro-gated and isolated in `Execution/`;
  disabling the flag returns the app to its read-only behavior.

## Future (out of scope here)

- Permanent-delete opt-in; empty-Trash-after-run helper.
- Background/auto-run without the confirm sheet (a per-drive "always run copies"
  preference).
- Per-drive "safe to wipe" rollup view (this spec verifies wipe-safety per *delete
  operation*; a whole-drive verdict is a separate feature).
- Sandboxed build using `Volume.bookmark` for security-scoped access.
