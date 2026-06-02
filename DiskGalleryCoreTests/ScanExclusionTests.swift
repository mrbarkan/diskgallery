import XCTest
@testable import DiskGalleryCore

final class ScanExclusionTests: XCTestCase {
    func testSystemVolumesExcludedOnBootVolume() {
        XCTAssertTrue(ScanExclusion.isExcluded(relPath: "System/Volumes", isBootVolume: true))
    }

    func testSystemVolumesNotExcludedOffBootVolume() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "System/Volumes", isBootVolume: false))
    }

    func testSystemFolderItselfIsKept() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "System", isBootVolume: true))
    }

    func testDescendantOfExcludedNodeIsNotMatched() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "System/Volumes/Data/x", isBootVolume: true))
    }

    func testNonRootNodeOfSameNameIsKept() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "Users/me/System/Volumes", isBootVolume: true))
    }

    func testOrdinaryUserPathIsKept() {
        XCTAssertFalse(ScanExclusion.isExcluded(relPath: "Users/me/Photos/IMG.jpg", isBootVolume: true))
    }
}
