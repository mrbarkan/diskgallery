# Execution Engine — Stage 2 (Move) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add **Move** to the execution engine — a Move is a verified copy followed by sending the source to the macOS Trash, and the source is never trashed until the destination copy is checksum-verified.

**Architecture:** Build on Stage 1. A new `FileTrasher` primitive (in `Execution/`) wraps `FileManager.trashItem`. `ExecutorService` gains `moveDrafts` (materialize `.move` plan steps) and its `run` loop dispatches per `op.type`: `.copy` keeps Stage 1 behavior; `.move` does a verified copy then trashes the source (and is idempotent if the source was already moved); `.delete` is a not-yet-available skip (Stage 3). The reconnect confirm flow surfaces moves alongside copies, and completed-move source annotations are cleared so they don't re-prompt.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 15+, GRDB 7, CryptoKit (via `HashVerifier`), XCTest.

## Global Constraints

- Swift 6.0, macOS 15.0 target.
- **Read-only cataloging preserved.** Do NOT add file-mutating APIs to the 5 files `MutationGuardTests` scans, and do NOT add any `Execution/` file to that test's `sources` list. All mutation stays inside `DiskGalleryCore/Execution/`.
- **Do NOT edit any file under `DiskGallery/Views/Modern/`**, `OLEDDisplayView.swift`, or `ModernTokens.swift`. Do NOT add a new `SidebarItem` enum case.
- **Move safety invariant (non-negotiable):** the source is sent to the **Trash** (never permanently deleted, never `removeItem`) and **only after** the destination copy returns `.verified` or `.skippedIdentical` from `FileCopier`. On `.conflict`, `.checksumMismatch`, or a thrown error, the source is left untouched.
- **Idempotent / resumable:** re-running a move whose source is already gone but whose destination exists is a success (`.done`), not a failure.
- Reuse `FileCopier` (the Stage 1 copy primitive) and `HashVerifier` — no new copy/hash logic.
- Destination path mirrors the source's relative path (same as copy).
- Execution is Pro-gated (`Feature.transfer`).
- New source files require `xcodegen generate` (XcodeGen uses explicit file refs, no synchronized groups; installed at /opt/homebrew/bin/xcodegen). Include `DiskGallery.xcodeproj` in the commit when a file is added.
- Verification commands (from repo root):
  - Core tests: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test`
  - App build: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
  - Baseline (Stage 1 complete): build green, **159** Core tests pass. Treat "all green, 0 failures" as the gate (exact counts are approximate).
- App layer has no unit-test target → verified by build + manual smoke.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Branch: `feature/execution-engine` (continue on it; Stage 1 is already committed there).

## File Structure

- Create `DiskGalleryCore/Execution/FileTrasher.swift` — trash primitive (FileManager.trashItem). No DB.
- Modify `DiskGalleryCore/Execution/ExecutorService.swift` — add `moveDrafts` (+ a shared private `drafts` helper that `copyDrafts` delegates to), construct a `FileTrasher`, and refactor `run` to dispatch per `op.type`.
- Modify `DiskGalleryCoreTests/ExecutionTests.swift` — tests for FileTrasher and move execution.
- Modify `DiskGallery/App/AppEnvironment.swift` — surface moves on reconnect, prompt copy/move counts, clear completed-move source annotations.
- Modify `DiskGallery/Views/ExecutionConfirmView.swift` — sheet copy reflecting copies + moves.

---

## Task 1: `FileTrasher` — send-to-Trash primitive

**Files:**
- Create: `DiskGalleryCore/Execution/FileTrasher.swift`
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (append)

**Interfaces:**
- Produces: `FileTrasher()` with `@discardableResult func trash(_ url: URL) throws -> URL?` — sends `url` to the macOS Trash, returning the trashed location (nil if the OS doesn't report one).

- [ ] **Step 1: Write the failing test**

Append to `DiskGalleryCoreTests/ExecutionTests.swift` (inside the `ExecutionTests` class; reuse the existing `tempDir()` helper added in Stage 1):

```swift
    func testFileTrasherRemovesSourceFromOriginalPath() throws {
        let root = try tempDir()
        let victim = root.appendingPathComponent("doomed.bin")
        try Data(repeating: 0x44, count: 512).write(to: victim)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))

        let trashedURL = try FileTrasher().trash(victim)

        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path),
                       "the file must no longer exist at its original path")
        if let trashedURL { XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path)) }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "cannot find 'FileTrasher'|error:" | head`
Expected: FAIL — `cannot find 'FileTrasher' in scope`.

- [ ] **Step 3: Create `FileTrasher`**

Create `DiskGalleryCore/Execution/FileTrasher.swift`:

```swift
import Foundation

