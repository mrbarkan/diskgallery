import XCTest
@testable import DiskGalleryCore

final class PathVisibilityTests: XCTestCase {
    func testPlainFileIsVisible() {
        XCTAssertFalse(PathVisibility.isHidden(relPath: "Photos/IMG_0001.jpg"))
    }

    func testDotfileIsHidden() {
        XCTAssertTrue(PathVisibility.isHidden(relPath: ".DS_Store"))
    }

    func testFileInsideHiddenFolderIsHidden() {
        XCTAssertTrue(PathVisibility.isHidden(relPath: ".Trashes/old.jpg"))
        XCTAssertTrue(PathVisibility.isHidden(relPath: "Docs/.git/config"))
    }

    func testEmptyPathIsVisible() {
        XCTAssertFalse(PathVisibility.isHidden(relPath: ""))
    }

    func testLeadingSlashHandled() {
        XCTAssertTrue(PathVisibility.isHidden(relPath: "/.config/x"))
        XCTAssertFalse(PathVisibility.isHidden(relPath: "/Movies/clip.mov"))
    }
}
