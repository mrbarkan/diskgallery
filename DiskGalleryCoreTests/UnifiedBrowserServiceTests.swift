import XCTest
import GRDB
@testable import DiskGalleryCore

final class UnifiedBrowserServiceTests: XCTestCase {

    // MARK: Pure merge/grouping (no DB)

    private func raw(_ name: String, _ vol: String, size: Int64, isDir: Bool = true) -> UnifiedBrowserService.RawEntry {
        UnifiedBrowserService.RawEntry(
            name: name, isDir: isDir,
            copy: UnifiedCopy(volumeKey: vol, volumeName: vol, relPath: name, size: size,
                              modifiedAt: nil, contentHash: nil, entryId: 1, snapshotId: 1))
    }

    func testMergeGroupsSameNameAcrossDrives() {
        let nodes = UnifiedBrowserService.merge([
            raw("ARCHIVE", "A", size: 500),
            raw("ARCHIVE", "B", size: 500),
            raw("PHOTOS", "A", size: 900),
        ], hideHidden: true)
        let archive = try! XCTUnwrap(nodes.first { $0.name == "ARCHIVE" })
        XCTAssertEqual(archive.driveCount, 2)
        XCTAssertEqual(archive.coverage, .backedUp)
        let photos = try! XCTUnwrap(nodes.first { $0.name == "PHOTOS" })
        XCTAssertEqual(photos.driveCount, 1)
        XCTAssertEqual(photos.coverage, .atRisk)
    }

    func testMergeHidesDotfilesWhenAsked() {
        let visible = UnifiedBrowserService.merge([raw(".DS_Store", "A", size: 1, isDir: false),
                                                   raw("KEEP", "A", size: 1)], hideHidden: true)
        XCTAssertEqual(visible.map(\.name), ["KEEP"])
        let all = UnifiedBrowserService.merge([raw(".DS_Store", "A", size: 1, isDir: false),
                                               raw("KEEP", "A", size: 1)], hideHidden: false)
        XCTAssertEqual(Set(all.map(\.name)), [".DS_Store", "KEEP"])
    }

    func testMergeSortsDirectoriesBeforeFiles() {
        let nodes = UnifiedBrowserService.merge([
            raw("zfile", "A", size: 10, isDir: false),
            raw("afolder", "A", size: 1, isDir: true),
        ], hideHidden: true)
        XCTAssertEqual(nodes.map(\.name), ["afolder", "zfile"])   // dir first despite name/size
    }

    // MARK: Real SQL against a single scanned volume

    func testChildrenAndSummaryOnScannedTree() async throws {
        let catalog = try Fixture.makeCatalog()
        _ = try await Fixture.scan(catalog, try Fixture.makeTree())   // a.txt,b.txt,sub/(c.txt,a.txt),empty/

        let top = try await catalog.unified.children(ofPath: "", hideHidden: true)
        XCTAssertEqual(Set(top.map(\.name)), ["a.txt", "b.txt", "sub", "empty"])
        XCTAssertTrue(top.allSatisfy { $0.driveCount == 1 && $0.coverage == .atRisk })

        let subKids = try await catalog.unified.children(ofPath: "sub", hideHidden: true)
        XCTAssertEqual(Set(subKids.map(\.name)), ["c.txt", "a.txt"])

        let summary = try await catalog.unified.summary(hideHidden: true)
        XCTAssertEqual(summary.atRiskCount, 4)
        XCTAssertEqual(summary.driveCount, 1)
        XCTAssertEqual(summary.redundantBytes, 0)
    }

    func testInProgressSnapshotIsIgnored() async throws {
        let catalog = try Fixture.makeCatalog()
        let tree = try Fixture.makeTree()
        _ = try await Fixture.scan(catalog, tree)                 // complete snapshot S1

        // A newer scan of the same volume, stopped early → leaves an incomplete S2.
        var pausedId: Int64?
        for try await p in catalog.scanner.run(volumeURL: tree, resumeSnapshotId: nil,
                                               batchSize: 2, maxBatches: 1) {
            pausedId = p.snapshotId
        }
        let sid = try XCTUnwrap(pausedId)
        let incomplete = try await catalog.database.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT isComplete FROM snapshot WHERE id = ?", arguments: [sid]) ?? true
        }
        XCTAssertFalse(incomplete, "second scan should be left incomplete")

        // The unified view must still reflect the COMPLETE snapshot, not the half-built one.
        let top = try await catalog.unified.children(ofPath: "", hideHidden: true)
        XCTAssertEqual(Set(top.map(\.name)), ["a.txt", "b.txt", "sub", "empty"])
        XCTAssertEqual(top.first { $0.name == "sub" }?.referenceSize, 150)   // rolled-up size from S1
        let summary = try await catalog.unified.summary(hideHidden: true)
        XCTAssertEqual(summary.driveCount, 1)
    }
}
