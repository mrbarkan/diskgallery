import Foundation
import GRDB

/// A drive in the library, paired with its most recent snapshot's summary.
public struct VolumeSummary: Codable, Sendable, Identifiable, FetchableRecord {
    public var id: Int64                 // volume id
    public var uuid: String?
    public var name: String
    public var latestSnapshotId: Int64?
    public var scannedAt: Date?
    public var totalCapacity: Int64?
    public var freeCapacity: Int64?
    public var fsType: String?
    public var fileCount: Int64?
    public var totalLogical: Int64?
    public var rootEntryId: Int64?
    public var latestSnapshotComplete: Bool?

    public init(id: Int64, uuid: String?, name: String, latestSnapshotId: Int64?,
                scannedAt: Date?, totalCapacity: Int64?, freeCapacity: Int64?,
                fsType: String?, fileCount: Int64?, totalLogical: Int64?,
                rootEntryId: Int64?, latestSnapshotComplete: Bool?) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.latestSnapshotId = latestSnapshotId
        self.scannedAt = scannedAt
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.fsType = fsType
        self.fileCount = fileCount
        self.totalLogical = totalLogical
        self.rootEntryId = rootEntryId
        self.latestSnapshotComplete = latestSnapshotComplete
    }
}

/// Read queries that power the library sidebar and the tree browser.
public struct LibraryService: Sendable {
    let db: AppDatabase

    private static let volumeSummarySQL = """
        SELECT v.id AS id, v.uuid AS uuid, v.name AS name,
               s.id AS latestSnapshotId, s.scannedAt AS scannedAt,
               s.totalCapacity AS totalCapacity, s.freeCapacity AS freeCapacity,
               s.fsType AS fsType, s.fileCount AS fileCount, s.totalLogical AS totalLogical,
               s.rootEntryId AS rootEntryId, s.isComplete AS latestSnapshotComplete
        FROM volume v
        LEFT JOIN snapshot s ON s.id = (
            SELECT id FROM snapshot s2 WHERE s2.volumeId = v.id
            ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
        )
        """

    public func volumes() async throws -> [VolumeSummary] {
        try await db.writer.read { db in
            try VolumeSummary.fetchAll(db, sql: Self.volumeSummarySQL + " ORDER BY v.name COLLATE NOCASE")
        }
    }

    public func volume(id: Int64) async throws -> VolumeSummary? {
        try await db.writer.read { db in
            try VolumeSummary.fetchOne(db, sql: Self.volumeSummarySQL + " WHERE v.id = ?", arguments: [id])
        }
    }

    /// Direct children of a folder, folders first then alphabetical.
    public func children(parentId: Int64, snapshotId: Int64) async throws -> [Entry] {
        try await db.writer.read { db in
            try Entry.fetchAll(db, sql: """
                SELECT * FROM entry
                WHERE snapshotId = ? AND parentId = ?
                ORDER BY isDir DESC, name COLLATE NOCASE
                """, arguments: [snapshotId, parentId])
        }
    }

    public func entry(id: Int64) async throws -> Entry? {
        try await db.writer.read { db in
            try Entry.fetchOne(db, key: id)
        }
    }

    public func rootEntry(snapshotId: Int64) async throws -> Entry? {
        try await db.writer.read { db in
            try Entry.fetchOne(db, sql: "SELECT * FROM entry WHERE snapshotId = ? AND parentId IS NULL", arguments: [snapshotId])
        }
    }

    public func deleteVolume(id: Int64) async throws {
        _ = try await db.writer.write { db in
            try Volume.deleteOne(db, key: id)
        }
    }

    public func deleteSnapshot(id: Int64) async throws {
        _ = try await db.writer.write { db in
            try Snapshot.deleteOne(db, key: id)
        }
    }
}
