import Foundation
import AppKit
import DiskGalleryCore

/// Tracks currently-mounted volumes so the UI can show connected badges and the
/// duplicate verifier can resolve a stored drive to its live mount point.
///
/// All volume probing (`statfs` / resource values) runs OFF the main thread — those
/// calls can block for seconds on a slow or spinning-up drive, which would freeze
/// the UI (notably right when you plug a backup drive in).
@MainActor
@Observable
final class VolumeService {
    struct Mounted: Identifiable, Sendable {
        let url: URL
        let info: VolumeInfo
        var id: String { info.uuid ?? info.name }
        var key: String { info.uuid ?? info.name }
    }

    private(set) var external: [Mounted] = []
    private var urlByKey: [String: URL] = [:]

    init() {
        startObserving()
        Task { await refresh() }
    }

    func isConnected(key: String) -> Bool { urlByKey[key] != nil }
    func mountURL(forKey key: String) -> URL? { urlByKey[key] }
    /// The full key→mountURL registry (same one `isConnected`/`mountURL` consult).
    func mountSnapshot() -> [String: URL] { urlByKey }

    /// Probes volumes on a background task, then publishes results on the main actor.
    func refresh() async {
        let snapshot = await Task.detached(priority: .utility) {
            Self.enumerateVolumes()
        }.value
        external = snapshot.mounted
        urlByKey = snapshot.byKey
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { await self?.refresh() }
            }
        }
    }

    private struct Snapshot: Sendable {
        var mounted: [Mounted]
        var byKey: [String: URL]
    }

    /// Blocking work — must run off the main thread.
    nonisolated private static func enumerateVolumes() -> Snapshot {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeIsLocalKey, .volumeNameKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []

        var mounted: [Mounted] = []
        var byKey: [String: URL] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let info = VolumeMetadata.read(url)
            byKey[info.uuid ?? info.name] = url

            let removable = (values?.volumeIsRemovable ?? false) || (values?.volumeIsEjectable ?? false)
            let isInternal = values?.volumeIsInternal ?? true
            let isLocal = values?.volumeIsLocal ?? true
            if VolumeFilter.shouldList(isLocal: isLocal, isRemovable: removable, isInternal: isInternal) {
                mounted.append(Mounted(url: url, info: info))
            }
        }
        mounted.sort { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
        return Snapshot(mounted: mounted, byKey: byKey)
    }
}