/// Sends a file or folder to the macOS Trash (recoverable) — never a permanent
/// delete. Used by Move (to remove the source after a verified copy) and, later, by
/// Delete. Lives in `Execution/`, the executor's mutation surface.
public struct FileTrasher: Sendable {
    public init() {}

    /// Moves `url` to the Trash, returning the resulting in-Trash location when the
    /// OS reports one. Throws if the item can't be trashed.
    @discardableResult
    public func trash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
```

- [ ] **Step 4: Regenerate the project, then run to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green, 0 failures (≈160). `xcodegen generate` adds the new `FileTrasher.swift` to the project (explicit file refs).

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Execution/FileTrasher.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): FileTrasher — send-to-Trash primitive for Move/Delete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `ExecutorService` — Move execution

**Files:**
- Modify: `DiskGalleryCore/Execution/ExecutorService.swift`
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (append)

**Interfaces:**
- Consumes: `FileTrasher` (Task 1); `FileCopier`, `FileOperation`, `OpType`, `OpStatus`, `PlanStep`/`PlanOperation` (existing).
- Produces:
  - `static func moveDrafts(from steps: [PlanStep], isConnected: (String) -> Bool, now: Date) -> [FileOperation]`
  - `run` now executes `.copy`, `.move` (verified copy → trash source; idempotent), and `.delete` (skipped — Stage 3).

- [ ] **Step 1: Write the failing tests**

Append to `DiskGalleryCoreTests/ExecutionTests.swift`:

```swift
    func testExecutorMoveCopiesThenTrashesSource() async throws {
        let catalog = try Fixture.makeCatalog()
        let driveA = try tempDir(), driveB = try tempDir()
        let src = driveA.appendingPathComponent("m.bin")
        try Data(repeating: 0x4D, count: 4096).write(to: src)

        let step = PlanStep(id: "s1", orderIndex: 1, operation: .move, name: "m.bin",
                            sourceDriveKey: "A", sourceDriveName: "A", sourcePath: "m.bin",
                            destinationDriveKey: "B", destinationDriveName: "B", bytes: 4096,
                            estDuration: 0, feasibility: .ok, dependsOn: [], isOverride: false)
        let drafts = ExecutorService.moveDrafts(from: [step], isConnected: { _ in true }, now: Date())
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.type, .move)

        let enqueued = try await catalog.execution.enqueue(drafts)
        let mounts = ["A": driveA, "B": driveB]
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: driveB.appendingPathComponent("m.bin").path),
                      "destination copy must exist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path),
                       "source must be trashed after a verified copy")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done)
    }

    func testExecutorMoveDoesNotTrashSourceOnConflict() async throws {
        let catalog = try Fixture.makeCatalog()
        let driveA = try tempDir(), driveB = try tempDir()
        let src = driveA.appendingPathComponent("c.bin")
        let dst = driveB.appendingPathComponent("c.bin")
        try Data(repeating: 0x41, count: 1000).write(to: src)
        try Data(repeating: 0x42, count: 1000).write(to: dst)   // different file already at dest

        let op = FileOperation(type: .move, sourceVolumeKey: "A", sourceRelPath: "c.bin",
                               destVolumeKey: "B", destRelPath: "c.bin", bytes: 1000,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        let mounts = ["A": driveA, "B": driveB]
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path),
                      "source must NOT be trashed on conflict")
        XCTAssertEqual(try Data(contentsOf: dst), Data(repeating: 0x42, count: 1000),
                       "destination must not be overwritten")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .skipped)
    }

    func testExecutorMoveIsIdempotentWhenSourceAlreadyGone() async throws {
        let catalog = try Fixture.makeCatalog()
        let driveA = try tempDir(), driveB = try tempDir()
        // Source absent, destination already present (a move that completed the copy+trash
        // but crashed before recording done).
        try Data(repeating: 0x4D, count: 64).write(to: driveB.appendingPathComponent("m.bin"))

        let op = FileOperation(type: .move, sourceVolumeKey: "A", sourceRelPath: "m.bin",
                               destVolumeKey: "B", destRelPath: "m.bin", bytes: 64,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        let mounts = ["A": driveA, "B": driveB]
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done, "already-moved source + present dest = done")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "moveDrafts|error:" | head`
Expected: FAIL — `type 'ExecutorService' has no member 'moveDrafts'`.

- [ ] **Step 3: Add `moveDrafts` + the shared drafts helper, construct the trasher**

In `DiskGalleryCore/Execution/ExecutorService.swift`:

(a) Add a `trasher` stored property and construct it in `init`. Replace the property block + init (lines 9-15) with:

```swift
    let db: AppDatabase
    let copier: FileCopier
    let trasher: FileTrasher

    init(db: AppDatabase, hasher: HashVerifier) {
        self.db = db
        self.copier = FileCopier(hasher: hasher)
        self.trasher = FileTrasher()
    }
```

(b) Replace the existing `copyDrafts(...)` method (lines 19-30) with a shared private helper plus two public wrappers:

```swift
    /// Build pending operations from a plan's steps of a given operation, for
    /// source+destination drives that are currently connected. Destination path
    /// mirrors the source path.
    private static func drafts(from steps: [PlanStep], planOp: PlanOperation, opType: OpType,
                              isConnected: (String) -> Bool, now: Date) -> [FileOperation] {
        steps.compactMap { step in
            guard step.operation == planOp,
                  let srcKey = step.sourceDriveKey, let srcPath = step.sourcePath,
                  let dstKey = step.destinationDriveKey,
                  isConnected(srcKey), isConnected(dstKey) else { return nil }
            return FileOperation(type: opType, sourceVolumeKey: srcKey, sourceRelPath: srcPath,
                                 destVolumeKey: dstKey, destRelPath: srcPath, bytes: step.bytes,
                                 status: .pending, createdAt: now)
        }
    }

    public static func copyDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                  now: Date) -> [FileOperation] {
        drafts(from: steps, planOp: .copy, opType: .copy, isConnected: isConnected, now: now)
    }

    public static func moveDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                  now: Date) -> [FileOperation] {
        drafts(from: steps, planOp: .move, opType: .move, isConnected: isConnected, now: now)
    }
