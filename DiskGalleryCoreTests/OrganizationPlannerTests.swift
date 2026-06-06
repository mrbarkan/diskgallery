import XCTest
@testable import DiskGalleryCore

final class OrganizationPlannerTests: XCTestCase {

    // MARK: Builders

    private func drive(_ id: Int64, _ name: String, total: Int64?, free: Int64?,
                       connected: Bool = true, medium: DriveHardware.Medium? = nil,
                       speed: Int? = nil, bus: DriveHardware.Bus = .usb,
                       role: DriveRole = .neutral, priority: Int = 0) -> PlanDrive {
        let hw = DriveHardware(bus: bus, medium: medium, linkSpeedMbps: speed,
                               capturedAt: Date(timeIntervalSince1970: 0))
        return PlanDrive(id: id, key: name, name: name, totalCapacity: total, freeCapacity: free,
                         isConnected: connected, hardware: hw, role: role, priority: priority)
    }

    private func item(_ vol: String, _ rel: String, _ tag: Tag, _ size: Int64) -> PlanItemSource {
        PlanItemSource(volumeKey: vol, volumeName: vol, relPath: rel,
                       name: (rel as NSString).lastPathComponent, isDir: false, tag: tag, sizeBytes: size)
    }

    private func step(_ plan: OrganizationPlan, _ id: String) -> PlanStep? {
        plan.steps.first { $0.id == id }
    }

    // MARK: Assignment

