import Foundation

/// Identity + capacity facts about a mounted volume. All read-only.
public struct VolumeInfo: Sendable {
    public var uuid: String?
    public var name: String
    public var totalCapacity: Int64?
    public var freeCapacity: Int64?
    public var fsType: String?
    public var isRemovable: Bool
    public var isEjectable: Bool

    public init(uuid: String?, name: String, totalCapacity: Int64?, freeCapacity: Int64?,
                fsType: String?, isRemovable: Bool, isEjectable: Bool) {
        self.uuid = uuid
        self.name = name
        self.totalCapacity = totalCapacity
        self.freeCapacity = freeCapacity
        self.fsType = fsType
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
    }
}

public enum VolumeMetadata {
    static let resourceKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeNameKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeIsRemovableKey, .volumeIsEjectableKey,
    ]

    /// Reads volume identity/capacity for the given mounted URL (a volume root or
    /// any path on it). Never writes.
    public static func read(_ url: URL) -> VolumeInfo {
        let values = try? url.resourceValues(forKeys: resourceKeys)
        let fallbackName = url.lastPathComponent.isEmpty ? "Untitled" : url.lastPathComponent
        return VolumeInfo(
            uuid: values?.volumeUUIDString,
            name: values?.volumeName ?? fallbackName,
            totalCapacity: values?.volumeTotalCapacity.map(Int64.init),
            freeCapacity: values?.volumeAvailableCapacity.map(Int64.init),
            fsType: filesystemType(url),
            isRemovable: values?.volumeIsRemovable ?? false,
            isEjectable: values?.volumeIsEjectable ?? false)
    }

    /// Filesystem type (e.g. "apfs", "hfs", "exfat") via `statfs`.
    static func filesystemType(_ url: URL) -> String? {
        var stat = statfs()
        guard statfs(url.path, &stat) == 0 else { return nil }
        return withUnsafeBytes(of: &stat.f_fstypename) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
