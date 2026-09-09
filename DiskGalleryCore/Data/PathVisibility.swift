import Foundation

/// Decides whether a path is "hidden" in the macOS sense — any component begins with a
/// dot. Pure so it's testable and reusable by every view that filters hidden files.
public enum PathVisibility {
    public static func isHidden(relPath: String) -> Bool {
        relPath.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

/// Helpers for building safe SQL `LIKE` patterns from user/path strings.
public enum SQLPattern {
    /// A `LIKE ? ESCAPE '\'` pattern matching every descendant of `folderRelPath`
    /// (i.e. `folderRelPath/…`). LIKE metacharacters in the folder name (`\ % _`)
    /// are escaped so a folder literally named `2024_trip` can't match `2024Xtrip`.
    public static func childrenPrefix(of folderRelPath: String) -> String {
        let escaped = folderRelPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "/%"
    }
}
