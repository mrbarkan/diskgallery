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

    func testGalleryItemsHideHiddenAcrossDepth() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seed(catalog, children: [
            ("a.jpg", "a.jpg", "jpg", false),
            ("t.jpg", ".Trashes/t.jpg", "jpg", false),   // inside a hidden folder
            ("b.jpg", ".b.jpg", "jpg", false),           // dot-prefixed file
            ("c.jpg", "Photos/.thumbs/c.jpg", "jpg", false), // hidden component below root
        ])
        let shown = try await catalog.gallery.items(categories: [.photos], hideHidden: true)
        XCTAssertEqual(shown.map(\.relPath), ["a.jpg"])
        let all = try await catalog.gallery.items(categories: [.photos], hideHidden: false)
        XCTAssertEqual(Set(all.map(\.relPath)), [".Trashes/t.jpg", ".b.jpg", "a.jpg", "Photos/.thumbs/c.jpg"])
    }

    func testSearchHidesHidden() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seed(catalog, children: [
            ("report.jpg", "report.jpg", "jpg", false),
            ("report.jpg", ".Trashes/report.jpg", "jpg", false),
        ])
        let hidden = try await catalog.search.search("report", hideHidden: true)
        XCTAssertEqual(hidden.map(\.relPath), ["report.jpg"])
        let all = try await catalog.search.search("report", hideHidden: false)
        XCTAssertEqual(all.count, 2)
    }

    func testDuplicateSetsHideHidden() async throws {
        let catalog = try Fixture.makeCatalog()
        // Two visible copies + one hidden copy of the same (name,size).
        try await seed(catalog, uuid: "UUID-D1", name: "D1", children: [
            ("dup.jpg", "dup.jpg", "jpg", false),
        ])
        try await seed(catalog, uuid: "UUID-D2", name: "D2", children: [
            ("dup.jpg", "dup.jpg", "jpg", false),
            ("dup.jpg", ".Trashes/dup.jpg", "jpg", false),
        ])
        let hidden = try await catalog.duplicates.duplicateSets(hideHidden: true)
        XCTAssertEqual(hidden.first(where: { $0.name == "dup.jpg" })?.copies, 2)
        let all = try await catalog.duplicates.duplicateSets(hideHidden: false)
        XCTAssertEqual(all.first(where: { $0.name == "dup.jpg" })?.copies, 3)
    }
}
