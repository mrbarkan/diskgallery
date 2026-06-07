import Foundation

/// Pure merge math for the unified browser — given a path's copies across drives,
/// picks the reference copy, flags partial/identical copies, and computes coverage.
/// No DB/IO, so it's trivially unit-testable.
public enum UnifiedMerge {
    public static func node(relPath: String, name: String, isDir: Bool, copies: [UnifiedCopy]) -> UnifiedNode {
        // Reference: largest size, then newest modifiedAt, then smallest volumeKey.
        let refIndex = copies.indices.max { a, b in
            let ca = copies[a], cb = copies[b]
            if ca.size != cb.size { return ca.size < cb.size }
            let ma = ca.modifiedAt ?? .distantPast, mb = cb.modifiedAt ?? .distantPast
            if ma != mb { return ma < mb }
            return ca.volumeKey > cb.volumeKey
        }
        guard let ri = refIndex else {
            return UnifiedNode(relPath: relPath, name: name, isDir: isDir, copies: [],
                               referenceSize: 0, redundantSize: 0, driveCount: 0, coverage: .atRisk)
        }
        let refSize = copies[ri].size
        let refHash = copies[ri].contentHash

        var finalized = copies.enumerated().map { index, original -> UnifiedCopy in
            var c = original
            c.isReference = (index == ri)
            c.isPartial = !c.isReference && c.size < Int64(Double(refSize) * 0.9)
            if !isDir, let h = c.contentHash, let rh = refHash {
                c.matchesReference = (h == rh)
            } else {
                c.matchesReference = nil
            }
            return c
        }
        // Sort: reference first, then size desc, then drive name.
        finalized.sort { a, b in
            if a.isReference != b.isReference { return a.isReference }
            if a.size != b.size { return a.size > b.size }
            return a.volumeName.localizedCaseInsensitiveCompare(b.volumeName) == .orderedAscending
        }

        let total = copies.reduce(0) { $0 + $1.size }
        let coverage: Coverage = copies.count <= 1 ? .atRisk : (copies.count == 2 ? .backedUp : .protected)
        return UnifiedNode(relPath: relPath, name: name, isDir: isDir, copies: finalized,
                           referenceSize: refSize, redundantSize: total - refSize,
                           driveCount: copies.count, coverage: coverage)
    }
}
