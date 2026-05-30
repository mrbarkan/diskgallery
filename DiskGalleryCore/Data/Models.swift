import Foundation
import GRDB

/// A keep/delete decision a user attaches to a file or folder.
public enum Tag: Int, Codable, Sendable, CaseIterable, Identifiable {
    case none = 0
    case keep = 1
    case delete = 2
    case review = 3

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .none: return "None"
        case .keep: return "Keep"
        case .delete: return "Delete"
        case .review: return "Review"
        }
    }

    /// Finder color code used when this decision is written as a Finder tag.
    public var finderColorCode: Int {
        switch self {
        case .none: return 0
        case .keep: return FinderColor.green.rawValue
        case .delete: return FinderColor.red.rawValue
        case .review: return FinderColor.yellow.rawValue
        }
    }
}

/// A macOS Finder color. Raw values are Finder's internal color codes (the number
/// after the newline in `_kMDItemUserTags`).
public enum FinderColor: Int, Codable, Sendable, CaseIterable, Identifiable {
    case none = 0
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    public var id: Int { rawValue }

    /// The standard Finder tag name for this color.
    public var tagName: String {
        switch self {
        case .none: return ""
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

    /// Finder's visible top-to-bottom order — what number keys 1…7 map to.
    public static let keyOrder: [FinderColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]
}

/// A physical drive, identified by volume UUID (falling back to name when the
/// filesystem exposes no UUID, e.g. some exFAT volumes).
public struct Volume: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "volume"

    public var id: Int64?
    public var uuid: String?
    public var name: String
    public var bookmark: Data?          // reserved for a future sandboxed build
    public var createdAt: Date

    public init(id: Int64? = nil, uuid: String?, name: String, bookmark: Data? = nil, createdAt: Date) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.bookmark = bookmark
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One catalog capture of a volume at a point in time.
public struct Snapshot: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "snapshot"

    public var id: Int64?
    public var volumeId: Int64
    public var scannedAt: Date
    public var totalCapacity: Int64?
    public var freeCapacity: Int64?
    public var fsType: String?
    public var rootEntryId: Int64?
    public var fileCount: Int64?
    public var totalLogical: Int64?
    public var isComplete: Bool          // false while a scan is in progress / paused

    public init(id: Int64? = nil, volumeId: Int64, scannedAt: Date,
                totalCapacity: Int64? = nil, freeCapacity: Int64? = nil, fsType: String? = nil,
                rootEntryId: Int64? = nil, fileCount: Int64? = nil, totalLogical: Int64? = nil,
                isComplete: Bool = true) {
        self.id = id
        self.volumeId = volumeId
        self.scannedAt = scannedAt
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.fsType = fsType
        self.rootEntryId = rootEntryId
        self.fileCount = fileCount
        self.totalLogical = totalLogical
        self.isComplete = isComplete
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A directory still waiting to be expanded during a (possibly paused) scan. The
/// presence of rows for a snapshot means that scan is resumable.
struct PendingDir: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "pendingDir"
    var id: Int64?
    var snapshotId: Int64
    var entryId: Int64
    var relPath: String

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A single file or folder within a snapshot. Folder sizes are pre-computed and
/// stored in `subtreeLogicalSize` / `subtreeAllocSize` so browsing is instant
/// while the drive is disconnected.
public struct Entry: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "entry"

    public var id: Int64                 // assigned explicitly during a scan
    public var snapshotId: Int64
    public var parentId: Int64?
    public var name: String
    public var relPath: String           // path relative to volume root = stable identity
    public var isDir: Bool
    public var logicalSize: Int64
    public var allocSize: Int64
    public var subtreeLogicalSize: Int64?
    public var subtreeAllocSize: Int64?
    public var modifiedAt: Date?
    public var ext: String?
    public var contentHash: String?

    public init(id: Int64, snapshotId: Int64, parentId: Int64?, name: String, relPath: String,
                isDir: Bool, logicalSize: Int64, allocSize: Int64,
                subtreeLogicalSize: Int64? = nil, subtreeAllocSize: Int64? = nil,
                modifiedAt: Date? = nil, ext: String? = nil, contentHash: String? = nil) {
        self.id = id
        self.snapshotId = snapshotId
        self.parentId = parentId
        self.name = name
        self.relPath = relPath
        self.isDir = isDir
        self.logicalSize = logicalSize
        self.allocSize = allocSize
        self.subtreeLogicalSize = subtreeLogicalSize
        self.subtreeAllocSize = subtreeAllocSize
        self.modifiedAt = modifiedAt
        self.ext = ext
        self.contentHash = contentHash
    }

    /// Size to display: a folder's stored subtree total, or a file's own size.
    public var displaySize: Int64 {
        isDir ? (subtreeLogicalSize ?? 0) : logicalSize
    }
}

/// A keep/delete annotation, keyed to (volume UUID, relative path) so it survives
/// re-scanning the same drive (which produces a brand-new snapshot + entry rows).
public struct Annotation: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "annotation"

    public var id: Int64?
    public var volumeUuid: String        // falls back to volume name when no UUID
    public var relPath: String
    public var tag: Tag
    public var color: FinderColor
    public var note: String?
    public var updatedAt: Date

    public init(id: Int64? = nil, volumeUuid: String, relPath: String, tag: Tag,
                color: FinderColor = .none, note: String?, updatedAt: Date) {
        self.id = id
        self.volumeUuid = volumeUuid
        self.relPath = relPath
        self.tag = tag
        self.color = color
        self.note = note
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
