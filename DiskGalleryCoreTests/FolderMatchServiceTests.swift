import XCTest
import GRDB
@testable import DiskGalleryCore

final class FolderMatchServiceTests: XCTestCase {

    typealias File = (path: String, size: Int64, hash: String?)

    private func f(_ path: String, _ size: Int64, _ hash: String? = nil) -> File { (path, size, hash) }

    /// Seeds a snapshot of drive `name` (creating the volume on first use). Real scans
    /// resolve to the host volume, so distinct drives are modelled with synthetic rows.
    @discardableResult
    private func seed(_ catalog: Catalog, _ name: String, _ files: [File],
                      scannedAt: Date = Date(), isComplete: Bool = true) async throws -> Int64 {
        try await catalog.database.writer.write { db in
            var volumeId = try Int64.fetchOne(db, sql: "SELECT id FROM volume WHERE name = ?", arguments: [name])
            if volumeId == nil {
                var volume = Volume(uuid: "UUID-\(name)", name: name, createdAt: Date())
                try volume.insert(db)
                volumeId = volume.id
            }
            var snapshot = Snapshot(volumeId: volumeId!, scannedAt: scannedAt, isComplete: isComplete)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            for file in files {
                let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: nil, name: name, relPath: file.path,
                          isDir: false, logicalSize: file.size, allocSize: file.size,
                          contentHash: file.hash).insert(db)
                nextId += 1
            }
            return snapshot.id!
        }
    }

    private let photos: [FolderMatchServiceTests.File] = [
        ("Photos/2024/a.jpg", 500, nil), ("Photos/2024/sub/b.jpg", 300, nil),
    ]

    func testExactMatchUnderDifferentPathOnAnotherDrive() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("Backup/Old2024/a.jpg", 500), f("Backup/Old2024/sub/b.jpg", 300),
                                           f("other.txt", 10)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.sourceFileCount, 2)
        XCTAssertEqual(result.sourceBytes, 800)
        XCTAssertEqual(result.matches.count, 1)
        let match = try XCTUnwrap(result.matches.first)
        XCTAssertEqual(match.volumeName, "DriveB")
        XCTAssertEqual(match.volumeKey, "UUID-DriveB")
        XCTAssertEqual(match.relPath, "Backup/Old2024")
        XCTAssertEqual(match.kind, .exact)
        XCTAssertEqual(match.fileCount, 2)
        XCTAssertEqual(match.totalBytes, 800)
        XCTAssertEqual(match.verification, .unverified)
    }

    func testSupersetReportsExtraFilesAndBytes() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500), f("B/sub/b.jpg", 300),
                                           f("B/c.txt", 70), f("B/sub/d.txt", 30)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches.map(\.kind), [.superset(extraFiles: 2, extraBytes: 100)])
        XCTAssertEqual(result.matches.first?.fileCount, 4)
    }

    func testMissingFileIsNotAMatch() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches, [])
        XCTAssertFalse(result.isEmpty)
    }

    func testSizeMismatchIsNotAMatch() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500), f("B/sub/b.jpg", 301)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches, [])
    }

    func testFinderJunkIsIgnoredOnBothSides() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos + [f("Photos/2024/.DS_Store", 6148),
                                                                 f("Photos/2024/sub/Thumbs.db", 99)])
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500), f("B/sub/b.jpg", 300),
                                           f("B/._a.jpg", 4096), f("B/.DS_Store", 12),
                                           f("B/.Spotlight-V100/store.db", 900)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.sourceFileCount, 2)
        XCTAssertEqual(result.matches.map(\.kind), [.exact])
    }

    func testSameDriveCopyIsExcluded() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos + [f("Copy/a.jpg", 500), f("Copy/sub/b.jpg", 300)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches, [])
    }

    func testOnlyLatestSnapshotOfADriveCounts() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500), f("B/sub/b.jpg", 300)],
                       scannedAt: Date(timeIntervalSinceNow: -86_400 * 2))
        try await seed(catalog, "DriveB", [f("unrelated.txt", 5)])   // copy deleted since

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches, [])
    }

    func testIncompleteLatestSnapshotIsIgnored() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        let complete = try await seed(catalog, "DriveB", [f("B/a.jpg", 500), f("B/sub/b.jpg", 300)],
                                      scannedAt: Date(timeIntervalSinceNow: -86_400))
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500)], isComplete: false)   // rescan in progress

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches.map(\.snapshotId), [complete])
        XCTAssertEqual(result.matches.map(\.kind), [.exact])
    }

    func testCopyAtDriveRoot() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("a.jpg", 500), f("sub/b.jpg", 300)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches.map(\.relPath), [""])
        XCTAssertEqual(result.matches.map(\.kind), [.exact])
    }

    func testEmptyFolderIsEmpty() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Nothing/Here")
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.matches, [])
    }

    func testJunkOnlyFolderIsEmpty() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", [f("Junk/.DS_Store", 6148), f("Junk/._x", 4096)])
        try await seed(catalog, "DriveB", [f("Other/.DS_Store", 6148)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Junk")
        XCTAssertTrue(result.isEmpty)
    }

    func testNoCopiesAnywhere() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "DriveB", [f("unrelated.txt", 5)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.matches, [])
    }

    func testSimilarlyNamedSiblingFoldersDontLeakIntoManifest() async throws {
        let catalog = try Fixture.makeCatalog()
        // `_` is a LIKE wildcard and LIKE is ASCII case-insensitive: both siblings would
        // leak in (and their large files would become the anchor) without the guards.
        let source = try await seed(catalog, "DriveA", [f("2024_trip/a.jpg", 500),
                                                        f("2024Xtrip/huge.mov", 9_000),
                                                        f("2024_TRIP/other.mov", 8_000)])
        try await seed(catalog, "DriveB", [f("Copy/a.jpg", 500)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "2024_trip")
        XCTAssertEqual(result.sourceFileCount, 1)
        XCTAssertEqual(result.matches.map(\.relPath), ["Copy"])
        XCTAssertEqual(result.matches.map(\.kind), [.exact])
    }

    func testCandidatesAreCapped() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", [f("Src/a.jpg", 500)])
        try await seed(catalog, "DriveB", (0..<60).map { f(String(format: "c%02d/a.jpg", $0), 500) })

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Src")
        XCTAssertEqual(result.matches.count, FolderMatchService.candidateLimit)
        XCTAssertEqual(FolderMatchService.candidateLimit, 50)
    }

    func testExactMatchesSortBeforeSupersets() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        try await seed(catalog, "Alpha", [f("X/a.jpg", 500), f("X/sub/b.jpg", 300), f("X/e1", 1), f("X/e2", 1)])
        try await seed(catalog, "Beta", [f("Y/a.jpg", 500), f("Y/sub/b.jpg", 300), f("Y/e1", 1)])
        try await seed(catalog, "Gamma", [f("Z/a.jpg", 500), f("Z/sub/b.jpg", 300)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "Photos/2024")
        XCTAssertEqual(result.matches.map(\.volumeName), ["Gamma", "Beta", "Alpha"])
    }

    func testAllHashesEqualIsVerified() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", [f("P/a.jpg", 500, "h1"), f("P/sub/b.jpg", 300, "h2")])
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500, "h1"), f("B/sub/b.jpg", 300, "h2"), f("B/x", 1)])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "P")
        XCTAssertEqual(result.matches.map(\.verification), [.verified])
    }

    func testDifferingHashIsMismatched() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", [f("P/a.jpg", 500, "h1"), f("P/sub/b.jpg", 300, "h2")])
        try await seed(catalog, "DriveB", [f("B/a.jpg", 500, "h1"), f("B/sub/b.jpg", 300, "XX")])

        let result = try await catalog.folderMatches.findMatches(snapshotId: source, folderRelPath: "P")
        XCTAssertEqual(result.matches.map(\.verification), [.mismatched(["sub/b.jpg"])])
    }

    func testPairsLocateEachFileOnBothDrives() async throws {
        let catalog = try Fixture.makeCatalog()
        let source = try await seed(catalog, "DriveA", photos)
        let target = try await seed(catalog, "DriveB", [f("B/a.jpg", 500, "h1"), f("B/sub/b.jpg", 300),
                                                        f("B/extra", 1)])

        let pairs = try await catalog.folderMatches.pairs(sourceSnapshotId: source, sourceFolder: "Photos/2024",
                                                          targetSnapshotId: target, targetFolder: "B")
        XCTAssertEqual(pairs.map(\.relativePath), ["a.jpg", "sub/b.jpg"])
        XCTAssertEqual(pairs.map(\.sourceRelPath), ["Photos/2024/a.jpg", "Photos/2024/sub/b.jpg"])
        XCTAssertEqual(pairs.map(\.targetRelPath), ["B/a.jpg", "B/sub/b.jpg"])
        XCTAssertEqual(pairs.map(\.targetHash), ["h1", nil])
    }
}
