import Foundation
import Observation
import AppKit
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
    var isResume: Bool
}

enum ScanStop { case none, pause, discard }

/// Holds the catalog + live UI state. The single source of truth injected into the
/// view tree. GRDB never appears here — everything goes through `Catalog`.
@MainActor
@Observable
final class AppEnvironment {
    let catalog: Catalog
    let volumes: VolumeService
    let shortcuts = ShortcutStore()
    let theme = ThemeStore()

    var volumeSummaries: [VolumeSummary] = []
    var tagCounts: [Tag: Int] = [:]
    var totalReclaimable: Int64 = 0

    var selection: SidebarItem?
    var selectedEntries: [Entry] = []
    var selectedVolumeKey: String?

    var activeScan: ScanState?
    var stopRequested = false        // drives the Stop confirmation prompt
    var dataVersion = 0          // bumped on any mutation, so views reload
    var errorMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanStop: ScanStop = .none
    @ObservationIgnored private var currentScanSnapshotId: Int64?
    @ObservationIgnored private var keyMonitor: Any?

    init() throws {
        catalog = try Catalog.makeDefault()
        volumes = VolumeService()
    }

    // MARK: Keyboard shortcuts (window-level, decoupled from List focus)

    func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Let modifier chords (⌘C, etc.) pass through untouched.
            if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
            guard let characters = event.charactersIgnoringModifiers else { return event }
            // Extract only Sendable data before hopping to the main actor.
            let consumed = MainActor.assumeIsolated { self.handleShortcut(characters: characters) }
            return consumed ? nil : event
        }
    }

    /// Runs the tagging shortcut bound to `characters` on the current selection.
    /// Returns true if the key was consumed.
    private func handleShortcut(characters: String) -> Bool {
        guard case .volume = selection else { return false }                    // only while browsing
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return false }  // not while typing
        guard let action = shortcuts.action(forKey: characters) else { return false }
        let targets = selectedEntries
        guard !targets.isEmpty else { return false }
        Task { await perform(action, on: targets) }
        return true
    }

    var isSelectedVolumeConnected: Bool {
        guard let key = selectedVolumeKey else { return false }
        return volumes.isConnected(key: key)
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
        beginScan(url: url, resumeSnapshotId: nil, isResume: false)
    }

    /// Continues a drive's paused (incomplete) scan. The drive must be connected.
    func resumeScan(volume: VolumeSummary) {
        guard let snapshotId = volume.latestSnapshotId else { return }
        let key = volume.uuid ?? volume.name
        guard let mountURL = volumes.mountURL(forKey: key) else {
            errorMessage = "Connect “\(volume.name)” to resume its scan."
            return
        }
        beginScan(url: mountURL, resumeSnapshotId: snapshotId, isResume: true)
    }

    private func beginScan(url: URL, resumeSnapshotId: Int64?, isResume: Bool) {
        scanTask?.cancel()
        scanStop = .none
        stopRequested = false
        currentScanSnapshotId = resumeSnapshotId
        scanTask = Task { await runScan(url: url, resumeSnapshotId: resumeSnapshotId, isResume: isResume) }
    }

    // Stop prompt actions
    func requestStop() { stopRequested = true }
    func continueScan() { stopRequested = false }
    func pauseScan() { stopRequested = false; scanStop = .pause }
    func discardScan() { stopRequested = false; scanStop = .discard }

    private func runScan(url: URL, resumeSnapshotId: Int64?, isResume: Bool) async {
        let name = VolumeMetadata.read(url).name
        activeScan = ScanState(volumeName: name, progress: ScanProgress(currentPath: name), isResume: isResume)

        let stream = resumeSnapshotId.map { catalog.scanner.resume(snapshotId: $0, volumeURL: url) }
            ?? catalog.scanner.scan(volumeURL: url)

        var completed = false
        do {
            for try await progress in stream {
                if let sid = progress.snapshotId { currentScanSnapshotId = sid }
                activeScan?.progress = progress
                if progress.isComplete { completed = true }
                if scanStop != .none { break }      // user chose Pause or Discard
            }
        } catch is CancellationError {
            // superseded by a new scan
        } catch {
            errorMessage = error.localizedDescription
        }

        let mode = scanStop
        let snapshotId = currentScanSnapshotId
        scanStop = .none
        activeScan = nil

        if mode == .discard, let sid = snapshotId {
            try? await catalog.library.deleteSnapshot(id: sid)
        }
        await refresh()
        if completed, let sid = snapshotId,
           let summary = volumeSummaries.first(where: { $0.latestSnapshotId == sid }) {
            selection = .volume(summary.id)
        }
    }

    // MARK: Tagging

    /// Dispatches a keyboard shortcut. Keys toggle: pressing a tag/color that the
    /// whole selection already has clears it.
    func perform(_ action: ShortcutAction, on entries: [Entry]) async {
        if let decision = action.decision {
            await toggleDecision(decision, on: entries)
        } else if let color = action.color {
            await toggleColor(color, on: entries)
        }
    }

    func toggleDecision(_ tag: Tag, on entries: [Entry]) async {
        let allHave = await allEntries(entries, satisfy: { $0.tag == tag })
        await applyDecision(allHave ? .none : tag, to: entries)
    }

    func toggleColor(_ color: FinderColor, on entries: [Entry]) async {
        let allHave = await allEntries(entries, satisfy: { $0.color == color })
        await applyColor(allHave ? .none : color, to: entries)
    }

    private func allEntries(_ entries: [Entry], satisfy predicate: (Annotation) -> Bool) async -> Bool {
        guard let key = selectedVolumeKey, !entries.isEmpty else { return false }
        let map = (try? await catalog.annotations.annotations(
            volumeKey: key, relPaths: entries.map(\.relPath))) ?? [:]
        return entries.allSatisfy { entry in
            if let annotation = map[entry.relPath] { return predicate(annotation) }
            return false
        }
    }

    func applyDecision(_ tag: Tag, to entries: [Entry]) async {
        await apply(to: entries) { store, key, relPath in
            try await store.setDecision(tag, volumeKey: key, relPath: relPath)
        }
    }

    func applyColor(_ color: FinderColor, to entries: [Entry]) async {
        await apply(to: entries) { store, key, relPath in
            try await store.setColor(color, volumeKey: key, relPath: relPath)
        }
    }

    func applyNote(_ note: String?, to entry: Entry) async {
        guard let key = selectedVolumeKey else { return }
        _ = try? await catalog.annotations.setNote(note, volumeKey: key, relPath: entry.relPath)
        dataVersion += 1
        await refresh()
    }

    /// Updates the catalog for each entry, then writes the resulting Finder tags to
    /// the connected drive (catalog-only when the drive is disconnected).
    private func apply(to entries: [Entry],
                       _ mutate: (AnnotationStore, String, String) async throws -> Annotation?) async {
        guard let key = selectedVolumeKey, !entries.isEmpty else { return }
        let mount = volumes.mountURL(forKey: key)
        var writes: [(url: URL, decision: Tag, color: FinderColor)] = []
        for entry in entries {
            let annotation = (try? await mutate(catalog.annotations, key, entry.relPath)) ?? nil
            if let mount {
                writes.append((mount.appendingPathComponent(entry.relPath),
                               annotation?.tag ?? .none,
                               annotation?.color ?? .none))
            }
        }
        await writeFinderTags(writes)
        dataVersion += 1
        await refresh()
    }

    private func writeFinderTags(_ writes: [(url: URL, decision: Tag, color: FinderColor)]) async {
        guard !writes.isEmpty else { return }
        let writer = catalog.finderTags
        await Task.detached(priority: .utility) {
            for write in writes {
                try? writer.apply(decision: write.decision, color: write.color, to: write.url)
            }
        }.value
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
}
