import XCTest
import GRDB
@testable import DiskGalleryCore

final class HiddenFilesTests: XCTestCase {
    /// Seeds one volume + complete snapshot. Returns (rootId, snapshotId).
    /// Files are (name, relPath, parentIsRoot). Root dir has parentId nil.
    @discardableResult
    private func seed(_ catalog: Catalog, uuid: String = "UUID-H", name: String = "Hdrive",
                      children: [(name: String, relPath: String, ext: String?, dir: Bool)])
        async throws -> (rootId: Int64, snapshotId: Int64) {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: uuid, name: name, createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 500_000, isComplete: true)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            let rootId = nextId
            try Entry(id: rootId, snapshotId: snapshot.id!, parentId: nil, name: name,
                      relPath: "", isDir: true, logicalSize: 0, allocSize: 0, ext: nil).insert(db)
            nextId += 1
            for c in children {
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: rootId, name: c.name,
                          relPath: c.relPath, isDir: c.dir, logicalSize: 10, allocSize: 10,
                          ext: c.ext).insert(db)
                nextId += 1
            }
            return (rootId, snapshot.id!)
        }
    }

    func testChildrenHideDotfilesWhenHideHiddenOn() async throws {
        let catalog = try Fixture.makeCatalog()
        let (rootId, snapshotId) = try await seed(catalog, children: [
            ("a.jpg", "a.jpg", "jpg", false),
            (".DS_Store", ".DS_Store", nil, false),
            (".hidden", ".hidden", nil, true),
        ])

        let shown = try await catalog.library.children(parentId: rootId, snapshotId: snapshotId, hideHidden: true)
        XCTAssertEqual(shown.map(\.name).sorted(), ["a.jpg"])

        let all = try await catalog.library.children(parentId: rootId, snapshotId: snapshotId, hideHidden: false)
        XCTAssertEqual(all.count, 3)   // default false → nothing filtered
    }
}
