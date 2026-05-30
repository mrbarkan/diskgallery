import Foundation
import CryptoKit

/// Computes SHA-256 digests by streaming files in chunks.
///
/// READ-ONLY: opens files for reading only. `MutationGuardTests` enforces that no
/// file-mutating API appears here.
public struct HashVerifier: Sendable {
    public static let chunkSize = 1 << 20   // 1 MB

    public init() {}

    /// Streams `fileURL` through SHA-256 without loading it whole. Honours task
    /// cancellation between chunks. Returns a lowercase hex digest.
    public func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
