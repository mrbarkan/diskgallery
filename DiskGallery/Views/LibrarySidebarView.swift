import SwiftUI
import AppKit
import DiskGalleryCore

struct LibrarySidebarView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var editingGroupId: Int64?
    @State private var editingName = ""
    @FocusState private var renameFocused: Bool

    // Live drag-target feedback (where a drop will land).
    @State private var dropTargetVolumeId: Int64?
    @State private var dropTargetGroupId: Int64?
    @State private var ungroupedTargeted = false

    // Per-drive Previews sheet (one at a time, same pattern as group rename state).
    @State private var previewsVolume: VolumeSummary?

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        @Bindable var env = env
        List(selection: $env.selection) {
            Section {
                Label("All Drives", systemImage: "square.stack.3d.up.fill")
                    .badge(env.coverageSummary.atRiskCount > 0 ? Text("\(env.coverageSummary.atRiskCount) at risk") : nil)
                    .tag(SidebarItem.allDrives)
            }

            Section {
                Label("Gallery", systemImage: "square.grid.3x3.fill")
                    .tag(SidebarItem.gallery)
                Label("Duplicates", systemImage: "doc.on.doc")
                    .badge(env.totalReclaimable > 0 ? Text(Format.bytes(env.totalReclaimable)) : nil)
                    .tag(SidebarItem.duplicates)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Tagged", systemImage: "tag")
                    .badge(plannedItemCount)
                    .tag(SidebarItem.taggedAll)
            } header: { sectionHeader("Library") }

            Section {
                Label("Organize", systemImage: "wand.and.stars")
                    .badge(organizeItemCount)
                    .tag(SidebarItem.organize)
            } header: { sectionHeader("Plan") }

            if env.volumeSummaries.isEmpty && env.driveGroups.isEmpty {
                Section {
                    Text("No drives cataloged yet").foregroundStyle(.secondary).font(.callout)
                } header: { sectionHeader("Drives") }
            } else {
                ForEach(env.driveSections) { section in
                    if let group = section.group {
                        Section {
                            if !group.isCollapsed {
                                ForEach(section.drives) { driveRow($0) }
                            }
                        } header: { groupHeader(group, count: section.drives.count) }
                    } else {
                        Section {
                            ForEach(section.drives) { driveRow($0) }
                        } header: { ungroupedHeader(hasGroups: !env.driveGroups.isEmpty) }
                    }
                }
            }
        }
        .navigationTitle("DiskGallery")
        .sheet(item: $previewsVolume) { ScanCacheView(summary: $0) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: scan) {
                    Label("Scan…", systemImage: "externaldrive.badge.plus")
                }
                .help("Catalog a drive or folder (read-only)")
            }
            ToolbarItem(placement: .automatic) {
                Button { Task { await addGroup() } } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .help("Create a drive group")
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Export Library…") { env.exportLibrary() }
                    Button("Import Library…") { env.importLibrary() }
                } label: {
                    Label("Library", systemImage: "ellipsis.circle")
                }
                .help("Back up or restore your whole catalog")
            }
        }
    }

    private var plannedItemCount: Int {
        Tag.actionTags.reduce(0) { $0 + (env.tagCounts[$1] ?? 0) }
    }

    private var organizeItemCount: Int {
        [Tag.move, .backup, .delete].reduce(0) { $0 + (env.tagCounts[$1] ?? 0) }
    }

    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        Text(title)
    }

    private func scan() { env.chooseAndScan() }

    // MARK: Drives — grouping, drag & drop

    private func driveRow(_ summary: VolumeSummary) -> some View {
        DriveRow(summary: summary)
            .overlay(alignment: .top) {
                Capsule().fill(accent)
                    .frame(height: 2.5).offset(y: -3)
                    .shadow(color: accent.opacity(0.6), radius: 3)
                    .opacity(dropTargetVolumeId == summary.id ? 1 : 0)
            }
            .tag(SidebarItem.volume(summary.id))
            .draggable(DriveDragID.drive(summary.id)) { dragPreview(icon: "externaldrive.fill", name: summary.name) }
            .dropDestination(for: String.self) { items, _ in
                dropTargetVolumeId = nil
                guard let item = items.first, let dragged = DriveDragID.parseDrive(item) else { return false }
                Task { await env.dropDrive(dragged, before: summary.id) }
                return true
            } isTargeted: { hovering in
                if hovering { dropTargetVolumeId = summary.id }
                else if dropTargetVolumeId == summary.id { dropTargetVolumeId = nil }
            }
            .animation(.easeOut(duration: 0.13), value: dropTargetVolumeId)
            .contextMenu { driveContextMenu(summary) }
    }

    private func dragPreview(icon: String, name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(name).fontWeight(.semibold).lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
    }

    @ViewBuilder private func driveContextMenu(_ summary: VolumeSummary) -> some View {
        if summary.latestSnapshotComplete == false {
            Button("Resume Scan") { env.resumeScan(volume: summary) }
                .disabled(!env.volumes.isConnected(key: summary.uuid ?? summary.name))
            Divider()
        }
        Button("Scan Cache / Previews…") { previewsVolume = summary }
        Divider()
        DriveRoleMenu(key: summary.uuid ?? summary.name)
        Menu("Move to") {
            Button("New Group…") { Task { await env.createGroup(name: "New Group", withDrive: summary.id) } }
            if !env.driveGroups.isEmpty {
                Divider()
                ForEach(env.driveGroups) { group in
                    Button(group.name) { Task { await env.moveDrive(summary.id, toGroup: group.id) } }
                        .disabled(summary.groupId == group.id)
                }
            }
            if summary.groupId != nil {
                Divider()
                Button("Ungrouped") { Task { await env.moveDrive(summary.id, toGroup: nil) } }
            }
        }
        Divider()
        Button("Remove from Library", role: .destructive) {
            Task { await env.deleteVolume(id: summary.id) }
        }
    }

    @ViewBuilder private func groupHeader(_ group: DriveGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
            if editingGroupId == group.id {
                TextField("Group", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { commitRename(group) }
                    .onExitCommand { editingGroupId = nil }
            } else {
                sectionHeader(group.name)
                Spacer()
                Text("\(count)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(dropTargetGroupId == group.id ? 0.18 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(group) }
        .onTapGesture { toggleCollapse(group) }
        .draggable(DriveDragID.group(group.id ?? -1)) { dragPreview(icon: "folder.fill", name: group.name) }
        .dropDestination(for: String.self) { items, _ in
            dropTargetGroupId = nil
            guard let item = items.first, let id = group.id else { return false }
            if let draggedGroup = DriveDragID.parseGroup(item) {
                Task { await env.dropGroup(draggedGroup, before: id) }
                return true
            }
            if let draggedDrive = DriveDragID.parseDrive(item) {
                Task { await env.moveDrive(draggedDrive, toGroup: group.id) }
                return true
            }
            return false
        } isTargeted: { hovering in
            if hovering { dropTargetGroupId = group.id }
            else if dropTargetGroupId == group.id { dropTargetGroupId = nil }
        }
        .animation(.easeOut(duration: 0.13), value: dropTargetGroupId)
        .contextMenu {
            Button("Rename") { beginRename(group) }
            Button("Delete Group", role: .destructive) {
                if let id = group.id { Task { await env.deleteGroup(id: id) } }
            }
        }
    }

    private func ungroupedHeader(hasGroups: Bool) -> some View {
        HStack {
            sectionHeader(hasGroups ? "Ungrouped" : "Drives")
            Spacer()
        }
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(ungroupedTargeted ? 0.18 : 0))
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            ungroupedTargeted = false
            guard let item = items.first, let dragged = DriveDragID.parseDrive(item) else { return false }
            Task { await env.moveDrive(dragged, toGroup: nil) }
            return true
        } isTargeted: { ungroupedTargeted = $0 }
        .animation(.easeOut(duration: 0.13), value: ungroupedTargeted)
    }

    private func toggleCollapse(_ group: DriveGroup) {
        if let id = group.id { Task { await env.setGroupCollapsed(id: id, collapsed: !group.isCollapsed) } }
    }

    private func addGroup() async {
        if let id = await env.createGroup(name: "New Group") {
            editingGroupId = id
            editingName = "New Group"
            renameFocused = true
        }
    }

    private func beginRename(_ group: DriveGroup) {
        editingGroupId = group.id
        editingName = group.name
        renameFocused = true
    }

    private func commitRename(_ group: DriveGroup) {
        let name = editingName
        editingGroupId = nil
        if let id = group.id { Task { await env.renameGroup(id: id, to: name) } }
    }
}

