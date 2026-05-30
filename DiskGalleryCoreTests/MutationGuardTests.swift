import XCTest
@testable import DiskGalleryCore

/// Enforces the core promise: the scanning and hashing code only ever *reads* the
/// filesystem. This is a static check over the source — if anyone adds a
/// file-mutating API to these files, this test fails.
final class MutationGuardTests: XCTestCase {

    func testScanningAndHashingSourcesNeverMutateFilesystem() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DiskGalleryCoreTests/
            .deletingLastPathComponent()   // repo root

        let sources = [
            "DiskGalleryCore/Scanning/Scanner.swift",
            "DiskGalleryCore/Scanning/VolumeMetadata.swift",
            "DiskGalleryCore/Scanning/ScanProgress.swift",
            "DiskGalleryCore/Duplicates/HashVerifier.swift",
        ]

        let forbidden = [
            "removeItem", "createFile", "moveItem", "copyItem", "createDirectory",
            "replaceItem", "trashItem", "createSymbolicLink", "linkItem",
            "FileHandle(forWritingTo", "FileHandle(forUpdating", ".write(to:",
            "setAttributes", "setResourceValues",
        ]

        for relPath in sources {
            let url = repoRoot.appendingPathComponent(relPath)
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token),
                               "\(relPath) must not reference filesystem-mutating API '\(token)'")
            }
        }
    }
}
