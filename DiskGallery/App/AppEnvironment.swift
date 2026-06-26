import Foundation
import Observation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskGalleryCore

/// What the sidebar selection points at.
enum SidebarItem: Hashable {
    case volume(Int64)
    case allDrives     // All Drives: merged cross-drive browser with coverage + comparison
    case duplicates
    case tagged(Tag)
    case search
    case plan          // Action plan: everything tagged, grouped by drive
    case transfer      // Transfer planner: will it fit?
    case organize      // Organize: cross-drive, ordered, non-destructive transfer plan
    case gallery       // Gallery: cross-drive contact sheet

    /// A stable string for persisting the selection across launches.
    var token: String {
        switch self {
        case .volume(let id): "volume:\(id)"
        case .allDrives:      "allDrives"
        case .duplicates:     "duplicates"
        case .tagged(let t):  "tagged:\(t.rawValue)"
        case .search:         "search"
        case .plan:           "plan"
        case .transfer:       "transfer"
        case .organize:       "organize"
        case .gallery:        "gallery"
        }
    }

    init?(token: String) {
        switch token {
        case "allDrives":  self = .allDrives
        case "duplicates": self = .duplicates
        case "search":     self = .search
        // Merged into Organize — restore old selections onto the Organize home.
        case "plan":       self = .organize
        case "transfer":   self = .organize
        case "organize":   self = .organize
        case "gallery":    self = .gallery
        default:
            if token.hasPrefix("volume:"), let id = Int64(token.dropFirst("volume:".count)) {
                self = .volume(id)
            } else if token.hasPrefix("tagged:"), let raw = Int(token.dropFirst("tagged:".count)),
                      let tag = Tag(rawValue: raw) {
                self = .tagged(tag)
            } else {
                return nil
            }
        }
    }
}

extension SidebarItem {
    /// The single "Tagged" sidebar destination = all action tags. Encoded as
    /// `.tagged(.none)` so no new enum case is needed (keeps Modern's switch compiling).
    static var taggedAll: SidebarItem { .tagged(.none) }
}

/// A lightweight reference to a gallery tile, carrying its own drive key so cross-drive
/// selections can be tagged correctly (the Gallery spans drives, unlike the .volume browser).
struct GalleryItemRef: Identifiable, Hashable {
    let id: Int64            // entry id
    let relPath: String
    let name: String
    let logicalSize: Int64
    let volumeKey: String    // uuid ?? name
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
    let roleLabels = DriveRoleLabelsStore()

    var volumeSummaries: [VolumeSummary] = []
    var driveGroups: [DriveGroup] = []
    var tagCounts: [Tag: Int] = [:]
    var totalReclaimable: Int64 = 0
    /// Per-drive role assignments, keyed by volume key (uuid ?? name). Loaded on refresh;
    /// updated optimistically by the role setters. Drives absent here are `.neutral`
    /// (or `.localSystem` for the boot disk — see `role(forKey:)`).
    var driveRoleAssignments: [String: DriveRoleAssignment] = [:]
    /// Cross-drive backup-coverage headline, for the All Drives OLED + sidebar badge.
    var coverageSummary: CoverageSummary = .empty
    /// The node selected in the All Drives outline — drives the comparison panel
    /// (Modern right pane / Classic detail column).
    var selectedUnifiedNode: UnifiedNode?

    var selection: SidebarItem? {
        didSet { if let selection { viewPrefs.lastSelection = selection.token } }
    }
    var selectedEntries: [Entry] = []
    var selectedVolumeKey: String?
    var selectedGalleryItems: [GalleryItemRef] = []

    var activeScan: ScanState?
    var stopRequested = false        // Stop pressed; scan halted; showing the prompt
    var dataVersion = 0          // bumped on any mutation, so views reload
    var errorMessage: String?
    var upgradeFeature: Feature?     // non-nil ⇒ show the upgrade sheet for this feature

    var executionPrompt: ExecutionPrompt?       // non-nil shows the confirm sheet
    var executionProgress: ExecutionProgress?   // non-nil shows the progress HUD
    @ObservationIgnored private var executionTask: Task<Void, Never>?

