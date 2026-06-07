import XCTest
@testable import DiskGalleryCore

final class UnifiedMergeTests: XCTestCase {
    private func copy(_ key: String, size: Int64, modified: TimeInterval? = nil,
                      hash: String? = nil) -> UnifiedCopy {
        UnifiedCopy(volumeKey: key, volumeName: key, relPath: "ARCHIVE", size: size,
                    modifiedAt: modified.map { Date(timeIntervalSince1970: $0) },
                    contentHash: hash, entryId: 1, snapshotId: 1)
    }

    func testReferenceIsLargestThenNewest() {
        let node = UnifiedMerge.node(relPath: "ARCHIVE", name: "ARCHIVE", isDir: true,
                                     copies: [copy("A", size: 100),
                                              copy("B", size: 300),
                                              copy("C", size: 300, modified: 999)])
        XCTAssertEqual(node.copies.first?.volumeKey, "C")        // 300 & newest → reference, sorted first
        XCTAssertTrue(node.copies.first?.isReference ?? false)
        XCTAssertEqual(node.referenceSize, 300)
        XCTAssertEqual(node.redundantSize, 100 + 300)            // sum(700) - reference(300)
        XCTAssertEqual(node.driveCount, 3)
    }

    func testCoverageByDriveCount() {
        func cov(_ n: Int) -> Coverage {
            UnifiedMerge.node(relPath: "x", name: "x", isDir: true,
                              copies: (0..<n).map { copy("V\($0)", size: 1) }).coverage
        }
        XCTAssertEqual(cov(1), .atRisk)
        XCTAssertEqual(cov(2), .backedUp)
        XCTAssertEqual(cov(3), .protected)
    }

    func testPartialFlag() {
        let node = UnifiedMerge.node(relPath: "x", name: "x", isDir: true,
                                     copies: [copy("A", size: 1000), copy("B", size: 800)])
        XCTAssertEqual(node.copies.first { $0.volumeKey == "B" }?.isPartial, true)   // 800 < 90% of 1000
        XCTAssertEqual(node.copies.first { $0.volumeKey == "A" }?.isPartial, false)
    }

    func testMatchesReferenceForFiles() {
        let node = UnifiedMerge.node(relPath: "f", name: "f", isDir: false,
                                     copies: [copy("A", size: 100, hash: "h1"),
                                              copy("B", size: 100, hash: "h1"),
                                              copy("C", size: 100, hash: "h2")])
        XCTAssertEqual(node.copies.first { $0.volumeKey == "B" }?.matchesReference, true)
        XCTAssertEqual(node.copies.first { $0.volumeKey == "C" }?.matchesReference, false)
    }

    func testDirectoriesHaveNilMatchesReference() {
        let node = UnifiedMerge.node(relPath: "d", name: "d", isDir: true,
                                     copies: [copy("A", size: 100, hash: "h1"), copy("B", size: 100, hash: "h1")])
        XCTAssertNil(node.copies.first?.matchesReference)
    }
}
