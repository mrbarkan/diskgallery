import XCTest
@testable import DiskGalleryCore

final class AnnotationListTests: XCTestCase {

    func testAllReturnsEveryAnnotationIncludingColorOnly() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.setColor(.red, volumeKey: key, relPath: "b.txt")

        let all = try await catalog.annotations.all()
        XCTAssertEqual(all.count, 2)
        let byPath: [String: Annotation] = Dictionary(uniqueKeysWithValues: all.map { ($0.relPath, $0) })
        XCTAssertEqual(byPath["a.txt"]?.tag, .delete)
        XCTAssertEqual(byPath["b.txt"]?.color, .red)
        XCTAssertEqual(byPath["b.txt"]?.tag, Tag.none)
    }

    func testTaggedEntriesInReturnsOnlyRequestedTags() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "a.txt")
        try await catalog.annotations.setDecision(.move, volumeKey: key, relPath: "b.txt")
        try await catalog.annotations.setDecision(.keep, volumeKey: key, relPath: "sub/c.txt")

        let deleteAndMove = try await catalog.annotations.taggedEntries(in: [.delete, .move])
        XCTAssertEqual(Set(deleteAndMove.map(\.relPath)), ["a.txt", "b.txt"])

        let keepOnly = try await catalog.annotations.taggedEntries(in: [.keep])
        XCTAssertEqual(keepOnly.map(\.relPath), ["sub/c.txt"])

        let empty = try await catalog.annotations.taggedEntries(in: [])
        XCTAssertTrue(empty.isEmpty)
    }
}
