import Foundation

/// A macOS Finder tag (name + color code) read from / written to a file.
public struct FinderTag: Sendable, Equatable {
    public var name: String
    public var colorCode: Int        // 0 = no color, 1…7 = Finder colors
    public init(name: String, colorCode: Int) {
        self.name = name
        self.colorCode = colorCode
    }
}

/// Reads and writes real macOS Finder tags (`com.apple.metadata:_kMDItemUserTags`).
///
/// This is the ONLY component that writes to a scanned drive, and only when the
/// user explicitly applies a tag. Cataloging (Scanner/HashVerifier) stays strictly
/// read-only. Tags DiskGallery doesn't manage are preserved.
public struct FinderTagWriter: Sendable {
    public init() {}

    static let attribute = "com.apple.metadata:_kMDItemUserTags"

    /// Tag names DiskGallery owns — applying replaces only these, never the user's own.
    static let managedNames: Set<String> = {
        var names: Set<String> = [Tag.keep.label, Tag.delete.label, Tag.review.label]
        for color in FinderColor.allCases where color != .none { names.insert(color.tagName) }
        return names
    }()

    public enum FinderTagError: Error, Sendable { case writeFailed(Int32) }

    public func read(_ url: URL) -> [FinderTag] {
        guard let data = Self.xattrData(url),
              let array = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String]
        else { return [] }
        return array.map { raw in
            let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return FinderTag(name: String(parts.first ?? ""),
                             colorCode: parts.count > 1 ? (Int(parts[1]) ?? 0) : 0)
        }
    }

    /// Writes the decision + color as Finder tags, preserving the user's other tags.
    /// `.none`/`.none` clears DiskGallery's tags from the file.
    public func apply(decision: Tag, color: FinderColor, to url: URL) throws {
        var tags = read(url).filter { !Self.managedNames.contains($0.name) }
        if decision != .none {
            tags.append(FinderTag(name: decision.label, colorCode: decision.finderColorCode))
        }
        if color != .none {
            tags.append(FinderTag(name: color.tagName, colorCode: color.rawValue))
        }
        try write(tags, to: url)
    }

    func write(_ tags: [FinderTag], to url: URL) throws {
        let strings = tags.map { $0.colorCode == 0 ? $0.name : "\($0.name)\n\($0.colorCode)" }

        if strings.isEmpty {
            _ = url.path.withCString { removexattr($0, Self.attribute, 0) }
            return
        }
        let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
        let ok = url.path.withCString { path -> Bool in
            data.withUnsafeBytes { raw in
                setxattr(path, Self.attribute, raw.baseAddress, raw.count, 0, 0) == 0
            }
        }
        if !ok { throw FinderTagError.writeFailed(errno) }
    }

    static func xattrData(_ url: URL) -> Data? {
        url.path.withCString { path -> Data? in
            let length = getxattr(path, attribute, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, attribute, $0.baseAddress, length, 0, 0) }
            return read >= 0 ? data : nil
        }
    }
}
