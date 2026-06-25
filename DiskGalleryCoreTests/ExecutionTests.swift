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
}
