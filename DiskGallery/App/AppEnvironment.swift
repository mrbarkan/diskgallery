import Foundation
import Observation
import DiskGalleryCore

/// What the sidebar selection points at.
enum SidebarItem: Hashable {
    case volume(Int64)
    case duplicates
    case tagged(Tag)
    case search
}

struct ScanState {
    var volumeName: String
    var progress: ScanProgress
}

/// Holds the catalog + live UI state. The single source of truth injected into the
/// view tree. GRDB never appears here — everything goes through `Catalog`.
@MainActor
@Observable
final class AppEnvironment {
    let catalog: Catalog
    let volumes: VolumeService

    var volumeSummaries: [VolumeSummary] = []
    var tagCounts: [Tag: Int] = [:]
    var totalReclaimable: Int64 = 0

    var selection: SidebarItem?
    var selectedEntry: Entry?
    var selectedVolumeKey: String?

    var activeScan: ScanState?
    var dataVersion = 0          // bumped on any mutation, so views reload
    var errorMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init() throws {
        catalog = try Catalog.makeDefault()
        volumes = VolumeService()
    }

    func refresh() async {
        do {
            volumeSummaries = try await catalog.library.volumes()
            tagCounts = try await catalog.annotations.counts()
            totalReclaimable = try await catalog.duplicates.totalReclaimable()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Scanning

    func startScan(url: URL) {
        scanTask?.cancel()
        scanTask = Task { await runScan(url) }
    }

    func cancelScan() {
        scanTask?.cancel()
        activeScan = nil
    }

    private func runScan(_ url: URL) async {
        let name = VolumeMetadata.read(url).name
        activeScan = ScanState(volumeName: name, progress: ScanProgress(currentPath: name))
        do {
            for try await progress in catalog.scanner.scan(volumeURL: url) {
                activeScan?.progress = progress
                if progress.isComplete {
                    activeScan = nil
                    await refresh()
                    if let sid = progress.snapshotId,
                       let summary = volumeSummaries.first(where: { $0.latestSnapshotId == sid }) {
                        selection = .volume(summary.id)
                    }
                }
            }
        } catch is CancellationError {
            activeScan = nil
        } catch {
            activeScan = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Annotations

    func setTag(_ tag: Tag, note: String?, volumeKey: String, relPath: String) async {
        do {
            try await catalog.annotations.set(tag: tag, note: note, volumeKey: volumeKey, relPath: relPath)
            dataVersion += 1
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Duplicate hash verification

    /// Hashes the connected members of a duplicate set (off the main thread) and
    /// caches the digests. Disconnected members are skipped.
    func verify(set: DuplicateSet) async {
        do {
            let members = try await catalog.duplicates.members(name: set.name, logicalSize: set.logicalSize)
            var jobs: [(entryId: Int64, url: URL)] = []
            for member in members where member.contentHash == nil {
                let key = member.volumeUuid ?? member.volumeName
                if let mount = volumes.mountURL(forKey: key) {
                    jobs.append((member.entryId, mount.appendingPathComponent(member.relPath)))
                }
            }
            let hasher = catalog.hasher
            let computed: [(Int64, String)] = await Task.detached {
                var out: [(Int64, String)] = []
                for job in jobs {
                    if let hash = try? hasher.sha256(fileURL: job.url) {
                        out.append((job.entryId, hash))
                    }
                }
                return out
            }.value
            for (entryId, hash) in computed {
                try await catalog.duplicates.recordHash(entryId: entryId, hash: hash)
            }
            dataVersion += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Catalog management

    func deleteVolume(id: Int64) async {
        do {
            try await catalog.library.deleteVolume(id: id)
            if case .volume(id) = selection { selection = nil }
            dataVersion += 1
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
