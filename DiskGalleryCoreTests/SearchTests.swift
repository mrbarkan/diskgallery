import XCTest
@testable import DiskGalleryCore

final class SearchTests: XCTestCase {

    func testNameSearchMatchesFiles() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let txt = try await catalog.search.search("txt")
        XCTAssertEqual(Set(txt.map(\.relPath)), ["a.txt", "b.txt", "sub/c.txt", "sub/a.txt"])
    }

    func testPrefixSearch() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        // "a" should prefix-match the two a.txt files (token "a"), not b/c.
        let a = try await catalog.search.search("a")
        XCTAssertEqual(Set(a.map(\.relPath)), ["a.txt", "sub/a.txt"])
    }

    func testFolderNameSearch() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let results = try await catalog.search.search("sub")
        XCTAssertTrue(results.contains { $0.relPath == "sub" && $0.isDir })
    }

    func testEmptyAndNoMatchQueries() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let empty = try await catalog.search.search("   ")
        XCTAssertEqual(empty.count, 0)

        let none = try await catalog.search.search("zzqqxnotpresent")
        XCTAssertEqual(none.count, 0)
    }

    func testScopedSearchToVolumeLatest() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)

        let scoped = try await catalog.search.search("txt", scope: .volumeLatest(volume.id))
        XCTAssertEqual(scoped.count, 4)
    }

    func testDuplicatesOnlyFilterWithQuery() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let dups = try await catalog.search.search("txt", filter: .duplicatesOnly)
        XCTAssertEqual(Set(dups.map(\.relPath)), ["a.txt", "sub/a.txt"])
    }

    func testTaggedFilterStandalone() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)
        try await catalog.annotations.setDecision(.delete, volumeKey: key, relPath: "b.txt")

        let tagged = try await catalog.search.search("", filter: .tagged(.delete))
        XCTAssertEqual(tagged.map(\.relPath), ["b.txt"])
    }

    func testCategoryFilterWithQuery() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        try Fixture.writeFile(root, "holiday.jpg", bytes: 10)
        _ = try await Fixture.scan(catalog, root)

        let photos = try await catalog.search.search("h", filter: .category(.photos))
        XCTAssertTrue(photos.contains { $0.relPath == "holiday.jpg" })
        let raw = try await catalog.search.search("h", filter: .category(.raw))
        XCTAssertFalse(raw.contains { $0.relPath == "holiday.jpg" })
    }

    func testEmptyQueryNoFilterStillReturnsNothing() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let none = try await catalog.search.search("", filter: .none)
        XCTAssertEqual(none.count, 0)
    }
}
