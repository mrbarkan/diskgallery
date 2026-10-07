import XCTest
@testable import DiskGalleryCore

final class JunkFilesTests: XCTestCase {
    func testFinderMetadataIsJunk() {
        XCTAssertTrue(JunkFiles.isJunk(relPath: ".DS_Store"))
        XCTAssertTrue(JunkFiles.isJunk(relPath: "Photos/.DS_Store"))
        XCTAssertTrue(JunkFiles.isJunk(relPath: "Photos/Thumbs.db"))
        XCTAssertTrue(JunkFiles.isJunk(relPath: "desktop.ini"))
    }

    func testAppleDoubleFilesAreJunk() {
        XCTAssertTrue(JunkFiles.isJunk(relPath: "Photos/._IMG_0001.jpg"))
    }

    func testAnythingInsideAJunkFolderIsJunk() {
        XCTAssertTrue(JunkFiles.isJunk(relPath: ".Spotlight-V100/Store-V2/store.db"))
        XCTAssertTrue(JunkFiles.isJunk(relPath: "Backup/.Trashes/501/old.jpg"))
        XCTAssertTrue(JunkFiles.isJunk(relPath: ".fseventsd/0000"))
    }

    func testOrdinaryFilesAndDotfilesAreNotJunk() {
        XCTAssertFalse(JunkFiles.isJunk(relPath: "Photos/IMG_0001.jpg"))
        XCTAssertFalse(JunkFiles.isJunk(relPath: "Code/.git/config"))
        XCTAssertFalse(JunkFiles.isJunk(relPath: "Code/.gitignore"))
        XCTAssertFalse(JunkFiles.isJunk(relPath: ""))
    }
}

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
