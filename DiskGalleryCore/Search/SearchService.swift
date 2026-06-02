import Foundation
import GRDB

public enum SearchScope: Sendable, Equatable {
    case all
    case volumeLatest(Int64)   // a volume id; searches its most recent snapshot
    case snapshot(Int64)
}

/// A content predicate layered on top of a search, independent of the volume `scope`.
public enum SearchFilter: Sendable, Equatable {
    case none
    case category(FileCategory)   // post-filtered in Swift by extension
    case tagged(Tag)              // entry has this decision tag
    case duplicatesOnly           // (name, logicalSize) appears 2+ times in the latest snapshots
}

public struct SearchResult: Codable, Sendable, Identifiable, FetchableRecord {
    public var entryId: Int64
    public var snapshotId: Int64
    public var name: String
    public var relPath: String
    public var isDir: Bool
    public var logicalSize: Int64
    public var subtreeLogicalSize: Int64?
    public var volumeName: String
    public var volumeUuid: String?

    public var id: Int64 { entryId }
    public var displaySize: Int64 { isDir ? (subtreeLogicalSize ?? 0) : logicalSize }
}

/// Full-text name search across the library via SQLite FTS5.
public struct SearchService: Sendable {
    let db: AppDatabase

    /// Turns raw user input into a safe FTS5 prefix query. Each token is quoted
    /// (so punctuation can't inject FTS operators) and prefix-matched. Returns nil
    /// when there's nothing to search.
    static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    public func search(_ query: String, scope: SearchScope = .all,
                       filter: SearchFilter = .none, limit: Int = 1000) async throws -> [SearchResult] {
        let match = Self.ftsQuery(query)
        if match == nil && filter == .none { return [] }

        let latestCTE = """
            WITH latest AS (
                SELECT s.id FROM snapshot s
                WHERE s.id = (
                    SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                    ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
                )
            )
            """

        let selectCols = """
            SELECT e.id AS entryId, e.snapshotId AS snapshotId, e.name AS name, e.relPath AS relPath,
                   e.isDir AS isDir, e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize,
                   v.name AS volumeName, v.uuid AS volumeUuid
            """

        var arguments: [(any DatabaseValueConvertible)?] = []
        var sql: String

        if let match {
            sql = """
                \(selectCols)
                FROM entryFts
                JOIN entry e ON e.id = entryFts.rowid
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE entryFts MATCH ?
                """
            arguments.append(match)
        } else {
            sql = """
                \(latestCTE)
                \(selectCols)
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                WHERE e.snapshotId IN (SELECT id FROM latest)
                """
        }

        switch scope {
        case .all:
            break
        case .snapshot(let snapshotId):
            sql += " AND e.snapshotId = ?"
            arguments.append(snapshotId)
        case .volumeLatest(let volumeId):
            sql += """
                 AND e.snapshotId = (
                    SELECT id FROM snapshot WHERE volumeId = ? ORDER BY scannedAt DESC, id DESC LIMIT 1
                )
                """
            arguments.append(volumeId)
        }

        switch filter {
        case .none, .category:
            break
        case .tagged(let tag):
            sql += """
                 AND EXISTS (
                    SELECT 1 FROM annotation a
                    WHERE a.relPath = e.relPath
                      AND (a.volumeUuid = v.uuid OR (v.uuid IS NULL AND a.volumeUuid = v.name))
                      AND a.tag = ?
                )
                """
            arguments.append(tag.rawValue)
        case .duplicatesOnly:
            if match != nil { sql = latestCTE + "\n" + sql }
            sql += """
                 AND e.isDir = 0 AND (
                    SELECT COUNT(*) FROM entry e2
                    WHERE e2.name = e.name AND e2.logicalSize = e.logicalSize
                      AND e2.isDir = 0 AND e2.snapshotId IN (SELECT id FROM latest)
                ) >= 2
                """
        }

        sql += " ORDER BY e.isDir DESC, e.name COLLATE NOCASE LIMIT ?"
        arguments.append(limit)

        let finalSQL = sql
        let statementArguments = StatementArguments(arguments)
        var results = try await db.writer.read { db in
            try SearchResult.fetchAll(db, sql: finalSQL, arguments: statementArguments)
        }

        if case .category(let category) = filter, category != .all {
            results = results.filter { category.matches(filename: $0.name) }
        }
        return results
    }
}
