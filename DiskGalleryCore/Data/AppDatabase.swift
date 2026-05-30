import Foundation
import GRDB

/// Owns the SQLite connection (a WAL `DatabasePool`) and runs migrations.
/// Fully encapsulates GRDB so the app target never imports it.
final class AppDatabase: Sendable {
    let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Migrations.makeMigrator().migrate(writer)
    }

    /// Tuned for fast bulk inserts. WAL is implied by `DatabasePool`.
    static func makePool(at url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = -20000")   // ~20 MB page cache
        }
        return try DatabasePool(path: url.path, configuration: config)
    }

    /// `~/Library/Application Support/DiskGallery/catalog.sqlite`. Creating this
    /// directory writes only inside the app's own container — never a scanned drive.
    static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("DiskGallery", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.sqlite")
    }
}
