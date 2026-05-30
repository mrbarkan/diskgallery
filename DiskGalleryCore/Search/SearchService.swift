import Foundation
import GRDB

public enum SearchScope: Sendable, Equatable {
    case all
    case volumeLatest(Int64)   // a volume id; searches its most recent snapshot
    case snapshot(Int64)
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

    public func search(_ query: String, scope: SearchScope = .all, limit: Int = 1000) async throws -> [SearchResult] {
        guard let match = Self.ftsQuery(query) else { return [] }

        var sql = """
            SELECT e.id AS entryId, e.snapshotId AS snapshotId, e.name AS name, e.relPath AS relPath,
                   e.isDir AS isDir, e.logicalSize AS logicalSize, e.subtreeLogicalSize AS subtreeLogicalSize,
                   v.name AS volumeName
            FROM entryFts
            JOIN entry e ON e.id = entryFts.rowid
            JOIN snapshot s ON s.id = e.snapshotId
            JOIN volume v ON v.id = s.volumeId
            WHERE entryFts MATCH ?
            """
        var arguments: [(any DatabaseValueConvertible)?] = [match]

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

        sql += " ORDER BY e.isDir DESC, e.name COLLATE NOCASE LIMIT ?"
        arguments.append(limit)

        let finalSQL = sql
        let statementArguments = StatementArguments(arguments)
        return try await db.writer.read { db in
            try SearchResult.fetchAll(db, sql: finalSQL, arguments: statementArguments)
        }
    }
}
