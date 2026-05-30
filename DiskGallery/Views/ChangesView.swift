import SwiftUI
import DiskGalleryCore

/// "What changed since last scan?" — diffs two snapshots of one drive, entirely from
/// stored data, so it works even with the drive disconnected.
struct ChangesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let summary: VolumeSummary

    @State private var snapshots: [SnapshotInfo] = []
    @State private var baseId: Int64?
    @State private var headId: Int64?
    @State private var diff: SnapshotDiff?
    @State private var category: Category = .added
    @State private var loaded = false

    enum Category: String, CaseIterable, Identifiable { case added, removed, resized; var id: String { rawValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Changes — \(summary.name)").font(.headline)
                    Text("Compare two scans of this drive").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if loaded && snapshots.count < 2 {
                ContentUnavailableView {
                    Label("Only one scan so far", systemImage: "clock.arrow.2.circlepath")
                } description: {
                    Text("Re-scan “\(summary.name)” to capture a second snapshot, then compare what changed.")
                } actions: {
                    if env.volumes.isConnected(key: summary.uuid ?? summary.name) {
                        Button("Re-scan Now") { env.rescan(volume: summary); dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(width: 660, height: 580)
        .task { await loadSnapshots() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            snapshotPickers
            if let diff { summaryBar(diff); changeList(diff) } else { ProgressView().frame(maxHeight: .infinity) }
        }
        .padding(16)
    }

    private var snapshotPickers: some View {
        HStack(spacing: 12) {
            Picker("From", selection: $baseId) {
                ForEach(snapshots) { snap in Text(Format.date(snap.scannedAt)).tag(Int64?.some(snap.id)) }
            }.fixedSize()
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("To", selection: $headId) {
                ForEach(snapshots) { snap in Text(Format.date(snap.scannedAt)).tag(Int64?.some(snap.id)) }
            }.fixedSize()
            Spacer()
        }
        .onChange(of: baseId) { _, _ in Task { await computeDiff() } }
        .onChange(of: headId) { _, _ in Task { await computeDiff() } }
    }

    private func summaryBar(_ diff: SnapshotDiff) -> some View {
        HStack(spacing: 10) {
            StatPill(title: "Added", value: "\(diff.addedCount)", tint: .green)
            StatPill(title: "Removed", value: "\(diff.removedCount)", tint: .red)
            StatPill(title: "Resized", value: "\(diff.resizedCount)", tint: .orange)
            StatPill(title: "Net change", value: Format.signedBytes(diff.netBytes),
                     tint: diff.netBytes >= 0 ? .green : .red)
        }
    }

    @ViewBuilder
    private func changeList(_ diff: SnapshotDiff) -> some View {
        Picker("", selection: $category) {
            Text("Added \(diff.addedCount)").tag(Category.added)
            Text("Removed \(diff.removedCount)").tag(Category.removed)
            Text("Resized \(diff.resizedCount)").tag(Category.resized)
        }
        .pickerStyle(.segmented).labelsHidden()

        let rows = list(for: category, diff: diff)
        if rows.isEmpty {
            ContentUnavailableView("No \(category.rawValue) files", systemImage: "equal.circle")
                .frame(maxHeight: .infinity)
        } else {
            List(rows) { entry in ChangeRow(entry: entry) }
            if diff.truncated {
                Text("Showing the largest \(rows.count) by size.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func list(for category: Category, diff: SnapshotDiff) -> [ChangedEntry] {
        switch category {
        case .added: return diff.added
        case .removed: return diff.removed
        case .resized: return diff.resized
        }
    }

    private func loadSnapshots() async {
        snapshots = (try? await env.catalog.changes.completeSnapshots(volumeId: summary.id)) ?? []
        if headId == nil { headId = snapshots.first?.id }
        if baseId == nil { baseId = snapshots.dropFirst().first?.id }
        loaded = true
        await computeDiff()
    }

    private func computeDiff() async {
        guard let baseId, let headId, baseId != headId else { diff = nil; return }
        diff = try? await env.catalog.changes.diff(baseSnapshotId: baseId, headSnapshotId: headId)
    }
}

private struct ChangeRow: View {
    let entry: ChangedEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(entry.relPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(detail).font(.callout).foregroundStyle(tint).monospacedDigit()
        }
    }

    private var icon: String {
        switch entry.kind {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .resized: return "arrow.up.arrow.down.circle.fill"
        }
    }
    private var tint: Color {
        switch entry.kind {
        case .added: return .green
        case .removed: return .red
        case .resized: return entry.delta >= 0 ? .orange : .blue
        }
    }
    private var detail: String {
        switch entry.kind {
        case .added: return Format.bytes(entry.newSize)
        case .removed: return Format.bytes(entry.oldSize)
        case .resized: return Format.signedBytes(entry.delta)
        }
    }
}
