import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers
import DiskGalleryCore

/// What the sidebar selection points at.
enum SidebarItem: Hashable {
    case volume(Int64)
    case duplicates
    case tagged(Tag)
    case search
    case plan          // Action plan: everything tagged, grouped by drive
    case transfer      // Transfer planner: will it fit?
}

struct ScanState {
    var volumeName: String
    var progress: ScanProgress
    var isResume: Bool
}

/// Outcome of pushing catalogued annotations onto connected drives as Finder tags.
struct TagSyncResult {
    var drivesSynced = 0
    var filesWritten = 0
    var drivesSkipped = 0   // offline drives
    var filesSkipped = 0    // annotations on offline drives
    var failures = 0        // write errors
}

/// Holds the catalog + live UI state. The single source of truth injected into the
/// view tree. GRDB never appears here — everything goes through `Catalog`.
@MainActor
@Observable
final class AppEnvironment {
    let catalog: Catalog
    let volumes: VolumeService
    let shortcuts = ShortcutStore()
    let theme = ThemeStore()
    let license = LicenseStore()

    var volumeSummaries: [VolumeSummary] = []
    var tagCounts: [Tag: Int] = [:]
    var totalReclaimable: Int64 = 0

    var selection: SidebarItem?
    var selectedEntries: [Entry] = []
    var selectedVolumeKey: String?

    var activeScan: ScanState?
    var stopRequested = false        // Stop pressed; scan halted; showing the prompt
    var dataVersion = 0          // bumped on any mutation, so views reload
    var errorMessage: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var currentScanSnapshotId: Int64?
    @ObservationIgnored private var currentScanURL: URL?
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
        stopRequested = false
        currentScanURL = url
        currentScanSnapshotId = resumeSnapshotId
        let name = VolumeMetadata.read(url).name
        activeScan = ScanState(volumeName: name, progress: ScanProgress(currentPath: name), isResume: isResume)
        scanTask = Task { await runScan(url: url, resumeSnapshotId: resumeSnapshotId) }
    }

    // MARK: Stop prompt

    /// Halts the scan immediately (it becomes a resumable pause) and shows the prompt,
    /// so the scan can't finish while the user decides.
    func requestStop() {
        stopRequested = true
        scanTask?.cancel()
    }

    /// Keep Going — resume the just-halted scan.
    func continueScan() {
        guard let url = currentScanURL else { stopRequested = false; activeScan = nil; return }
        let wasResume = activeScan?.isResume ?? false
        beginScan(url: url, resumeSnapshotId: currentScanSnapshotId, isResume: wasResume)
    }

    /// Pause — leave the partial snapshot for later; just close the sheet.
    func pauseScan() {
        stopRequested = false
        activeScan = nil
        Task { await refresh() }
    }

    /// Discard — delete the partial snapshot.
    func discardScan() {
        stopRequested = false
        let snapshotId = currentScanSnapshotId
        activeScan = nil
        Task {
            if let snapshotId { try? await catalog.library.deleteSnapshot(id: snapshotId) }
            await refresh()
        }
    }

    private func runScan(url: URL, resumeSnapshotId: Int64?) async {
        let stream = resumeSnapshotId.map { catalog.scanner.resume(snapshotId: $0, volumeURL: url) }
            ?? catalog.scanner.scan(volumeURL: url)

        var completed = false
        do {
            for try await progress in stream {
                if let sid = progress.snapshotId { currentScanSnapshotId = sid }
                activeScan?.progress = progress
                if progress.isComplete { completed = true; break }
            }
        } catch is CancellationError {
            return   // halted by Stop, or superseded — leave the UI to the prompt / new task
        } catch {
            errorMessage = error.localizedDescription
        }

        if completed {
            let snapshotId = currentScanSnapshotId
            stopRequested = false
            activeScan = nil
            dataVersion += 1          // force the browser to reload now-rolled-up folder sizes
            await refresh()
            if let snapshotId, let summary = volumeSummaries.first(where: { $0.latestSnapshotId == snapshotId }) {
                selection = .volume(summary.id)
            }
            return
        }
        if stopRequested { return }   // halted for the prompt — keep the sheet up
        activeScan = nil              // ended unexpectedly
        await refresh()
    }

    /// Re-scans an already-known drive (a fresh snapshot), so its changes can be
    /// compared against the previous scan. The drive must be connected.
    func rescan(volume: VolumeSummary) {
        let key = volume.uuid ?? volume.name
        guard let mountURL = volumes.mountURL(forKey: key) else {
            errorMessage = "Connect “\(volume.name)” to re-scan it."
            return
        }
        startScan(url: mountURL)
    }

    // MARK: Backup / restore

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.title = "Export Library"
        panel.message = "Save a portable copy of your whole catalog — every drive, tag, and note."
        panel.nameFieldStringValue = "DiskGallery Library.\(BackupService.fileExtension)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: BackupService.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backup = catalog.backup
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try backup.export(to: url) }.value
            } catch {
                errorMessage = "Couldn’t export the library: \(error.localizedDescription)"
            }
        }
    }

    func importLibrary() {
        guard activeScan == nil else {
            errorMessage = "Finish or pause the current scan before importing a library."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Library"
        panel.message = "Choose a DiskGallery backup to load."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: BackupService.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        alert.messageText = "Replace your current library?"
        alert.informativeText = "Importing replaces everything currently in DiskGallery with this backup. A safety copy of your current library is saved first."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let backup = catalog.backup
        let safety = Self.safetyBackupURL()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try? backup.export(to: safety)      // best-effort safety copy
                    try backup.restore(from: url)
                }.value
                selection = nil
                selectedEntries = []
                dataVersion += 1
                await volumes.refresh()
                await refresh()
                selection = volumeSummaries.first.map { SidebarItem.volume($0.id) }
            } catch {
                errorMessage = "Couldn’t import the library: \(error.localizedDescription)"
            }
        }
    }

    private static func safetyBackupURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DiskGallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Pre-Import Backup.\(BackupService.fileExtension)")
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

    /// Pushes every catalogued annotation onto its drive as a Finder tag, for all
    /// connected drives. Non-destructive — the same write the app already performs at
    /// tag time, batched for drives that were offline then. Offline drives are skipped.
    func syncFinderTags() async -> TagSyncResult {
        var result = TagSyncResult()
        let annotations = (try? await catalog.annotations.all()) ?? []
        guard !annotations.isEmpty else { return result }

        let byVolume = Dictionary(grouping: annotations, by: { $0.volumeUuid })
        let writer = catalog.finderTags

        for (key, group) in byVolume {
            guard let mount = volumes.mountURL(forKey: key) else {
                result.drivesSkipped += 1
                result.filesSkipped += group.count
                continue
            }
            result.drivesSynced += 1
            let jobs = group.map { (url: mount.appendingPathComponent($0.relPath),
                                    decision: $0.tag, color: $0.color) }
            let failures = await Task.detached(priority: .utility) { () -> Int in
                var failed = 0
                for job in jobs {
                    do { try writer.apply(decision: job.decision, color: job.color, to: job.url) }
                    catch { failed += 1 }
                }
                return failed
            }.value
            result.failures += failures
            result.filesWritten += group.count - failures
        }
        return result
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
