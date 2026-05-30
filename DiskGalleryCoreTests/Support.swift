import Foundation
import XCTest
@testable import DiskGalleryCore

enum TestError: Error { case noSnapshot }

enum Fixture {
    /// Builds a known temp tree:
    ///   a.txt(100), b.txt(200), sub/c.txt(50), sub/a.txt(100 == dup of a.txt), empty/
    /// Totals: 4 files, 450 bytes. sub subtree = 150. root subtree = 450.
    @discardableResult
    static func makeTree(name: String = "tree") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskGalleryTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeFile(root, "a.txt", bytes: 100)
        try writeFile(root, "b.txt", bytes: 200)
        try writeFile(root, "sub/c.txt", bytes: 50)
        try writeFile(root, "sub/a.txt", bytes: 100)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)
        return root
    }

    static func writeFile(_ root: URL, _ relPath: String, bytes: Int, fill: UInt8 = 0x41) throws {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
    }

    static func makeCatalog() throws -> Catalog {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskGalleryTests-\(UUID().uuidString).sqlite")
        return try Catalog(databaseURL: dbURL)
    }

    /// Drives a scan to completion and returns the new snapshot id.
    @discardableResult
    static func scan(_ catalog: Catalog, _ url: URL) async throws -> Int64 {
        var snapshotId: Int64?
        for try await progress in catalog.scanner.scan(volumeURL: url) {
            if progress.isComplete { snapshotId = progress.snapshotId }
        }
        guard let id = snapshotId else { throw TestError.noSnapshot }
        return id
    }

    /// Snapshot of every path's modification date under `root` (for read-only checks).
    static func modificationDates(_ root: URL) throws -> [String: Date] {
        var result: [String: Date] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])!
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values.contentModificationDate { result[url.path] = date }
        }
        return result
    }
}
