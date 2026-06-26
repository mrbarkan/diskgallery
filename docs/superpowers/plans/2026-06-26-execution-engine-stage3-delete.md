# Execution Engine — Stage 3 (Delete) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add **Delete** to the execution engine — a file may be sent to the Trash only once a SHA-256-identical copy is verified on a connected **backup-role** drive (a different volume, so the surviving copy is never the last one).

**Architecture:** Build on Stages 1–2. `ExecutorService` gains `backupCandidates` (a catalog query for copies of a file on backup-role drives), `deleteDrafts` (materialize `.delete` plan steps — which have no destination), and `performDelete`. The `run` loop is refactored so the source-connected check applies to all ops while the destination check applies only to copy/move; `.delete` (previously a "not available yet" skip) now runs `performDelete`, which trashes the source only after verifying an identical copy on a connected backup drive — otherwise it skips, never guesses. The reconnect flow surfaces deletes and clears completed-delete source annotations.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 15+, GRDB 7, CryptoKit (via `HashVerifier`), XCTest.

## Global Constraints

- Swift 6.0, macOS 15.0 target.
- **Read-only cataloging preserved.** Do NOT add file-mutating APIs to the 5 files `MutationGuardTests` scans, and do NOT add any `Execution/` file to that test's `sources` list. All mutation stays inside `DiskGalleryCore/Execution/`.
- **Do NOT edit any file under `DiskGallery/Views/Modern/`**, `OLEDDisplayView.swift`, or `ModernTokens.swift`. Do NOT add a new `SidebarItem` enum case.
- **Delete safety invariant (data-loss-critical, non-negotiable):** the source is sent to the macOS **Trash** (never `removeItem`/permanent) and **only after** a SHA-256 hash of the source equals the SHA-256 hash of an existing file on a **connected, backup-role drive** (`DriveRole.mainBackup` or `.fallbackBackup`) that is a **different volume** than the source. Because the surviving verified copy is on another drive, the deleted file is never the last copy. If no such verified copy is reachable, the source is left **untouched** and the op is `skipped` (never guessed, never deleted "optimistically").
- **Idempotent:** re-running a delete whose source is already gone is `.done`, not a failure.
- Reuse `HashVerifier` and `FileTrasher` — no new hashing/trash logic.
- Backup roles are exactly `DriveRole.mainBackup` and `DriveRole.fallbackBackup` (reference these enum cases; don't hardcode strings).
- Execution is Pro-gated (`Feature.transfer`).
- Stage 3 adds **no new source files** (it modifies `ExecutorService.swift`, `AppEnvironment.swift`, `ExecutionConfirmView.swift`), so `xcodegen generate` is not strictly required; the build/test commands include it anyway to keep the project in sync (harmless).
- Verification commands (from repo root):
  - Core tests: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test`
  - App build: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
  - Baseline (Stage 2 complete): build green, **163** Core tests pass. Treat "all green, 0 failures" as the gate (counts approximate).
- App layer has no unit-test target → verified by build + manual smoke.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Branch: `feature/execution-engine` (continue on it; Stages 1–2 already committed there).

## File Structure

- Modify `DiskGalleryCore/Execution/ExecutorService.swift` — add `BackupCandidate` + `backupCandidates`, `deleteDrafts`, a stored `hasher`, refactor `run`, add `performDelete`.
- Modify `DiskGalleryCoreTests/ExecutionTests.swift` — tests for `backupCandidates` and delete execution.
- Modify `DiskGallery/App/AppEnvironment.swift` — surface deletes on reconnect, prompt delete count, clear completed-delete source annotations.
- Modify `DiskGallery/Views/ExecutionConfirmView.swift` — sheet copy including deletes.

---

## Task 1: `backupCandidates` — find verified-copy candidates on backup drives

**Files:**
- Modify: `DiskGalleryCore/Execution/ExecutorService.swift` (add `BackupCandidate` struct + `backupCandidates` method)
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (append)

**Interfaces:**
- Consumes: existing catalog tables (`entry`, `snapshot`, `volume`, `driveRole`), `DriveRole`.
- Produces:
  - `struct BackupCandidate: Codable, Sendable, FetchableRecord { var volumeKey: String; var relPath: String }`
  - `func backupCandidates(name: String, size: Int64, excludingVolumeKey: String) async throws -> [BackupCandidate]` — copies of `(name,size)` on backup-role drives other than `excludingVolumeKey`, from each volume's latest snapshot.

- [ ] **Step 1: Write the failing test**

Append to `DiskGalleryCoreTests/ExecutionTests.swift` (inside the class). It builds two volumes that both hold an identical `dup.bin`; only a backup-role drive should count as a candidate. (If two folder scans don't yield two distinct volumes, follow the multi-volume setup in `CrossDriveDuplicateTests.swift`.)

```swift
    /// A standalone temp "drive" directory named `name`, holding one file `dup.bin`.
    private func volTree(_ name: String) throws -> URL {
        let root = try tempDir().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 2048).write(to: root.appendingPathComponent("dup.bin"))
        return root
    }

    func testBackupCandidatesOnlyMatchesBackupRoleDrives() async throws {
        let catalog = try Fixture.makeCatalog()
        _ = try await Fixture.scan(catalog, try volTree("vola"))
        _ = try await Fixture.scan(catalog, try volTree("volb"))
        let vols = try await catalog.library.volumes()
        XCTAssertEqual(vols.count, 2, "two folder scans should produce two volumes")
        let keyA = AnnotationStore.volumeKey(uuid: vols[0].uuid, name: vols[0].name)
        let keyB = AnnotationStore.volumeKey(uuid: vols[1].uuid, name: vols[1].name)

        // No roles assigned → no backup candidates.
        let none = try await catalog.execution.backupCandidates(name: "dup.bin", size: 2048,
                                                                excludingVolumeKey: keyA)
        XCTAssertTrue(none.isEmpty)

        // Mark B as a backup → B's copy is now a valid surviving copy when deleting from A.
        try await catalog.driveRoles.setRole(.mainBackup, forKey: keyB)
        let found = try await catalog.execution.backupCandidates(name: "dup.bin", size: 2048,
                                                                 excludingVolumeKey: keyA)
        XCTAssertEqual(found.map(\.volumeKey), [keyB])
        XCTAssertEqual(found.first?.relPath, "dup.bin")

        // Excluding B (the only backup) → empty (never matches the excluded volume).
        let excludingB = try await catalog.execution.backupCandidates(name: "dup.bin", size: 2048,
                                                                      excludingVolumeKey: keyB)
        XCTAssertTrue(excludingB.isEmpty)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "backupCandidates|error:" | head`
Expected: FAIL — `type 'ExecutorService' has no member 'backupCandidates'`.

- [ ] **Step 3: Implement `BackupCandidate` + `backupCandidates`**

In `DiskGalleryCore/Execution/ExecutorService.swift`, add the struct just above `public final class ExecutorService` (after the imports):

```swift
/// A copy of a file located on a backup-role drive — used to verify that deleting
/// the source is safe (an identical copy survives elsewhere).
public struct BackupCandidate: Codable, Sendable, FetchableRecord {
    public var volumeKey: String
    public var relPath: String
}
```

Then add this method inside `ExecutorService` (e.g. after `history()`):

```swift
    /// Copies of `(name, size)` on backup-role drives OTHER than `excludingVolumeKey`,
    /// from each volume's latest snapshot. The volume key matches the catalog's
    /// `uuid ?? name` convention. Used by Delete to confirm a surviving copy exists
    /// on a backup before trashing the source.
    public func backupCandidates(name: String, size: Int64,
                                 excludingVolumeKey: String) async throws -> [BackupCandidate] {
        try await db.writer.read { db in
            try BackupCandidate.fetchAll(db, sql: """
                WITH latest AS (
                    SELECT s.id FROM snapshot s
                    WHERE s.id = (
                        SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                        ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
                    )
                )
                SELECT (CASE WHEN v.uuid IS NOT NULL THEN v.uuid ELSE v.name END) AS volumeKey,
                       e.relPath AS relPath
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                JOIN driveRole r ON (r.volumeKey = v.uuid OR (v.uuid IS NULL AND r.volumeKey = v.name))
                WHERE e.isDir = 0 AND e.name = ? AND e.logicalSize = ?
                      AND e.snapshotId IN (SELECT id FROM latest)
                      AND r.role IN (?, ?)
                      AND (CASE WHEN v.uuid IS NOT NULL THEN v.uuid ELSE v.name END) <> ?
                ORDER BY v.name COLLATE NOCASE, e.relPath
                """, arguments: [name, size, DriveRole.mainBackup.rawValue,
                                 DriveRole.fallbackBackup.rawValue, excludingVolumeKey])
        }
    }
```

- [ ] **Step 4: Regenerate the project, then run to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green, 0 failures (≈164).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Execution/ExecutorService.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): backupCandidates — find verified-copy candidates on backup drives

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Delete execution

**Files:**
- Modify: `DiskGalleryCore/Execution/ExecutorService.swift`
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (append)

**Interfaces:**
- Consumes: `backupCandidates` (Task 1), `HashVerifier`, `FileTrasher`, `FileOperation`, `OpType`, `PlanStep`.
- Produces:
  - `static func deleteDrafts(from steps: [PlanStep], isConnected: (String) -> Bool, now: Date) -> [FileOperation]`
  - `run` now executes `.delete` via `performDelete` (replacing the "not available yet" skip), with the source-connected check applying to all ops and the destination check applying only to copy/move.

- [ ] **Step 1: Write the failing tests**

Append to `DiskGalleryCoreTests/ExecutionTests.swift`:

```swift
    func testDeleteTrashesSourceWhenVerifiedBackupCopyExists() async throws {
        let catalog = try Fixture.makeCatalog()
        let volA = try volTree("dela"), volB = try volTree("delb")   // both hold identical dup.bin
        _ = try await Fixture.scan(catalog, volA)
        _ = try await Fixture.scan(catalog, volB)
        let vols = try await catalog.library.volumes()
        let keyA = AnnotationStore.volumeKey(uuid: vols[0].uuid, name: vols[0].name)
        let keyB = AnnotationStore.volumeKey(uuid: vols[1].uuid, name: vols[1].name)
        try await catalog.driveRoles.setRole(.mainBackup, forKey: keyB)   // B is a backup

        // Map the catalog volume keys to the on-disk trees.
        let mounts = [keyA: volA, keyB: volB]
        let op = FileOperation(type: .delete, sourceVolumeKey: keyA, sourceRelPath: "dup.bin",
                               destVolumeKey: nil, destRelPath: nil, bytes: 2048,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        XCTAssertFalse(FileManager.default.fileExists(atPath: volA.appendingPathComponent("dup.bin").path),
                       "source must be trashed once a verified backup copy exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: volB.appendingPathComponent("dup.bin").path),
                      "the backup copy must remain")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done)
    }

    func testDeleteSkipsWhenOnlyCopyIsOnANonBackupDrive() async throws {
        let catalog = try Fixture.makeCatalog()
        let volA = try volTree("ndela"), volB = try volTree("ndelb")
        _ = try await Fixture.scan(catalog, volA)
        _ = try await Fixture.scan(catalog, volB)
        let vols = try await catalog.library.volumes()
        let keyA = AnnotationStore.volumeKey(uuid: vols[0].uuid, name: vols[0].name)
        let keyB = AnnotationStore.volumeKey(uuid: vols[1].uuid, name: vols[1].name)
        // B has a copy but is NOT a backup role (left neutral) → not a valid surviving copy.

        let mounts = [keyA: volA, keyB: volB]
        let op = FileOperation(type: .delete, sourceVolumeKey: keyA, sourceRelPath: "dup.bin",
                               destVolumeKey: nil, destRelPath: nil, bytes: 2048,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: volA.appendingPathComponent("dup.bin").path),
                      "source must NOT be trashed without a backup-role verified copy")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .skipped)
    }

    func testDeleteIsIdempotentWhenSourceAlreadyGone() async throws {
        let catalog = try Fixture.makeCatalog()
        let volA = try volTree("idela")
        _ = try await Fixture.scan(catalog, volA)
        let vols = try await catalog.library.volumes()
        let keyA = AnnotationStore.volumeKey(uuid: vols[0].uuid, name: vols[0].name)
        try FileManager.default.removeItem(at: volA.appendingPathComponent("dup.bin"))   // already gone

        let op = FileOperation(type: .delete, sourceVolumeKey: keyA, sourceRelPath: "dup.bin",
                               destVolumeKey: nil, destRelPath: nil, bytes: 2048,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            key == keyA ? volA.appendingPathComponent(rel) : nil
        }, progress: { _ in })

        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done, "already-gone source = done (idempotent)")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "deleteDrafts|performDelete|delete is not available|error:" | head`
Expected: FAIL — the delete tests don't trash/complete because `.delete` currently returns the "delete is not available yet" skip (so `testDeleteTrashesSource…` fails its assertions / the methods don't exist).

- [ ] **Step 3: Add a stored `hasher` and `deleteDrafts`**

In `DiskGalleryCore/Execution/ExecutorService.swift`:

(a) Add a `hasher` stored property and set it in `init`. Replace the property block + init (lines 9-17) with:

```swift
    let db: AppDatabase
    let copier: FileCopier
    let trasher: FileTrasher
    let hasher: HashVerifier

    init(db: AppDatabase, hasher: HashVerifier) {
        self.db = db
        self.copier = FileCopier(hasher: hasher)
        self.trasher = FileTrasher()
        self.hasher = hasher
    }
