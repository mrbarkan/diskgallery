import Foundation

/// Coarse file-type grouping by extension, used by the Duplicates filter chips and the
/// Search "Photos · RAW" saved search. `.all` is the catch-all: it matches every file,
/// and any unmatched/extensionless file maps to `.all`.
public enum FileCategory: String, CaseIterable, Sendable {
    case all, photos, video, raw, documents

    public var label: String {
        switch self {
        case .all:       return "All"
        case .photos:    return "Photos"
        case .video:     return "Video"
        case .raw:       return "RAW"
        case .documents: return "Documents"
        }
    }

    /// Extensions owned by each specific category (lowercased, no dot). `.all` owns none —
    /// it is the universal matcher.
    private static let extensions: [FileCategory: Set<String>] = [
        .raw:       ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "srw"],
        .photos:    ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp"],
        .video:     ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "prores"],
        .documents: ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers", "xlsx", "csv"],
    ]

    /// The category a bare extension belongs to (`.all` when unmatched or empty).
    public static func category(forExtension ext: String) -> FileCategory {
        let key = ext.lowercased()
        guard !key.isEmpty else { return .all }
        for (category, set) in extensions where set.contains(key) { return category }
        return .all
    }

    /// Whether a filename belongs to this category. `.all` matches everything.
    public func matches(filename: String) -> Bool {
        if self == .all { return true }
        let ext = (filename as NSString).pathExtension
        return Self.category(forExtension: ext) == self
    }
}