```

- [ ] **Step 4: Refactor `run` to dispatch per op type**

Replace the `run(...)` method (current lines 58-93) with the version below. The resolve-nil "drive not connected" guard and the `.running` transition are unchanged; the per-outcome copy mapping is extracted into `applyCopyOutcome` (reused by Move), and Move adds the trash step + idempotency:

```swift
    /// Runs the given operations in order. `resolve(volumeKey, relPath)` maps to the
    /// on-disk URL (nil when the drive isn't mounted). Honors task cancellation.
    public func run(_ ops: [FileOperation],
                    resolve: @Sendable (String, String) -> URL?,
                    progress: @Sendable @MainActor (FileOperation) -> Void) async {
        for op in ops {
            if Task.isCancelled { break }
            guard let id = op.id else { continue }

            guard let dstKey = op.destVolumeKey, let dstPath = op.destRelPath,
                  let src = resolve(op.sourceVolumeKey, op.sourceRelPath),
                  let dst = resolve(dstKey, dstPath) else {
                let updated = try? await finish(id, status: .skipped, skipReason: "drive not connected")
                if let updated { await progress(updated) }
                continue
            }

            _ = try? await update(id) { $0.status = .running; $0.startedAt = Date() }
            do {
                let updated: FileOperation?
                switch op.type {
                case .copy:
                    let outcome = try copier.copyVerified(from: src, to: dst)
                    updated = try await applyCopyOutcome(id, outcome)
                case .move:
                    updated = try await performMove(id, src: src, dst: dst)
                case .delete:
                    updated = try await finish(id, status: .skipped,
                                               skipReason: "delete is not available yet")
                }
                if let updated { await progress(updated) }
            } catch {
                if let updated = try? await finish(id, status: .failed, failureReason: error.localizedDescription) {
                    await progress(updated)
                }
            }
        }
    }

    /// A verified copy then trashes the source. The source is trashed ONLY after the
    /// destination copy is checksum-verified. Idempotent: if the source is already gone
    /// but the destination exists, the move is treated as already completed.
    private func performMove(_ id: Int64, src: URL, dst: URL) async throws -> FileOperation? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: src.path) {
            if fm.fileExists(atPath: dst.path) {
                return try await finish(id, status: .done)
            }
            return try await finish(id, status: .failed, failureReason: "source not found")
        }
        let outcome = try copier.copyVerified(from: src, to: dst)
        switch outcome {
        case .verified(let h), .skippedIdentical(let h):
            try trasher.trash(src)                 // safe: destination copy is verified
            return try await finish(id, status: .done, sourceHash: h, destHash: h)
        case .conflict:
            return try await finish(id, status: .skipped,
                                    skipReason: "a different file already exists at the destination")
        case .checksumMismatch:
            return try await finish(id, status: .failed, failureReason: "checksum mismatch after copy")
        }
    }

    /// Maps a copy outcome to a terminal status (used by `.copy` and the copy phase of `.move`).
    private func applyCopyOutcome(_ id: Int64, _ outcome: FileCopier.Outcome) async throws -> FileOperation? {
        switch outcome {
        case .verified(let h), .skippedIdentical(let h):
            return try await finish(id, status: .done, sourceHash: h, destHash: h)
        case .conflict:
            return try await finish(id, status: .skipped,
                                    skipReason: "a different file already exists at the destination")
        case .checksumMismatch:
            return try await finish(id, status: .failed, failureReason: "checksum mismatch after copy")
        }
    }
