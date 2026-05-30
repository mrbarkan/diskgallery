import SwiftUI
import DiskGalleryCore

/// Everything the user has tagged, grouped by drive, in a suggested plug-in order —
/// so they know which drives to connect (and in what order) to act on their decisions.
struct ActionPlanView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stats: [DriveStats] = []

    /// Drives with pending decisions, most-to-do first.
    private var planned: [DriveStats] {
        stats.filter(\.hasPending).sorted { lhs, rhs in
            if lhs.pendingCount != rhs.pendingCount { return lhs.pendingCount > rhs.pendingCount }
            return lhs.deleteBytes > rhs.deleteBytes
        }
    }

    private var totalDelete: Int64 { stats.reduce(0) { $0 + $1.deleteBytes } }
    private var totalKeep: Int64 { stats.reduce(0) { $0 + $1.keepBytes } }
    private var totalReview: Int64 { stats.reduce(0) { $0 + $1.reviewBytes } }
    private var drivesToConnect: Int {
        planned.filter { !env.volumes.isConnected(key: $0.volumeKey) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if planned.isEmpty {
                ContentUnavailableView("Nothing tagged yet",
                                       systemImage: "checklist",
                                       description: Text("Mark files or folders Keep, Delete, or Review while browsing a drive — they’ll be collected here into a plan."))
            } else {
                List {
                    Section("Plug in these drives, in this order") {
                        ForEach(Array(planned.enumerated()), id: \.element.id) { index, drive in
                            DrivePlanRow(order: index + 1, drive: drive)
                        }
                    }
                }
            }
        }
        .navigationTitle("Action Plan")
        .task(id: env.dataVersion) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatPill(title: "To delete", value: Format.bytes(totalDelete), tint: .red)
            StatPill(title: "To keep", value: Format.bytes(totalKeep), tint: .green)
            StatPill(title: "To review", value: Format.bytes(totalReview), tint: .yellow)
            StatPill(title: "Drives to connect", value: "\(drivesToConnect)", tint: .accentColor)
        }
        .padding(12)
    }

    private func load() async {
        stats = (try? await env.catalog.planning.driveStats()) ?? []
    }
}

private struct DrivePlanRow: View {
    @Environment(AppEnvironment.self) private var env
    let order: Int
    let drive: DriveStats

    private var connected: Bool { env.volumes.isConnected(key: drive.volumeKey) }

    var body: some View {
        Button {
            env.selection = .volume(drive.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(order)")
                    .font(.callout.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(connected ? Color.accentColor : Color.secondary, in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        DriveStatusDot(connected: connected)
                        Text(drive.name).font(.headline)
                        if !connected {
                            Text("connect to act")
                                .font(.caption2).foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.15), in: Capsule())
                        }
                    }
                    Text("Last scanned \(Format.relativeDate(drive.scannedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 14) {
                        tagStat(.delete, count: drive.deleteCount, bytes: drive.deleteBytes)
                        tagStat(.keep, count: drive.keepCount, bytes: drive.keepBytes)
                        tagStat(.review, count: drive.reviewCount, bytes: drive.reviewBytes)
                    }
                    .padding(.top, 2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tagStat(_ tag: Tag, count: Int, bytes: Int64) -> some View {
        if count > 0 {
            HStack(spacing: 4) {
                Image(systemName: tag.symbol).foregroundStyle(tag.swiftUIColor)
                Text("\(count)").fontWeight(.medium)
                Text("· \(Format.bytes(bytes))").foregroundStyle(.secondary)
            }
            .font(.caption).monospacedDigit()
        }
    }
}
