import XCTest
@testable import DiskGalleryCore

final class RevealTargetTests: XCTestCase {
    func testResolvesExistingFileURL() throws {
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = RevealTarget.url(mountURL: root, relPath: "a.txt")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "a.txt")
    }

    func testReturnsNilWhenFileMissing() throws {
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertNil(RevealTarget.url(mountURL: root, relPath: "does/not/exist.txt"))
    }

    func testReturnsNilWhenMountIsNil() {
        XCTAssertNil(RevealTarget.url(mountURL: nil, relPath: "a.txt"))
    }

    func testHandlesNestedRelPath() throws {
        let root = try Fixture.makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let url = RevealTarget.url(mountURL: root, relPath: "sub/c.txt")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "c.txt")
    }
}
