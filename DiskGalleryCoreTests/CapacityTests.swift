import XCTest
@testable import DiskGalleryCore

final class CapacityTests: XCTestCase {

    func testFractionUsedHalfFull() {
        XCTAssertEqual(Capacity.fractionUsed(total: 100, free: 50), 0.5, accuracy: 0.0001)
    }

    func testFractionUsedClampsAndHandlesUnknown() {
        XCTAssertEqual(Capacity.fractionUsed(total: nil, free: 10), 0)
        XCTAssertEqual(Capacity.fractionUsed(total: 0, free: 0), 0)
        // free > total would imply negative used → clamps to full.
        XCTAssertEqual(Capacity.fractionUsed(total: 100, free: -20), 1, accuracy: 0.0001)
    }

    func testOverCapacityThreshold() {
        XCTAssertFalse(Capacity.isOverCapacity(total: 100, free: 10)) // 90%
        XCTAssertTrue(Capacity.isOverCapacity(total: 100, free: 5))   // 95%
        XCTAssertTrue(Capacity.isOverCapacity(total: 100, free: 0))   // 100%
        XCTAssertFalse(Capacity.isOverCapacity(total: nil, free: nil))
    }

    func testUsedBytes() {
        XCTAssertEqual(Capacity.usedBytes(total: 100, free: 30, logicalFallback: nil), 70)
        XCTAssertEqual(Capacity.usedBytes(total: nil, free: nil, logicalFallback: 40), 40)
        XCTAssertEqual(Capacity.usedBytes(total: 100, free: 150, logicalFallback: nil), 0) // clamps
    }

    func testFreeBytes() {
        XCTAssertEqual(Capacity.freeBytes(total: 100, free: 30, logicalFallback: nil), 30)
        XCTAssertEqual(Capacity.freeBytes(total: 100, free: nil, logicalFallback: 40), 60)
        XCTAssertEqual(Capacity.freeBytes(total: nil, free: nil, logicalFallback: nil), 0)
    }
}
