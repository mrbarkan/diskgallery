import XCTest
import GRDB
@testable import DiskGalleryCore

final class PlanningTests: XCTestCase {

    func testTagRollupsAndNestingDedup() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = volume.uuid ?? volume.name

        // Tag a folder AND a file inside it the same way — the child must not double-count.
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "sub")        // subtree = 150
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "sub/a.txt")  // 100, nested
        try await catalog.annotations.setDecision(.keep, volumeKey: key, relPath: "a.txt")         // 100

        let stats = try await catalog.planning.driveStats()
        let drive = try XCTUnwrap(stats.first { $0.id == volume.id })

        XCTAssertEqual(drive.deleteBytes, 150, "Nested tagged child must not be summed twice")
        XCTAssertEqual(drive.deleteCount, 1)
        XCTAssertEqual(drive.keepBytes, 100)
        XCTAssertEqual(drive.keepCount, 1)
        XCTAssertEqual(drive.reviewBytes, 0)
    }

    func testMoveAndBackupRollups() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = volume.uuid ?? volume.name

        try await catalog.annotations.setDecision(.move, volumeKey: key, relPath: "b.txt")    // 200
        try await catalog.annotations.setDecision(.backup, volumeKey: key, relPath: "sub")     // subtree = 150

        let stats = try await catalog.planning.driveStats()
        let drive = try XCTUnwrap(stats.first { $0.id == volume.id })
        XCTAssertEqual(drive.moveBytes, 200)
        XCTAssertEqual(drive.moveCount, 1)
        XCTAssertEqual(drive.backupBytes, 150)
        XCTAssertEqual(drive.backupCount, 1)
        XCTAssertEqual(drive.pendingCount, 2)
    }

    func testPlannedItemsReturnsTopLevelOnly() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = volume.uuid ?? volume.name

        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "sub")
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "sub/c.txt")

        let items = try await catalog.planning.plannedItems(volumeKey: key, tag: .delete)
        XCTAssertEqual(items.map(\.relPath), ["sub"])
        XCTAssertEqual(items.first?.sizeBytes, 150)
        XCTAssertEqual(items.first?.isDir, true)
    }
}
