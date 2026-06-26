import XCTest
import GRDB
@testable import DiskGalleryCore

final class GalleryTests: XCTestCase {
    /// Seeds a synthetic volume + complete snapshot + entries (mirrors ExecutionTests.seedVolume),
    /// with an explicit `ext` so the gallery's category filter can match.
    private func seedVolume(_ catalog: Catalog, uuid: String, name: String,
                            files: [(name: String, ext: String?, size: Int64, isDir: Bool)]) async throws {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: uuid, name: name, createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 500_000, isComplete: true)
            try snapshot.insert(db)
            var nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            for f in files {
                try Entry(id: nextId, snapshotId: snapshot.id!, parentId: nil, name: f.name,
                          relPath: f.name, isDir: f.isDir, logicalSize: f.size, allocSize: f.size,
                          ext: f.ext).insert(db)
                nextId += 1
            }
        }
    }

    func testGalleryItemsFlattenMediaAcrossDrivesWithProvenance() async throws {
        let catalog = try Fixture.makeCatalog()
        try await seedVolume(catalog, uuid: "UUID-A", name: "Alpha", files: [
            ("a.jpg", "jpg", 100, false),
            ("clip.mov", "mov", 200, false),
            ("notes.txt", "txt", 50, false),
            ("folder", nil, 0, true),            // excluded: directory
            ("archive.zip", "zip", 999, false),  // excluded: not a media category
        ])
        try await seedVolume(catalog, uuid: "UUID-B", name: "Bravo", files: [
            ("b.png", "png", 300, false),
        ])

        // Photos only → a.jpg (Alpha) + b.png (Bravo), with provenance.
        let photos = try await catalog.gallery.items(categories: [.photos])
        XCTAssertEqual(photos.map(\.relPath).sorted(), ["a.jpg", "b.png"])
        let alpha = photos.first { $0.relPath == "a.jpg" }
        XCTAssertEqual(alpha?.volumeName, "Alpha")
        XCTAssertEqual(alpha?.volumeKey, "UUID-A")
        XCTAssertEqual(alpha?.ext, "jpg")
        XCTAssertEqual(alpha?.logicalSize, 100)

        // Photos + video + documents → 4 files; zip + folder excluded.
        let media = try await catalog.gallery.items(categories: [.photos, .video, .documents])
        XCTAssertEqual(Set(media.map(\.relPath)), ["a.jpg", "clip.mov", "notes.txt", "b.png"])
        XCTAssertFalse(media.contains { $0.relPath == "archive.zip" })
        XCTAssertFalse(media.contains { $0.isDirNamePlaceholder })   // see note below

        // `.all` owns no extensions → empty.
        let none = try await catalog.gallery.items(categories: [.all])
        XCTAssertTrue(none.isEmpty)
    }
}

private extension GalleryEntry {
    // Folders are excluded by the query; this guards that none leaked in by name.
    var isDirNamePlaceholder: Bool { name == "folder" }
}
