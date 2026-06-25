import Foundation

/// Copies a single file with checksum verification, never overwriting a differing
/// destination. Writes to a temp file in the destination directory, verifies the
/// copy by SHA-256, then atomically renames it into place (same-volume rename is
/// atomic) — so an interrupted copy never leaves a half-written final file.
///
/// This is the executor's mutation primitive; it lives in `Execution/`, separate from
/// the read-only scanning/hashing code that `MutationGuardTests` guards.
public struct FileCopier: Sendable {
    public enum Outcome: Equatable, Sendable {
        case verified(hash: String)
        case skippedIdentical(hash: String)
        case conflict
        case checksumMismatch
    }

    let hasher: HashVerifier
    public init(hasher: HashVerifier = HashVerifier()) { self.hasher = hasher }

    public func copyVerified(from src: URL, to dst: URL) throws -> Outcome {
        let fm = FileManager.default
        let srcHash = try hasher.sha256(fileURL: src)

        if fm.fileExists(atPath: dst.path) {
            let dstHash = try hasher.sha256(fileURL: dst)
            return dstHash == srcHash ? .skippedIdentical(hash: srcHash) : .conflict
        }

        let parent = dst.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".dg-tmp-\(UUID().uuidString)")
        if fm.fileExists(atPath: temp.path) { try? fm.removeItem(at: temp) }

        do {
            try fm.copyItem(at: src, to: temp)
            let tempHash = try hasher.sha256(fileURL: temp)
            guard tempHash == srcHash else {
                try? fm.removeItem(at: temp)
                return .checksumMismatch
            }
            try fm.moveItem(at: temp, to: dst)   // same-volume rename = atomic
            return .verified(hash: srcHash)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
