import XCTest
@testable import DiskGalleryCore

final class VolumeFilterTests: XCTestCase {
    func testExternalUSBDriveIsListed() {
        XCTAssertTrue(VolumeFilter.shouldList(isLocal: true, isRemovable: true, isInternal: false))
    }

    func testExternalNonRemovableLocalDriveIsListed() {
        XCTAssertTrue(VolumeFilter.shouldList(isLocal: true, isRemovable: false, isInternal: false))
    }

    func testNetworkDriveIsExcluded() {
        XCTAssertFalse(VolumeFilter.shouldList(isLocal: false, isRemovable: false, isInternal: false))
    }

    func testInternalBootDiskIsExcluded() {
        XCTAssertFalse(VolumeFilter.shouldList(isLocal: true, isRemovable: false, isInternal: true))
    }

    func testRemovableInternalIsListed() {
        XCTAssertTrue(VolumeFilter.shouldList(isLocal: true, isRemovable: true, isInternal: true))
    }
}
