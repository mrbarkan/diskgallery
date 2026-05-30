import Foundation
import GRDB

/// One drive's capacity and tag rollups, computed entirely offline from the latest
/// snapshot of each volume. Powers the Action Plan and Transfer Planner so the user
/// can decide what to move where *before* plugging anything in.
public struct DriveStats: Sendable, Identifiable {
    public var id: Int64                 // volume id
    public var uuid: String?
    public var name: String
    public var latestSnapshotId: Int64?
    public var scannedAt: Date?
    public var isComplete: Bool
    public var totalCapacity: Int64?
    public var freeCapacity: Int64?
    public var usedLogical: Int64?       // catalogued bytes (root subtree)
    public var fileCount: Int64?

    /// De-duplicated tag totals (a tagged folder and its tagged children count once).
    public var keepBytes: Int64 = 0
    public var deleteBytes: Int64 = 0
    public var reviewBytes: Int64 = 0
    public var moveBytes: Int64 = 0
    public var backupBytes: Int64 = 0
    public var keepCount: Int = 0
    public var deleteCount: Int = 0
    public var reviewCount: Int = 0
    public var moveCount: Int = 0
    public var backupCount: Int = 0

    public var volumeKey: String { uuid ?? name }
    public var pendingCount: Int { Tag.actionTags.reduce(0) { $0 + count(for: $1) } }
    public var hasPending: Bool { pendingCount > 0 }

    public func bytes(for tag: Tag) -> Int64 {
        switch tag {
        case .keep: return keepBytes
        case .delete: return deleteBytes
        case .review: return reviewBytes
        case .move: return moveBytes
        case .backup: return backupBytes
        case .none: return 0
        }
    }

    public func count(for tag: Tag) -> Int {
        switch tag {
        case .keep: return keepCount
        case .delete: return deleteCount
        case .review: return reviewCount
        case .move: return moveCount
        case .backup: return backupCount
        case .none: return 0
        }
    }
}

/// A single top-level tagged item to be moved/deleted, for the planner's detail list.
public struct PlannedItem: Sendable, Identifiable {
    public var relPath: String
    public var name: String
    public var isDir: Bool
    public var sizeBytes: Int64
    public var id: String { relPath }
}

/// Computes capacity and tag-based plans across the whole library, offline.
public struct PlanningService: Sendable {
    let db: AppDatabase

    /// Latest complete-or-not snapshot id per volume, plus that snapshot's capacities.
    private static let driveSQL = """
        SELECT v.id AS volumeId, v.uuid AS uuid, v.name AS name,
               s.id AS latestSnapshotId, s.scannedAt AS scannedAt, s.isComplete AS isComplete,
               s.totalCapacity AS totalCapacity, s.freeCapacity AS freeCapacity,
               s.totalLogical AS usedLogical, s.fileCount AS fileCount
        FROM volume v
        LEFT JOIN snapshot s ON s.id = (
            SELECT id FROM snapshot s2 WHERE s2.volumeId = v.id
            ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
        )
        ORDER BY v.name COLLATE NOCASE
        """

    /// Every tagged path with its size resolved against its drive's latest snapshot.
    private static let taggedSQL = """
        WITH latest AS (
            SELECT s.id, s.volumeId FROM snapshot s
            WHERE s.id = (
                SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
            )
        )
        SELECT v.id AS volumeId, a.relPath AS relPath, a.tag AS tag,
               e.name AS name, e.isDir AS isDir,
               e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize
        FROM annotation a
        JOIN volume v ON (v.uuid = a.volumeUuid OR (v.uuid IS NULL AND v.name = a.volumeUuid))
        LEFT JOIN latest l ON l.volumeId = v.id
        LEFT JOIN entry e ON e.snapshotId = l.id AND e.relPath = a.relPath
        WHERE a.tag != 0
        """

    private struct TaggedRow: Decodable, FetchableRecord {
        var volumeId: Int64
        var relPath: String
        var tag: Int
        var name: String?
        var isDir: Bool?
        var logicalSize: Int64?
        var subtreeLogicalSize: Int64?

