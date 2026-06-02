import Foundation

/// Decides whether a mounted volume should appear as a catalog-able external drive.
/// Pure so the policy is unit-testable; the app supplies the resource-value facts.
public enum VolumeFilter {
    /// List a volume only when it is **local** (excludes network shares and most cloud
    /// file-providers, which report `isLocal == false`) AND it is external — i.e.
    /// removable, or simply not the internal disk.
    public static func shouldList(isLocal: Bool, isRemovable: Bool, isInternal: Bool) -> Bool {
        guard isLocal else { return false }
        return isRemovable || !isInternal
    }
}
