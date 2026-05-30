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
}