        var displaySize: Int64 { (isDir == true ? subtreeLogicalSize : logicalSize) ?? 0 }
    }

    private struct DriveRow: Decodable, FetchableRecord {
        var volumeId: Int64
        var uuid: String?
        var name: String
        var latestSnapshotId: Int64?
        var scannedAt: Date?
        var isComplete: Bool?
        var totalCapacity: Int64?
        var freeCapacity: Int64?
        var usedLogical: Int64?
        var fileCount: Int64?
    }

    public func driveStats() async throws -> [DriveStats] {
        let (drives, tagged) = try await db.writer.read { db in
            (try DriveRow.fetchAll(db, sql: Self.driveSQL),
             try TaggedRow.fetchAll(db, sql: Self.taggedSQL))
        }

        // Group tagged rows by (volume, tag), drop nested children, then sum.
        var byVolume: [Int64: [Tag: [TaggedRow]]] = [:]
        for row in tagged {
            guard let tag = Tag(rawValue: row.tag), tag != .none else { continue }
            byVolume[row.volumeId, default: [:]][tag, default: []].append(row)
        }

        return drives.map { drive in
            var stats = DriveStats(
                id: drive.volumeId, uuid: drive.uuid, name: drive.name,
                latestSnapshotId: drive.latestSnapshotId, scannedAt: drive.scannedAt,
                isComplete: drive.isComplete ?? true,
                totalCapacity: drive.totalCapacity, freeCapacity: drive.freeCapacity,
                usedLogical: drive.usedLogical, fileCount: drive.fileCount)

            for (tag, rows) in byVolume[drive.volumeId] ?? [:] {
                let top = Self.topLevel(rows)
                let bytes = top.reduce(0) { $0 + $1.displaySize }
                switch tag {
                case .keep:   stats.keepBytes = bytes;   stats.keepCount = top.count
                case .delete: stats.deleteBytes = bytes; stats.deleteCount = top.count
                case .review: stats.reviewBytes = bytes; stats.reviewCount = top.count
                case .move:   stats.moveBytes = bytes;   stats.moveCount = top.count
                case .backup: stats.backupBytes = bytes; stats.backupCount = top.count
                case .none:   break
                }
            }
            return stats
        }
    }

    /// The de-duplicated top-level items for one tag on one drive — what the planner
    /// would actually move or delete.
    public func plannedItems(volumeKey: String, tag: Tag) async throws -> [PlannedItem] {
        let rows = try await db.writer.read { db in
            try TaggedRow.fetchAll(db, sql: Self.taggedSQL)
        }
        let matching = rows.filter { row in
            guard Tag(rawValue: row.tag) == tag else { return false }
            return true
        }
        // Resolve volumeKey → volumeId set (uuid or name based).
        let volumeId = try await db.writer.read { db -> Int64? in
            try Int64.fetchOne(db, sql:
                "SELECT id FROM volume WHERE uuid = ? OR (uuid IS NULL AND name = ?)",
                arguments: [volumeKey, volumeKey])
        }
        let onDrive = matching.filter { $0.volumeId == volumeId }
        return Self.topLevel(onDrive)
            .map { PlannedItem(relPath: $0.relPath, name: $0.name ?? ($0.relPath as NSString).lastPathComponent,
                               isDir: $0.isDir ?? false, sizeBytes: $0.displaySize) }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Keeps only items with no tagged ancestor in the same set, so a tagged folder
    /// and a tagged file inside it aren't summed twice.
    private static func topLevel(_ rows: [TaggedRow]) -> [TaggedRow] {
        let paths = Set(rows.map(\.relPath))
        return rows.filter { row in
            var path = row.relPath
            while let slash = path.lastIndex(of: "/") {
                path = String(path[path.startIndex ..< slash])
                if paths.contains(path) { return false }
            }
            return true
        }
    }
}