```

(b) Add `deleteDrafts` next to `copyDrafts`/`moveDrafts` (delete steps have NO destination, so this does not use the shared `drafts` helper):

```swift
    /// Build pending delete operations from a plan's delete steps, for source drives
    /// that are currently connected. Delete has no destination.
    public static func deleteDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                    now: Date) -> [FileOperation] {
        steps.compactMap { step in
            guard step.operation == .delete,
                  let srcKey = step.sourceDriveKey, let srcPath = step.sourcePath,
                  isConnected(srcKey) else { return nil }
            return FileOperation(type: .delete, sourceVolumeKey: srcKey, sourceRelPath: srcPath,
                                 destVolumeKey: nil, destRelPath: nil, bytes: step.bytes,
                                 status: .pending, createdAt: now)
        }
    }
```

- [ ] **Step 4: Refactor `run` (source-first resolve) and add `performDelete`**

Replace the `run(...)` method (current lines 71-106) with this version — the source-connected check applies to all ops; copy/move additionally require the destination; `.delete` runs `performDelete`:

```swift
    /// Runs the given operations in order. `resolve(volumeKey, relPath)` maps to the
    /// on-disk URL (nil when the drive isn't mounted). Honors task cancellation.
    public func run(_ ops: [FileOperation],
                    resolve: @Sendable (String, String) -> URL?,
                    progress: @Sendable @MainActor (FileOperation) -> Void) async {
        for op in ops {
            if Task.isCancelled { break }
            guard let id = op.id else { continue }

            // Every operation needs its source drive connected.
            guard let src = resolve(op.sourceVolumeKey, op.sourceRelPath) else {
                if let u = try? await finish(id, status: .skipped, skipReason: "drive not connected") {
                    await progress(u)
                }
                continue
            }

            _ = try? await update(id) { $0.status = .running; $0.startedAt = Date() }
            do {
                let updated: FileOperation?
                switch op.type {
                case .copy, .move:
                    // Copy and Move additionally need the destination drive connected.
                    guard let dstKey = op.destVolumeKey, let dstPath = op.destRelPath,
                          let dst = resolve(dstKey, dstPath) else {
                        if let u = try? await finish(id, status: .skipped,
                                                     skipReason: "destination drive not connected") {
                            await progress(u)
                        }
                        continue
                    }
                    if op.type == .copy {
                        updated = try await applyCopyOutcome(id, copier.copyVerified(from: src, to: dst))
                    } else {
                        updated = try await performMove(id, src: src, dst: dst)
                    }
                case .delete:
                    updated = try await performDelete(id, op: op, src: src, resolve: resolve)
                }
                if let updated { await progress(updated) }
            } catch {
                if let u = try? await finish(id, status: .failed, failureReason: error.localizedDescription) {
                    await progress(u)
                }
            }
        }
    }

    /// Trashes the source ONLY after finding a SHA-256-identical copy on a connected
    /// backup-role drive (a different volume — so the surviving copy is never the last).
    /// Idempotent: if the source is already gone, the delete is treated as done.
    /// If no verified backup copy is reachable, the source is left untouched (skipped).
    private func performDelete(_ id: Int64, op: FileOperation, src: URL,
                               resolve: @Sendable (String, String) -> URL?) async throws -> FileOperation? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: src.path) {
            return try await finish(id, status: .done)       // already deleted
        }
        let srcHash = try hasher.sha256(fileURL: src)
        let name = (op.sourceRelPath as NSString).lastPathComponent
        let candidates = try await backupCandidates(name: name, size: op.bytes,
                                                     excludingVolumeKey: op.sourceVolumeKey)
        for candidate in candidates {
            guard let url = resolve(candidate.volumeKey, candidate.relPath),
                  fm.fileExists(atPath: url.path) else { continue }
            if try hasher.sha256(fileURL: url) == srcHash {
                try trasher.trash(src)        // safe: a verified copy survives on a backup drive
                return try await finish(id, status: .done, sourceHash: srcHash)
            }
        }
        return try await finish(id, status: .skipped,
                                skipReason: "no checksum-verified copy on a connected backup drive")
    }
