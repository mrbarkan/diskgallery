import XCTest
import GRDB
@testable import DiskGalleryCore

final class ExecutionTests: XCTestCase {

    func testOperationRoundTripsThroughTheDatabase() async throws {
        let catalog = try Fixture.makeCatalog()   // runs migrations incl. v7
        let template = FileOperation(type: .copy, sourceVolumeKey: "A", sourceRelPath: "shoot/a.cr2",
                           destVolumeKey: "B", destRelPath: "shoot/a.cr2", bytes: 1234,
                           status: .pending, createdAt: Date())
        let insertedOp = try await catalog.database.writer.write { db -> FileOperation in
            var op = template
            try op.insert(db)
            return op
        }
        XCTAssertNotNil(insertedOp.id)

        let fetched = try await catalog.database.writer.read { db in
            try FileOperation.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.type, .copy)
        XCTAssertEqual(fetched.first?.status, .pending)
        XCTAssertEqual(fetched.first?.destRelPath, "shoot/a.cr2")
        XCTAssertEqual(fetched.first?.bytes, 1234)
    }

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

    // MARK: - backupCandidates

    /// Seeds a synthetic volume+snapshot+entry directly (avoids real-FS scan collapsing
    /// multiple temp dirs to the same host-volume UUID).
    private func seedVolume(_ catalog: Catalog, uuid: String, name: String,
                            files: [(name: String, size: Int64)]) async throws {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: uuid, name: name, createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 500_000, isComplete: true)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            for file in files {
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: nil, name: file.name,
                          relPath: file.name, isDir: false, logicalSize: file.size, allocSize: file.size).insert(db)
                nextId += 1
            }
        }
    }

    // NOTE: real folder scans collapse multiple temp dirs to one host-volume UUID, so
    // these tests SEED the catalog (two distinct volumes, via the `seedVolume` helper
    // added in Stage 3 Task 1) AND create real files on disk (so `performDelete` can
    // hash + trash). The seeded volume UUID is the volume key; the `resolve` closure
    // maps that same key to the on-disk temp dir.

    func testDeleteTrashesSourceWhenVerifiedBackupCopyExists() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-DA", name: "dela", files: [("dup.bin", 2048)])
        try await seedVolume(catalog, uuid: "UUID-DB", name: "delb", files: [("dup.bin", 2048)])
        try await catalog.driveRoles.setRole(.mainBackup, forKey: "UUID-DB")   // B is a backup
        // Real identical files on disk for hashing + trashing.
        let dirA = try tempDir(), dirB = try tempDir()
        try Data(repeating: 0x44, count: 2048).write(to: dirA.appendingPathComponent("dup.bin"))
        try Data(repeating: 0x44, count: 2048).write(to: dirB.appendingPathComponent("dup.bin"))
        let mounts = ["UUID-DA": dirA, "UUID-DB": dirB]

        let op = FileOperation(type: .delete, sourceVolumeKey: "UUID-DA", sourceRelPath: "dup.bin",
                               destVolumeKey: nil, destRelPath: nil, bytes: 2048,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        XCTAssertFalse(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("dup.bin").path),
                       "source must be trashed once a verified backup copy exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("dup.bin").path),
                      "the backup copy must remain")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done)
    }

    func testDeleteSkipsWhenOnlyCopyIsOnANonBackupDrive() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-NA", name: "ndela", files: [("dup.bin", 2048)])
        try await seedVolume(catalog, uuid: "UUID-NB", name: "ndelb", files: [("dup.bin", 2048)])
        // B has the copy but NO backup role → not a valid surviving copy.
        let dirA = try tempDir(), dirB = try tempDir()
        try Data(repeating: 0x44, count: 2048).write(to: dirA.appendingPathComponent("dup.bin"))
        try Data(repeating: 0x44, count: 2048).write(to: dirB.appendingPathComponent("dup.bin"))
        let mounts = ["UUID-NA": dirA, "UUID-NB": dirB]

        let op = FileOperation(type: .delete, sourceVolumeKey: "UUID-NA", sourceRelPath: "dup.bin",
                               destVolumeKey: nil, destRelPath: nil, bytes: 2048,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: dirA.appendingPathComponent("dup.bin").path),
                      "source must NOT be trashed without a backup-role verified copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirB.appendingPathComponent("dup.bin").path),
                      "the other copy must also be untouched on a skip")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .skipped)
    }

    func testDeleteIsIdempotentWhenSourceAlreadyGone() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-IA", name: "idela", files: [("dup.bin", 2048)])
        let dirA = try tempDir()   // no dup.bin written → source already gone on disk
        let mounts = ["UUID-IA": dirA]

        let op = FileOperation(type: .delete, sourceVolumeKey: "UUID-IA", sourceRelPath: "dup.bin",
                               destVolumeKey: nil, destRelPath: nil, bytes: 2048,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            mounts[key]?.appendingPathComponent(rel)
        }, progress: { _ in })

        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .done, "already-gone source = done (idempotent)")
    }

    func testDeleteSkipsADirectorySource() async throws {
        let catalog = try Fixture.makeCatalog()
        let dirA = try tempDir()
        let folder = dirA.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let op = FileOperation(type: .delete, sourceVolumeKey: "UUID-FD", sourceRelPath: "folder",
                               destVolumeKey: nil, destRelPath: nil, bytes: 0,
                               status: .pending, createdAt: Date())
        let enqueued = try await catalog.execution.enqueue([op])
        await catalog.execution.run(enqueued, resolve: { key, rel in
            key == "UUID-FD" ? dirA.appendingPathComponent(rel) : nil
        }, progress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "a folder source must not be trashed")
        let after = try await catalog.execution.history()
        XCTAssertEqual(after.first?.status, .skipped)
    }

    func testBackupCandidatesOnlyMatchesBackupRoleDrives() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-VOLA", name: "vola",
                             files: [("dup.bin", 2048)])
        try await seedVolume(catalog, uuid: "UUID-VOLB", name: "volb",
                             files: [("dup.bin", 2048)])
        let vols = try await catalog.library.volumes()
        XCTAssertEqual(vols.count, 2, "two seeded volumes should appear in the library")
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
}