```

(Leave the `update`/`finish` persistence helpers and `pendingCopies`/`history`/`enqueue` unchanged.)

- [ ] **Step 5: Regenerate the project, then run to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green, 0 failures (≈163). (`xcodegen generate` is harmless here even though no file was added; it keeps the project in sync.)

- [ ] **Step 6: Commit**

```bash
git add DiskGalleryCore/Execution/ExecutorService.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): Move execution — verified copy then trash source (idempotent)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: App — surface moves in the reconnect flow + clear completed-move annotations

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift`
- Modify: `DiskGallery/Views/ExecutionConfirmView.swift`

**Interfaces:**
- Consumes: `ExecutorService.copyDrafts` + `ExecutorService.moveDrafts` (Task 2), `catalog.execution.run/enqueue/history`, `catalog.annotations.setDecision`, `env.volumes`, `Feature.transfer`.
- Produces: `ExecutionPrompt` gains `copyCount`/`moveCount`; the reconnect flow surfaces copies + moves and clears the source annotation of each completed move.

> **Verification:** no app unit-test target — gate is `** BUILD SUCCEEDED **` + the manual smoke in Step 4.

- [ ] **Step 1: Surface moves on mount + add prompt counts**

In `DiskGallery/App/AppEnvironment.swift`:

(a) Add count helpers to `ExecutionPrompt` (the struct currently at ~line 778). Replace it with:

```swift
    /// A batch of copy/move operations ready to run for the just-connected drive(s).
    struct ExecutionPrompt: Identifiable {
        let id = UUID()
        var drafts: [FileOperation]
        var fileCount: Int { drafts.count }
        var copyCount: Int { drafts.filter { $0.type == .copy }.count }
        var moveCount: Int { drafts.filter { $0.type == .move }.count }
        var totalBytes: Int64 { drafts.reduce(0) { $0 + $1.bytes } }
        var driveNames: [String]
    }
```

(b) Rename `surfaceReadyCopiesOnMount()` → `surfaceReadyOperationsOnMount()` and compute copy + move drafts. Replace the method (currently ~lines 792-805) with:

```swift
    /// On reconnect: if Pro and the current plan has copy/move steps whose drives are
    /// all connected, surface the confirm sheet.
    func surfaceReadyOperationsOnMount() async {
        guard license.isUnlocked(.transfer) else { return }
        guard executionPrompt == nil, executionProgress == nil else { return }
        let plan = await organizationPlan()
        let connected: (String) -> Bool = { [volumes] in volumes.isConnected(key: $0) }
        let drafts = ExecutorService.copyDrafts(from: plan.steps, isConnected: connected, now: Date())
            + ExecutorService.moveDrafts(from: plan.steps, isConnected: connected, now: Date())
        guard !drafts.isEmpty else { return }
        let names = Set(drafts.compactMap { $0.destVolumeKey }
            .compactMap { key in volumeSummaries.first { ($0.uuid ?? $0.name) == key }?.name })
        executionPrompt = ExecutionPrompt(drafts: drafts, driveNames: names.sorted())
    }
