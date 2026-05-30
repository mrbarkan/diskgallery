import Foundation
import AppKit
import DiskGalleryCore

/// Tracks currently-mounted volumes so the UI can show connected badges and the
/// duplicate verifier can resolve a stored drive to its live mount point.
@MainActor
@Observable
final class VolumeService {
    struct Mounted: Identifiable, Sendable {
        let url: URL
        let info: VolumeInfo
        var id: String { info.uuid ?? info.name }
        var key: String { info.uuid ?? info.name }
    }

    /// External (removable/ejectable/non-internal) drives, for the scan picker.
    private(set) var external: [Mounted] = []
    /// Every mounted volume keyed by its stable key, for badge + hash resolution.
    private var urlByKey: [String: URL] = [:]

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func isConnected(key: String) -> Bool { urlByKey[key] != nil }
    func mountURL(forKey key: String) -> URL? { urlByKey[key] }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeNameKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var mounted: [Mounted] = []
        var map: [String: URL] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let info = VolumeMetadata.read(url)
            map[info.uuid ?? info.name] = url

            let removable = (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false)
            let isInternal = values?.volumeIsInternal ?? true
            if removable || !isInternal {
                mounted.append(Mounted(url: url, info: info))
            }
        }
        external = mounted.sorted {
            $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending
        }
        urlByKey = map
    }
}
