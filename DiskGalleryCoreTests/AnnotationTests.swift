import XCTest
@testable import DiskGalleryCore

final class AnnotationTests: XCTestCase {

    private func volumeKey(_ catalog: Catalog) async throws -> String {
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        return AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)
    }

    func testAnnotationSurvivesRescan() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let key = try await volumeKey(catalog)
        try await catalog.annotations.set(tag: .delete, note: "redundant copy",
                                          volumeKey: key, relPath: "a.txt")

        // Re-scan the same drive -> brand new snapshot + entry rows.
        _ = try await Fixture.scan(catalog, root)

        let annotation = try await catalog.annotations.annotation(volumeKey: key, relPath: "a.txt")
        XCTAssertEqual(annotation?.tag, .delete)
        XCTAssertEqual(annotation?.note, "redundant copy")
    }

    func testTaggedEntriesResolveAgainstLatestSnapshot() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let key = try await volumeKey(catalog)

        try await catalog.annotations.set(tag: .delete, note: nil, volumeKey: key, relPath: "sub/c.txt")
        _ = try await Fixture.scan(catalog, root)  // re-scan

        let tagged = try await catalog.annotations.taggedEntries(.delete)
        XCTAssertEqual(tagged.count, 1)
        let entry = try XCTUnwrap(tagged.first)
        XCTAssertEqual(entry.relPath, "sub/c.txt")
        XCTAssertEqual(entry.displayName, "c.txt")
        XCTAssertEqual(entry.logicalSize, 50)        // resolved to current entry
        XCTAssertNotNil(entry.entryId)
    }

    func testClearingAnnotationDeletesIt() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let key = try await volumeKey(catalog)

        try await catalog.annotations.set(tag: .keep, note: "x", volumeKey: key, relPath: "b.txt")
        let afterSet = try await catalog.annotations.annotation(volumeKey: key, relPath: "b.txt")
        XCTAssertNotNil(afterSet)

        try await catalog.annotations.set(tag: .none, note: nil, volumeKey: key, relPath: "b.txt")
        let afterClear = try await catalog.annotations.annotation(volumeKey: key, relPath: "b.txt")
        XCTAssertNil(afterClear)
    }

    func testCountsByTag() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let key = try await volumeKey(catalog)

        try await catalog.annotations.set(tag: .delete, note: nil, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.set(tag: .delete, note: nil, volumeKey: key, relPath: "b.txt")
        try await catalog.annotations.set(tag: .keep, note: nil, volumeKey: key, relPath: "sub/c.txt")

        let counts = try await catalog.annotations.counts()
        XCTAssertEqual(counts[.delete], 2)
        XCTAssertEqual(counts[.keep], 1)
    }
}
