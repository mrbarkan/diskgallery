import Foundation

/// How well-protected an item is, by how many drives hold a copy.
public enum Coverage: String, Sendable, Equatable {
    case atRisk      // on a single drive — no backup
    case backedUp    // on two drives
    case protected   // on three or more
}

/// One drive's copy of a merged item. Pure value type — live connection state is
/// derived in the app layer, not here.
public struct UnifiedCopy: Sendable, Identifiable, Equatable {
    public var id: String { "\(volumeKey)|\(relPath)" }
    public var volumeKey: String
    public var volumeName: String
    public var relPath: String
    public var size: Int64
    public var modifiedAt: Date?
    public var contentHash: String?
    public var entryId: Int64
    public var snapshotId: Int64
    public var isReference: Bool
    public var isPartial: Bool
    public var matchesReference: Bool?

    public init(volumeKey: String, volumeName: String, relPath: String, size: Int64,
                modifiedAt: Date?, contentHash: String?, entryId: Int64, snapshotId: Int64,
                isReference: Bool = false, isPartial: Bool = false, matchesReference: Bool? = nil) {
        self.volumeKey = volumeKey
        self.volumeName = volumeName
        self.relPath = relPath
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.entryId = entryId
        self.snapshotId = snapshotId
        self.isReference = isReference
        self.isPartial = isPartial
        self.matchesReference = matchesReference
    }
}

/// A merged item across drives — one logical file/folder with its per-drive copies.
public struct UnifiedNode: Sendable, Identifiable, Equatable {
    /// Composite so a name that's a file on one drive and a folder on another stay distinct.
    public var id: String { "\(relPath)|\(isDir)" }
    public var relPath: String
    public var name: String
    public var isDir: Bool
    public var copies: [UnifiedCopy]
    public var referenceSize: Int64    // the reference copy's size (the "one disk" size)
    public var redundantSize: Int64    // Σ copy sizes − referenceSize (reclaimable if de-duped)
    public var driveCount: Int
    public var coverage: Coverage

    public init(relPath: String, name: String, isDir: Bool, copies: [UnifiedCopy],
                referenceSize: Int64, redundantSize: Int64, driveCount: Int, coverage: Coverage) {
        self.relPath = relPath
        self.name = name
        self.isDir = isDir
        self.copies = copies
        self.referenceSize = referenceSize
        self.redundantSize = redundantSize
        self.driveCount = driveCount
        self.coverage = coverage
    }
}

/// Headline coverage figures (top-level granularity) for the All Drives banner/badge.
public struct CoverageSummary: Sendable, Equatable {
    public var atRiskBytes: Int64
    public var atRiskCount: Int
    public var redundantBytes: Int64
    public var driveCount: Int

    public init(atRiskBytes: Int64, atRiskCount: Int, redundantBytes: Int64, driveCount: Int) {
        self.atRiskBytes = atRiskBytes
        self.atRiskCount = atRiskCount
        self.redundantBytes = redundantBytes
        self.driveCount = driveCount
    }

    public static let empty = CoverageSummary(atRiskBytes: 0, atRiskCount: 0, redundantBytes: 0, driveCount: 0)
}
