import Foundation

/// Decides whether a path is "hidden" in the macOS sense — any component begins with a
/// dot. Pure so it's testable and reusable by every view that filters hidden files.
public enum PathVisibility {
    public static func isHidden(relPath: String) -> Bool {
        relPath.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}