    func testMoveAssignedToCandidateWithRoom() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 900)]
        let it = item("A", "big", .move, 300)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        let s = step(plan, it.id)
        XCTAssertEqual(s?.operation, .move)
        XCTAssertEqual(s?.destinationDriveKey, "B")
        XCTAssertEqual(s?.feasibility, .ok)
        XCTAssertTrue(plan.isFeasible)
    }

    func testNeverAssignsToSourceEvenWhenSourceHasMostRoom() {
        // A (source) has tons of room; B is the only valid destination.
        let drives = [drive(1, "A", total: 1000, free: 990),
                      drive(2, "B", total: 1000, free: 800)]
        let it = item("A", "f", .move, 50)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "B")
    }

    func testRespectsThresholdSoTightDriveIsNotChosen() {
        // Only candidate B would exceed 95% after the write → unassigned.
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 60)]   // headroom = 60 - 50 = 10
        let it = item("A", "f", .backup, 50)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.feasibility, .unassigned)
        XCTAssertFalse(plan.isFeasible)
        XCTAssertEqual(plan.unassigned.count, 1)
    }

    func testBackupPrefersHDDOverSSDWhenRoomIsEqual() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "SSD", total: 1000, free: 800, medium: .ssd, speed: 10000),
                      drive(3, "HDD", total: 1000, free: 800, medium: .hdd, speed: 5000)]
        let it = item("A", "f", .backup, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "HDD")
    }

    func testMovePrefersFasterDriveWhenMediumAndRoomEqual() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "Slow", total: 1000, free: 800, speed: 5000),
                      drive(3, "Fast", total: 1000, free: 800, speed: 10000)]
        let it = item("A", "f", .move, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "Fast")
    }

    func testConnectedDrivePreferredWhenEverythingElseEqual() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "Online", total: 1000, free: 800, connected: true, speed: 5000),
                      drive(3, "Offline", total: 1000, free: 800, connected: false, speed: 5000)]
        let it = item("A", "f", .move, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "Online")
    }

    // MARK: Overrides

    func testOverrideIsHonored() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 800),
                      drive(3, "C", total: 1000, free: 800)]
        let it = item("A", "f", .move, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it], overrides: [it.id: "C"])
        let s = step(plan, it.id)
        XCTAssertEqual(s?.destinationDriveKey, "C")
        XCTAssertEqual(s?.isOverride, true)
    }

    func testOverrideThatOverflowsIsHonoredButFlagged() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 60)]   // headroom 10
        let it = item("A", "f", .move, 50)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it], overrides: [it.id: "B"])
        let s = step(plan, it.id)
        XCTAssertEqual(s?.destinationDriveKey, "B")
        XCTAssertEqual(s?.feasibility, .overflow)
        XCTAssertEqual(s?.isOverride, true)
    }

    // MARK: Determinism

    func testDeterministicAcrossRuns() {
        let drives = [drive(1, "A", total: 2000, free: 1500),
                      drive(2, "B", total: 1000, free: 800),
                      drive(3, "C", total: 1000, free: 800)]
        let items = [item("A", "x", .move, 200), item("B", "y", .backup, 100),
                     item("C", "z", .move, 300), item("A", "w", .delete, 50)]
        let a = OrganizationPlanner.plan(drives: drives, items: items)
        let b = OrganizationPlanner.plan(drives: drives, items: items)
        XCTAssertEqual(a.steps, b.steps)
    }

    // MARK: Feasibility

    func testInfeasibleWhenTotalRoomInsufficient() {
        // Two 600-byte moves but only ~650 of usable headroom on the single destination.
        let drives = [drive(1, "A", total: 2000, free: 1500),
                      drive(2, "B", total: 1000, free: 700)]   // headroom 650
        let items = [item("A", "one", .move, 600), item("A", "two", .move, 600)]
        let plan = OrganizationPlanner.plan(drives: drives, items: items)
        XCTAssertFalse(plan.isFeasible)
        XCTAssertEqual(plan.unassigned.count, 1)
    }

    func testItemLargerThanAnyFreeIsUnassigned() {
        let drives = [drive(1, "A", total: 2000, free: 1500),
                      drive(2, "B", total: 1000, free: 500)]   // headroom 450
        let it = item("A", "huge", .move, 600)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.feasibility, .unassigned)
    }

    func testSingleDriveMovesUnassignedButDeletesStillFree() {
        let drives = [drive(1, "A", total: 1000, free: 200)]
        let mv = item("A", "m", .move, 100)
        let del = item("A", "d", .delete, 50)
        let plan = OrganizationPlanner.plan(drives: drives, items: [mv, del])
        XCTAssertEqual(step(plan, mv.id)?.feasibility, .unassigned)
        XCTAssertEqual(step(plan, del.id)?.operation, .delete)
        XCTAssertEqual(plan.totalBytesToFree, 150)   // delete 50 + move 100 (intended)
    }

    // MARK: Semantics & projections

    func testBackupLeavesSourceFreeUnchanged() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 900)]
        let it = item("A", "f", .backup, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        let a = plan.projections.first { $0.id == "A" }
        let b = plan.projections.first { $0.id == "B" }
        XCTAssertEqual(a?.projectedFree, 500)   // copy: source unchanged
        XCTAssertEqual(b?.projectedFree, 800)   // destination consumed 100
    }

    func testMoveFreesSource() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 900)]
        let it = item("A", "f", .move, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        let a = plan.projections.first { $0.id == "A" }
        let b = plan.projections.first { $0.id == "B" }
        XCTAssertEqual(a?.projectedFree, 600)   // move: source reclaimed 100
        XCTAssertEqual(b?.projectedFree, 800)
    }

    func testDeleteFreesSourceInProjection() {
        let drives = [drive(1, "A", total: 1000, free: 100)]
        let it = item("A", "d", .delete, 200)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        let a = plan.projections.first { $0.id == "A" }
        XCTAssertEqual(a?.projectedFree, 300)
    }

    // MARK: Sequencing

    func testVerifyIsFirstAndDeleteOrdersBeforeDependentFill() {
        // Backup into D only fits after a delete on D frees space.
        let drives = [drive(1, "A", total: 1000, free: 500),     // source of the backup
                      drive(2, "D", total: 1000, free: 40)]      // nearly full destination
        let del = item("D", "old", .delete, 100)                 // frees D: 40 -> 140
        let bk  = item("A", "new", .backup, 50)                  // needs D's freed space
        let plan = OrganizationPlanner.plan(drives: drives, items: [del, bk])

        XCTAssertEqual(plan.steps.first?.operation, .verify)
        XCTAssertEqual(plan.steps.first?.orderIndex, 1)
        let dStep = step(plan, del.id)
        let bStep = step(plan, bk.id)
        XCTAssertEqual(bStep?.destinationDriveKey, "D")
        XCTAssertEqual(bStep?.feasibility, .ok)
        XCTAssertEqual(dStep != nil && bStep != nil, true)
        XCTAssertLessThan(dStep!.orderIndex, bStep!.orderIndex)
        XCTAssertTrue(bStep!.dependsOn.contains(del.id))
        XCTAssertTrue(plan.isFeasible)
    }

    // MARK: Connection + report

    func testOfflineDestinationFlaggedAndListedToConnect() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "Cold", total: 1000, free: 800, connected: false)]
        let it = item("A", "f", .move, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.feasibility, .needsConnect)
        XCTAssertTrue(plan.drivesToConnect.contains("Cold"))
        let md = plan.reportMarkdown()
        XCTAssertTrue(md.contains("Cold"))
        XCTAssertTrue(md.localizedCaseInsensitiveContains("connect"))
    }

    func testReportListsNumberedStepsWithSourceAndDestination() {
        let drives = [drive(1, "A", total: 1000, free: 500),
                      drive(2, "B", total: 1000, free: 900)]
        let it = item("A", "photos", .move, 100)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        let text = plan.reportText()
        XCTAssertTrue(text.contains("1."))            // verify step numbered
        XCTAssertTrue(text.contains("photos"))
        XCTAssertTrue(text.contains("A"))
        XCTAssertTrue(text.contains("B"))
    }

    func testEmptyInputsProduceEmptyFeasiblePlan() {
        let plan = OrganizationPlanner.plan(drives: [drive(1, "A", total: 1000, free: 500)], items: [])
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.isFeasible)
        XCTAssertTrue(plan.unassigned.isEmpty)
    }

    // MARK: Totals & estimates

    func testTotalsAggregateByOperation() {
        let drives = [drive(1, "A", total: 4000, free: 3000),
                      drive(2, "B", total: 4000, free: 3500)]
        let items = [item("A", "m", .move, 100), item("A", "b", .backup, 200), item("A", "d", .delete, 50)]
        let plan = OrganizationPlanner.plan(drives: drives, items: items)
        XCTAssertEqual(plan.totalBytesToMove, 100)
        XCTAssertEqual(plan.totalBytesToCopy, 200)
        XCTAssertEqual(plan.totalBytesToFree, 150)   // delete 50 + move 100
    }

    func testTransferStepsHavePositiveDurationEstimate() {
        let drives = [drive(1, "A", total: 10_000_000_000, free: 9_000_000_000, speed: 5000),
                      drive(2, "B", total: 10_000_000_000, free: 9_000_000_000, speed: 5000)]
        let it = item("A", "big", .move, 1_000_000_000)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertGreaterThan(step(plan, it.id)?.estDuration ?? 0, 0)
        XCTAssertGreaterThan(plan.estTotalDuration, 0)
    }

    // MARK: Integration — organizationInputs() (DB-backed)

    func testOrganizationInputsReturnsCrossDriveTopLevelItems() async throws {
        let catalog = try Fixture.makeCatalog()
        let root = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, root)
        let volumes = try await catalog.library.volumes()
        let volume = try XCTUnwrap(volumes.first)
        let key = volume.uuid ?? volume.name

        // Tag a folder and a nested child the same way (dedup), plus a separate backup.
        try await catalog.annotations.setDecision(.move, volumeKey: key, relPath: "sub")
        try await catalog.annotations.setDecision(.move, volumeKey: key, relPath: "sub/c.txt")
        try await catalog.annotations.setDecision(.backup, volumeKey: key, relPath: "b.txt")
        try await catalog.annotations.setDecision(.keep, volumeKey: key, relPath: "a.txt")   // not actionable

        let (stats, items) = try await catalog.planning.organizationInputs()

        XCTAssertFalse(stats.isEmpty)
        let moves = items.filter { $0.tag == .move }
        XCTAssertEqual(moves.map(\.relPath), ["sub"])           // nested child de-duplicated
        XCTAssertEqual(moves.first?.sizeBytes, 150)             // sub subtree
        XCTAssertEqual(items.filter { $0.tag == .backup }.map(\.relPath), ["b.txt"])
        XCTAssertTrue(items.allSatisfy { $0.tag != .keep })     // keep excluded
        XCTAssertTrue(items.allSatisfy { $0.volumeKey == key })
    }

    // MARK: Drive roles (item 5)

    func testBackupPrefersMainBackupRoleOverLargerFasterNeutral() {
        // B is a bigger/faster HDD (the old heuristic would pick it for Backup),
        // but C carries the Main Backup role — role must win.
        let drives = [drive(1, "A", total: 10000, free: 9000),
                      drive(2, "B", total: 10000, free: 9000, medium: .hdd, speed: 40000, bus: .thunderbolt),
                      drive(3, "C", total: 5000, free: 3000, medium: .ssd, speed: 5000, bus: .usb,
                            role: .mainBackup)]
        let it = item("A", "f", .backup, 1000)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "C")
    }

    func testMovePrefersArchiveRoleOverFasterMain() {
        let drives = [drive(1, "A", total: 10000, free: 9000),
                      drive(2, "B", total: 10000, free: 9000, medium: .ssd, speed: 40000, role: .main),
                      drive(3, "C", total: 10000, free: 9000, medium: .hdd, speed: 5000, role: .archive)]
        let it = item("A", "old", .move, 500)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "C")
    }

    func testNeverAssignsToLocalSystem() {
        // The only drive with room is the boot disk — it must never be a destination.
        let drives = [drive(1, "A", total: 1000, free: 100),
                      drive(2, "Macintosh HD", total: 100000, free: 90000, role: .localSystem)]
        let it = item("A", "f", .backup, 500)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.feasibility, .unassigned)
        XCTAssertFalse(plan.isFeasible)
    }

    func testPriorityBreaksTieAmongSameRole() {
        // B and C are identical Main Backup drives; lower priority value wins.
        let drives = [drive(1, "A", total: 10000, free: 9000),
                      drive(2, "B", total: 5000, free: 3000, medium: .hdd, speed: 5000, role: .mainBackup, priority: 5),
                      drive(3, "C", total: 5000, free: 3000, medium: .hdd, speed: 5000, role: .mainBackup, priority: 1)]
        let it = item("A", "f", .backup, 1000)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "C")
    }

    func testBackupNotPlacedOnWorkDrive() {
        let drives = [drive(1, "A", total: 1000, free: 100),
                      drive(2, "B", total: 10000, free: 9000, role: .work)]
        let it = item("A", "f", .backup, 500)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.feasibility, .unassigned)
    }

    func testAllNeutralFallsBackToCapacityRanking() {
        // No roles assigned → behave like before: the drive with the most room wins.
        let drives = [drive(1, "A", total: 10000, free: 9000),
                      drive(2, "B", total: 10000, free: 5000),
                      drive(3, "C", total: 10000, free: 9000)]
        let it = item("A", "f", .move, 1000)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it])
        XCTAssertEqual(step(plan, it.id)?.destinationDriveKey, "C")
    }

    func testManualOverrideStillWinsAgainstRoles() {
        // Override forces B even though C holds the Main Backup role.
        let drives = [drive(1, "A", total: 10000, free: 9000),
                      drive(2, "B", total: 10000, free: 9000),
                      drive(3, "C", total: 10000, free: 9000, role: .mainBackup)]
        let it = item("A", "f", .backup, 1000)
        let plan = OrganizationPlanner.plan(drives: drives, items: [it], overrides: [it.id: "B"])
        let s = step(plan, it.id)
        XCTAssertEqual(s?.destinationDriveKey, "B")
        XCTAssertTrue(s?.isOverride ?? false)
    }
}
