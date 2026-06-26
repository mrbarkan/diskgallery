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
}
