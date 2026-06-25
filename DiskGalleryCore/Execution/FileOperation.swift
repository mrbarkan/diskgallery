import Foundation
import GRDB

/// What an operation does. Raw values are stable (persisted). Stage 1 uses `.copy`.
public enum OpType: String, Codable, Sendable { case copy, move, delete }

/// Lifecycle of one operation. `verified` is a transient between a confirmed copy and
/// its commit; `done`/`failed`/`skipped` are terminal and become history.
public enum OpStatus: String, Codable, Sendable {
    case pending, running, verified, done, failed, skipped
}

/// One file operation, materialized from the Organize plan and tracked through
/// execution so a run is resumable and auditable. Keyed by the stable volume key
/// (`uuid ?? name`), like annotations — survives re-scans and reconnects.
public struct FileOperation: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "operation"

    public var id: Int64?
    public var type: OpType
    public var sourceVolumeKey: String
    public var sourceRelPath: String
    public var destVolumeKey: String?
    public var destRelPath: String?
    public var bytes: Int64
    public var sourceHash: String?
    public var destHash: String?
    public var status: OpStatus
    public var failureReason: String?
    public var skipReason: String?
    public var dependsOn: Int64?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: Int64? = nil, type: OpType, sourceVolumeKey: String, sourceRelPath: String,
                destVolumeKey: String? = nil, destRelPath: String? = nil, bytes: Int64,
                sourceHash: String? = nil, destHash: String? = nil, status: OpStatus,
                failureReason: String? = nil, skipReason: String? = nil, dependsOn: Int64? = nil,
                createdAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.sourceVolumeKey = sourceVolumeKey
        self.sourceRelPath = sourceRelPath
        self.destVolumeKey = destVolumeKey
        self.destRelPath = destRelPath
        self.bytes = bytes
        self.sourceHash = sourceHash
        self.destHash = destHash
        self.status = status
        self.failureReason = failureReason
        self.skipReason = skipReason
        self.dependsOn = dependsOn
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
