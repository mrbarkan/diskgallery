import Foundation
import GRDB

/// An annotated path, resolved against the latest snapshot of its volume when one
/// exists (so the list can show the file's current name/size).
public struct TaggedEntry: Codable, Sendable, Identifiable, FetchableRecord {
    public var annotationId: Int64
    public var volumeUuid: String
    public var volumeName: String?
    public var relPath: String
    public var tag: Tag
    public var note: String?
    public var name: String?
    public var isDir: Bool?
    public var logicalSize: Int64?
    public var subtreeLogicalSize: Int64?
    public var entryId: Int64?
    public var snapshotId: Int64?

    public var id: Int64 { annotationId }
    public var displayName: String { name ?? (relPath as NSString).lastPathComponent }
    public var displaySize: Int64? { (isDir == true) ? subtreeLogicalSize : logicalSize }
}

/// Reads and writes Keep/Delete/Review annotations. Keyed by `(volumeKey, relPath)`
/// where `volumeKey` is the volume UUID, or its name when no UUID exists — so an
/// annotation survives re-scanning the same drive.
public struct AnnotationStore: Sendable {
    let db: AppDatabase

    /// The stable per-drive key used for annotations.
    public static func volumeKey(uuid: String?, name: String) -> String {
        uuid ?? name
    }

    public func annotation(volumeKey: String, relPath: String) async throws -> Annotation? {
        try await db.writer.read { db in
            try Annotation
                .filter(Column("volumeUuid") == volumeKey && Column("relPath") == relPath)
                .fetchOne(db)
        }
    }

    /// Upserts an annotation. Clearing it (tag `.none` + empty note) deletes the row.
    public func set(tag: Tag, note: String?, volumeKey: String, relPath: String) async throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try await db.writer.write { db in
            if tag == .none && cleanNote == nil {
                try db.execute(sql: "DELETE FROM annotation WHERE volumeUuid = ? AND relPath = ?",
                               arguments: [volumeKey, relPath])
                return
            }
            if var existing = try Annotation
                .filter(Column("volumeUuid") == volumeKey && Column("relPath") == relPath)
                .fetchOne(db)
            {
                existing.tag = tag
                existing.note = cleanNote
                existing.updatedAt = Date()
                try existing.update(db)
            } else {
                var created = Annotation(volumeUuid: volumeKey, relPath: relPath,
                                         tag: tag, note: cleanNote, updatedAt: Date())
                try created.insert(db)
            }
        }
    }

    public func taggedEntries(_ tag: Tag) async throws -> [TaggedEntry] {
        try await db.writer.read { db in
            try TaggedEntry.fetchAll(db, sql: """
                WITH latest AS (
                    SELECT s.id, s.volumeId FROM snapshot s
                    WHERE s.id = (
                        SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                        ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
                    )
                )
                SELECT a.id AS annotationId, a.volumeUuid AS volumeUuid, v.name AS volumeName,
                       a.relPath AS relPath, a.tag AS tag, a.note AS note,
                       e.name AS name, e.isDir AS isDir, e.logicalSize AS logicalSize,
                       e.subtreeLogicalSize AS subtreeLogicalSize,
                       e.id AS entryId, e.snapshotId AS snapshotId
                FROM annotation a
                LEFT JOIN volume v
                    ON (v.uuid = a.volumeUuid OR (v.uuid IS NULL AND v.name = a.volumeUuid))
                LEFT JOIN latest l ON l.volumeId = v.id
                LEFT JOIN entry e ON e.snapshotId = l.id AND e.relPath = a.relPath
                WHERE a.tag = ?
                ORDER BY v.name COLLATE NOCASE, a.relPath COLLATE NOCASE
                """, arguments: [tag.rawValue])
        }
    }

    /// Tags for a set of paths on one drive, for decorating browser rows in one query.
    public func tags(volumeKey: String, relPaths: [String]) async throws -> [String: Tag] {
        guard !relPaths.isEmpty else { return [:] }
        return try await db.writer.read { db in
            let rows = try Annotation
                .filter(Column("volumeUuid") == volumeKey && relPaths.contains(Column("relPath")))
                .fetchAll(db)
            return Dictionary(rows.map { ($0.relPath, $0.tag) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Counts per tag, for sidebar badges. Returns a map keyed by tag.
    public func counts() async throws -> [Tag: Int] {
        try await db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT tag, COUNT(*) AS c FROM annotation GROUP BY tag")
            var result: [Tag: Int] = [:]
            for row in rows {
                if let tag = Tag(rawValue: row["tag"]) { result[tag] = row["c"] }
            }
            return result
        }
    }
}
