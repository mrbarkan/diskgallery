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
    public var groupId: Int64?           // nil = ungrouped
    public var sortIndex: Int            // order within its group (or within ungrouped)
    public var hardware: DriveHardware?  // best-effort device facts (bus, medium, speed…)
    public var previewTypes: String?     // JSON-encoded [FileCategory]; nil = default (photos+raw)

    public init(id: Int64, uuid: String?, name: String, latestSnapshotId: Int64?,
                scannedAt: Date?, totalCapacity: Int64?, freeCapacity: Int64?,
                fsType: String?, fileCount: Int64?, totalLogical: Int64?,
                rootEntryId: Int64?, latestSnapshotComplete: Bool?,
                groupId: Int64? = nil, sortIndex: Int = 0, hardware: DriveHardware? = nil,
                previewTypes: String? = nil) {
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
        self.groupId = groupId
        self.sortIndex = sortIndex
        self.hardware = hardware
        self.previewTypes = previewTypes
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
               s.rootEntryId AS rootEntryId, s.isComplete AS latestSnapshotComplete,
               v.groupId AS groupId, v.sortIndex AS sortIndex, v.hardware AS hardware,
               v.previewTypes AS previewTypes
        FROM volume v
        LEFT JOIN snapshot s ON s.id = (
            SELECT id FROM snapshot s2 WHERE s2.volumeId = v.id
            ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
        )
        LEFT JOIN driveGroup g ON g.id = v.groupId
        """

    /// User-defined manual order: named groups first (by the group's order), then ungrouped,
    /// drives ordered within each by their `sortIndex`; name breaks ties for stability.
    private static let volumeOrderSQL = """
         ORDER BY CASE WHEN v.groupId IS NULL THEN 1 ELSE 0 END,
                  g.sortIndex, v.sortIndex, v.name COLLATE NOCASE
        """

    public func volumes() async throws -> [VolumeSummary] {
        try await db.writer.read { db in
            try VolumeSummary.fetchAll(db, sql: Self.volumeSummarySQL + Self.volumeOrderSQL)
        }
    }

    // MARK: Groups & ordering

    public func groups() async throws -> [DriveGroup] {
        try await db.writer.read { db in
            try DriveGroup.fetchAll(db, sql: "SELECT * FROM driveGroup ORDER BY sortIndex, id")
        }
    }

    @discardableResult
    public func createGroup(name: String) async throws -> DriveGroup {
        try await db.writer.write { db in
            let next = try Int.fetchOne(db, sql: "SELECT IFNULL(MAX(sortIndex), -1) + 1 FROM driveGroup") ?? 0
            var group = DriveGroup(name: name, sortIndex: next)
            try group.insert(db)
            return group
        }
    }

    public func renameGroup(id: Int64, name: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE driveGroup SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func setGroupCollapsed(id: Int64, collapsed: Bool) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE driveGroup SET isCollapsed = ? WHERE id = ?", arguments: [collapsed, id])
        }
    }

    /// Deletes a group; its drives move to the end of ungrouped, keeping their relative order.
    public func deleteGroup(id: Int64) async throws {
        try await db.writer.write { db in
            let members = try Int64.fetchAll(db, sql:
                "SELECT id FROM volume WHERE groupId = ? ORDER BY sortIndex, name COLLATE NOCASE",
                arguments: [id])
            var next = try Int.fetchOne(db,
                sql: "SELECT IFNULL(MAX(sortIndex), -1) + 1 FROM volume WHERE groupId IS NULL") ?? 0
            for vid in members {
                try db.execute(sql: "UPDATE volume SET groupId = NULL, sortIndex = ? WHERE id = ?",
                               arguments: [next, vid])
                next += 1
            }
            try DriveGroup.deleteOne(db, key: id)
        }
    }

    public func reorderGroups(orderedIds: [Int64]) async throws {
        try await db.writer.write { db in
            for (index, gid) in orderedIds.enumerated() {
                try db.execute(sql: "UPDATE driveGroup SET sortIndex = ? WHERE id = ?",
                               arguments: [index, gid])
            }
        }
    }

    /// The single primitive for both move and reorder: assigns each listed drive to `groupId`
    /// (nil = ungrouped) and sets its `sortIndex` to its position in the list.
    public func reorderDrives(orderedVolumeIds: [Int64], inGroup groupId: Int64?) async throws {
        try await db.writer.write { db in
            for (index, vid) in orderedVolumeIds.enumerated() {
                try db.execute(sql: "UPDATE volume SET groupId = ?, sortIndex = ? WHERE id = ?",
                               arguments: [groupId, index, vid])
            }
        }
    }

    public func updateHardware(volumeId: Int64, hardware: DriveHardware) async throws {
        try await db.writer.write { db in
            guard var volume = try Volume.fetchOne(db, key: volumeId) else { return }
            guard volume.hardware != hardware else { return }
            volume.hardware = hardware
            try volume.update(db, columns: ["hardware"])
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

    /// Updates the JSON-encoded preview-type selection for a drive (nil resets to default).
    public func setPreviewTypes(_ json: String?, volumeId: Int64) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE volume SET previewTypes = ? WHERE id = ?", arguments: [json, volumeId])
        }
    }
}