    struct ThumbnailProgress { var completed: Int; var total: Int }
    var thumbnailProgress: ThumbnailProgress?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?

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
            let consumed = MainActor.assumeIsolated {
                self.handleShortcut(characters: characters)
            }
            return consumed ? nil : event
        }
    }

    /// Runs the tagging shortcut bound to `characters` on the current selection.
    /// Returns true if the key was consumed.
    private func handleShortcut(characters: String) -> Bool {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText { return false }  // not while typing
        guard let action = shortcuts.action(forKey: characters) else { return false }
        switch selection {
        case .volume:
            let targets = selectedEntries
            guard !targets.isEmpty else { return false }
            Task { await perform(action, on: targets) }
            return true
        case .gallery:
            guard !selectedGalleryItems.isEmpty else { return false }
            Task { await performGallery(action) }
            return true
        default:
            return false
        }
    }

    func requestUpgrade(_ feature: Feature) { upgradeFeature = feature }

    /// The view to open on launch: the last-selected one (when "Restore last view" is on
    /// and it still resolves), otherwise the first cataloged drive.
    func restoredLaunchSelection() -> SidebarItem? {
        if viewPrefs.restoreLastView,
           let token = viewPrefs.lastSelection,
           let item = SidebarItem(token: token) {
            if case .volume(let id) = item,
               !volumeSummaries.contains(where: { $0.id == id }) {
                return volumeSummaries.first.map { SidebarItem.volume($0.id) }   // drive gone
            }
            return item
        }
        return volumeSummaries.first.map { SidebarItem.volume($0.id) }
    }

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
            driveRoleAssignments = try await catalog.driveRoles.all()
            coverageSummary = try await catalog.unified.summary(hideHidden: viewPrefs.hideHidden)
        } catch {
            report(error)
        }
    }

    // MARK: All Drives (unified cross-drive browser)

    func unifiedChildren(path: String) async -> [UnifiedNode] {
        do { return try await catalog.unified.children(ofPath: path, hideHidden: viewPrefs.hideHidden) }
        catch { report(error); return [] }
    }

    func unifiedCoverage() async -> CoverageSummary {
        do { return try await catalog.unified.summary(hideHidden: viewPrefs.hideHidden) }
        catch { report(error); return .empty }
    }

    /// Tags a specific drive's copy (feeds the Organize plan). Non-destructive.
    /// Refreshes so the sidebar Tagged/Reclaimable counts and Organize plan stay in sync.
    func tagCopy(_ tag: Tag, copy: UnifiedCopy) {
        Task {
            try? await catalog.annotations.setDecision(tag, volumeKey: copy.volumeKey, relPath: copy.relPath)
            dataVersion += 1
            await refresh()
        }
    }

    // MARK: Drive roles (item 5)

    /// Is this drive the Mac's internal boot disk? (Mounted at "/".)
    func isBootVolume(key: String) -> Bool {
        volumes.mountURL(forKey: key)?.path == "/"
    }

    /// The effective role for a drive: an explicit assignment, else Local/System for the
    /// boot disk, else Neutral.
    func role(forKey key: String) -> DriveRole {
        if let assigned = driveRoleAssignments[key] { return assigned.role }
        return isBootVolume(key: key) ? .localSystem : .neutral
    }

    func priority(forKey key: String) -> Int {
        driveRoleAssignments[key]?.priority ?? 0
    }

    /// Assigns a role (optimistic cache update + persist + reload dependent views).
    /// Persists the full effective record so an implicit default (e.g. the boot disk's
    /// `.localSystem`) is never lost when only one dimension changes.
    func setDriveRole(_ role: DriveRole, forKey key: String) {
        let priority = priority(forKey: key)
        driveRoleAssignments[key] = DriveRoleAssignment(role: role, priority: priority)
        dataVersion += 1
        Task { try? await catalog.driveRoles.set(role: role, priority: priority, forKey: key) }
    }

    func setDrivePriority(_ priority: Int, forKey key: String) {
        let role = role(forKey: key)
        driveRoleAssignments[key] = DriveRoleAssignment(role: role, priority: priority)
        dataVersion += 1
        Task { try? await catalog.driveRoles.set(role: role, priority: priority, forKey: key) }
    }

    /// Surfaces an error to the user — but never a `CancellationError`, which is the
    /// normal, expected outcome of a superseded or stopped operation (a new scan, a
    /// cancelled `.task`), not a failure worth an alert.
    private func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
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
        } catch { report(error); return nil }
    }

    /// Creates a new group containing just `volumeId` (the "New Group from Drive" action).
    func createGroup(name: String, withDrive volumeId: Int64) async {
        do {
            let group = try await catalog.library.createGroup(name: name)
            try await catalog.library.reorderDrives(orderedVolumeIds: [volumeId], inGroup: group.id)
            dataVersion += 1
            await refresh()
        } catch { report(error) }
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
        catch { report(error) }
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
        Task { [weak self] in await self?.surfaceReadyOperationsOnMount() }
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
            } catch { report(error) }
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
            report(error)
        }

        // A cancelled AsyncThrowingStream finishes *without* throwing, so the
        // `catch is CancellationError` above never fires on Stop/supersede. Detect the
        // cancellation here: this task no longer owns the UI (a new scan or the Stop
        // prompt does), so bail before clearing its progress or running a refresh that
        // would itself throw CancellationError from the database.
        if Task.isCancelled { return }

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

    /// Tagging entry point for the Gallery: applies the shortcut's decision/color to the
    /// gallery selection, grouped by each item's own drive key (the Gallery spans drives).
    /// Toggle semantics match the .volume browser: clear the tag if every selected item
    /// already has it, otherwise set it.
    func performGallery(_ action: ShortcutAction) async {
        let byKey = Dictionary(grouping: selectedGalleryItems, by: \.volumeKey)
        guard !byKey.isEmpty else { return }
        if let tag = action.decision {
            let allHave = await galleryAllSatisfy(byKey) { $0.tag == tag }
            await applyKeyed(byKey) { store, key, relPath in
                try await store.setDecision(allHave ? .none : tag, volumeKey: key, relPath: relPath)
            }
        } else if let color = action.color {
            let allHave = await galleryAllSatisfy(byKey) { $0.color == color }
            await applyKeyed(byKey) { store, key, relPath in
                try await store.setColor(allHave ? .none : color, volumeKey: key, relPath: relPath)
            }
        }
    }

    private func galleryAllSatisfy(_ byKey: [String: [GalleryItemRef]],
                                   _ predicate: (Annotation) -> Bool) async -> Bool {
        for (key, items) in byKey {
            let map = (try? await catalog.annotations.annotations(
                volumeKey: key, relPaths: items.map(\.relPath))) ?? [:]
            for item in items {
                guard let a = map[item.relPath], predicate(a) else { return false }
            }
        }
        return true
    }

    /// Per-drive variant of `apply(to:_:)`: mutates each item's annotation under its own
    /// volume key, then writes Finder tags for any connected drive. Reuses `writeFinderTags`.
    private func applyKeyed(_ byKey: [String: [GalleryItemRef]],
                            _ mutate: (AnnotationStore, String, String) async throws -> Annotation?) async {
        var writes: [(url: URL, decision: Tag, color: FinderColor)] = []
        for (key, items) in byKey {
            let mount = volumes.mountURL(forKey: key)
            for item in items {
                let annotation = (try? await mutate(catalog.annotations, key, item.relPath)) ?? nil
                if let mount {
                    writes.append((mount.appendingPathComponent(item.relPath),
                                   annotation?.tag ?? .none, annotation?.color ?? .none))
                }
            }
        }
        await writeFinderTags(writes)
        dataVersion += 1
        await refresh()
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

    // MARK: Organize (cross-drive transfer plan)

    /// The planner's inputs, gathered from the catalog: every drive as a `PlanDrive`
    /// (capacity + hardware + live connection) and the de-duplicated Move/Backup/Delete
    /// items across all drives. The Modern page caches these so destination overrides
    /// re-plan instantly (the planner itself is pure and synchronous).
    func organizationPlanInputs() async -> (drives: [PlanDrive], items: [PlanItemSource]) {
        do {
            let (stats, items) = try await catalog.planning.organizationInputs()
            let summaryByKey = Dictionary(volumeSummaries.map { ($0.uuid ?? $0.name, $0) },
                                          uniquingKeysWith: { first, _ in first })
            let drives = stats.map { stat in
                PlanDrive(id: stat.id, key: stat.volumeKey, name: stat.name,
                          totalCapacity: stat.totalCapacity, freeCapacity: stat.freeCapacity,
                          usedLogical: stat.usedLogical,
                          isConnected: volumes.isConnected(key: stat.volumeKey),
                          hardware: summaryByKey[stat.volumeKey]?.hardware,
                          role: role(forKey: stat.volumeKey),
                          priority: priority(forKey: stat.volumeKey))
            }
            return (drives, items)
        } catch {
            report(error)
            return ([], [])
        }
    }

    /// A batch of copy/move operations ready to run for the just-connected drive(s).
    struct ExecutionPrompt: Identifiable {
        let id = UUID()
        var drafts: [FileOperation]
        var fileCount: Int { drafts.count }
        var copyCount: Int { drafts.filter { $0.type == .copy }.count }
        var moveCount: Int { drafts.filter { $0.type == .move }.count }
        var deleteCount: Int { drafts.filter { $0.type == .delete }.count }
        var totalBytes: Int64 { drafts.reduce(0) { $0 + $1.bytes } }
        var driveNames: [String]
    }

    struct ExecutionProgress {
        var completed: Int
        var total: Int
        var currentName: String
    }

    /// On reconnect: if Pro and the current plan has copy/move steps whose drives are
    /// all connected, surface the confirm sheet.
    func surfaceReadyOperationsOnMount() async {
        guard license.isUnlocked(.transfer) else { return }
        guard executionPrompt == nil, executionProgress == nil else { return }
        let plan = await organizationPlan()
        let connected: (String) -> Bool = { [volumes] in volumes.isConnected(key: $0) }
        let drafts = ExecutorService.copyDrafts(from: plan.steps, isConnected: connected, now: Date())
            + ExecutorService.moveDrafts(from: plan.steps, isConnected: connected, now: Date())
            + ExecutorService.deleteDrafts(from: plan.steps, isConnected: connected, now: Date())
        guard !drafts.isEmpty else { return }
        let names = Set(drafts.compactMap { $0.destVolumeKey }
            .compactMap { key in volumeSummaries.first { ($0.uuid ?? $0.name) == key }?.name })
        executionPrompt = ExecutionPrompt(drafts: drafts, driveNames: names.sorted())
    }

    /// Runs the operations the user confirmed in the sheet.
    func runConfirmedExecution() {
        guard let prompt = executionPrompt else { return }
        executionPrompt = nil
        executionProgress = ExecutionProgress(completed: 0, total: prompt.drafts.count, currentName: "")
        // Snapshot mount URLs on the main actor now (VolumeService is @MainActor-isolated;
        // the resolve closure must be nonisolated/Sendable, so we can't call it directly from there).
        let mountSnapshot = volumes.mountSnapshot()
        executionTask = Task { [weak self] in
            guard let self else { return }
            let enqueued = (try? await self.catalog.execution.enqueue(prompt.drafts)) ?? []
            let total = enqueued.count
            await self.catalog.execution.run(enqueued, resolve: { key, rel in
                mountSnapshot[key]?.appendingPathComponent(rel)
            }, progress: { @MainActor [weak self] op in
                guard let self else { return }
                let done = (self.executionProgress?.completed ?? 0) + 1
                self.executionProgress = ExecutionProgress(completed: done, total: total,
                                                           currentName: (op.sourceRelPath as NSString).lastPathComponent)
            })
            // A completed move or delete leaves its source in the Trash — clear the source's
            // annotation so it isn't re-proposed on the next reconnect.
            let ids = Set(enqueued.compactMap(\.id))
            let finished = (try? await self.catalog.execution.history()) ?? []
            for op in finished where op.id.map(ids.contains) == true
                && (op.type == .move || op.type == .delete) && op.status == .done {
                try? await self.catalog.annotations.setDecision(.none, volumeKey: op.sourceVolumeKey,
                                                                relPath: op.sourceRelPath)
            }
            self.executionProgress = nil
            self.dataVersion += 1
        }
    }

    func cancelExecution() {
        executionTask?.cancel()
    }

    /// Builds the non-destructive organization plan from every drive's tagged items.
    /// Pure planning — nothing is moved. `overrides` maps an item id to a chosen
    /// destination drive key, letting the user steer the auto-suggested assignments.
    func organizationPlan(overrides: [String: String] = [:]) async -> OrganizationPlan {
        let (drives, items) = await organizationPlanInputs()
        return OrganizationPlanner.plan(drives: drives, items: items, overrides: overrides)
    }

    /// All drives that could receive a Move/Backup (everything except `sourceKey`),
    /// for the per-item destination override picker.
    func destinationChoices(excluding sourceKey: String) -> [VolumeSummary] {
        volumeSummaries.filter { ($0.uuid ?? $0.name) != sourceKey }
    }

    /// Saves the plan's step-by-step playbook as a Markdown file (non-destructive).
    func exportOrganizationReport(_ plan: OrganizationPlan) {
        let panel = NSSavePanel()
        panel.title = "Export Organization Plan"
        panel.message = "Save the step-by-step transfer plan as a Markdown file. Nothing is moved — this is your playbook."
        panel.nameFieldStringValue = "DiskGallery Organization Plan.md"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "md") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(plan.reportMarkdown().utf8).write(to: url)
        } catch {
            errorMessage = "Couldn’t export the plan: \(error.localizedDescription)"
        }
    }

    /// Copies the plain-text playbook to the clipboard.
    func copyOrganizationReport(_ plan: OrganizationPlan) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plan.reportText(), forType: .string)
    }

    // MARK: Thumbnail generation

    /// Default preview types when a drive has none set.
    static let defaultPreviewTypes: [FileCategory] = [.photos, .raw]

    func previewTypes(for summary: VolumeSummary) -> [FileCategory] {
        guard let json = summary.previewTypes,
              let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return Self.defaultPreviewTypes
        }
        return raw.compactMap { FileCategory(rawValue: $0) }
    }

    func setPreviewTypes(_ types: [FileCategory], forVolume summary: VolumeSummary) {
        let json = String(data: (try? JSONEncoder().encode(types.map(\.rawValue))) ?? Data(), encoding: .utf8)
        Task { [weak self] in
            try? await self?.catalog.library.setPreviewTypes(json, volumeId: summary.id)
            await self?.refresh()
        }
    }

    /// Generate + cache thumbnails for a connected drive's selected preview types.
    func generateThumbnails(for summary: VolumeSummary) {
        let key = summary.uuid ?? summary.name
        guard let mount = volumes.mountURL(forKey: key) else { return }   // must be connected
        let categories = previewTypes(for: summary)
        thumbnailProgress = ThumbnailProgress(completed: 0, total: 0)
        thumbnailTask = Task { [weak self] in
            guard let self else { return }
            let entries = (try? await self.catalog.thumbnails.entriesNeedingPreview(
                volumeId: summary.id, categories: categories)) ?? []
            self.thumbnailProgress = ThumbnailProgress(completed: 0, total: entries.count)
            var done = 0
            for entry in entries {
                if Task.isCancelled { break }
                let fileURL = mount.appendingPathComponent(entry.relPath)
                let fresh = (try? await self.catalog.thumbnails.isFresh(
                    volumeKey: key, relPath: entry.relPath,
                    srcModifiedAt: entry.modifiedAt, srcSize: entry.size)) ?? false
                if !fresh, let data = await self.catalog.thumbnails.generate(fileURL: fileURL, maxPixel: 512) {
                    try? await self.catalog.thumbnails.store(data, volumeKey: key, relPath: entry.relPath,
                                                             srcModifiedAt: entry.modifiedAt, srcSize: entry.size)
                }
                done += 1
                self.thumbnailProgress = ThumbnailProgress(completed: done, total: entries.count)
            }
            self.thumbnailProgress = nil
            self.dataVersion += 1
        }
    }

    func cancelThumbnails() { thumbnailTask?.cancel() }

    // MARK: Catalog management

    func deleteVolume(id: Int64) async {
        do {
            try await catalog.library.deleteVolume(id: id)
            if case .volume(id) = selection { selection = nil }
            dataVersion += 1
            await refresh()
        } catch {
            report(error)
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
            report(error)
        }
    }
}
