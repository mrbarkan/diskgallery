import Foundation
import GRDB

/// One displayable file in the Gallery contact sheet, carrying its owning drive's provenance.
/// A read-projection (not a table record): decoded from the gallery query's columns.
public struct GalleryEntry: Codable, Sendable, Identifiable, FetchableRecord {
    public var id: Int64            // entry id (stable within its snapshot)
    public var name: String
    public var relPath: String
    public var ext: String?
    public var logicalSize: Int64
    public var modifiedAt: Date?
    public var volumeId: Int64
    public var volumeUuid: String?
    public var volumeName: String

    /// The annotation/thumbnail key for this file's drive (uuid when known, else name) —
    /// matches how Stage A keyed thumbnails and how annotations are keyed.
    public var volumeKey: String { volumeUuid ?? volumeName }
}

/// Read query powering the Gallery: a flat, cross-drive list of media files drawn from each
/// volume's latest COMPLETE snapshot. Strictly read-only.
public struct GalleryService: Sendable {
    let db: AppDatabase

    /// Media files across drives' latest complete snapshots, ordered drive-name then path.
    /// `categories` selects file types (empty extension set → no rows). `volumeId` (when set)
    /// restricts to one drive.
    public func items(categories: [FileCategory], volumeId: Int64? = nil,
                      limit: Int = 2000, hideHidden: Bool = false) async throws -> [GalleryEntry] {
        let exts = FileCategory.extensions(for: categories)
        guard !exts.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: exts.count).joined(separator: ",")
        let volumeClause: String
        let volumeArg: Int64?
        if let volumeId {
            volumeClause = "AND v.id = ?"
            volumeArg = volumeId
        } else {
            volumeClause = ""
            volumeArg = nil
        }
        let hiddenClause = hideHidden ? "AND e.relPath NOT LIKE '.%' AND e.relPath NOT LIKE '%/.%'" : ""
        let extArgs = exts.map { $0 as DatabaseValueConvertible }
        let sqlArgs: StatementArguments = {
            var a: [DatabaseValueConvertible] = extArgs
            if let v = volumeArg { a.append(v) }
            a.append(limit)
            return StatementArguments(a)
        }()
        return try await db.writer.read { db in
            try GalleryEntry.fetchAll(db, sql: """
                SELECT e.id AS id, e.name AS name, e.relPath AS relPath, e.ext AS ext,
                       e.logicalSize AS logicalSize, e.modifiedAt AS modifiedAt,
                       v.id AS volumeId, v.uuid AS volumeUuid, v.name AS volumeName
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE s.isComplete = 1
                  AND s.id = (SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId AND s2.isComplete = 1
                              ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1)
                  AND e.isDir = 0
                  AND LOWER(e.ext) IN (\(placeholders))
                  \(volumeClause)
                  \(hiddenClause)
                ORDER BY v.name COLLATE NOCASE, e.relPath
                LIMIT ?
                """, arguments: sqlArgs)
        }
    }
}
