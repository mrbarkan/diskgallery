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
}
