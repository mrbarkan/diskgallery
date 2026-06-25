import Foundation

/// Sends a file or folder to the macOS Trash (recoverable) — never a permanent
/// delete. Used by Move (to remove the source after a verified copy) and, later, by
/// Delete. Lives in `Execution/`, the executor's mutation surface.
public struct FileTrasher: Sendable {
    public init() {}

    /// Moves `url` to the Trash, returning the resulting in-Trash location when the
    /// OS reports one. Throws if the item can't be trashed.
    @discardableResult
    public func trash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }
}