struct DriveRow: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary

    var body: some View {
        let key = summary.uuid ?? summary.name
        let connected = env.volumes.isConnected(key: key)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .help(connected ? "Connected" : "Disconnected")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(summary.name).lineLimit(1)
                    if summary.latestSnapshotComplete == false {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                            .help("Scan incomplete — right-click to resume")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                hardwareBadge
                if summary.latestSnapshotComplete != false, summary.scannedAt != nil {
                    Text("scanned \(Format.relativeDate(summary.scannedAt))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if summary.latestSnapshotComplete != false, summary.totalCapacity != nil {
                    CapacityBar(total: summary.totalCapacity, free: summary.freeCapacity, height: 4)
                        .frame(maxWidth: 190)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if summary.latestSnapshotComplete == false {
            return "Incomplete — resume to finish"
        }
        if let total = summary.totalLogical, let files = summary.fileCount {
            return "\(Format.bytes(total)) · \(Format.count(files)) files"
        }
        return "Not scanned"
    }

    @ViewBuilder private var hardwareBadge: some View {
        if let hw = summary.hardware.map(DriveHardwareDisplay.init), hw.hasRowBadge {
            HStack(spacing: 4) {
                badgePill(icon: hw.busIcon, text: hw.busShort)
                if let speed = hw.speedText { badgePill(text: speed) }
                if let medium = hw.mediumText { badgePill(text: medium) }
            }
            .help(hw.badgeText)
        }
    }

    private func badgePill(icon: String? = nil, text: String) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            Text(text).font(.system(size: 9, weight: .medium))
        }
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.secondary.opacity(0.15), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

