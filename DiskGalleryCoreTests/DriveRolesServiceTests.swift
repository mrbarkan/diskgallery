import XCTest
@testable import DiskGalleryCore

final class DriveRolesServiceTests: XCTestCase {

    func testSetAndGetRoleAndPriority() async throws {
        let catalog = try Fixture.makeCatalog()
        let svc = catalog.driveRoles
        let empty = try await svc.all()
        XCTAssertTrue(empty.isEmpty)

        try await svc.setRole(.mainBackup, forKey: "VOL-1")
        try await svc.setPriority(5, forKey: "VOL-1")

        let a = try await svc.assignment(forKey: "VOL-1")
        XCTAssertEqual(a?.role, .mainBackup)
        XCTAssertEqual(a?.priority, 5)

        let all = try await svc.all()
        XCTAssertEqual(all["VOL-1"]?.role, .mainBackup)
        XCTAssertEqual(all["VOL-1"]?.priority, 5)
    }

    func testMissingKeyReturnsNil() async throws {
        let catalog = try Fixture.makeCatalog()
        let a = try await catalog.driveRoles.assignment(forKey: "missing")
        XCTAssertNil(a)
    }

    func testSetRolePreservesPriorityAndViceVersa() async throws {
        let svc = try Fixture.makeCatalog().driveRoles
        try await svc.setPriority(3, forKey: "K")
        try await svc.setRole(.archive, forKey: "K")     // must not wipe the priority
        let a = try await svc.assignment(forKey: "K")
        XCTAssertEqual(a?.role, .archive)
        XCTAssertEqual(a?.priority, 3)
    }

    func testSetWritesBothRoleAndPriorityAtomically() async throws {
        // Guards the boot-disk regression: a priority write must carry the effective role
        // (e.g. .localSystem) rather than defaulting the role to .neutral.
        let svc = try Fixture.makeCatalog().driveRoles
        try await svc.set(role: .localSystem, priority: 2, forKey: "BOOT")
        let a = try await svc.assignment(forKey: "BOOT")
        XCTAssertEqual(a?.role, .localSystem)
        XCTAssertEqual(a?.priority, 2)
    }

    func testClearRemovesAssignment() async throws {
        let svc = try Fixture.makeCatalog().driveRoles
        try await svc.setRole(.main, forKey: "K")
        try await svc.clear(forKey: "K")
        let after = try await svc.assignment(forKey: "K")
        XCTAssertNil(after)
    }
}
