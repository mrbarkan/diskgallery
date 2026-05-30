import XCTest
import GRDB
@testable import DiskGalleryCore

final class BackupTests: XCTestCase {

    func testExportThenRestoreReproducesTheCatalog() async throws {
        // Source catalog with one scanned drive + an annotation.
        let source = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(source, root)
        let sourceVolumes = try await source.library.volumes()
        let volume = try XCTUnwrap(sourceVolumes.first)
        try await source.annotations.setDecision(.keep, volumeKey: volume.uuid ?? volume.name, relPath: "a.txt")

        let beforeVolumes = try await source.library.volumes().count
        let beforeTagged = try await source.annotations.taggedEntries(.keep).count
        XCTAssertEqual(beforeTagged, 1)

        // Export to a portable file.
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskGalleryTests-\(UUID().uuidString).\(BackupService.fileExtension)")
        try source.backup.export(to: backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))

        // Restore into a fresh, empty catalog.
        let target = try Fixture.makeCatalog()
        let emptyCount = try await target.library.volumes().count
        XCTAssertEqual(emptyCount, 0)
        try target.backup.restore(from: backupURL)

        let restoredCount = try await target.library.volumes().count
        XCTAssertEqual(restoredCount, beforeVolumes)
        let restoredTagged = try await target.annotations.taggedEntries(.keep).count
        XCTAssertEqual(restoredTagged, beforeTagged)

        // Entries came across too — folder rollups intact.
        let restoredVolumes = try await target.library.volumes()
        let restoredVolume = try XCTUnwrap(restoredVolumes.first)
        let snapshotId = try XCTUnwrap(restoredVolume.latestSnapshotId)
        let rootEntry = try await target.library.rootEntry(snapshotId: snapshotId)
        XCTAssertEqual(rootEntry?.subtreeLogicalSize, 450)
    }

    func testRestoreRejectsNonCatalogFile() async throws {
        let target = try Fixture.makeCatalog()
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-db-\(UUID().uuidString).\(BackupService.fileExtension)")
        try Data("hello world, not a database".utf8).write(to: junk)

        XCTAssertThrowsError(try target.backup.restore(from: junk))
    }
}
