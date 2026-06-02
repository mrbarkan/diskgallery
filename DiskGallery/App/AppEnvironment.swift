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

/// One sidebar section of drives: a named group (or the ungrouped catch-all when `group == nil`)
/// with its drives in manual order. Computed from `volumeSummaries` + the loaded `driveGroups`.
struct DriveGroupSection: Identifiable {
    let group: DriveGroup?          // nil == ungrouped
    var drives: [VolumeSummary]
    var id: Int64 { group?.id ?? -1 }
    var isUngrouped: Bool { group == nil }
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
    let recentSearches = RecentSearchStore()
    let viewPrefs = ViewPrefsStore()

    var volumeSummaries: [VolumeSummary] = []
    var driveGroups: [DriveGroup] = []
    var tagCounts: [Tag: Int] = [:]
    var totalReclaimable: Int64 = 0

    var selection: SidebarItem?
    var selectedEntries: [Entry] = []
    var selectedVolumeKey: String?

    var activeScan: ScanState?
    var stopRequested = false        // Stop pressed; scan halted; showing the prompt
    var dataVersion = 0          // bumped on any mutation, so views reload
    var errorMessage: String?
    var upgradeFeature: Feature?     // non-nil ⇒ show the upgrade sheet for this feature

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var currentScanSnapshotId: Int64?
    @ObservationIgnored private var currentScanURL: URL?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var mountObserver: Any?

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

    func requestUpgrade(_ feature: Feature) { upgradeFeature = feature }

    var isSelectedVolumeConnected: Bool {
        guard let key = selectedVolumeKey else { return false }
        return volumes.isConnected(key: key)
    }

    /// Is the drive holding this file currently connected? Drives the enabled state of
    /// the "Show in Finder" controls.
    func canReveal(volumeKey: String?) -> Bool {
        guard let volumeKey else { return false }
        return volumes.mountURL(forKey: volumeKey) != nil
    }

