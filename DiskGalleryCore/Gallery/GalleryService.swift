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

/// One subfolder tile in the Gallery's folder drill-down, with how many matching media
/// files live anywhere beneath it.
public struct GalleryFolder: Sendable, Identifiable, Hashable {
    public var relPath: String
    public var name: String
    public var mediaCount: Int
    public var id: String { relPath }
}

/// Read query powering the Gallery: a flat, cross-drive list of media files drawn from each
/// volume's latest COMPLETE snapshot. Strictly read-only.
public struct GalleryService: Sendable {
    let db: AppDatabase

    /// Media files across drives' latest complete snapshots, ordered drive-name then path.
    /// `categories` selects file types (empty extension set → no rows). `volumeId` (when set)
    /// restricts to one drive.
    /// `directOnly` (folder drill-down) restricts to the folder's own files rather than its
    /// whole subtree; with `underRelPath` nil/empty it means the volume root.
    public func items(categories: [FileCategory], volumeId: Int64? = nil,
                      limit: Int = 2000, hideHidden: Bool = false,
                      underRelPath: String? = nil, directOnly: Bool = false) async throws -> [GalleryEntry] {
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
        let folder = underRelPath.flatMap { $0.isEmpty ? nil : $0 }   // Detail Scan folder scope
        // `directOnly`: direct children only — no further "/" after the folder prefix.
        let folderClause = (folder != nil ? "AND e.relPath LIKE ? ESCAPE '\\'" : "")
            + (directOnly ? (folder != nil ? " AND e.relPath NOT LIKE ? ESCAPE '\\'" : " AND e.relPath NOT LIKE '%/%'") : "")
        let extArgs = exts.map { $0 as DatabaseValueConvertible }
        let sqlArgs: StatementArguments = {
            var a: [DatabaseValueConvertible] = extArgs
            if let v = volumeArg { a.append(v) }
            if let folder {
                a.append(SQLPattern.childrenPrefix(of: folder))
                if directOnly { a.append(SQLPattern.childrenPrefix(of: folder) + "/%") }
            }
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
                  \(folderClause)
                ORDER BY v.name COLLATE NOCASE, e.relPath
                LIMIT ?
                """, arguments: sqlArgs)
        }
    }

    /// Direct subfolders of `underRelPath` ("" / nil = volume root) in the volume's latest
    /// complete snapshot, each with the number of `categories` files anywhere beneath it.
    /// One aggregate pass over the subtree's media rows, grouped by the next path component.
    public func folders(volumeId: Int64, underRelPath: String?, categories: [FileCategory],
                        hideHidden: Bool = false) async throws -> [GalleryFolder] {
        let folder = underRelPath.flatMap { $0.isEmpty ? nil : $0 }
        let childStart = (folder.map { $0.utf8.count + 1 } ?? 0) + 1   // 1-based, after "folder/"
        let hiddenClause = hideHidden ? "AND e.name NOT LIKE '.%'" : ""
        let exts = FileCategory.extensions(for: categories)
        let placeholders = Array(repeating: "?", count: max(exts.count, 1)).joined(separator: ",")
        let snapshotSQL = """
            (SELECT id FROM snapshot WHERE volumeId = ? AND isComplete = 1
             ORDER BY scannedAt DESC, id DESC LIMIT 1)
            """
        let scopeClause = folder != nil
            ? "AND e.relPath LIKE ? ESCAPE '\\' AND e.relPath NOT LIKE ? ESCAPE '\\'"
            : "AND e.relPath NOT LIKE '%/%'"
        var dirValues: [DatabaseValueConvertible] = [volumeId]
        if let folder { dirValues += [SQLPattern.childrenPrefix(of: folder), SQLPattern.childrenPrefix(of: folder) + "/%"] }
        let dirArgs: StatementArguments = StatementArguments(dirValues)
        let countClause = folder != nil ? "AND e.relPath LIKE ? ESCAPE '\\'" : ""
        var countValues: [DatabaseValueConvertible] = [childStart, childStart, childStart, volumeId]
        countValues += exts.isEmpty ? [""] : exts.map { $0 as DatabaseValueConvertible }
        if let folder { countValues.append(SQLPattern.childrenPrefix(of: folder)) }
        let countArgs: StatementArguments = StatementArguments(countValues)
        return try await db.writer.read { db in
            let dirs = try Row.fetchAll(db, sql: """
                SELECT e.relPath AS relPath, e.name AS name FROM entry e
                WHERE e.snapshotId = \(snapshotSQL) AND e.isDir = 1 \(scopeClause) \(hiddenClause)
                ORDER BY e.name COLLATE NOCASE
                """, arguments: dirArgs)
            let counts = try Row.fetchAll(db, sql: """
                SELECT substr(e.relPath, ?, instr(substr(e.relPath, ?), '/') - 1) AS child, COUNT(*) AS n
                FROM entry e
                WHERE instr(substr(e.relPath, ?), '/') > 0
                  AND e.snapshotId = \(snapshotSQL)
                  AND e.isDir = 0 AND LOWER(e.ext) IN (\(placeholders))
                  \(countClause)
                GROUP BY child
                """, arguments: countArgs)
            var byChild: [String: Int] = [:]
            for row in counts { byChild[row["child"]] = row["n"] }
            return dirs.map { row in
                let name: String = row["name"]
                return GalleryFolder(relPath: row["relPath"], name: name, mediaCount: byChild[name] ?? 0)
            }
        }
    }
}
