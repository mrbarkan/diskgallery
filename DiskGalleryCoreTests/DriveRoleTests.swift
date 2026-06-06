import XCTest
@testable import DiskGalleryCore

final class DriveRoleTests: XCTestCase {

    func testCasesAndDefaultLabels() {
        XCTAssertEqual(DriveRole.allCases.count, 7)
        XCTAssertEqual(DriveRole.localSystem.defaultLabel, "Local / System")
        XCTAssertEqual(DriveRole.main.defaultLabel, "Main")
        XCTAssertEqual(DriveRole.work.defaultLabel, "Work / Scratch")
        XCTAssertEqual(DriveRole.mainBackup.defaultLabel, "Main Backup")
        XCTAssertEqual(DriveRole.fallbackBackup.defaultLabel, "Fallback Backup")
        XCTAssertEqual(DriveRole.archive.defaultLabel, "Archive / Cold")
        XCTAssertEqual(DriveRole.neutral.defaultLabel, "Neutral")
    }

    func testLocalSystemIsNeverADestination() {
        XCTAssertTrue(DriveRole.localSystem.neverDestination)
        XCTAssertFalse(DriveRole.localSystem.canReceive(.backup))
        XCTAssertFalse(DriveRole.localSystem.canReceive(.move))
    }

    func testBackupGoesToBackupRolesNotWork() {
        XCTAssertTrue(DriveRole.mainBackup.canReceive(.backup))
        XCTAssertTrue(DriveRole.fallbackBackup.canReceive(.backup))
        XCTAssertFalse(DriveRole.work.canReceive(.backup))
    }

    func testMoveNeverOntoBackupDrive() {
        XCTAssertFalse(DriveRole.mainBackup.canReceive(.move))
        XCTAssertFalse(DriveRole.fallbackBackup.canReceive(.move))
        XCTAssertTrue(DriveRole.archive.canReceive(.move))
        XCTAssertTrue(DriveRole.work.canReceive(.move))
        XCTAssertTrue(DriveRole.main.canReceive(.move))
    }

    func testNeutralIsAlwaysAnEligibleFallback() {
        XCTAssertTrue(DriveRole.neutral.canReceive(.backup))
        XCTAssertTrue(DriveRole.neutral.canReceive(.move))
    }

    func testRoleRankOrdering() {
        XCTAssertGreaterThan(DriveRole.mainBackup.rank(for: .backup),
                             DriveRole.fallbackBackup.rank(for: .backup))
        XCTAssertGreaterThan(DriveRole.fallbackBackup.rank(for: .backup),
                             DriveRole.neutral.rank(for: .backup))
        XCTAssertGreaterThan(DriveRole.archive.rank(for: .move),
                             DriveRole.main.rank(for: .move))
        XCTAssertGreaterThan(DriveRole.main.rank(for: .move),
                             DriveRole.work.rank(for: .move))
    }
}
