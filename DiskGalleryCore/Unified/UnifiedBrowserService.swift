import Foundation
import GRDB

/// Builds the cross-drive "All Drives" view: direct children at a path, merged across
/// every volume's latest snapshot. GRDB stays behind this facade; the grouping/merge
/// math is a pure static function so it's unit-testable without a database.
public struct UnifiedBrowserService: Sendable {
    let db: AppDatabase

    /// One pre-merge row: an entry on one drive at a given parent path.
    struct RawEntry {
        var name: String
        var isDir: Bool
        var copy: UnifiedCopy
    }

    /// Direct children at `parentPath` ("" = root), merged across drives' latest snapshots.
    public func children(ofPath parentPath: String, hideHidden: Bool) async throws -> [UnifiedNode] {
        let raws = try await rawChildren(ofPath: parentPath)
        return Self.merge(raws, hideHidden: hideHidden)
    }

    /// Headline coverage figures over top-level folders (cheap, meaningful).
    public func summary(hideHidden: Bool) async throws -> CoverageSummary {
        let top = try await children(ofPath: "", hideHidden: hideHidden)
        let atRisk = top.filter { $0.coverage == .atRisk }
        return CoverageSummary(
            atRiskBytes: atRisk.reduce(0) { $0 + $1.referenceSize },
            atRiskCount: atRisk.count,
            redundantBytes: top.reduce(0) { $0 + $1.redundantSize },
            driveCount: try await scannedDriveCount())
    }

    /// Number of drives with at least one *complete* snapshot (i.e. browsable here).
    func scannedDriveCount() async throws -> Int {
        try await db.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT volumeId) FROM snapshot WHERE isComplete = 1") ?? 0
        }
    }

    /// Children resolved by `parentId` per latest snapshot — wildcard-safe (names may
    /// contain `_`/`%`), unlike a `relPath LIKE` match. Only **complete** snapshots are
    /// considered, so an in-progress/paused rescan never shows a half-built tree.
    func rawChildren(ofPath parentPath: String) async throws -> [RawEntry] {
        try await db.writer.read { db -> [RawEntry] in
            let parentClause = parentPath.isEmpty ? "parent.parentId IS NULL" : "parent.relPath = :p"
            let sql = """
                WITH latest AS (
                    SELECT s.id AS sid, s.volumeId AS vid FROM snapshot s
                    WHERE s.isComplete = 1 AND s.id = (
                        SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId AND s2.isComplete = 1
                        ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1)
                )
                SELECT v.uuid AS uuid, v.name AS volumeName, l.sid AS snapshotId,
                       e.id AS entryId, e.name AS name, e.relPath AS relPath, e.isDir AS isDir,
                       e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize,
                       e.modifiedAt AS modifiedAt, e.contentHash AS contentHash
                FROM latest l
                JOIN volume v ON v.id = l.vid
                JOIN entry parent ON parent.snapshotId = l.sid AND \(parentClause)
                JOIN entry e ON e.snapshotId = l.sid AND e.parentId = parent.id
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: parentPath.isEmpty ? [:] : ["p": parentPath])
            return rows.map { row in
                let isDir: Bool = row["isDir"]
                let relPath: String = row["relPath"]
                let size: Int64 = isDir ? (row["subtreeLogicalSize"] ?? 0) : (row["logicalSize"] ?? 0)
                let key = (row["uuid"] as String?) ?? (row["volumeName"] as String)
                let copy = UnifiedCopy(volumeKey: key, volumeName: row["volumeName"], relPath: relPath,
                                       size: size, modifiedAt: row["modifiedAt"], contentHash: row["contentHash"],
                                       entryId: row["entryId"], snapshotId: row["snapshotId"])
                return RawEntry(name: row["name"], isDir: isDir, copy: copy)
            }
        }
    }

    /// Groups raw rows into merged nodes — pure, DB-free. Keyed by (name, isDir) so a
    /// name that's a file on one drive and a folder on another forms two distinct nodes
    /// (keeping logical-size vs subtree-size comparisons consistent within each).
    static func merge(_ entries: [RawEntry], hideHidden: Bool) -> [UnifiedNode] {
        var byKey: [String: (name: String, relPath: String, isDir: Bool, copies: [UnifiedCopy])] = [:]
        for e in entries {
            if hideHidden && e.name.hasPrefix(".") { continue }
            let key = "\(e.name)|\(e.isDir)"
            var bucket = byKey[key] ?? (name: e.name, relPath: e.copy.relPath, isDir: e.isDir, copies: [])
            bucket.copies.append(e.copy)
            byKey[key] = bucket
        }
        let nodes = byKey.values.map { b in
            UnifiedMerge.node(relPath: b.relPath, name: b.name, isDir: b.isDir, copies: b.copies)
        }
        return nodes.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            if a.referenceSize != b.referenceSize { return a.referenceSize > b.referenceSize }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}
