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
        try await catalog.annotations.set(tag: .delete, color: .none, note: "redundant copy",
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

        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "sub/c.txt")
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

        try await catalog.annotations.set(tag: .keep, color: .none, note: "x", volumeKey: key, relPath: "b.txt")
        let afterSet = try await catalog.annotations.annotation(volumeKey: key, relPath: "b.txt")
        XCTAssertNotNil(afterSet)

        try await catalog.annotations.set(tag: .none, color: .none, note: nil, volumeKey: key, relPath: "b.txt")
        let afterClear = try await catalog.annotations.annotation(volumeKey: key, relPath: "b.txt")
        XCTAssertNil(afterClear)
    }

    func testCountsByTag() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let key = try await volumeKey(catalog)

        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "b.txt")
        try await catalog.annotations.setDecision(.keep, volumeKey: key, relPath: "sub/c.txt")

        let counts = try await catalog.annotations.counts()
        XCTAssertEqual(counts[.delete], 2)
        XCTAssertEqual(counts[.keep], 1)
    }

    func testDecisionAndColorAreIndependent() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let key = try await volumeKey(catalog)

        try await catalog.annotations.setDecision(.keep, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.setColor(.blue, volumeKey: key, relPath: "a.txt")

        let ann = try await catalog.annotations.annotation(volumeKey: key, relPath: "a.txt")
        XCTAssertEqual(ann?.tag, .keep)      // decision preserved when setting color
        XCTAssertEqual(ann?.color, .blue)

        // Clearing only the decision keeps the color -> row remains.
        try await catalog.annotations.setDecision(.none, volumeKey: key, relPath: "a.txt")
        let ann2 = try await catalog.annotations.annotation(volumeKey: key, relPath: "a.txt")
        XCTAssertEqual(ann2?.tag, Tag.none)
        XCTAssertEqual(ann2?.color, FinderColor.blue)

        // Clearing the color too removes the row.
        try await catalog.annotations.setColor(.none, volumeKey: key, relPath: "a.txt")
        let ann3 = try await catalog.annotations.annotation(volumeKey: key, relPath: "a.txt")
        XCTAssertNil(ann3)
    }
}
