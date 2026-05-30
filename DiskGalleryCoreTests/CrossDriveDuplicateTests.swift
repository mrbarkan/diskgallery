import XCTest
import GRDB
@testable import DiskGalleryCore

final class CrossDriveDuplicateTests: XCTestCase {

    /// Volume identity on a real scan resolves to the host volume, so to model several
    /// distinct drives we seed synthetic volumes/snapshots/entries directly.
    private func seedDrive(_ catalog: Catalog, uuid: String, name: String,
                           files: [(name: String, size: Int64)]) async throws {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: uuid, name: name, createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 500_000, isComplete: true)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            for file in files {
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: nil, name: file.name,
                          relPath: file.name, isDir: false, logicalSize: file.size, allocSize: file.size).insert(db)
                nextId += 1
            }
        }
    }

    func testCrossDriveDuplicatesSpanDrivesAndExcludeSameDrivePairs() async throws {
        let catalog = try Fixture.makeCatalog()
        // movie.mov(500) lives on BOTH drives. dupinA(50) is duplicated WITHIN drive A only.
        try await seedDrive(catalog, uuid: "UUID-A", name: "DriveA",
                            files: [("movie.mov", 500), ("dupinA.txt", 50), ("copy_dupinA.txt", 50), ("photo.jpg", 100)])
        try await seedDrive(catalog, uuid: "UUID-B", name: "DriveB",
                            files: [("movie.mov", 500), ("report.pdf", 200)])

        // movie.mov has two copies named identically across the drives.
        // dupinA/copy_dupinA share a SIZE but different names, so they aren't a set.

        let all = try await catalog.duplicates.duplicateSets()
        let movie = try XCTUnwrap(all.first { $0.name == "movie.mov" })
        XCTAssertEqual(movie.copies, 2)
        XCTAssertEqual(movie.driveCount, 2)
        XCTAssertTrue(movie.spansDrives)
        XCTAssertEqual(Set(movie.driveList), ["DriveA", "DriveB"])

        let crossOnly = try await catalog.duplicates.duplicateSets(crossDriveOnly: true)
        XCTAssertTrue(crossOnly.allSatisfy { $0.driveCount >= 2 })
        XCTAssertTrue(crossOnly.contains { $0.name == "movie.mov" })
    }

    func testSameDriveDuplicateIsExcludedFromCrossDriveFilter() async throws {
        let catalog = try Fixture.makeCatalog()
        // Two identically-named files on the SAME drive: a duplicate set, but single-drive.
        try await seedDrive(catalog, uuid: "UUID-A", name: "DriveA",
                            files: [("clip.mov", 300)])
        try await catalog.database.writer.write { db in
            let sid = try Int64.fetchOne(db, sql: "SELECT id FROM snapshot LIMIT 1")!
            let nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            try Entry(id: nextId, snapshotId: sid, parentId: nil, name: "clip.mov",
                      relPath: "backup/clip.mov", isDir: false, logicalSize: 300, allocSize: 300).insert(db)
        }

        let all = try await catalog.duplicates.duplicateSets()
        XCTAssertTrue(all.contains { $0.name == "clip.mov" && $0.copies == 2 })

        let crossOnly = try await catalog.duplicates.duplicateSets(crossDriveOnly: true)
        XCTAssertFalse(crossOnly.contains { $0.name == "clip.mov" }, "Same-drive duplicate must be excluded")
    }
}