```

(Leave `performMove`, `applyCopyOutcome`, `update`, `finish`, `enqueue`, `pendingCopies`, `history`, and the draft helpers unchanged.)

- [ ] **Step 5: Regenerate the project, then run to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green, 0 failures (≈167). The Stage 1/2 copy & move tests still pass (the `run` refactor preserves their behavior — source resolves, then destination resolves for copy/move).

- [ ] **Step 6: Commit**

```bash
git add DiskGalleryCore/Execution/ExecutorService.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): Delete execution — trash source only after a backup-verified copy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: App — surface deletes in the reconnect flow + clear completed-delete annotations

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift`
- Modify: `DiskGallery/Views/ExecutionConfirmView.swift`

**Interfaces:**
- Consumes: `ExecutorService.deleteDrafts` (Task 2), the existing copy/move draft + run flow, `catalog.annotations.setDecision`.
- Produces: `ExecutionPrompt` gains `deleteCount`; the reconnect flow surfaces copies + moves + deletes and clears the source annotation of each completed delete (in addition to moves).

> **Verification:** no app unit-test target — gate is `** BUILD SUCCEEDED **` + the manual smoke in Step 4.

- [ ] **Step 1: Surface deletes on mount + add `deleteCount`**

In `DiskGallery/App/AppEnvironment.swift`:

(a) Add `deleteCount` to `ExecutionPrompt` (alongside `copyCount`/`moveCount`):

```swift
        var deleteCount: Int { drafts.filter { $0.type == .delete }.count }
