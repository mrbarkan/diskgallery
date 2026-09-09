import XCTest
import GRDB
@testable import DiskGalleryCore

final class ThumbnailTests: XCTestCase {
    func testThumbnailRoundTripsAndVolumePreviewTypesPersist() async throws {
        let catalog = try Fixture.makeCatalog()   // runs migrations incl. v8
        try await catalog.database.writer.write { db in
            var vol = Volume(uuid: "UUID-T", name: "T", createdAt: Date(), previewTypes: "[\"photos\",\"raw\"]")
            try vol.insert(db)
            var t = Thumbnail(volumeKey: "UUID-T", relPath: "a/b.cr2", cacheFile: "deadbeef.heic",
                              srcModifiedAt: Date(), srcSize: 4096, generatedAt: Date())
            try t.insert(db)
        }
        let (vol, thumb) = try await catalog.database.writer.read { db in
            (try Volume.fetchOne(db), try Thumbnail.fetchOne(db))
        }
        XCTAssertEqual(vol?.previewTypes, "[\"photos\",\"raw\"]")
        XCTAssertEqual(thumb?.relPath, "a/b.cr2")
        XCTAssertEqual(thumb?.cacheFile, "deadbeef.heic")
        XCTAssertEqual(thumb?.srcSize, 4096)
    }

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("DGThumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testCachedRelPathsReturnsStoredSet() async throws {
        let dbURL = try tempDir().appendingPathComponent("catalog.sqlite")
        let catalog = try Catalog(databaseURL: dbURL)
        try await catalog.thumbnails.store(Data([0x1]), volumeKey: "A", relPath: "x.jpg", srcModifiedAt: nil, srcSize: 1)
        try await catalog.thumbnails.store(Data([0x2]), volumeKey: "A", relPath: "y.jpg", srcModifiedAt: nil, srcSize: 1)

        let cached = try await catalog.thumbnails.cachedRelPaths(volumeKey: "A", relPaths: ["x.jpg", "y.jpg", "z.jpg"])
        XCTAssertEqual(cached, ["x.jpg", "y.jpg"])

        let other = try await catalog.thumbnails.cachedRelPaths(volumeKey: "B", relPaths: ["x.jpg"])
        XCTAssertTrue(other.isEmpty)
        let empty = try await catalog.thumbnails.cachedRelPaths(volumeKey: "A", relPaths: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testCacheStoreRetrieveAndFreshness() async throws {
        // Catalog whose sidecar thumbnails dir is a temp dir (Catalog derives it from the db path).
        let dbURL = try tempDir().appendingPathComponent("catalog.sqlite")
        let catalog = try Catalog(databaseURL: dbURL)
        let mtime = Date(timeIntervalSince1970: 1_000_000)

        // Miss before store.
        let before = try await catalog.thumbnails.thumbnailURL(volumeKey: "A", relPath: "x.jpg")
        XCTAssertNil(before)

        try await catalog.thumbnails.store(Data(repeating: 0x9, count: 128),
                                           volumeKey: "A", relPath: "x.jpg", srcModifiedAt: mtime, srcSize: 999)

        // Hit after store, sidecar file exists.
        let url = try await catalog.thumbnails.thumbnailURL(volumeKey: "A", relPath: "x.jpg")
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))

        // Fresh for same mtime/size; stale when mtime changes.
        let fresh = try await catalog.thumbnails.isFresh(volumeKey: "A", relPath: "x.jpg", srcModifiedAt: mtime, srcSize: 999)
        XCTAssertTrue(fresh)
        let stale = try await catalog.thumbnails.isFresh(volumeKey: "A", relPath: "x.jpg",
                                                         srcModifiedAt: Date(timeIntervalSince1970: 2_000_000), srcSize: 999)
        XCTAssertFalse(stale)

        // Clear wipes it.
        try await catalog.thumbnails.clear()
        let afterClear = try await catalog.thumbnails.thumbnailURL(volumeKey: "A", relPath: "x.jpg")
        XCTAssertNil(afterClear)
    }

    func testEntriesNeedingPreviewScopesToSubtree() async throws {
        let catalog = try Fixture.makeCatalog()
        try await catalog.database.writer.write { db in
            var vol = Volume(uuid: "UUID-S", name: "S", createdAt: Date())
            try vol.insert(db)
            var snap = Snapshot(volumeId: vol.id!, scannedAt: Date(),
                                totalCapacity: 1000, freeCapacity: 500, isComplete: true)
            try snap.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id),0) FROM entry") ?? 0) + 1
            for rel in ["Trips/2024_trip/a.jpg", "Trips/2024_trip/sub/b.jpg",
                        "Trips/2024Xtrip/c.jpg", "Other/d.jpg"] {
                try Entry(id: nextId, snapshotId: snap.id!, parentId: nil,
                          name: (rel as NSString).lastPathComponent, relPath: rel,
                          isDir: false, logicalSize: 10, allocSize: 10, ext: "jpg").insert(db)
                nextId += 1
            }
        }
        let volId = try await catalog.database.writer.read { try Int64.fetchOne($0, sql: "SELECT id FROM volume")! }

        let scoped = try await catalog.thumbnails.entriesNeedingPreview(
            volumeId: volId, categories: [.photos], underRelPath: "Trips/2024_trip")
        XCTAssertEqual(Set(scoped.map(\.relPath)), ["Trips/2024_trip/a.jpg", "Trips/2024_trip/sub/b.jpg"])
        // The "_" in the folder name must be treated literally, not as a LIKE wildcard,
        // so the sibling "2024Xtrip" is NOT matched.
        XCTAssertFalse(scoped.contains { $0.relPath.contains("2024Xtrip") })

        let all = try await catalog.thumbnails.entriesNeedingPreview(volumeId: volId, categories: [.photos])
        XCTAssertEqual(all.count, 4)
    }
}
