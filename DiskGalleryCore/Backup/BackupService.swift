import Foundation
import GRDB

/// Exports and restores the whole catalog (drives, snapshots, tags, notes) as one
/// portable `.diskgallery` file the user can stash in iCloud/Dropbox or move between
/// Macs. Uses SQLite's online-backup API so the live database stays open and valid.
public struct BackupService: Sendable {
    let db: AppDatabase

    public enum BackupError: Error, Sendable, LocalizedError {
        case notACatalog

        public var errorDescription: String? {
            switch self {
            case .notACatalog: return "That file isn’t a DiskGallery backup."
            }
        }
    }

    /// The recommended file extension for backups.
    public static let fileExtension = "diskgallery"

    /// Writes a consistent, standalone copy of the catalog to `destination`.
    public func export(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: sidecar(destination, "-wal"))
        try? FileManager.default.removeItem(at: sidecar(destination, "-shm"))
        let dest = try DatabaseQueue(path: destination.path)   // fresh, empty
        try db.writer.backup(to: dest)
    }

    /// Replaces the live catalog's contents with those from `source` (overwriting in
    /// place), then re-runs migrations so an older backup is upgraded to the current
    /// schema. The caller should take a safety copy first via `export(to:)`.
    public func restore(from source: URL) throws {
        let src = try DatabaseQueue(path: source.path)
        let looksValid = try src.read { db in
            try Bool.fetchOne(db, sql:
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='volume'") ?? false
        }
        guard looksValid else { throw BackupError.notACatalog }

        try src.backup(to: db.writer)                          // overwrite live DB
        try Migrations.makeMigrator().migrate(db.writer)       // upgrade if needed
    }

    private func sidecar(_ url: URL, _ suffix: String) -> URL {
        URL(fileURLWithPath: url.path + suffix)
    }
}
