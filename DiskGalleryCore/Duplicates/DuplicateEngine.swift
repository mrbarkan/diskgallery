import Foundation
import GRDB

/// A group of files that share a name and size across the library.
public struct DuplicateSet: Codable, Sendable, Identifiable, FetchableRecord {
    public var name: String
    public var logicalSize: Int64
    public var copies: Int
    public var reclaimable: Int64
    public var driveCount: Int           // how many distinct drives hold a copy
    public var driveNames: String        // comma-separated drive names

    public var id: String { "\(name)\u{1}\(logicalSize)" }

    /// True when copies live on two or more different drives (the useful signal for
    /// backup planning — a file that exists on several drives).
    public var spansDrives: Bool { driveCount >= 2 }
    public var driveList: [String] {
        driveNames.split(separator: ",").map { String($0) }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// One member file of a duplicate set, with enough info to locate and verify it.
public struct DuplicateMember: Codable, Sendable, Identifiable, FetchableRecord {
    public var entryId: Int64
    public var snapshotId: Int64
    public var relPath: String
    public var contentHash: String?
    public var modifiedAt: Date?
    public var volumeId: Int64
    public var volumeUuid: String?
    public var volumeName: String

    public var id: Int64 { entryId }
}

/// Finds likely-duplicate files purely from stored snapshots (works fully offline)
/// and records SHA-256 hashes once they're verified against connected drives.
public struct DuplicateEngine: Sendable {
    let db: AppDatabase

    /// Restricts results to the most recent snapshot of each volume, so re-scans
    /// don't double-count.
    private static let latestCTE = """
        WITH latest AS (
            SELECT s.id FROM snapshot s
            WHERE s.id = (
                SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
            )
        )
        """

    public func duplicateSets(minCopies: Int = 2, limit: Int = 500,
                              crossDriveOnly: Bool = false) async throws -> [DuplicateSet] {
        try await db.writer.read { db in
            try DuplicateSet.fetchAll(db, sql: """
                \(Self.latestCTE)
                SELECT e.name AS name, e.logicalSize AS logicalSize, COUNT(*) AS copies,
                       (COUNT(*) - 1) * e.logicalSize AS reclaimable,
                       COUNT(DISTINCT s.volumeId) AS driveCount,
                       GROUP_CONCAT(DISTINCT v.name) AS driveNames
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE e.isDir = 0 AND e.logicalSize > 0 AND e.snapshotId IN (SELECT id FROM latest)
                GROUP BY e.name, e.logicalSize
                HAVING COUNT(*) >= ? \(crossDriveOnly ? "AND COUNT(DISTINCT s.volumeId) >= 2" : "")
                ORDER BY reclaimable DESC, e.name COLLATE NOCASE
                LIMIT ?
                """, arguments: [minCopies, limit])
        }
    }

    /// Total bytes that could be reclaimed if every duplicate set kept one copy.
    public func totalReclaimable() async throws -> Int64 {
        try await db.writer.read { db in
            try Int64.fetchOne(db, sql: """
                \(Self.latestCTE)
                SELECT IFNULL(SUM((c - 1) * logicalSize), 0) FROM (
                    SELECT logicalSize, COUNT(*) AS c FROM entry
                    WHERE isDir = 0 AND logicalSize > 0 AND snapshotId IN (SELECT id FROM latest)
                    GROUP BY name, logicalSize HAVING COUNT(*) >= 2
                )
                """) ?? 0
        }
    }

    public func members(name: String, logicalSize: Int64) async throws -> [DuplicateMember] {
        try await db.writer.read { db in
            try DuplicateMember.fetchAll(db, sql: """
                \(Self.latestCTE)
                SELECT e.id AS entryId, e.snapshotId AS snapshotId, e.relPath AS relPath,
                       e.contentHash AS contentHash, e.modifiedAt AS modifiedAt,
                       v.id AS volumeId, v.uuid AS volumeUuid, v.name AS volumeName
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE e.isDir = 0 AND e.name = ? AND e.logicalSize = ?
                      AND e.snapshotId IN (SELECT id FROM latest)
                ORDER BY v.name COLLATE NOCASE, e.relPath
                """, arguments: [name, logicalSize])
        }
    }

    /// Caches a computed content hash so future verifications can skip the file.
    public func recordHash(entryId: Int64, hash: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE entry SET contentHash = ? WHERE id = ?", arguments: [hash, entryId])
        }
    }
}
