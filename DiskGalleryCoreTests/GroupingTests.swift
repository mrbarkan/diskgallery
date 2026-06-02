import XCTest
import GRDB
@testable import DiskGalleryCore

/// Volume identity on a real scan resolves to the host volume, so to model several
/// distinct drives we seed synthetic volumes directly (same approach as the duplicate tests).
final class GroupingTests: XCTestCase {

    @discardableResult
    private func seedVolume(_ catalog: Catalog, name: String, sortIndex: Int,
                            groupId: Int64? = nil, hardware: DriveHardware? = nil) async throws -> Int64 {
        try await catalog.database.writer.write { db in
            var v = Volume(uuid: "uuid-\(name)", name: name, createdAt: Date(),
                           groupId: groupId, sortIndex: sortIndex, hardware: hardware)
            try v.insert(db)
            return v.id!
        }
    }

    private func names(_ catalog: Catalog) async throws -> [String] {
        try await catalog.library.volumes().map(\.name)
    }

    // MARK: Ordering

    func testVolumesOrderByGroupThenSortIndexUngroupedLast() async throws {
        let catalog = try Fixture.makeCatalog()
        let g1 = try await catalog.library.createGroup(name: "First")
        let g2 = try await catalog.library.createGroup(name: "Second")

        try await seedVolume(catalog, name: "Zeta", sortIndex: 0)                       // ungrouped
        try await seedVolume(catalog, name: "Alpha", sortIndex: 1, groupId: g1.id)
        try await seedVolume(catalog, name: "Beta", sortIndex: 0, groupId: g1.id)
        try await seedVolume(catalog, name: "Gamma", sortIndex: 0, groupId: g2.id)

        // G1 (by sortIndex: Beta, Alpha) → G2 (Gamma) → ungrouped (Zeta).
        let order = try await names(catalog)
        XCTAssertEqual(order, ["Beta", "Alpha", "Gamma", "Zeta"])
    }

    func testReorderDrivesMovesAcrossGroupsAndReindexes() async throws {
        let catalog = try Fixture.makeCatalog()
        let g1 = try await catalog.library.createGroup(name: "Group")
        let zeta = try await seedVolume(catalog, name: "Zeta", sortIndex: 0)
        let beta = try await seedVolume(catalog, name: "Beta", sortIndex: 1)

        // Move both ungrouped drives into the group, Zeta before Beta.
        try await catalog.library.reorderDrives(orderedVolumeIds: [zeta, beta], inGroup: g1.id)

        let summaries = try await catalog.library.volumes()
        XCTAssertEqual(summaries.map(\.name), ["Zeta", "Beta"])
        XCTAssertTrue(summaries.allSatisfy { $0.groupId == g1.id })
        XCTAssertEqual(summaries.first { $0.name == "Zeta" }?.sortIndex, 0)
        XCTAssertEqual(summaries.first { $0.name == "Beta" }?.sortIndex, 1)
    }

    func testReorderGroupsChangesSectionOrder() async throws {
        let catalog = try Fixture.makeCatalog()
        let g1 = try await catalog.library.createGroup(name: "First")
        let g2 = try await catalog.library.createGroup(name: "Second")
        try await seedVolume(catalog, name: "A", sortIndex: 0, groupId: g1.id)
        try await seedVolume(catalog, name: "B", sortIndex: 0, groupId: g2.id)

        try await catalog.library.reorderGroups(orderedIds: [g2.id!, g1.id!])
        let order = try await names(catalog)
        XCTAssertEqual(order, ["B", "A"])
    }

    // MARK: Group lifecycle

    func testDeleteGroupOrphansDrivesToEndOfUngrouped() async throws {
        let catalog = try Fixture.makeCatalog()
        let g1 = try await catalog.library.createGroup(name: "Doomed")
        try await seedVolume(catalog, name: "Ungrouped", sortIndex: 0)              // already ungrouped
        try await seedVolume(catalog, name: "Member1", sortIndex: 0, groupId: g1.id)
        try await seedVolume(catalog, name: "Member2", sortIndex: 1, groupId: g1.id)

        try await catalog.library.deleteGroup(id: g1.id!)

        let summaries = try await catalog.library.volumes()
        let remainingGroups = try await catalog.library.groups()
        XCTAssertTrue(remainingGroups.isEmpty)
        XCTAssertTrue(summaries.allSatisfy { $0.groupId == nil })
        // Orphaned members land after the pre-existing ungrouped drive, keeping their order.
        XCTAssertEqual(summaries.map(\.name), ["Ungrouped", "Member1", "Member2"])
        XCTAssertEqual(Set(summaries.map(\.sortIndex)), [0, 1, 2])
    }

    func testRenameAndCollapsePersist() async throws {
        let catalog = try Fixture.makeCatalog()
        let g = try await catalog.library.createGroup(name: "Old")
        try await catalog.library.renameGroup(id: g.id!, name: "New")
        try await catalog.library.setGroupCollapsed(id: g.id!, collapsed: true)

        let groups = try await catalog.library.groups()
        let reloaded = try XCTUnwrap(groups.first)
        XCTAssertEqual(reloaded.name, "New")
        XCTAssertTrue(reloaded.isCollapsed)
    }

    // MARK: Hardware persistence

    func testHardwareRoundTripsThroughJSONColumn() async throws {
        let catalog = try Fixture.makeCatalog()
        // 1_700_000_000s since 1970 is an exact Double since the reference date → clean round trip.
        let hw = DriveHardware(bus: .usb, isInternal: false, medium: .ssd,
                               vendor: "ACME", model: "Rocket X1", linkSpeedMbps: 10000,
                               capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let id = try await seedVolume(catalog, name: "Drive", sortIndex: 0, hardware: hw)

        let fetched = try await catalog.library.volume(id: id)
        let summary = try XCTUnwrap(fetched)
        XCTAssertEqual(summary.hardware, hw)
    }

    func testUpdateHardwareOnlyTouchesHardware() async throws {
        let catalog = try Fixture.makeCatalog()
        let g = try await catalog.library.createGroup(name: "Keep me")
        let id = try await seedVolume(catalog, name: "Drive", sortIndex: 3, groupId: g.id)

        let hw = DriveHardware(bus: .thunderbolt, medium: .ssd,
                               capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await catalog.library.updateHardware(volumeId: id, hardware: hw)

        let fetched = try await catalog.library.volume(id: id)
        let summary = try XCTUnwrap(fetched)
        XCTAssertEqual(summary.hardware, hw)
        XCTAssertEqual(summary.groupId, g.id)   // group/order untouched
        XCTAssertEqual(summary.sortIndex, 3)
    }
}
