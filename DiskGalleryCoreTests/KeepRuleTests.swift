import XCTest
@testable import DiskGalleryCore

final class KeepRuleTests: XCTestCase {

    private func member(_ id: Int64, vol: String, modified: Date?) -> DuplicateMember {
        DuplicateMember(entryId: id, snapshotId: 1, relPath: "f.raw", contentHash: nil,
                        modifiedAt: modified, volumeId: id, volumeUuid: vol, volumeName: vol)
    }

    func testNewestKeepsLatestModified() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 9_000)
        let members = [member(1, vol: "A", modified: old), member(2, vol: "B", modified: new)]
        XCTAssertEqual(keptMemberID(members: members, rule: .newest, capacities: [:]), 2)
    }

    func testNewestTreatsNilDateAsOldest() {
        let some = Date(timeIntervalSince1970: 5_000)
        let members = [member(1, vol: "A", modified: nil), member(2, vol: "B", modified: some)]
        XCTAssertEqual(keptMemberID(members: members, rule: .newest, capacities: [:]), 2)
    }

    func testLargestDriveKeepsBiggestCapacity() {
        let members = [member(1, vol: "Small", modified: nil), member(2, vol: "Big", modified: nil)]
        let caps: [String: Int64] = ["Small": 500, "Big": 2_000]
        XCTAssertEqual(keptMemberID(members: members, rule: .largestDrive, capacities: caps), 2)
    }

    func testFastestDriveFallsBackToLargestDrive() {
        let members = [member(1, vol: "Small", modified: nil), member(2, vol: "Big", modified: nil)]
        let caps: [String: Int64] = ["Small": 500, "Big": 2_000]
        XCTAssertEqual(keptMemberID(members: members, rule: .fastestDrive, capacities: caps), 2)
    }

    func testStableTieBreakKeepsFirst() {
        let members = [member(1, vol: "A", modified: nil), member(2, vol: "B", modified: nil)]
        XCTAssertEqual(keptMemberID(members: members, rule: .largestDrive,
                                    capacities: ["A": 100, "B": 100]), 1)
    }

    func testEmptyMembersReturnsNil() {
        XCTAssertNil(keptMemberID(members: [], rule: .newest, capacities: [:]))
    }
}
