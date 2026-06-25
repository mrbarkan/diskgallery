import XCTest
import GRDB
@testable import DiskGalleryCore

final class ExecutionTests: XCTestCase {

    func testOperationRoundTripsThroughTheDatabase() async throws {
        let catalog = try Fixture.makeCatalog()   // runs migrations incl. v7
        let template = DiskGalleryCore.Operation(type: .copy, sourceVolumeKey: "A", sourceRelPath: "shoot/a.cr2",
                           destVolumeKey: "B", destRelPath: "shoot/a.cr2", bytes: 1234,
                           status: .pending, createdAt: Date())
        let insertedOp = try await catalog.database.writer.write { db -> DiskGalleryCore.Operation in
            var op = template
            try op.insert(db)
            return op
        }
        XCTAssertNotNil(insertedOp.id)

        let fetched = try await catalog.database.writer.read { db in
            try DiskGalleryCore.Operation.fetchAll(db)
        }
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.type, .copy)
        XCTAssertEqual(fetched.first?.status, .pending)
        XCTAssertEqual(fetched.first?.destRelPath, "shoot/a.cr2")
        XCTAssertEqual(fetched.first?.bytes, 1234)
    }
}
