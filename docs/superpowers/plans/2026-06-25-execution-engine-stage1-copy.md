# Execution Engine — Stage 1 (Infra + Verified Copy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the non-destructive slice of the execution engine — a persisted operation record + a checksum-verified file **copy** executor + a reconnect-triggered confirm-and-run flow — proving the whole "stage offline → reconnect → execute → verify" architecture with zero data-loss risk.

**Architecture:** A new, isolated `DiskGalleryCore/Execution/` module (the app's first deliberate file-mutation surface; the scanner/hasher stay read-only and `MutationGuardTests` is unchanged). An `operation` table (GRDB migration v7) tracks each op's lifecycle for resumable, auditable runs. `FileCopier` does copy→SHA-256-verify→atomic-rename, never overwriting a differing file. `ExecutorService` materializes copy operations from `OrganizationPlanner`'s plan (for currently-connected drives), persists them, and runs them. The app surfaces a confirm-once sheet on reconnect and shows history in the Organize home. Move and Delete are later stages.

**Tech Stack:** Swift 6.0, SwiftUI, macOS 15+, GRDB 7 (encapsulated in `DiskGalleryCore`), CryptoKit (via existing `HashVerifier`), XCTest.

## Global Constraints

- Swift 6.0, macOS 15.0 target.
- **Read-only cataloging is preserved.** Do NOT add file-mutating APIs to the 5 files
  `MutationGuardTests` scans (Scanner, VolumeMetadata, DriveHardwareProbe, ScanProgress,
  HashVerifier) and do NOT add any `Execution/` file to that test's `sources` list. The
  executor mutates only inside `DiskGalleryCore/Execution/`.
- **Do NOT edit any file under `DiskGallery/Views/Modern/`**, nor `OLEDDisplayView.swift`,
  `ModernTokens.swift`. (Classic-only direction.) In particular, **do not add a new
  `SidebarItem` enum case** — it would break Modern's exhaustive `ModernWorkspace` switch.
  Activity/History is therefore an **Organize segment**, not a sidebar row (see Task 5;
  this refines spec §UI).
- **Stage 1 is Copy only.** No move, no delete, no Trash, no source mutation. The only
  writes are: create destination directories, copy to a temp file, rename temp→final.
- Reuse `HashVerifier.sha256(fileURL:)` for all hashing — do not write new hashing code.
- Destination path **mirrors the source's relative path** on the destination volume.
- **Never overwrite** an existing destination file: identical (hash match) → skipped(done);
  differing → skipped(conflict).
- Execution is gated behind the Pro flag `Feature.transfer` (`env.license.isUnlocked(.transfer)`).
- GRDB record pattern (match existing models): `Codable, Sendable, Identifiable,
  FetchableRecord, MutablePersistableRecord` + `static let databaseTableName` +
  `didInsert`. Column names equal property names (camelCase).
- Verification commands (from repo root):
  - Core tests: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test`
  - App build: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build`
  - Baseline at plan time: build green, **153/153** Core tests pass. App layer has no unit-test target → verified by build + manual smoke.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Branch: `feature/execution-engine` (already created; spec committed there).

## File Structure

- Create `DiskGalleryCore/Execution/FileOperation.swift` — the `FileOperation` record + `OpType`/`OpStatus` enums. One responsibility: the persisted op model.
- Create `DiskGalleryCore/Execution/FileCopier.swift` — pure verified-copy primitive (FileManager + HashVerifier). No DB.
- Create `DiskGalleryCore/Execution/ExecutorService.swift` — materialize-from-plan, persist, query, run. The Core facade (`catalog.execution`).
- Modify `DiskGalleryCore/Data/Migrations.swift` — add migration `v7` (operation table).
- Modify `DiskGalleryCore/Catalog.swift` — vend `execution`.
- Create `DiskGalleryCoreTests/ExecutionTests.swift` — tests for the three Core tasks.
- Modify `DiskGallery/App/AppEnvironment.swift` — ready-ops computation, Pro-gated run, reconnect trigger, progress state.
- Create `DiskGallery/Views/ExecutionConfirmView.swift` — the confirm-once sheet + progress.
- Modify `DiskGallery/App/DiskGalleryApp.swift` — present the sheet (like the scan sheet).
- Modify `DiskGallery/Views/OrganizeView.swift` — add an "Activity" segment to `OrganizeHomeView`.

---

## Task 1: `FileOperation` model + migration v7

**Files:**
- Create: `DiskGalleryCore/Execution/FileOperation.swift`
- Modify: `DiskGalleryCore/Data/Migrations.swift` (add `v7` after the `v6` block, before `return migrator`)
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (new)

**Interfaces:**
- Produces: `FileOperation` (record), `enum OpType: String { copy, move, delete }`,
  `enum OpStatus: String { pending, running, verified, done, failed, skipped }`. The
  `operation` table with columns equal to the record's properties.

- [ ] **Step 1: Write the failing test**

Create `DiskGalleryCoreTests/ExecutionTests.swift`:

```swift
import XCTest
import GRDB
@testable import DiskGalleryCore

final class ExecutionTests: XCTestCase {

    func testOperationRoundTripsThroughTheDatabase() async throws {
        let catalog = try Fixture.makeCatalog()   // runs migrations incl. v7
        var op = FileOperation(type: .copy, sourceVolumeKey: "A", sourceRelPath: "shoot/a.cr2",
                           destVolumeKey: "B", destRelPath: "shoot/a.cr2", bytes: 1234,
                           status: .pending, createdAt: Date())
        try await catalog.database.writer.write { db in try op.insert(db) }
        XCTAssertNotNil(op.id)

        let fetched = try await catalog.database.writer.read { db in
            try FileOperation.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.type, .copy)
        XCTAssertEqual(fetched.first?.status, .pending)
        XCTAssertEqual(fetched.first?.destRelPath, "shoot/a.cr2")
        XCTAssertEqual(fetched.first?.bytes, 1234)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "cannot find 'FileOperation'|error:" | head`
Expected: FAIL — `cannot find 'FileOperation' in scope`.

- [ ] **Step 3: Create the `FileOperation` record**

Create `DiskGalleryCore/Execution/FileOperation.swift`:

```swift
import Foundation
import GRDB

/// What an operation does. Raw values are stable (persisted). Stage 1 uses `.copy`.
public enum OpType: String, Codable, Sendable { case copy, move, delete }

/// Lifecycle of one operation. `verified` is a transient between a confirmed copy and
/// its commit; `done`/`failed`/`skipped` are terminal and become history.
public enum OpStatus: String, Codable, Sendable {
    case pending, running, verified, done, failed, skipped
}

/// One file operation, materialized from the Organize plan and tracked through
/// execution so a run is resumable and auditable. Keyed by the stable volume key
/// (`uuid ?? name`), like annotations — survives re-scans and reconnects.
public struct FileOperation: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "operation"

    public var id: Int64?
    public var type: OpType
    public var sourceVolumeKey: String
    public var sourceRelPath: String
    public var destVolumeKey: String?
    public var destRelPath: String?
    public var bytes: Int64
    public var sourceHash: String?
    public var destHash: String?
    public var status: OpStatus
    public var failureReason: String?
    public var skipReason: String?
    public var dependsOn: Int64?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: Int64? = nil, type: OpType, sourceVolumeKey: String, sourceRelPath: String,
                destVolumeKey: String? = nil, destRelPath: String? = nil, bytes: Int64,
                sourceHash: String? = nil, destHash: String? = nil, status: OpStatus,
                failureReason: String? = nil, skipReason: String? = nil, dependsOn: Int64? = nil,
                createdAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.sourceVolumeKey = sourceVolumeKey
        self.sourceRelPath = sourceRelPath
        self.destVolumeKey = destVolumeKey
        self.destRelPath = destRelPath
        self.bytes = bytes
        self.sourceHash = sourceHash
        self.destHash = destHash
        self.status = status
        self.failureReason = failureReason
        self.skipReason = skipReason
        self.dependsOn = dependsOn
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

- [ ] **Step 4: Add migration v7**

In `DiskGalleryCore/Data/Migrations.swift`, immediately after the `migrator.registerMigration("v6")` block's closing `}` and before `return migrator`, add:

```swift
        // Execution engine: persisted operations (copy/move/delete) tracked through
        // their lifecycle so runs are resumable and auditable. Volume keys use the
        // stable `uuid ?? name` identity, like annotations/roles.
        migrator.registerMigration("v7") { db in
            try db.create(table: "operation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("sourceVolumeKey", .text).notNull()
                t.column("sourceRelPath", .text).notNull()
                t.column("destVolumeKey", .text)
                t.column("destRelPath", .text)
                t.column("bytes", .integer).notNull().defaults(to: 0)
                t.column("sourceHash", .text)
                t.column("destHash", .text)
                t.column("status", .text).notNull()
                t.column("failureReason", .text)
                t.column("skipReason", .text)
                t.column("dependsOn", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("startedAt", .datetime)
                t.column("finishedAt", .datetime)
            }
            try db.create(index: "idx_operation_status", on: "operation", columns: ["status"])
        }
```

- [ ] **Step 5: Regenerate the Xcode project (new source files)**

Run: `xcodegen generate`
Expected: `Created project at .../DiskGallery.xcodeproj` (picks up the new `Execution/` files; `project.yml` globs the `DiskGalleryCore` directory).

- [ ] **Step 6: Run the test to verify it passes**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, 154 tests, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add DiskGalleryCore/Execution/FileOperation.swift DiskGalleryCore/Data/Migrations.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): operation record + migration v7 for the execution engine

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `FileCopier` — verified copy primitive

**Files:**
- Create: `DiskGalleryCore/Execution/FileCopier.swift`
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (append)

**Interfaces:**
- Produces: `FileCopier(hasher:)` with
  `func copyVerified(from src: URL, to dst: URL) throws -> FileCopier.Outcome` and
  `enum Outcome: Equatable, Sendable { case verified(hash: String); case skippedIdentical(hash: String); case conflict; case checksumMismatch }`.
- Consumes: `HashVerifier` (Task uses existing `sha256(fileURL:)`).

- [ ] **Step 1: Write the failing tests**

Append to `DiskGalleryCoreTests/ExecutionTests.swift` (inside the class):

```swift
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DGExec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCopyVerifiedWritesAndVerifies() throws {
        let root = try tempDir()
        let src = root.appendingPathComponent("a.bin")
        let dst = root.appendingPathComponent("out/a.bin")   // nested: dir must be created
        try Data(repeating: 0x41, count: 4096).write(to: src)

        let outcome = try FileCopier().copyVerified(from: src, to: dst)
        XCTAssertEqual(outcome, .verified(hash: try HashVerifier().sha256(fileURL: src)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
        // No stray temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".dg-tmp-") }, [])
    }

    func testCopyVerifiedSkipsIdenticalDestination() throws {
        let root = try tempDir()
        let src = root.appendingPathComponent("a.bin")
        let dst = root.appendingPathComponent("a.bin.copy")
        try Data(repeating: 0x42, count: 1000).write(to: src)
        try Data(repeating: 0x42, count: 1000).write(to: dst)   // identical

        let outcome = try FileCopier().copyVerified(from: src, to: dst)
        XCTAssertEqual(outcome, .skippedIdentical(hash: try HashVerifier().sha256(fileURL: src)))
    }

    func testCopyVerifiedReportsConflictAndNeverOverwrites() throws {
        let root = try tempDir()
        let src = root.appendingPathComponent("a.bin")
        let dst = root.appendingPathComponent("a.bin.copy")
        try Data(repeating: 0x41, count: 1000).write(to: src)
        try Data(repeating: 0x42, count: 1000).write(to: dst)   // different

        let outcome = try FileCopier().copyVerified(from: src, to: dst)
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(try Data(contentsOf: dst), Data(repeating: 0x42, count: 1000),
                       "destination must NOT be overwritten on conflict")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "cannot find 'FileCopier'|error:" | head`
Expected: FAIL — `cannot find 'FileCopier' in scope`.

- [ ] **Step 3: Implement `FileCopier`**

Create `DiskGalleryCore/Execution/FileCopier.swift`:

```swift
import Foundation

/// Copies a single file with checksum verification, never overwriting a differing
/// destination. Writes to a temp file in the destination directory, verifies the
/// copy by SHA-256, then atomically renames it into place (same-volume rename is
/// atomic) — so an interrupted copy never leaves a half-written final file.
///
/// This is the executor's mutation primitive; it lives in `Execution/`, separate from
/// the read-only scanning/hashing code that `MutationGuardTests` guards.
public struct FileCopier: Sendable {
    public enum Outcome: Equatable, Sendable {
        case verified(hash: String)
        case skippedIdentical(hash: String)
        case conflict
        case checksumMismatch
    }

    let hasher: HashVerifier
    public init(hasher: HashVerifier = HashVerifier()) { self.hasher = hasher }

    public func copyVerified(from src: URL, to dst: URL) throws -> Outcome {
        let fm = FileManager.default
        let srcHash = try hasher.sha256(fileURL: src)

        if fm.fileExists(atPath: dst.path) {
            let dstHash = try hasher.sha256(fileURL: dst)
            return dstHash == srcHash ? .skippedIdentical(hash: srcHash) : .conflict
        }

        let parent = dst.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".dg-tmp-\(UUID().uuidString)")
        if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }

        do {
            try fm.copyItem(at: src, to: temp)
            let tempHash = try hasher.sha256(fileURL: temp)
            guard tempHash == srcHash else {
                try? fm.removeItem(at: temp)
                return .checksumMismatch
            }
            try fm.moveItem(at: temp, to: dst)   // same-volume rename = atomic
            return .verified(hash: srcHash)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
```

- [ ] **Step 4: Regenerate the project, then run to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green, 0 failures (≈157 — treat all-green as the gate). `xcodegen generate` is required: XcodeGen uses explicit file refs (no synchronized groups), so the new `FileCopier.swift` must be added to the project before it compiles.

- [ ] **Step 5: Commit**

```bash
git add DiskGalleryCore/Execution/FileCopier.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): verified copy primitive (copy -> sha256 -> atomic rename)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `ExecutorService` (materialize, persist, run) + Catalog wiring

**Files:**
- Create: `DiskGalleryCore/Execution/ExecutorService.swift`
- Modify: `DiskGalleryCore/Catalog.swift` (add the property + init line)
- Test: `DiskGalleryCoreTests/ExecutionTests.swift` (append)

**Interfaces:**
- Consumes: `FileOperation`, `OpStatus`, `FileCopier` (Tasks 1–2); `PlanStep`/`PlanOperation`
  (existing planner); `HashVerifier`; `AppDatabase`.
- Produces (on `catalog.execution`):
  - `static func copyDrafts(from steps: [PlanStep], isConnected: (String) -> Bool, now: Date) -> [FileOperation]`
  - `func enqueue(_ ops: [FileOperation]) async throws -> [FileOperation]`
  - `func pendingCopies() async throws -> [FileOperation]`
  - `func history() async throws -> [FileOperation]`
  - `func run(_ ops: [FileOperation], resolve: @Sendable (String, String) -> URL?, progress: @Sendable @MainActor (FileOperation) -> Void) async`

- [ ] **Step 1: Write the failing test**

Append to `DiskGalleryCoreTests/ExecutionTests.swift`:

```swift
    func testExecutorRunsCopyDraftsEndToEnd() async throws {
        let catalog = try Fixture.makeCatalog()
        // Two temp dirs act as the source and destination "drives".
        let driveA = try tempDir(), driveB = try tempDir()
        try Data(repeating: 0x53, count: 2048).write(to: driveA.appendingPathComponent("a.bin"))

        // One copy step: A/a.bin -> B (mirrors relPath).
        let step = PlanStep(id: "s1", orderIndex: 1, operation: .copy, name: "a.bin",
                            sourceDriveKey: "A", sourceDriveName: "A", sourcePath: "a.bin",
                            destinationDriveKey: "B", destinationDriveName: "B", bytes: 2048,
                            estDuration: 0, feasibility: .ok, dependsOn: [], isOverride: false)

        let drafts = ExecutorService.copyDrafts(from: [step], isConnected: { _ in true }, now: Date())
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.destRelPath, "a.bin")

        let enqueued = try await catalog.execution.enqueue(drafts)
        let pending = try await catalog.execution.pendingCopies()
        XCTAssertEqual(pending.count, 1)

        let mounts = ["A": driveA, "B": driveB]
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        // The file was copied + verified to drive B, and the op is done.
        XCTAssertTrue(FileManager.default.fileExists(atPath: driveB.appendingPathComponent("a.bin").path))
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done)
        XCTAssertNotNil(after.first?.destHash)
    }

    func testExecutorSkipsWhenDriveNotConnected() async throws {
        let catalog = try Fixture.makeCatalog()
        let op = FileOperation(type: .copy, sourceVolumeKey: "A", sourceRelPath: "a.bin",
                           destVolumeKey: "B", destRelPath: "a.bin", bytes: 1,
                           status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { _, _ in nil }, progress: { _ in })
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .skipped)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | grep -E "cannot find|value of type 'Catalog'|error:" | head`
Expected: FAIL — `cannot find 'ExecutorService'` / `value of type 'Catalog' has no member 'execution'`.

- [ ] **Step 3: Implement `ExecutorService`**

Create `DiskGalleryCore/Execution/ExecutorService.swift`:

```swift
import Foundation
import GRDB

/// The execution engine facade (`catalog.execution`). Materializes copy operations
/// from the Organize plan, persists them, and runs them with checksum verification.
/// This is the app's deliberate file-mutation surface (via `FileCopier`); cataloging
/// stays read-only.
public final class ExecutorService: Sendable {
    let db: AppDatabase
    let copier: FileCopier

    init(db: AppDatabase, hasher: HashVerifier) {
        self.db = db
        self.copier = FileCopier(hasher: hasher)
    }

    /// Build pending copy operations from a plan's copy steps, for source+destination
    /// drives that are currently connected. Destination path mirrors the source path.
    public static func copyDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                  now: Date) -> [FileOperation] {
        steps.compactMap { step in
            guard step.operation == .copy,
                  let srcKey = step.sourceDriveKey, let srcPath = step.sourcePath,
                  let dstKey = step.destinationDriveKey,
                  isConnected(srcKey), isConnected(dstKey) else { return nil }
            return FileOperation(type: .copy, sourceVolumeKey: srcKey, sourceRelPath: srcPath,
                             destVolumeKey: dstKey, destRelPath: srcPath, bytes: step.bytes,
                             status: .pending, createdAt: now)
        }
    }

    /// Persists drafts as pending rows; returns them with assigned ids.
    public func enqueue(_ ops: [FileOperation]) async throws -> [FileOperation] {
        try await db.writer.write { db in
            try ops.map { var o = $0; try o.insert(db); return o }
        }
    }

    public func pendingCopies() async throws -> [FileOperation] {
        try await db.writer.read { db in
            try FileOperation
                .filter(Column("status") == OpStatus.pending.rawValue
                        && Column("type") == OpType.copy.rawValue)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// All operations, newest first — the audit log / history.
    public func history() async throws -> [FileOperation] {
        try await db.writer.read { db in
            try FileOperation.order(Column("id").desc).fetchAll(db)
        }
    }

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
                let outcome = try copier.copyVerified(from: src, to: dst)
                let updated: FileOperation?
                switch outcome {
                case .verified(let h), .skippedIdentical(let h):
                    updated = try await finish(id, status: .done, sourceHash: h, destHash: h)
                case .conflict:
                    updated = try await finish(id, status: .skipped,
                                               skipReason: "a different file already exists at the destination")
                case .checksumMismatch:
                    updated = try await finish(id, status: .failed, failureReason: "checksum mismatch after copy")
                }
                if let updated { await progress(updated) }
            } catch {
                if let updated = try? await finish(id, status: .failed, failureReason: error.localizedDescription) {
                    await progress(updated)
                }
            }
        }
    }

    // MARK: - Persistence helpers

    @discardableResult
    private func update(_ id: Int64, _ mutate: @Sendable @escaping (inout FileOperation) -> Void) async throws -> FileOperation? {
        try await db.writer.write { db in
            guard var op = try FileOperation.fetchOne(db, key: id) else { return nil }
            mutate(&op)
            try op.update(db)
            return op
        }
    }

    private func finish(_ id: Int64, status: OpStatus, sourceHash: String? = nil,
                        destHash: String? = nil, failureReason: String? = nil,
                        skipReason: String? = nil) async throws -> FileOperation? {
        try await update(id) {
            $0.status = status
            $0.finishedAt = Date()
            if let sourceHash { $0.sourceHash = sourceHash }
            if let destHash { $0.destHash = destHash }
            $0.failureReason = failureReason
            $0.skipReason = skipReason
        }
    }
}
```

- [ ] **Step 4: Wire it into `Catalog`**

In `DiskGalleryCore/Catalog.swift`, add the property after `public let unified: UnifiedBrowserService` (line 21):

```swift
    public let execution: ExecutorService
```

and add this line at the end of `init`, after `self.unified = UnifiedBrowserService(db: db)` (line 38):

```swift
        self.execution = ExecutorService(db: db, hasher: hasher)
```

- [ ] **Step 5: Regenerate the project, then run to verify it passes**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGalleryCore -configuration Debug -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -4`
Expected: `** TEST SUCCEEDED **`, all green, 0 failures (≈159 — treat all-green as the gate). `xcodegen generate` adds the new `ExecutorService.swift` to the project (explicit file refs).

- [ ] **Step 6: Commit**

```bash
git add DiskGalleryCore/Execution/ExecutorService.swift DiskGalleryCore/Catalog.swift DiskGalleryCoreTests/ExecutionTests.swift DiskGallery.xcodeproj
git commit -m "feat(core): ExecutorService — materialize, persist, run verified copies

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: App — Pro-gated reconnect confirm sheet + run

**Files:**
- Modify: `DiskGallery/App/AppEnvironment.swift` (ready-ops computation, run, mount trigger, progress state)
- Create: `DiskGallery/Views/ExecutionConfirmView.swift`
- Modify: `DiskGallery/App/DiskGalleryApp.swift` (present the sheet)

**Interfaces:**
- Consumes: `catalog.execution` (Task 3), `OrganizationPlan` via `env.organizationPlan()`,
  `env.volumes` (`isConnected`, `mountURL`), `env.license.isUnlocked(.transfer)`.
- Produces: `env.executionPrompt: ExecutionPrompt?` (drives the sheet),
  `env.runConfirmedExecution()`, `env.executionProgress: ExecutionProgress?`.

> **Verification:** no app unit-test target — gate is `** BUILD SUCCEEDED **` + the manual smoke in Step 4.

- [ ] **Step 1: Add execution state + logic to `AppEnvironment`**

In `DiskGallery/App/AppEnvironment.swift`, add these observable properties near the other UI state (e.g. after `var dataVersion = 0` on line 121):

```swift
    var executionPrompt: ExecutionPrompt?       // non-nil shows the confirm sheet
    var executionProgress: ExecutionProgress?   // non-nil shows the progress HUD
    @ObservationIgnored private var executionTask: Task<Void, Never>?
```

Add these types and methods (e.g. near the organization-plan methods around line 775):

```swift
    /// A batch of copy operations ready to run for the just-connected drive(s).
    struct ExecutionPrompt: Identifiable {
        let id = UUID()
        var drafts: [FileOperation]
        var fileCount: Int { drafts.count }
        var totalBytes: Int64 { drafts.reduce(0) { $0 + $1.bytes } }
        var driveNames: [String]
    }

    struct ExecutionProgress {
        var completed: Int
        var total: Int
        var currentName: String
    }

    /// On reconnect: if Pro and the current plan has copy steps whose drives are all
    /// connected, surface the confirm sheet.
    func surfaceReadyCopiesOnMount() async {
        guard license.isUnlocked(.transfer) else { return }
        guard executionPrompt == nil, executionProgress == nil else { return }
        let plan = await organizationPlan()
        let drafts = ExecutorService.copyDrafts(from: plan.steps,
                                                isConnected: { [volumes] in volumes.isConnected(key: $0) },
                                                now: Date())
        guard !drafts.isEmpty else { return }
        let names = Set(drafts.compactMap { $0.destVolumeKey }
            .compactMap { key in volumeSummaries.first { ($0.uuid ?? $0.name) == key }?.name })
        executionPrompt = ExecutionPrompt(drafts: drafts, driveNames: names.sorted())
    }

    /// Runs the operations the user confirmed in the sheet.
    func runConfirmedExecution() {
        guard let prompt = executionPrompt else { return }
        executionPrompt = nil
        executionProgress = ExecutionProgress(completed: 0, total: prompt.drafts.count, currentName: "")
        executionTask = Task { [weak self] in
            guard let self else { return }
            let enqueued = (try? await self.catalog.execution.enqueue(prompt.drafts)) ?? []
            var done = 0
            await self.catalog.execution.run(enqueued, resolve: { [volumes = self.volumes] key, rel in
                volumes.mountURL(forKey: key)?.appendingPathComponent(rel)
            }, progress: { op in
                done += 1
                self.executionProgress = ExecutionProgress(completed: done, total: enqueued.count,
                                                           currentName: (op.sourceRelPath as NSString).lastPathComponent)
            })
            self.executionProgress = nil
            self.dataVersion += 1
        }
    }

    func cancelExecution() {
        executionTask?.cancel()
    }
```

Then wire the mount trigger: in `startHardwareCapture()` (around line 400), inside the existing `didMountNotification` observer closure, after the hardware-capture `Task`, add a second task:

```swift
            Task { [weak self] in await self?.surfaceReadyCopiesOnMount() }
```

- [ ] **Step 2: Create the confirm sheet + progress view**

Create `DiskGallery/Views/ExecutionConfirmView.swift`:

```swift
import SwiftUI
import DiskGalleryCore

/// Confirm-once review sheet shown when a drive with ready copy operations connects.
struct ExecutionConfirmView: View {
    @Environment(AppEnvironment.self) private var env
    let prompt: AppEnvironment.ExecutionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to back up", systemImage: "externaldrive.badge.checkmark")
                .font(.title2.bold())
            Text("\(prompt.fileCount) file\(prompt.fileCount == 1 ? "" : "s") · \(Format.bytes(prompt.totalBytes)) → \(prompt.driveNames.joined(separator: ", "))")
                .foregroundStyle(.secondary)
            Label("Files are copied and checksum-verified. Nothing is moved or deleted; existing files are never overwritten.",
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
        .frame(width: 440)
    }
}

/// Progress HUD shown while operations run.
struct ExecutionProgressView: View {
    @Environment(AppEnvironment.self) private var env
    let progress: AppEnvironment.ExecutionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backing up…").font(.headline)
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            Text("\(progress.completed) of \(progress.total) · \(progress.currentName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel") { env.cancelExecution() }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
```

- [ ] **Step 3: Present the sheet/HUD in `ContentView`**

In `DiskGallery/App/DiskGalleryApp.swift`, in `ContentView.body`, after the existing scan-progress `.sheet` (around line 153), add:

```swift
        .sheet(item: Binding(get: { env.executionPrompt }, set: { env.executionPrompt = $0 })) { prompt in
            ExecutionConfirmView(prompt: prompt).environment(env)
        }
        .sheet(isPresented: Binding(get: { env.executionProgress != nil }, set: { _ in })) {
            if let p = env.executionProgress { ExecutionProgressView(progress: p).environment(env) }
        }
```

(`ExecutionPrompt` is already `Identifiable`; `ContentView` already has `env` in scope.)

- [ ] **Step 4: Regenerate the project, build + smoke**

Run: `xcodegen generate && xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`. (`xcodegen generate` adds the new `ExecutionConfirmView.swift` to the project.)
Smoke (manual, requires a Pro/unconfigured license + two scanned drives with Backup-tagged files): tag a file Backup with a destination role set, connect the destination drive, confirm the **Ready to back up** sheet appears, click **Run**, watch the progress HUD, and verify the file now exists on the destination drive. (If no license is configured, all features are unlocked — see `LicenseStore`.)

- [ ] **Step 5: Commit**

```bash
git add DiskGallery/App/AppEnvironment.swift DiskGallery/Views/ExecutionConfirmView.swift DiskGallery/App/DiskGalleryApp.swift DiskGallery.xcodeproj
git commit -m "feat(app): Pro-gated reconnect confirm sheet + run for verified copies

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: App — Activity (history) segment in the Organize home

**Files:**
- Modify: `DiskGallery/Views/OrganizeView.swift` (add an "Activity" mode to `OrganizeHomeView` + an `ExecutionActivityList`)

**Interfaces:**
- Consumes: `catalog.execution.history()` (Task 3), `OrganizeHomeView` (existing, from the
  nav-declutter milestone). Refines spec §UI: Activity is an Organize segment, not a
  sidebar row (a new `SidebarItem` case would force editing frozen Modern).

> **Verification:** build + manual smoke (no app unit-test target).

- [ ] **Step 1: Add the Activity mode + list**

In `DiskGallery/Views/OrganizeView.swift`, in `OrganizeHomeView`, extend the `Mode` enum to include `activity`:

```swift
    enum Mode: String, CaseIterable, Identifiable {
        case plan = "Plan", byDrive = "By drive", activity = "Activity"
        var id: String { rawValue }
    }
```

and add the `activity` arm to the `switch mode` in the body:

```swift
            case .activity: ExecutionActivityList()
```

Then add this view at the end of the file (after `OrganizeStepRow`):

```swift
/// History of execution operations (newest first) — the audit log.
struct ExecutionActivityList: View {
    @Environment(AppEnvironment.self) private var env
    @State private var ops: [FileOperation] = []

    var body: some View {
        Group {
            if ops.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("When you run a backup from the reconnect prompt, each operation appears here."))
            } else {
                List(ops) { op in
                    HStack(spacing: 10) {
                        Image(systemName: icon(op.status)).foregroundStyle(tint(op.status)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((op.destRelPath ?? op.sourceRelPath as String)).lineLimit(1)
                            Text(detail(op)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(Format.bytes(op.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: env.dataVersion) { ops = (try? await env.catalog.execution.history()) ?? [] }
    }

    private func icon(_ s: OpStatus) -> String {
        switch s {
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .pending, .verified: "clock"
        }
    }
    private func tint(_ s: OpStatus) -> Color {
        switch s {
        case .done: .green
        case .failed: .red
        case .skipped: .orange
        default: .secondary
        }
    }
    private func detail(_ op: FileOperation) -> String {
        let where_ = "\(op.sourceVolumeKey) → \(op.destVolumeKey ?? "—")"
        if let r = op.failureReason ?? op.skipReason { return "\(where_) · \(r)" }
        return where_
    }
}
```

- [ ] **Step 2: Build + smoke**

Run: `xcodebuild -project DiskGallery.xcodeproj -scheme DiskGallery -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.
Smoke: open **Organize** → the segmented control now reads **[Plan · By drive · Activity]**; after a run, the Activity tab lists the operations with status icons and reasons.

- [ ] **Step 3: Commit**

```bash
git add DiskGallery/Views/OrganizeView.swift DiskGallery.xcodeproj
git commit -m "feat(app): Activity (execution history) segment in the Organize home

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Stage 1 scope):**
- Isolated `Execution/` module + read-only boundary preserved → Tasks 1–3; `MutationGuardTests` untouched (Global Constraints). ✓
- `operation` table + lifecycle (pending→running→done/failed/skipped) → Task 1 + Task 3. ✓
- Copy → verify → atomic rename; never overwrite; skip-identical/conflict → Task 2. ✓
- Materialize from the plan for connected drives; dest mirrors source path → Task 3 `copyDrafts`. ✓
- Confirm-once sheet on reconnect; Pro-gated; progress + cancel → Task 4. ✓
- Activity/history view → Task 5 (as an Organize segment; deviation from spec §UI noted, with reason). ✓
- Resumable (atomic rename + temp cleanup; re-run skips done, retries pending) → Task 2 + Task 3. ✓
- Out of Stage 1 (correctly deferred): Move, Delete, Trash, backup-verified delete, re-scan-after-run prompt.

**Placeholder scan:** none — every code step is complete; commands have expected output. The two "build + manual smoke" gates (Tasks 4–5) reflect the real absence of an app unit-test target, not a placeholder.

**Type consistency:** `FileOperation`/`OpType`/`OpStatus` (Task 1) are used unchanged in Tasks 3–5. `ExecutorService.copyDrafts/enqueue/pendingCopies/history/run` signatures (Task 3) match their call sites in Task 4. `FileCopier.Outcome` (Task 2) cases map 1:1 to the `switch` in `ExecutorService.run` (Task 3). `OrganizeHomeView.Mode` gains `.activity` consistently (Task 5). `PlanStep` field names match the planner (`sourceDriveKey`, `sourcePath`, `destinationDriveKey`, `operation == .copy`).

**Note for the executor (subagent-driven):** the test counts in Steps assume the Stage-1 tests are added cumulatively (153 baseline → +1, +3, +2 ≈ 159); if other tests change the baseline, treat "all green, 0 failures" as the gate rather than the exact number.
