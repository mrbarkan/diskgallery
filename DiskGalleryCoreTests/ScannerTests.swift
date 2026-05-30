import XCTest
import GRDB
@testable import DiskGalleryCore

final class ScannerTests: XCTestCase {

    func testScanRecordsEveryEntryWithCorrectSizes() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        let snapshotId = try await Fixture.scan(catalog, root)

        // 7 entries: root + (a.txt, b.txt, sub, empty) + (sub/c.txt, sub/a.txt)
        let total = try await catalog.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE snapshotId = ?", arguments: [snapshotId]) ?? 0
        }
        XCTAssertEqual(total, 7)

        // Per-file logical sizes.
        let a = try await catalog.database.writer.read { db in
            try Entry.fetchOne(db, sql: "SELECT * FROM entry WHERE snapshotId = ? AND relPath = ?",
                               arguments: [snapshotId, "a.txt"])
        }
        XCTAssertEqual(a?.logicalSize, 100)
        XCTAssertEqual(a?.isDir, false)
        XCTAssertEqual(a?.ext, "txt")
    }

    func testFolderSizesAreRolledUpAndStored() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        let snapshotId = try await Fixture.scan(catalog, root)

        let sub = try await catalog.database.writer.read { db in
            try Entry.fetchOne(db, sql: "SELECT * FROM entry WHERE snapshotId = ? AND relPath = ?",
                               arguments: [snapshotId, "sub"])
        }
        XCTAssertEqual(sub?.isDir, true)
        XCTAssertEqual(sub?.subtreeLogicalSize, 150)   // 50 + 100

        let rootEntry = try await catalog.library.rootEntry(snapshotId: snapshotId)
        XCTAssertEqual(rootEntry?.subtreeLogicalSize, 450)  // 100 + 200 + 150 + 0

        // Snapshot summary
        let snapshot = try await catalog.database.writer.read { db in
            try Snapshot.fetchOne(db, key: snapshotId)
        }
        XCTAssertEqual(snapshot?.fileCount, 4)
        XCTAssertEqual(snapshot?.totalLogical, 450)
    }

    func testEmptyFolderHasZeroSubtreeSize() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        let snapshotId = try await Fixture.scan(catalog, root)

        let empty = try await catalog.database.writer.read { db in
            try Entry.fetchOne(db, sql: "SELECT * FROM entry WHERE snapshotId = ? AND relPath = ?",
                               arguments: [snapshotId, "empty"])
        }
        XCTAssertEqual(empty?.subtreeLogicalSize, 0)
    }

    func testBrowsingChildrenFolderFirstThenAlphabetical() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        let snapshotId = try await Fixture.scan(catalog, root)
        let rootEntry = try await catalog.library.rootEntry(snapshotId: snapshotId)

        let children = try await catalog.library.children(parentId: rootEntry!.id, snapshotId: snapshotId)
        let names = children.map(\.name)
        // Folders (empty, sub) first, then files (a.txt, b.txt)
        XCTAssertEqual(names, ["empty", "sub", "a.txt", "b.txt"])
    }

    func testScanDoesNotModifyTheScannedTree() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()

        let before = try Fixture.modificationDates(root)
        _ = try await Fixture.scan(catalog, root)
        let after = try Fixture.modificationDates(root)

        XCTAssertEqual(before, after, "Scanning must not alter any file or folder on the drive")
    }

    func testScanningMissingPathThrows() async throws {
        let catalog = try Fixture.makeCatalog()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        do {
            _ = try await Fixture.scan(catalog, missing)
            XCTFail("Expected scan of a missing path to throw")
        } catch {
            // expected
        }
    }

    func testPauseAndResumeProducesSameCatalog() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()

        // Partial scan: stop after one batch, leaving directories queued.
        var snapshotId: Int64?
        for try await progress in catalog.scanner.run(volumeURL: root, resumeSnapshotId: nil,
                                                      batchSize: 2, maxBatches: 1) {
            snapshotId = progress.snapshotId
        }
        let sid = try XCTUnwrap(snapshotId)

        let paused = try await catalog.database.writer.read { db -> (complete: Bool, pending: Int, entries: Int) in
            let complete = try Bool.fetchOne(db, sql: "SELECT isComplete FROM snapshot WHERE id = ?", arguments: [sid]) ?? true
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pendingDir WHERE snapshotId = ?", arguments: [sid]) ?? 0
            let entries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE snapshotId = ?", arguments: [sid]) ?? 0
            return (complete, pending, entries)
        }
        XCTAssertFalse(paused.complete, "Paused scan should be incomplete")
        XCTAssertGreaterThan(paused.pending, 0, "Paused scan should leave directories queued")
        XCTAssertLessThan(paused.entries, 7, "Paused scan should be partial")

        // Resume to completion.
        for try await _ in catalog.scanner.resume(snapshotId: sid, volumeURL: root) {}

        let done = try await catalog.database.writer.read { db -> (entries: Int, complete: Bool, pending: Int, rootSize: Int64?, subSize: Int64?) in
            let entries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE snapshotId = ?", arguments: [sid]) ?? 0
            let complete = try Bool.fetchOne(db, sql: "SELECT isComplete FROM snapshot WHERE id = ?", arguments: [sid]) ?? false
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pendingDir WHERE snapshotId = ?", arguments: [sid]) ?? 0
            let rootSize = try Int64.fetchOne(db, sql: "SELECT subtreeLogicalSize FROM entry WHERE snapshotId = ? AND parentId IS NULL", arguments: [sid])
            let subSize = try Int64.fetchOne(db, sql: "SELECT subtreeLogicalSize FROM entry WHERE snapshotId = ? AND relPath = 'sub'", arguments: [sid])
            return (entries, complete, pending, rootSize, subSize)
        }
        XCTAssertEqual(done.entries, 7, "Resumed scan should hold the whole tree")
        XCTAssertTrue(done.complete, "Resumed scan should be complete")
        XCTAssertEqual(done.pending, 0, "Queue should be drained")
        XCTAssertEqual(done.rootSize, 450, "Root rollup correct after resume")
        XCTAssertEqual(done.subSize, 150, "Folder rollup correct after resume")
    }
}
