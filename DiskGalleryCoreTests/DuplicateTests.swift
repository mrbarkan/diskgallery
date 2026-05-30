import XCTest
@testable import DiskGalleryCore

final class DuplicateTests: XCTestCase {

    func testNameAndSizeDuplicateDetection() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let sets = try await catalog.duplicates.duplicateSets()
        XCTAssertEqual(sets.count, 1)
        let set = try XCTUnwrap(sets.first)
        XCTAssertEqual(set.name, "a.txt")
        XCTAssertEqual(set.logicalSize, 100)
        XCTAssertEqual(set.copies, 2)
        XCTAssertEqual(set.reclaimable, 100)

        let total = try await catalog.duplicates.totalReclaimable()
        XCTAssertEqual(total, 100)
    }

    func testDuplicateMembersResolveToFiles() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let members = try await catalog.duplicates.members(name: "a.txt", logicalSize: 100)
        XCTAssertEqual(members.count, 2)
        XCTAssertEqual(Set(members.map(\.relPath)), ["a.txt", "sub/a.txt"])
    }

    func testHashVerifierAgreesForIdenticalContentAndDiffersOtherwise() throws {
        let root = try Fixture.makeTree()
        let hasher = HashVerifier()

        let h1 = try hasher.sha256(fileURL: root.appendingPathComponent("a.txt"))
        let h2 = try hasher.sha256(fileURL: root.appendingPathComponent("sub/a.txt"))
        let hb = try hasher.sha256(fileURL: root.appendingPathComponent("b.txt"))

        XCTAssertEqual(h1, h2, "Identical bytes must hash equally")
        XCTAssertNotEqual(h1, hb)
        XCTAssertEqual(h1.count, 64) // SHA-256 hex
    }

    func testRecordHashPersists() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)

        let members = try await catalog.duplicates.members(name: "a.txt", logicalSize: 100)
        let first = try XCTUnwrap(members.first)
        try await catalog.duplicates.recordHash(entryId: first.entryId, hash: "deadbeef")

        let stored = try await catalog.library.entry(id: first.entryId)
        XCTAssertEqual(stored?.contentHash, "deadbeef")
    }
}
