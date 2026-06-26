import Foundation

/// Coarse file-type grouping by extension, used by the Duplicates filter chips and the
/// Search "Photos · RAW" saved search. `.all` is the catch-all: it matches every file,
/// and any unmatched/extensionless file maps to `.all`.
public enum FileCategory: String, CaseIterable, Sendable {
    case all, photos, video, raw, documents, audio

    public var label: String {
        switch self {
        case .all:       return "All"
        case .photos:    return "Photos"
        case .video:     return "Video"
        case .raw:       return "RAW"
        case .documents: return "Documents"
        case .audio:     return "Audio"
        }
    }

    /// Extensions owned by each specific category (lowercased, no dot). `.all` owns none —
    /// it is the universal matcher.
    private static let extensionsByCategory: [FileCategory: Set<String>] = [
        .raw:       ["cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "srw"],
        .photos:    ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp"],
        .video:     ["mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "prores"],
        .documents: ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "key", "numbers", "xlsx", "csv"],
        .audio:     ["mp3", "wav", "aac", "flac", "m4a", "aiff", "aif", "alac", "ogg"],
    ]

    /// The category a bare extension belongs to (`.all` when unmatched or empty).
    public static func category(forExtension ext: String) -> FileCategory {
        let key = ext.lowercased()
        guard !key.isEmpty else { return .all }
        for (category, set) in extensionsByCategory where set.contains(key) { return category }
        return .all
    }

    /// The union of file extensions covered by `categories` (lowercased, no dot).
    public static func extensions(for categories: [FileCategory]) -> [String] {
        var out = Set<String>()
        for c in categories { out.formUnion(extensionsByCategory[c] ?? []) }
        return Array(out)
    }

    /// Whether a filename belongs to this category. `.all` matches everything.
    public func matches(filename: String) -> Bool {
        if self == .all { return true }
        let ext = (filename as NSString).pathExtension
        return Self.category(forExtension: ext) == self
    }
}
