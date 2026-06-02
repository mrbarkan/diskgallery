import Foundation

/// Resolves a catalogued file (its drive's live mount point + path-relative-to-root)
/// to a real on-disk `URL`, but only when the file actually exists right now. Pure and
/// side-effect-free so the path logic is unit-testable; the app calls `NSWorkspace` with
/// the result. Returns nil when the drive is offline (`mountURL == nil`) or the file is
/// gone (moved/deleted since the last scan).
public enum RevealTarget {
    public static func url(mountURL: URL?, relPath: String) -> URL? {
        guard let mountURL else { return nil }
        let candidate = mountURL.appendingPathComponent(relPath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