```

(c) Update the single call site in `handleVolumeMounted()` (currently ~line 416) from `surfaceReadyCopiesOnMount()` to `surfaceReadyOperationsOnMount()`.

- [ ] **Step 2: Clear completed-move source annotations after a run**

In `runConfirmedExecution()` (the `executionTask = Task { ... }` block, ~lines 815-829), after `await self.catalog.execution.run(...)` returns and before `self.executionProgress = nil`, insert annotation cleanup. Replace the tail of the task body:

```swift
            }, progress: { @MainActor [weak self] op in
                guard let self else { return }
                let done = (self.executionProgress?.completed ?? 0) + 1
                self.executionProgress = ExecutionProgress(completed: done, total: total,
                                                           currentName: (op.sourceRelPath as NSString).lastPathComponent)
            })
            // A completed move leaves its source in the Trash — clear the source's
            // annotation so it isn't re-proposed as a move on the next reconnect.
            let ids = Set(enqueued.compactMap(\.id))
            let finished = (try? await self.catalog.execution.history()) ?? []
            for op in finished where op.id.map(ids.contains) == true && op.type == .move && op.status == .done {
                try? await self.catalog.annotations.setDecision(.none, volumeKey: op.sourceVolumeKey,
                                                                relPath: op.sourceRelPath)
            }
            self.executionProgress = nil
            self.dataVersion += 1
```

- [ ] **Step 3: Update the confirm sheet copy for copies + moves**

In `DiskGallery/Views/ExecutionConfirmView.swift`, replace `ExecutionConfirmView.body` (lines 9-28) with:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to run", systemImage: "externaldrive.badge.checkmark")
                .font(.title2.bold())
            Text(summary).foregroundStyle(.secondary)
            Label("Backups and moves are copied and checksum-verified before anything else happens. A move then sends the original to the Trash. Existing files are never overwritten.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { env.executionPrompt = nil }
                Button("Run") { env.runConfirmedExecution() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var summary: String {
        var parts: [String] = []
        if prompt.copyCount > 0 { parts.append("\(prompt.copyCount) back up") }
        if prompt.moveCount > 0 { parts.append("\(prompt.moveCount) move") }
        let what = parts.isEmpty ? "\(prompt.fileCount) operations" : parts.joined(separator: " · ")
        return "\(what) · \(Format.bytes(prompt.totalBytes)) → \(prompt.driveNames.joined(separator: ", "))"
    }
```

Also change the progress HUD title in `ExecutionProgressView` (line 38) from `Text("Backing up…")` to:

```swift
            Text("Running…").font(.headline)
```

- [ ] **Step 4: Regenerate the project, build + smoke**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (No new file this task; xcodegen keeps the project in sync.)
Smoke (manual, Pro/unconfigured license + two scanned drives): tag a file **Move** with a destination, connect the destination, confirm the **Ready to run** sheet shows "1 move → …", click **Run**, verify the file now exists on the destination **and** the original is in the Trash, the **Activity** tab shows it `done`, and re-mounting does not re-propose that move (its annotation was cleared).

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift DiskGallery/Views/ExecutionConfirmView.swift DiskGallery.xcodeproj
git commit -m "feat(app): surface moves in the reconnect flow; clear moved-source annotations

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Stage 2 = Move):**
- Move = verified copy → Trash source, never trash until verified → Task 2 `performMove`. ✓
- Source to Trash (not permanent), via the `FileTrasher` primitive → Task 1. ✓
- Conflict/mismatch/error leaves source untouched → Task 2 (tested). ✓
- Idempotent/resumable (source gone + dest present → done) → Task 2 `performMove` (tested). ✓
- Materialize `.move` plan steps for connected drives, dest mirrors source → Task 2 `moveDrafts`. ✓
- Reconnect confirm-once surfaces moves alongside copies; Pro-gated → Task 3. ✓
- Clear completed-move source annotations (spec "clear/update source annotation for move/delete") → Task 3. ✓
- Read-only boundary intact (`FileTrasher`/move mutation only in `Execution/`; `MutationGuardTests` unchanged) → Global Constraints + Task 1/2. ✓
- Out of scope (correctly deferred to Stage 3): Delete (run returns a "not available yet" skip).

**Placeholder scan:** none — all code complete; commands have expected output; the two build+smoke gates reflect the absent app unit-test target.

**Type consistency:** `FileTrasher.trash(_:) -> URL?` (Task 1) is called in Task 2 `performMove`. `moveDrafts`/`copyDrafts` (Task 2) match Task 3's call sites. `applyCopyOutcome`/`performMove` map `FileCopier.Outcome`'s four cases (unchanged from Stage 1). `ExecutionPrompt.copyCount/moveCount` (Task 3a) are used in the sheet (Task 3 Step 3). The `run` signature is unchanged, so Stage 1's copy tests and the Task 4 app caller still compile.

**Note (subagent-driven):** the `.delete` arm of `run`'s `switch` returns a "not available yet" skip — intentional for Stage 2 so the `OpType` switch stays exhaustive; Stage 3 replaces it with real delete.
