import Foundation

/// Live progress emitted while a scan runs. The final value has `isComplete == true`
/// and carries the new `snapshotId`.
public struct ScanProgress: Sendable {
    public var filesSeen: Int
    public var bytesSeen: Int64
    public var currentPath: String
    public var unreadableCount: Int
    public var isComplete: Bool
    public var snapshotId: Int64?

    public init(filesSeen: Int = 0, bytesSeen: Int64 = 0, currentPath: String = "",
                unreadableCount: Int = 0, isComplete: Bool = false, snapshotId: Int64? = nil) {
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.currentPath = currentPath
        self.unreadableCount = unreadableCount
        self.isComplete = isComplete
        self.snapshotId = snapshotId
    }
}
