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
    public var color: FinderColor
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

/// Reads and writes Keep/Delete/Review decisions and Finder colors. Keyed by
/// `(volumeKey, relPath)` where `volumeKey` is the volume UUID, or its name when no
/// UUID exists — so an annotation survives re-scanning the same drive.
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

    /// Annotations for many paths on one drive, for decorating browser rows.
    public func annotations(volumeKey: String, relPaths: [String]) async throws -> [String: Annotation] {
        guard !relPaths.isEmpty else { return [:] }
        return try await db.writer.read { db in
            let rows = try Annotation
                .filter(Column("volumeUuid") == volumeKey && relPaths.contains(Column("relPath")))
                .fetchAll(db)
            return Dictionary(rows.map { ($0.relPath, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    // MARK: Granular setters (each preserves the other dimensions)

    @discardableResult
    public func setDecision(_ tag: Tag, volumeKey: String, relPath: String) async throws -> Annotation? {
        try await upsert(volumeKey: volumeKey, relPath: relPath) { $0.tag = tag }
    }

    @discardableResult
    public func setColor(_ color: FinderColor, volumeKey: String, relPath: String) async throws -> Annotation? {
        try await upsert(volumeKey: volumeKey, relPath: relPath) { $0.color = color }
    }

    @discardableResult
    public func setNote(_ note: String?, volumeKey: String, relPath: String) async throws -> Annotation? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return try await upsert(volumeKey: volumeKey, relPath: relPath) { $0.note = clean }
    }

    /// Sets all dimensions at once (used by the detail editor's Save).
    @discardableResult
    public func set(tag: Tag, color: FinderColor, note: String?,
                    volumeKey: String, relPath: String) async throws -> Annotation? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = (trimmed?.isEmpty ?? true) ? nil : trimmed
        return try await upsert(volumeKey: volumeKey, relPath: relPath) {
            $0.tag = tag; $0.color = color; $0.note = clean
        }
    }

    /// Read-modify-write in one transaction. Deletes the row when it ends up empty;
    /// returns the saved annotation, or nil if it was cleared.
    private func upsert(volumeKey: String, relPath: String,
                        _ mutate: @Sendable @escaping (inout Annotation) -> Void) async throws -> Annotation? {
        try await db.writer.write { db in
            var annotation = try Annotation
                .filter(Column("volumeUuid") == volumeKey && Column("relPath") == relPath)
                .fetchOne(db)
                ?? Annotation(volumeUuid: volumeKey, relPath: relPath, tag: .none, color: .none,
                              note: nil, updatedAt: Date())
            mutate(&annotation)
            annotation.updatedAt = Date()

            let isEmpty = annotation.tag == .none && annotation.color == .none && (annotation.note?.isEmpty ?? true)
            if isEmpty {
                if let id = annotation.id { _ = try Annotation.deleteOne(db, key: id) }
                return nil
            }
            try annotation.save(db)
            return annotation
        }
    }

    // MARK: Lists & counts

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
                       a.relPath AS relPath, a.tag AS tag, a.color AS color, a.note AS note,
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

    /// Counts per decision tag, for sidebar badges.
    public func counts() async throws -> [Tag: Int] {
        try await db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT tag, COUNT(*) AS c FROM annotation WHERE tag != 0 GROUP BY tag")
            var result: [Tag: Int] = [:]
            for row in rows {
                if let tag = Tag(rawValue: row["tag"]) { result[tag] = row["c"] }
            }
            return result
        }
    }
}