```

(b) In `surfaceReadyOperationsOnMount()`, include delete drafts. Change the `drafts` computation to:

```swift
        let drafts = ExecutorService.copyDrafts(from: plan.steps, isConnected: connected, now: Date())
            + ExecutorService.moveDrafts(from: plan.steps, isConnected: connected, now: Date())
            + ExecutorService.deleteDrafts(from: plan.steps, isConnected: connected, now: Date())
```

(c) Extend the post-run annotation-clear loop in `runConfirmedExecution()` to also clear completed deletes. Change the loop condition from move-only to move-or-delete:

```swift
            for op in finished where op.id.map(ids.contains) == true
                && (op.type == .move || op.type == .delete) && op.status == .done {
                try? await self.catalog.annotations.setDecision(.none, volumeKey: op.sourceVolumeKey,
                                                                relPath: op.sourceRelPath)
            }
```

- [ ] **Step 2: Update the confirm sheet copy for deletes**

In `DiskGallery/Views/ExecutionConfirmView.swift`, update the `summary` computed var to include deletes, and strengthen the safety note. Replace the `summary` var with:

```swift
    private var summary: String {
        var parts: [String] = []
        if prompt.copyCount > 0 { parts.append("\(prompt.copyCount) back up") }
        if prompt.moveCount > 0 { parts.append("\(prompt.moveCount) move") }
        if prompt.deleteCount > 0 { parts.append("\(prompt.deleteCount) delete") }
        let what = parts.isEmpty ? "\(prompt.fileCount) operations" : parts.joined(separator: " · ")
        return "\(what) · \(Format.bytes(prompt.totalBytes)) → \(prompt.driveNames.joined(separator: ", "))"
    }
