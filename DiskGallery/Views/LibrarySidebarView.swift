import SwiftUI
import AppKit
import DiskGalleryCore

struct LibrarySidebarView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        List(selection: $env.selection) {
            Section("Library") {
                Label("Duplicates", systemImage: "doc.on.doc")
                    .badge(env.totalReclaimable > 0 ? Text(Format.bytes(env.totalReclaimable)) : nil)
                    .tag(SidebarItem.duplicates)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
            }

            Section("Decisions") {
                ForEach([Tag.delete, Tag.keep, Tag.review]) { tag in
                    Label(tag.label, systemImage: icon(for: tag))
                        .badge(env.tagCounts[tag] ?? 0)
                        .tag(SidebarItem.tagged(tag))
                }
            }

            Section("Drives") {
                if env.volumeSummaries.isEmpty {
                    Text("No drives cataloged yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(env.volumeSummaries) { summary in
                    DriveRow(summary: summary)
                        .tag(SidebarItem.volume(summary.id))
                        .contextMenu {
                            Button("Remove from Library", role: .destructive) {
                                Task { await env.deleteVolume(id: summary.id) }
                            }
                        }
                }
            }
        }
        .navigationTitle("DiskGallery")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: scan) {
                    Label("Scan…", systemImage: "externaldrive.badge.plus")
                }
                .help("Catalog a drive or folder (read-only)")
            }
        }
    }

    private func icon(for tag: Tag) -> String {
        switch tag {
        case .delete: return "trash"
        case .keep: return "checkmark.seal"
        case .review: return "questionmark.circle"
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
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(connected ? Color.green : Color.secondary)
                .help(connected ? "Connected" : "Disconnected")
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        if let total = summary.totalLogical, let files = summary.fileCount {
            return "\(Format.bytes(total)) · \(Format.count(files)) files"
        }
        if let scannedAt = summary.scannedAt {
            return "Scanned \(Format.date(scannedAt))"
        }
        return "Not scanned"
    }
}
