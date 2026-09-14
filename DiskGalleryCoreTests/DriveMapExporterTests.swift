import XCTest
import GRDB
@testable import DiskGalleryCore

final class DriveMapExporterTests: XCTestCase {
    /// Scans `root` into a fresh catalog and returns it with the new drive's id.
    private func scanned(_ root: URL) async throws -> (Catalog, Int64) {
        let catalog = try Fixture.makeCatalog()
        try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let id = try XCTUnwrap(volumes.first?.id)
        return (catalog, id)
    }

    func testBuildProducesNestedFoldersWithSizesAndCounts() async throws {
        let (catalog, id) = try await scanned(try Fixture.makeTree())
        let map = try await catalog.driveMaps.build(volumeId: id)

        XCTAssertEqual(map.root.bytes, 450)
        XCTAssertEqual(map.root.fileCount, 4)
        XCTAssertEqual(map.root.folders.map(\.name), ["empty", "sub"])
        let sub = try XCTUnwrap(map.root.folders.first { $0.name == "sub" })
        XCTAssertEqual(sub.relPath, "sub")
        XCTAssertEqual(sub.bytes, 150)
        XCTAssertEqual(sub.fileCount, 2)
        XCTAssertEqual(map.root.folders.first?.bytes, 0)
        XCTAssertEqual(map.drive.fileCount, 4)
        XCTAssertEqual(map.drive.folderCount, 2)
        XCTAssertEqual(map.categories, [DriveMap.CategoryTotal(name: "Documents", bytes: 450, count: 4)])
        XCTAssertEqual(map.extensionCategories["mov"], "Video")
    }

    func testFileSampleIsLargestNAndReportsRemainder() async throws {
        let root = try Fixture.makeTree()
        for (i, size) in [10, 20, 30, 40, 50, 60, 70].enumerated() {
            try Fixture.writeFile(root, "clips/f\(i).mov", bytes: size)
        }
        let (catalog, id) = try await scanned(root)
        let map = try await catalog.driveMaps.build(volumeId: id, options: DriveMapOptions(filesPerFolder: 3))

        let clips = try XCTUnwrap(map.root.folders.first { $0.name == "clips" })
        XCTAssertEqual(clips.files.map(\.name), ["f6.mov", "f5.mov", "f4.mov"])
        XCTAssertEqual(clips.moreFiles, 4)
        XCTAssertEqual(clips.fileCount, 7)
        XCTAssertEqual(clips.bytes, 280)
    }

    func testIncludeFilesFalseOmitsFiles() async throws {
        let (catalog, id) = try await scanned(try Fixture.makeTree())
        let map = try await catalog.driveMaps.build(volumeId: id, options: DriveMapOptions(includeFiles: false))

        XCTAssertFalse(map.includesFiles)
        XCTAssertTrue(map.root.files.isEmpty)
        XCTAssertEqual(map.root.moreFiles, 0)
        let sub = try XCTUnwrap(map.root.folders.first { $0.name == "sub" })
        XCTAssertTrue(sub.files.isEmpty)
        XCTAssertEqual(sub.moreFiles, 0)
        XCTAssertEqual(map.root.fileCount, 4)
    }

    func testHideHiddenDropsDotEntries() async throws {
        let root = try Fixture.makeTree()
        try Fixture.writeFile(root, ".secret.txt", bytes: 10)
        try Fixture.writeFile(root, ".cache/blob.bin", bytes: 20)
        let (catalog, id) = try await scanned(root)

        let hidden = try await catalog.driveMaps.build(volumeId: id)
        XCTAssertEqual(hidden.root.folders.map(\.name), ["empty", "sub"])
        XCTAssertFalse(hidden.root.files.contains { $0.name == ".secret.txt" })
        XCTAssertEqual(hidden.root.bytes, 450)

        let shown = try await catalog.driveMaps.build(volumeId: id, options: DriveMapOptions(hideHidden: false))
        XCTAssertTrue(shown.root.folders.contains { $0.name == ".cache" })
        XCTAssertEqual(shown.root.bytes, 480)
        XCTAssertEqual(shown.root.fileCount, 6)
    }

    func testBuildThrowsWithoutCompleteSnapshot() async throws {
        let catalog = try Fixture.makeCatalog()
        let id: Int64 = try await catalog.database.writer.write { db in
            var volume = Volume(uuid: "U-BLANK", name: "Blank", createdAt: Date())
            try volume.insert(db)
            return volume.id!
        }
        do {
            _ = try await catalog.driveMaps.build(volumeId: id)
            XCTFail("expected noCompleteSnapshot")
        } catch DriveMapError.noCompleteSnapshot {}
    }
}
