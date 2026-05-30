import XCTest
import GRDB
@testable import DiskGalleryCore

final class ChangeTests: XCTestCase {

    func testDiffDetectsAddedRemovedAndResized() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()   // a.txt(100) b.txt(200) sub/c.txt(50) sub/a.txt(100)

        let first = try await Fixture.scan(catalog, root)

        // Mutate the tree, then re-scan: +new.txt, −b.txt, a.txt resized 100→150.
        try Fixture.writeFile(root, "new.txt", bytes: 300)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        try Fixture.writeFile(root, "a.txt", bytes: 150)
        let second = try await Fixture.scan(catalog, root)

        XCTAssertNotEqual(first, second)

        let volumeId = try await catalog.database.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT volumeId FROM snapshot WHERE id = ?", arguments: [second]) ?? -1
        }

        let snaps = try await catalog.changes.completeSnapshots(volumeId: volumeId)
        XCTAssertEqual(snaps.count, 2, "Re-scan should keep both snapshots")

        let maybePair = try await catalog.changes.latestComparablePair(volumeId: volumeId)
        let pair = try XCTUnwrap(maybePair)
        XCTAssertEqual(pair.head, second)
        XCTAssertEqual(pair.base, first)

        let diff = try await catalog.changes.diff(baseSnapshotId: pair.base, headSnapshotId: pair.head)

        XCTAssertEqual(diff.addedCount, 1)
        XCTAssertEqual(diff.addedBytes, 300)
        XCTAssertEqual(diff.added.first?.name, "new.txt")

        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.removedBytes, 200)
        XCTAssertEqual(diff.removed.first?.name, "b.txt")

        XCTAssertEqual(diff.resizedCount, 1)
        XCTAssertEqual(diff.resizedNetBytes, 50)
        XCTAssertEqual(diff.resized.first?.delta, 50)

        XCTAssertEqual(diff.netBytes, 150)   // +300 −200 +50
        XCTAssertTrue(diff.hasChanges)
    }

    func testIdenticalRescanShowsNoChanges() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        let first = try await Fixture.scan(catalog, root)
        let second = try await Fixture.scan(catalog, root)

        let diff = try await catalog.changes.diff(baseSnapshotId: first, headSnapshotId: second)
        XCTAssertFalse(diff.hasChanges)
        XCTAssertEqual(diff.netBytes, 0)
    }
}