```

And replace the safety-note `Label` (the `checkmark.shield` line) with:

```swift
            Label("Backups and moves are copied and checksum-verified first; a move then trashes the original. A delete only happens when an identical copy is verified on a backup drive — otherwise it's skipped. Nothing is ever overwritten, and deletes go to the Trash.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 3: (no-op check) confirm `driveNames` still reads sensibly for deletes**

Deletes have no `destVolumeKey`, so they contribute nothing to `driveNames` (which is built from `destVolumeKey`). That's fine — the summary still shows source-free drive names for copies/moves, and deletes are counted in the breakdown. No code change; just don't "fix" `driveNames` to include delete sources (the sheet's "→ drives" reads as destinations).

- [ ] **Step 4: Regenerate the project, build + smoke**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.
Smoke (manual, Pro/unconfigured license; a drive marked as a **backup** role holding a copy of the file; the file also on a daily-driver source): tag the source file **Delete**, connect both the source and the backup drive, confirm the **Ready to run** sheet shows "1 delete", click **Run**, verify the source file is now in the Trash **and** the backup copy is intact, the **Activity** tab shows it `done`. Negative check: with the backup drive NOT connected (or the file not on any backup), the delete shows as `skipped` in Activity and the source is untouched.

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift DiskGallery/Views/ExecutionConfirmView.swift DiskGallery.xcodeproj
git commit -m "feat(app): surface deletes in the reconnect flow; clear deleted-source annotations

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Stage 3 = Delete):**
- Delete trashes the source only after a SHA-256-verified copy on a connected backup-role drive → Task 2 `performDelete` (tested). ✓
- Surviving copy is on a different volume (never the last copy) → `backupCandidates` excludes the source volume (Task 1) and only returns backup-role volumes; `performDelete` trusts only a hash match. ✓
- Unverifiable delete → skipped, source untouched → Task 2 (tested: copy on non-backup drive → skipped). ✓
- Deletes go to Trash (recoverable), never permanent → reuses `FileTrasher` (no `removeItem` of a source). ✓
- Idempotent (source already gone → done) → Task 2 (tested). ✓
- Materialize `.delete` plan steps (no destination) → Task 2 `deleteDrafts`. ✓
- Reconnect confirm-once surfaces deletes; Pro-gated → Task 3. ✓
- Clear completed-delete source annotations → Task 3. ✓
- Read-only boundary intact (`backupCandidates` is a read; trash mutation only via `FileTrasher` in `Execution/`; `MutationGuardTests` unchanged) → Global Constraints. ✓
- Engine now complete: Copy (Stage 1), Move (Stage 2), Delete (Stage 3).

**Placeholder scan:** none — all code complete; commands have expected output; the build+smoke gate reflects the absent app unit-test target.

**Type consistency:** `BackupCandidate { volumeKey, relPath }` (Task 1) is consumed by `performDelete` (Task 2). `backupCandidates(name:size:excludingVolumeKey:)` signature matches its Task 2 call. `deleteDrafts(from:isConnected:now:)` matches Task 3's call. The `run(_:resolve:progress:)` signature is unchanged (Stage 1/2 callers and tests still compile); the refactor only reorders the internal resolve checks. `ExecutionPrompt.deleteCount` (Task 3a) is used in the sheet (Task 3 Step 2). `DriveRole.mainBackup`/`.fallbackBackup` are the backup roles used in the query.

**Note (subagent-driven):** the `run` refactor changes the resolve guard from "source AND destination" to "source first, destination only for copy/move." This is required so delete ops (which have no destination) aren't skipped as "drive not connected." It preserves copy/move behavior: a missing destination now yields the clearer skip reason "destination drive not connected" instead of the generic "drive not connected" — verify the Stage 1/2 tests still pass (they assert status, not the reason string).
