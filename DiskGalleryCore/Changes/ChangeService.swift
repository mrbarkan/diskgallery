import Foundation
import GRDB

/// A completed catalog capture, for the "compare scans" picker.
public struct SnapshotInfo: Sendable, Identifiable, FetchableRecord, Decodable {
    public var id: Int64
    public var scannedAt: Date
    public var fileCount: Int64?
    public var totalLogical: Int64?
}

/// One file that differs between two snapshots of the same drive.
public struct ChangedEntry: Sendable, Identifiable {
    public enum Kind: String, Sendable { case added, removed, resized }
    public var relPath: String
    public var name: String
    public var kind: Kind
    public var oldSize: Int64?
    public var newSize: Int64?

    public var id: String { relPath }
    public var delta: Int64 { (newSize ?? 0) - (oldSize ?? 0) }
}

/// The difference between an older (base) and newer (head) snapshot.
public struct SnapshotDiff: Sendable {
    public var baseSnapshotId: Int64
    public var headSnapshotId: Int64
    public var baseDate: Date
    public var headDate: Date

    public var added: [ChangedEntry]
    public var removed: [ChangedEntry]
    public var resized: [ChangedEntry]

    public var addedCount: Int
    public var removedCount: Int
    public var resizedCount: Int

    public var addedBytes: Int64
    public var removedBytes: Int64
    public var resizedNetBytes: Int64

    /// Net change in catalogued bytes from base → head.
    public var netBytes: Int64 { addedBytes - removedBytes + resizedNetBytes }
    public var hasChanges: Bool { addedCount + removedCount + resizedCount > 0 }
    /// True when any list was capped for display (the counts/totals stay exact).
    public var truncated: Bool
}

/// Compares two snapshots of one drive to answer "what changed since last scan?"
/// — entirely from stored data, so it works with the drive disconnected.
public struct ChangeService: Sendable {
    let db: AppDatabase

    /// How many rows per category to materialise for the UI. Counts/totals are exact.
    public static let displayCap = 1_000

    /// Completed snapshots for a volume, newest first.
    public func completeSnapshots(volumeId: Int64) async throws -> [SnapshotInfo] {
        try await db.writer.read { db in
            try SnapshotInfo.fetchAll(db, sql: """
                SELECT id, scannedAt, fileCount, totalLogical
                FROM snapshot WHERE volumeId = ? AND isComplete = 1
                ORDER BY scannedAt DESC, id DESC
                """, arguments: [volumeId])
        }
    }

    /// The two most recent completed snapshots (head = newest, base = the one before).
    public func latestComparablePair(volumeId: Int64) async throws -> (base: Int64, head: Int64)? {
        let snaps = try await completeSnapshots(volumeId: volumeId)
        guard snaps.count >= 2 else { return nil }
        return (base: snaps[1].id, head: snaps[0].id)
    }

    private struct DiffRow: Decodable, FetchableRecord {
        var relPath: String
        var name: String
        var oldSize: Int64?
        var newSize: Int64?
    }

    public func diff(baseSnapshotId base: Int64, headSnapshotId head: Int64) async throws -> SnapshotDiff {
        try await db.writer.read { db in
            let cap = Self.displayCap

            func date(_ id: Int64) throws -> Date {
                try Date.fetchOne(db, sql: "SELECT scannedAt FROM snapshot WHERE id = ?", arguments: [id]) ?? Date()
            }

            // Added: in head, not in base.
            let added = try DiffRow.fetchAll(db, sql: """
                SELECT h.relPath AS relPath, h.name AS name, NULL AS oldSize, h.logicalSize AS newSize
                FROM entry h
                WHERE h.snapshotId = ? AND h.isDir = 0
                  AND NOT EXISTS (SELECT 1 FROM entry b WHERE b.snapshotId = ? AND b.isDir = 0 AND b.relPath = h.relPath)
                ORDER BY h.logicalSize DESC LIMIT ?
                """, arguments: [head, base, cap])
                .map { ChangedEntry(relPath: $0.relPath, name: $0.name, kind: .added, oldSize: nil, newSize: $0.newSize) }
            let addedAgg = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, IFNULL(SUM(h.logicalSize), 0) AS bytes
                FROM entry h
                WHERE h.snapshotId = ? AND h.isDir = 0
                  AND NOT EXISTS (SELECT 1 FROM entry b WHERE b.snapshotId = ? AND b.isDir = 0 AND b.relPath = h.relPath)
                """, arguments: [head, base])
            let addedCount: Int = addedAgg?["c"] ?? 0
            let addedBytes: Int64 = addedAgg?["bytes"] ?? 0

            // Removed: in base, not in head.
            let removed = try DiffRow.fetchAll(db, sql: """
                SELECT b.relPath AS relPath, b.name AS name, b.logicalSize AS oldSize, NULL AS newSize
                FROM entry b
                WHERE b.snapshotId = ? AND b.isDir = 0
                  AND NOT EXISTS (SELECT 1 FROM entry h WHERE h.snapshotId = ? AND h.isDir = 0 AND h.relPath = b.relPath)
                ORDER BY b.logicalSize DESC LIMIT ?
                """, arguments: [base, head, cap])
                .map { ChangedEntry(relPath: $0.relPath, name: $0.name, kind: .removed, oldSize: $0.oldSize, newSize: nil) }
            let removedAgg = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, IFNULL(SUM(b.logicalSize), 0) AS bytes
                FROM entry b
                WHERE b.snapshotId = ? AND b.isDir = 0
                  AND NOT EXISTS (SELECT 1 FROM entry h WHERE h.snapshotId = ? AND h.isDir = 0 AND h.relPath = b.relPath)
                """, arguments: [base, head])
            let removedCount: Int = removedAgg?["c"] ?? 0
            let removedBytes: Int64 = removedAgg?["bytes"] ?? 0

            // Resized: same relPath in both, different size.
            let resized = try DiffRow.fetchAll(db, sql: """
                SELECT h.relPath AS relPath, h.name AS name, b.logicalSize AS oldSize, h.logicalSize AS newSize
                FROM entry h JOIN entry b ON b.snapshotId = ? AND b.isDir = 0 AND b.relPath = h.relPath
                WHERE h.snapshotId = ? AND h.isDir = 0 AND h.logicalSize != b.logicalSize
                ORDER BY ABS(h.logicalSize - b.logicalSize) DESC LIMIT ?
                """, arguments: [base, head, cap])
                .map { ChangedEntry(relPath: $0.relPath, name: $0.name, kind: .resized, oldSize: $0.oldSize, newSize: $0.newSize) }
            let resizedAgg = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS c, IFNULL(SUM(h.logicalSize - b.logicalSize), 0) AS net
                FROM entry h JOIN entry b ON b.snapshotId = ? AND b.isDir = 0 AND b.relPath = h.relPath
                WHERE h.snapshotId = ? AND h.isDir = 0 AND h.logicalSize != b.logicalSize
                """, arguments: [base, head])
            let resizedCount: Int = resizedAgg?["c"] ?? 0
            let resizedNet: Int64 = resizedAgg?["net"] ?? 0

            let truncated = added.count < addedCount || removed.count < removedCount || resized.count < resizedCount

            return SnapshotDiff(
                baseSnapshotId: base, headSnapshotId: head,
                baseDate: try date(base), headDate: try date(head),
                added: added, removed: removed, resized: resized,
                addedCount: addedCount, removedCount: removedCount, resizedCount: resizedCount,
                addedBytes: addedBytes, removedBytes: removedBytes, resizedNetBytes: resizedNet,
                truncated: truncated)
        }
    }
}
