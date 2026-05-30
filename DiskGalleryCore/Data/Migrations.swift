import Foundation
import GRDB

/// Defines the v1 schema. Column names match the Swift property names (camelCase)
/// so GRDB's Codable mapping needs no custom keys.
enum Migrations {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "volume") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("uuid", .text)
                t.column("name", .text).notNull()
                t.column("bookmark", .blob)
                t.column("createdAt", .datetime).notNull()
            }
            // One physical drive == one row. UUID is unique when present; name-keyed
            // drives (no UUID) coexist via the partial index.
            try db.execute(sql: "CREATE UNIQUE INDEX idx_volume_uuid ON volume(uuid) WHERE uuid IS NOT NULL")

            try db.create(table: "snapshot") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("volumeId", .integer).notNull()
                    .references("volume", onDelete: .cascade)
                t.column("scannedAt", .datetime).notNull()
                t.column("totalCapacity", .integer)
                t.column("freeCapacity", .integer)
                t.column("fsType", .text)
                t.column("rootEntryId", .integer)
                t.column("fileCount", .integer)
                t.column("totalLogical", .integer)
            }
            try db.create(index: "idx_snapshot_volume", on: "snapshot", columns: ["volumeId"])

            try db.create(table: "entry") { t in
                t.primaryKey("id", .integer)          // assigned explicitly during scan
                t.column("snapshotId", .integer).notNull()
                    .references("snapshot", onDelete: .cascade)
                t.column("parentId", .integer)
                t.column("name", .text).notNull()
                t.column("relPath", .text).notNull()
                t.column("isDir", .boolean).notNull()
                t.column("logicalSize", .integer).notNull().defaults(to: 0)
                t.column("allocSize", .integer).notNull().defaults(to: 0)
                t.column("subtreeLogicalSize", .integer)
                t.column("subtreeAllocSize", .integer)
                t.column("modifiedAt", .datetime)
                t.column("ext", .text)
                t.column("contentHash", .text)
            }
            try db.create(index: "idx_entry_snapshot", on: "entry", columns: ["snapshotId"])
            try db.create(index: "idx_entry_parent", on: "entry", columns: ["parentId"])
            // Duplicate detection (files only) — partial index stays small.
            try db.execute(sql: "CREATE INDEX idx_entry_dupe ON entry(name, logicalSize) WHERE isDir = 0")
            try db.execute(sql: "CREATE INDEX idx_entry_hash ON entry(contentHash) WHERE contentHash IS NOT NULL")

            try db.create(table: "annotation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("volumeUuid", .text).notNull()
                t.column("relPath", .text).notNull()
                t.column("tag", .integer).notNull()
                t.column("note", .text)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["volumeUuid", "relPath"])
            }
            try db.create(index: "idx_annotation_tag", on: "annotation", columns: ["tag"])

            // Full-text name search. GRDB generates the external-content sync triggers.
            try db.create(virtualTable: "entryFts", using: FTS5()) { t in
                t.synchronize(withTable: "entry")
                t.column("name")
            }
        }

        return migrator
    }
}