    /// Reveals a catalogued file in Finder (selected, not just its folder). No-op when the
    /// drive is offline or the file no longer exists — the app never modifies files.
    func revealInFinder(volumeKey: String?, relPath: String) {
        guard let volumeKey else { return }
        let mountURL = volumes.mountURL(forKey: volumeKey)
        guard let url = RevealTarget.url(mountURL: mountURL, relPath: relPath) else {
            errorMessage = "That file isn't available — its drive may be disconnected or the file was moved."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refresh() async {
        do {
            volumeSummaries = try await catalog.library.volumes()
            driveGroups = try await catalog.library.groups()
            tagCounts = try await catalog.annotations.counts()
            totalReclaimable = try await catalog.duplicates.totalReclaimable()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Drive groups & ordering

    /// Named group sections (in their manual order) followed by the ungrouped catch-all.
    /// Drives within each are in manual order. Consumed identically by both sidebars.
    var driveSections: [DriveGroupSection] {
        let byGroup = Dictionary(grouping: volumeSummaries, by: { $0.groupId })
        func ordered(_ drives: [VolumeSummary]?) -> [VolumeSummary] {
            (drives ?? []).sorted { $0.sortIndex < $1.sortIndex }
        }
        var sections = driveGroups
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { DriveGroupSection(group: $0, drives: ordered(byGroup[$0.id])) }
        sections.append(DriveGroupSection(group: nil, drives: ordered(byGroup[nil])))
        return sections
    }

    /// Creates a group and returns its id (so the UI can start an inline rename).
    @discardableResult
    func createGroup(name: String) async -> Int64? {
        do {
            let group = try await catalog.library.createGroup(name: name)
            dataVersion += 1
            await refresh()
            return group.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Creates a new group containing just `volumeId` (the "New Group from Drive" action).
    func createGroup(name: String, withDrive volumeId: Int64) async {
        do {
            let group = try await catalog.library.createGroup(name: name)
            try await catalog.library.reorderDrives(orderedVolumeIds: [volumeId], inGroup: group.id)
            dataVersion += 1
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func renameGroup(id: Int64, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await run { try await self.catalog.library.renameGroup(id: id, name: trimmed) }
    }

    func deleteGroup(id: Int64) async {
        await run { try await self.catalog.library.deleteGroup(id: id) }
    }

    func setGroupCollapsed(id: Int64, collapsed: Bool) async {
        await run { try await self.catalog.library.setGroupCollapsed(id: id, collapsed: collapsed) }
    }

    func reorderGroups(orderedIds: [Int64]) async {
        await run { try await self.catalog.library.reorderGroups(orderedIds: orderedIds) }
    }

    /// Applies a fully-resolved drive order for one group (the drag primitive both sidebars call).
    func reorderDrives(orderedVolumeIds: [Int64], inGroup groupId: Int64?) async {
        await run { try await self.catalog.library.reorderDrives(orderedVolumeIds: orderedVolumeIds, inGroup: groupId) }
    }

    /// Appends `volumeId` to the end of `groupId` (nil = ungrouped) — the context-menu "Move to" action.
    func moveDrive(_ volumeId: Int64, toGroup groupId: Int64?) async {
        let existing = volumeSummaries
            .filter { $0.groupId == groupId && $0.id != volumeId }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)
        await reorderDrives(orderedVolumeIds: existing + [volumeId], inGroup: groupId)
    }

    /// Drag drop: place `draggedId` immediately before `targetId`, joining the target's group.
    func dropDrive(_ draggedId: Int64, before targetId: Int64) async {
        guard draggedId != targetId,
              let target = volumeSummaries.first(where: { $0.id == targetId }) else { return }
        let groupId = target.groupId
        var ids = volumeSummaries
            .filter { $0.groupId == groupId && $0.id != draggedId }
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(\.id)
        guard let index = ids.firstIndex(of: targetId) else { return }
        ids.insert(draggedId, at: index)
        await reorderDrives(orderedVolumeIds: ids, inGroup: groupId)
    }

    /// Drag drop: reorder group sections, placing `draggedId` immediately before `targetId`.
    func dropGroup(_ draggedId: Int64, before targetId: Int64) async {
        guard draggedId != targetId else { return }
        var ids = driveGroups.sorted { $0.sortIndex < $1.sortIndex }.compactMap(\.id)
        ids.removeAll { $0 == draggedId }
        guard let index = ids.firstIndex(of: targetId) else { return }
        ids.insert(draggedId, at: index)
        await reorderGroups(orderedIds: ids)
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        do { try await work(); dataVersion += 1; await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Hardware capture (on connect)

    private struct HardwareTarget: Sendable { let id: Int64; let url: URL }
    private struct HardwareProbeResult: Sendable { let id: Int64; let hardware: DriveHardware }

    /// Starts watching for drive connections so a cataloged drive's hardware facts are detected
    /// and refreshed whenever it's plugged in. Also backfills already-connected drives once.
    func startHardwareCapture() {
        guard mountObserver == nil else { return }
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.handleVolumeMounted() }
        }
        Task { await captureConnectedHardware() }
    }

    private func handleVolumeMounted() async {
        await volumes.refresh()             // make sure mount URLs are current first
        await captureConnectedHardware()
    }

    /// Probes every currently-connected cataloged drive (off the main thread) and persists any
    /// changed hardware facts. No-ops when nothing changed, so it won't loop on mount events.
    func captureConnectedHardware() async {
        let targets: [HardwareTarget] = volumeSummaries.compactMap { summary in
            let key = summary.uuid ?? summary.name
            guard let url = volumes.mountURL(forKey: key) else { return nil }
            return HardwareTarget(id: summary.id, url: url)
        }
        guard !targets.isEmpty else { return }

        let probed: [HardwareProbeResult] = await Task.detached(priority: .utility) {
            targets.compactMap { target in
                guard let hardware = DriveHardwareProbe.read(target.url) else { return nil }
                return HardwareProbeResult(id: target.id, hardware: hardware)
            }
        }.value

        var changed = false
        for result in probed {
            let current = volumeSummaries.first { $0.id == result.id }?.hardware
            guard current != result.hardware else { continue }
            do {
                try await catalog.library.updateHardware(volumeId: result.id, hardware: result.hardware)
                changed = true
            } catch { errorMessage = error.localizedDescription }
        }
        if changed { await refresh() }
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
