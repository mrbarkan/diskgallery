import SwiftUI
import AppKit
import DiskGalleryCore

struct LibrarySidebarView: View {
    @Environment(AppEnvironment.self) private var env

    private var modern: Bool { env.theme.skin == .modern }

    var body: some View {
        @Bindable var env = env
        List(selection: $env.selection) {
            Section {
                Label("Duplicates", systemImage: "doc.on.doc")
                    .badge(env.totalReclaimable > 0 ? Text(Format.bytes(env.totalReclaimable)) : nil)
                    .tag(SidebarItem.duplicates)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
            } header: { sectionHeader("Library") }

            Section {
                Label("Action Plan", systemImage: "checklist")
                    .badge(plannedItemCount)
                    .tag(SidebarItem.plan)
                Label("Transfer Planner", systemImage: "arrow.left.arrow.right")
                    .tag(SidebarItem.transfer)
            } header: { sectionHeader("Plan") }

            Section {
                ForEach(Tag.actionTags) { tag in
                    Label(tag.label, systemImage: icon(for: tag))
                        .badge(env.tagCounts[tag] ?? 0)
                        .tag(SidebarItem.tagged(tag))
                }
            } header: { sectionHeader("Action Tags") }

            Section {
                if env.volumeSummaries.isEmpty {
                    Text("No drives cataloged yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(env.volumeSummaries) { summary in
                    DriveRow(summary: summary)
                        .tag(SidebarItem.volume(summary.id))
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
            } header: { sectionHeader("Drives") }
        }
        .modernListChrome(modern)
        .navigationTitle("DiskGallery")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: scan) {
                    Label("Scan…", systemImage: "externaldrive.badge.plus")
                }
                .help("Catalog a drive or folder (read-only)")
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

    @ViewBuilder private func sectionHeader(_ title: String) -> some View {
        if modern {
            Text(title).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.5).textCase(.uppercase).foregroundStyle(.tertiary)
        } else {
            Text(title)
        }
    }

    private func icon(for tag: Tag) -> String {
        switch tag {
        case .delete: return "trash"
        case .keep: return "checkmark.seal"
        case .review: return "questionmark.circle"
        case .move: return "arrow.right.circle"
        case .backup: return "shippingbox"
        case .none: return "tag"
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
        if panel.runModal() == .OK, let url = panel.url {
            env.startScan(url: url)
        }
    }
}

struct DriveRow: View {
    @Environment(AppEnvironment.self) private var env
    let summary: VolumeSummary

    var body: some View {
        let key = summary.uuid ?? summary.name
        let connected = env.volumes.isConnected(key: key)
        let modern = env.theme.skin == .modern
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .shadow(color: connected && modern ? .green : .clear, radius: 4)
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
}
