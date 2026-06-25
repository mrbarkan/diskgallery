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
}
