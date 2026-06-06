import SwiftUI
import AppKit
import DiskGalleryCore

/// Modern glass sidebar — brand, scan button, nav sections, drive rows (spec §6).
/// A custom glass card (not a List) so it matches the mockup's `.sidebar` exactly.
struct ModernSidebar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    @State private var editingGroupId: Int64?
    @State private var editingName = ""
    @FocusState private var renameFocused: Bool

    // Live drag-target feedback (where a drop will land).
    @State private var dropTargetVolumeId: Int64?
    @State private var dropTargetGroupId: Int64?
    @State private var ungroupedTargeted = false

    /// Identity of the current drive arrangement — animates reflow when an order/group changes.
    private var orderSignature: [Int64] {
        env.driveSections.flatMap { [$0.id] + $0.drives.map(\.id) }
    }

    private var palette: AccentPalette { env.theme.accent.palette }
    private var accent: Color { palette.accent }

    var body: some View {
        VStack(spacing: 0) {
            brand
            scanButton
            ScrollView { nav.padding(.horizontal, 10).padding(.bottom, 14) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DGToken.hair(scheme), lineWidth: 1))
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.12), radius: 22, y: 14)
    }

    // MARK: Brand (top padding clears the floating traffic-lights — spec §4.2)
    private var brand: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [accent, palette.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DGToken.hair2(scheme), lineWidth: 1))
                    .shadow(color: palette.glow, radius: 8, y: 4)
                Image(systemName: "externaldrive.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.ink)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("DiskGallery").font(.system(size: 16, weight: .bold)).foregroundStyle(DGToken.ink(scheme))
                Text("OFFLINE CATALOG").font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.8).foregroundStyle(DGToken.ink3(scheme))
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
    }

    // MARK: Scan button
    private var scanButton: some View {
        Button(action: scan) {
            HStack(spacing: 8) {
                Image(systemName: "plus.rectangle").font(.system(size: 13, weight: .bold))
                Text("SCAN A DRIVE").font(.system(size: 10.5, weight: .bold, design: .monospaced)).tracking(1.6)
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(LinearGradient(colors: [accent, palette.accent2], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: palette.glow, radius: 10, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.bottom, 12)
        .help("Catalog a drive or folder (read-only)")
    }

    // MARK: Nav
    private var nav: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Library") {
                navItem("square.on.square", "Duplicates",
                        badge: env.totalReclaimable > 0 ? Format.bytes(env.totalReclaimable) : nil,
                        item: .duplicates)
                navItem("magnifyingglass", "Search", item: .search)
            }
            section("Plan") {
                navItem("checklist", "Action Plan",
                        badge: plannedCount > 0 ? Format.count(plannedCount) : nil, item: .plan)
                navItem("arrow.left.arrow.right", "Transfer Planner", item: .transfer)
                navItem("wand.and.stars", "Organize",
                        badge: organizeCount > 0 ? Format.count(organizeCount) : nil, item: .organize)
            }
            section("Action Tags") {
                // Mockup order (not Tag.actionTags order).
                ForEach([Tag.keep, .delete, .review, .move, .backup]) { tag in
                    navItem(icon(for: tag), tag.label,
                            badge: Format.count(env.tagCounts[tag] ?? 0), item: .tagged(tag))
                }
            }
            drivesArea
        }
    }

    // MARK: Drives (groups + manual order + hardware badges)

    @ViewBuilder private var drivesArea: some View {
        VStack(alignment: .leading, spacing: 2) {
            drivesHeader
            if env.volumeSummaries.isEmpty && env.driveGroups.isEmpty {
                Text("No drives cataloged yet").font(.system(size: 12)).foregroundStyle(DGToken.ink3(scheme))
                    .padding(.horizontal, 11).padding(.vertical, 6)
            }
            ForEach(env.driveSections) { section in
                driveSection(section)
            }
        }
        .animation(.snappy(duration: 0.24), value: orderSignature)
        .animation(.easeOut(duration: 0.13), value: dropTargetVolumeId)
        .animation(.easeOut(duration: 0.13), value: dropTargetGroupId)
        .animation(.easeOut(duration: 0.13), value: ungroupedTargeted)
    }

    private var drivesHeader: some View {
        HStack(spacing: 4) {
            Text("DRIVES").font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.8).foregroundStyle(DGToken.ink4(scheme))
            Spacer(minLength: 4)
            Text("\(connectedCount) / \(env.volumeSummaries.count)")
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.0).foregroundStyle(DGToken.ink3(scheme))
            Button { Task { await addGroup() } } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DGToken.ink3(scheme))
            }
            .buttonStyle(.plain).help("New group")
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }

    @ViewBuilder private func driveSection(_ section: DriveGroupSection) -> some View {
        if let group = section.group {
            groupHeader(group, count: section.drives.count)
            if !group.isCollapsed {
                ForEach(section.drives) { driveRow($0) }
            }
        } else if env.driveGroups.isEmpty {
            ForEach(section.drives) { driveRow($0) }       // flat list, no header
        } else {
            ungroupedHeader                                 // drop target to leave a group
            ForEach(section.drives) { driveRow($0) }
        }
    }

    private func driveRow(_ summary: VolumeSummary) -> some View {
        ModernDriveRow(summary: summary, selected: env.selection == .volume(summary.id), accent: accent)
            .overlay(alignment: .top) { insertionLine(visible: dropTargetVolumeId == summary.id) }
            .contentShape(Rectangle())
            .onTapGesture { env.selection = .volume(summary.id) }
            .draggable(DriveDragID.drive(summary.id)) { dragPreview(summary) }
            .dropDestination(for: String.self) { items, _ in
                dropTargetVolumeId = nil
                guard let item = items.first, let dragged = DriveDragID.parseDrive(item) else { return false }
                Task { await env.dropDrive(dragged, before: summary.id) }
                return true
            } isTargeted: { hovering in
                if hovering { dropTargetVolumeId = summary.id }
                else if dropTargetVolumeId == summary.id { dropTargetVolumeId = nil }
            }
            .contextMenu { driveContextMenu(summary) }
    }

    /// Accent insertion bar shown in the gap above the row a drop will land before.
    @ViewBuilder private func insertionLine(visible: Bool) -> some View {
        Capsule().fill(accent)
            .frame(height: 2.5).padding(.horizontal, 8).offset(y: -1.5)
            .shadow(color: accent.opacity(visible ? 0.7 : 0), radius: 4)
            .opacity(visible ? 1 : 0)
    }

    /// A light pill preview so the drag feels snappy (avoids snapshotting the full glass row).
    private func dragPreview(_ summary: VolumeSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.fill").font(.system(size: 11, weight: .semibold))
            Text(summary.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(DGToken.ink(scheme))
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
    }

    @ViewBuilder private func driveContextMenu(_ summary: VolumeSummary) -> some View {
        if summary.latestSnapshotComplete == false {
            Button("Resume Scan") { env.resumeScan(volume: summary) }
                .disabled(!env.volumes.isConnected(key: summary.uuid ?? summary.name))
            Divider()
        }
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
                .font(.system(size: 9, weight: .bold)).foregroundStyle(DGToken.ink3(scheme)).frame(width: 10)
            if editingGroupId == group.id {
                TextField("Group", text: $editingName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.0)
                    .foregroundStyle(DGToken.ink(scheme))
                    .focused($renameFocused)
                    .onSubmit { commitRename(group) }
                    .onExitCommand { editingGroupId = nil }
            } else {
                Text(group.name.uppercased())
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(1.5)
                    .foregroundStyle(DGToken.ink3(scheme)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(count)").font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DGToken.ink4(scheme))
        }
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 4)
        .background(alignment: .center) {
            let targeted = dropTargetGroupId == group.id
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent.opacity(targeted ? 0.16 : 0))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(accent.opacity(targeted ? 0.5 : 0), lineWidth: 1))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(group) }
        .onTapGesture { if let id = group.id { Task { await env.setGroupCollapsed(id: id, collapsed: !group.isCollapsed) } } }
        .draggable(DriveDragID.group(group.id ?? -1)) { groupDragPreview(group) }
        .dropDestination(for: String.self) { items, _ in
            dropTargetGroupId = nil
            guard let item = items.first, let id = group.id else { return false }
            if let draggedGroup = DriveDragID.parseGroup(item) {
                Task { await env.dropGroup(draggedGroup, before: id) }
                return true
            }
            if let draggedDrive = DriveDragID.parseDrive(item) {
                Task { await env.moveDrive(draggedDrive, toGroup: id) }
                return true
            }
            return false
        } isTargeted: { hovering in
            if hovering { dropTargetGroupId = group.id }
            else if dropTargetGroupId == group.id { dropTargetGroupId = nil }
        }
        .contextMenu {
            Button("Rename") { beginRename(group) }
            Button("Delete Group", role: .destructive) {
                if let id = group.id { Task { await env.deleteGroup(id: id) } }
            }
        }
    }

    private var ungroupedHeader: some View {
        HStack {
            Text("UNGROUPED").font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.5).foregroundStyle(DGToken.ink4(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 4)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accent.opacity(ungroupedTargeted ? 0.16 : 0))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(accent.opacity(ungroupedTargeted ? 0.5 : 0), lineWidth: 1))
                .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            ungroupedTargeted = false
            guard let item = items.first, let dragged = DriveDragID.parseDrive(item) else { return false }
            Task { await env.moveDrive(dragged, toGroup: nil) }
            return true
        } isTargeted: { ungroupedTargeted = $0 }
    }

    private func groupDragPreview(_ group: DriveGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill").font(.system(size: 11, weight: .semibold))
            Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(DGToken.ink(scheme))
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
    }

    // MARK: Group editing

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

    @ViewBuilder private func section<Content: View>(_ title: String, trailing: String = "",
                                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ModernNavSectionHeader(title: title, trailing: trailing)
            content()
        }
    }

    private func navItem(_ icon: String, _ title: String, badge: String? = nil, item: SidebarItem) -> some View {
        ModernNavItem(systemImage: icon, title: title, badge: badge,
                      selected: env.selection == item, accent: accent) {
            env.selection = item
        }
    }

    private var plannedCount: Int { Tag.actionTags.reduce(0) { $0 + (env.tagCounts[$1] ?? 0) } }
    /// Items the Organize plan acts on: everything Move / Backup / Delete.
    private var organizeCount: Int {
        [Tag.move, .backup, .delete].reduce(0) { $0 + (env.tagCounts[$1] ?? 0) }
    }
    private var connectedCount: Int {
        env.volumeSummaries.filter { env.volumes.isConnected(key: $0.uuid ?? $0.name) }.count
    }

    private func icon(for tag: Tag) -> String {
        switch tag {
        case .keep:   "checkmark.circle"
        case .delete: "trash"
        case .review: "questionmark.circle"
        case .move:   "arrow.right.circle"
        case .backup: "shippingbox"
        case .none:   "tag"
        }
    }

    private func scan() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a drive or folder to catalog. DiskGallery only reads — it never changes anything."
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url { env.startScan(url: url) }
    }
}

