import XCTest
@testable import DiskGalleryCore

final class FinderTagTests: XCTestCase {

    func testWriteReadRoundTrip() throws {
        let root = try Fixture.makeTree()
        let file = root.appendingPathComponent("a.txt")
        let writer = FinderTagWriter()

        try writer.apply(decision: .keep, color: .red, to: file)

        let tags = writer.read(file)
        XCTAssertTrue(tags.contains(FinderTag(name: "Keep", colorCode: 2)))  // Keep -> green(2)
        XCTAssertTrue(tags.contains(FinderTag(name: "Red", colorCode: 6)))
    }

    func testApplyReplacesManagedTagsButPreservesUserTags() throws {
        let root = try Fixture.makeTree()
        let file = root.appendingPathComponent("b.txt")
        let writer = FinderTagWriter()

        // A tag DiskGallery doesn't manage.
        try writer.write([FinderTag(name: "Important", colorCode: 0)], to: file)

        try writer.apply(decision: .delete, color: .none, to: file)
        var names = Set(writer.read(file).map(\.name))
        XCTAssertTrue(names.contains("Important"))
        XCTAssertTrue(names.contains("Delete"))

        // Re-applying swaps the managed decision but leaves the user's tag.
        try writer.apply(decision: .keep, color: .blue, to: file)
        names = Set(writer.read(file).map(\.name))
        XCTAssertTrue(names.contains("Important"))
        XCTAssertTrue(names.contains("Keep"))
        XCTAssertFalse(names.contains("Delete"))
        XCTAssertTrue(names.contains("Blue"))
    }

    func testMoveAndBackupTagsRoundTrip() throws {
        let root = try Fixture.makeTree()
        let file = root.appendingPathComponent("a.txt")
        let writer = FinderTagWriter()

        try writer.apply(decision: .move, color: .none, to: file)
        XCTAssertTrue(writer.read(file).contains(FinderTag(name: "Move", colorCode: 4)))   // Move -> blue(4)

        // Swapping to Backup replaces the managed decision (purple), not other tags.
        try writer.apply(decision: .backup, color: .none, to: file)
        let names = Set(writer.read(file).map(\.name))
        XCTAssertTrue(writer.read(file).contains(FinderTag(name: "Backup", colorCode: 3))) // Backup -> purple(3)
        XCTAssertFalse(names.contains("Move"))
    }

    func testClearRemovesManagedTags() throws {
        let root = try Fixture.makeTree()
        let file = root.appendingPathComponent("a.txt")
        let writer = FinderTagWriter()

        try writer.apply(decision: .review, color: .orange, to: file)
        XCTAssertFalse(writer.read(file).isEmpty)

        try writer.apply(decision: .none, color: .none, to: file)
        XCTAssertTrue(writer.read(file).isEmpty)
    }
}
