import Foundation
import GRDB

/// A drive's role assignment + priority, as the app reads it.
public struct DriveRoleAssignment: Sendable, Equatable {
    public var role: DriveRole
    public var priority: Int
    public init(role: DriveRole, priority: Int) {
        self.role = role
        self.priority = priority
    }
}

/// GRDB row backing a drive role. Keyed by the stable volume key (uuid ?? name).
struct DriveRoleRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "driveRole"
    var volumeKey: String
    var role: DriveRole
    var priority: Int
}

/// Reads and writes per-drive roles + priority. Mirrors `AnnotationStore`'s keying so
/// an assignment survives re-scanning the same drive. Pure persistence — the planner
/// consumes the values via `PlanDrive`.
public struct DriveRolesService: Sendable {
    let db: AppDatabase

    /// All assignments, keyed by volume key. Drives with no row are treated as `.neutral`.
    public func all() async throws -> [String: DriveRoleAssignment] {
        try await db.writer.read { db in
            let rows = try DriveRoleRecord.fetchAll(db)
            return Dictionary(rows.map { ($0.volumeKey, DriveRoleAssignment(role: $0.role, priority: $0.priority)) },
                              uniquingKeysWith: { first, _ in first })
        }
    }

    public func assignment(forKey key: String) async throws -> DriveRoleAssignment? {
        try await db.writer.read { db in
            try DriveRoleRecord.fetchOne(db, key: key)
                .map { DriveRoleAssignment(role: $0.role, priority: $0.priority) }
        }
    }

    /// Writes both role and priority in one upsert. Use this when the caller already
    /// knows the effective role (e.g. the boot disk's implicit `.localSystem`), so a
    /// priority change never resets the role to a default.
    public func set(role: DriveRole, priority: Int, forKey key: String) async throws {
        try await db.writer.write { db in
            try DriveRoleRecord(volumeKey: key, role: role, priority: priority).save(db)
        }
    }

    /// Sets the role, preserving any existing priority.
    public func setRole(_ role: DriveRole, forKey key: String) async throws {
        try await db.writer.write { db in
            var rec = try DriveRoleRecord.fetchOne(db, key: key)
                ?? DriveRoleRecord(volumeKey: key, role: .neutral, priority: 0)
            rec.role = role
            try rec.save(db)
        }
    }

    /// Sets the priority, preserving any existing role.
    public func setPriority(_ priority: Int, forKey key: String) async throws {
        try await db.writer.write { db in
            var rec = try DriveRoleRecord.fetchOne(db, key: key)
                ?? DriveRoleRecord(volumeKey: key, role: .neutral, priority: 0)
            rec.priority = priority
            try rec.save(db)
        }
    }

    public func clear(forKey key: String) async throws {
        try await db.writer.write { db in
            _ = try DriveRoleRecord.deleteOne(db, key: key)
        }
    }
}