// MARK: - Section header

private struct ModernNavSectionHeader: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .tracking(1.8).foregroundStyle(DGToken.ink4(scheme))
            Spacer(minLength: 4)
            if !trailing.isEmpty {
                Text(trailing).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .tracking(1.0).foregroundStyle(DGToken.ink3(scheme))
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    }
}

// MARK: - Nav item

private struct ModernNavItem: View {
    @Environment(\.colorScheme) private var scheme
    let systemImage: String
    let title: String
    var badge: String? = nil
    let selected: Bool
    var accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: systemImage).font(.system(size: 16)).frame(width: 18)
                    .foregroundStyle(selected ? accent : DGToken.ink3(scheme))
                Text(title).font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(selected ? DGToken.ink(scheme) : DGToken.ink2(scheme))
                Spacer(minLength: 6)
                if let badge, !badge.isEmpty {
                    Text(badge).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(selected ? accent.opacity(0.18) : DGToken.glass2(scheme), in: Capsule())
                        .foregroundStyle(selected ? accent : DGToken.ink3(scheme))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(selected ? accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? accent.opacity(0.40) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Drive row

private struct ModernDriveRow: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme
    let summary: VolumeSummary
    let selected: Bool
    var accent: Color

    var body: some View {
        let connected = env.volumes.isConnected(key: summary.uuid ?? summary.name)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(connected ? DGToken.ok : DGToken.ink4(scheme))
                    .frame(width: 8, height: 8)
                    .shadow(color: connected ? DGToken.ok.opacity(0.7) : .clear, radius: 4)
                Text(summary.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DGToken.ink(scheme)).lineLimit(1).truncationMode(.tail)
                if summary.latestSnapshotComplete == false {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(DGToken.warn)
                }
                Spacer(minLength: 0)
            }
            hardwareBadge
            Text(subtitle).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(summary.latestSnapshotComplete == false ? DGToken.warn : DGToken.ink3(scheme))
                .lineLimit(1).padding(.top, 5).padding(.bottom, 6)
            minibar
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(selected ? DGToken.glass2(scheme) : .clear,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(selected ? DGToken.hair2(scheme) : .clear, lineWidth: 1))
    }

    @ViewBuilder private var hardwareBadge: some View {
        if let hw = summary.hardware.map(DriveHardwareDisplay.init), hw.hasRowBadge {
            HStack(spacing: 4) {
                pill(icon: hw.busIcon, text: hw.busShort)
                if let speed = hw.speedText { pill(text: speed) }
                if let medium = hw.mediumText { pill(text: medium) }
                Spacer(minLength: 0)
            }
            .padding(.top, 5)
            .help(hw.badgeText)
        }
    }

    private func pill(icon: String? = nil, text: String) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 7.5, weight: .semibold)) }
            Text(text).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(DGToken.glass2(scheme), in: Capsule())
        .foregroundStyle(DGToken.ink3(scheme))
    }

    private var minibar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DGToken.inset(scheme))
                Capsule().fill(fraction >= 0.9 ? DGToken.bad : accent)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
    }

    private var fraction: Double {
        guard let total = summary.totalCapacity, total > 0 else { return 0 }
        let free = summary.freeCapacity ?? 0
        return min(1, max(0, Double(total - free) / Double(total)))
    }

    private var subtitle: String {
        if summary.latestSnapshotComplete == false { return "Incomplete — resume to finish" }
        if let total = summary.totalLogical, let files = summary.fileCount {
            return "\(Format.bytes(total)) · \(Format.count(files)) files"
        }
        return "Not scanned"
    }
}
