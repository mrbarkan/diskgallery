import Foundation

/// Decides whether a root-relative path should be skipped entirely during a scan.
/// Pure so the policy is unit-testable; the scanner supplies the boot-volume fact.
///
/// `/System/Volumes` re-mounts the APFS Data volume that the boot volume's firmlinks
/// (`/Applications`, `/Users`, `/Library`, …) already expose. Walking it double-counts
/// roughly half the disk. Excluding the single node prevents the entire subtree from
/// being recorded or descended.
public enum ScanExclusion {
    /// Root-relative paths skipped when scanning the boot volume. Exact match: once the
    /// node is omitted, no descendant path is ever generated.
    static let bootVolumeExclusions: Set<String> = ["System/Volumes"]

    public static func isExcluded(relPath: String, isBootVolume: Bool) -> Bool {
        isBootVolume && bootVolumeExclusions.contains(relPath)
    }
}
