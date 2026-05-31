import SwiftUI
import AppKit
import DiskGalleryCore

/// Modern glass sidebar — brand, scan button, nav sections, drive rows (spec §6).
/// A custom glass card (not a List) so it matches the mockup's `.sidebar` exactly.
struct ModernSidebar: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

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
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 14, trailing: 18))
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
            }
            section("Action Tags") {
                // Mockup order (not Tag.actionTags order).
                ForEach([Tag.keep, .delete, .review, .move, .backup]) { tag in
                    navItem(icon(for: tag), tag.label,
                            badge: Format.count(env.tagCounts[tag] ?? 0), item: .tagged(tag))
                }
            }
            section("Drives", trailing: "\(connectedCount) / \(env.volumeSummaries.count)") {
                if env.volumeSummaries.isEmpty {
                    Text("No drives cataloged yet").font(.system(size: 12)).foregroundStyle(DGToken.ink3(scheme))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                }
                ForEach(env.volumeSummaries) { summary in
                    ModernDriveRow(summary: summary, selected: env.selection == .volume(summary.id), accent: accent)
                        .contentShape(Rectangle())
                        .onTapGesture { env.selection = .volume(summary.id) }
                        .contextMenu {
                            if summary.latestSnapshotComplete == false {
                                Button("Resume Scan") { env.resumeScan(volume: summary) }
                                    .disabled(!env.volumes.isConnected(key: summary.uuid ?? summary.name))
                                Divider()
                            }
                            Button("Remove from Library", role: .destructive) {
                                Task { await env.deleteVolume(id: summary.id) }
                            }
                        }
                }
            }
        }
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
