import SwiftUI
import DiskGalleryCore

struct DuplicatesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sets: [DuplicateSet] = []
    @State private var selectedSetID: DuplicateSet.ID?
    @State private var members: [DuplicateMember] = []
    @State private var verifying = false
    @State private var crossDriveOnly = false

    var body: some View {
        VSplitView {
            setsList
            membersPanel
        }
        .navigationTitle("Duplicates")
        .task(id: reloadKey) { await loadSets() }
    }

    private var reloadKey: String { "\(env.dataVersion)-\(crossDriveOnly)" }

    private var setsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Files with the same name and size").font(.headline)
                    Spacer()
                    Text("Reclaimable: \(Format.bytes(env.totalReclaimable))")
                        .foregroundStyle(.orange)
                }
                Toggle("Only copies that span different drives", isOn: $crossDriveOnly)
                    .toggleStyle(.checkbox).font(.callout)
                    .help("Find files backed up on more than one drive — useful for planning which drives are redundant")
            }
            .padding(8)

            if sets.isEmpty {
                ContentUnavailableView("No duplicates found",
                                       systemImage: "checkmark.circle",
                                       description: Text("Scan more drives to compare them."))
            } else {
                List(sets, selection: $selectedSetID) { set in
                    HStack {
                        Image(systemName: set.spansDrives ? "externaldrive.badge.checkmark" : "doc.on.doc")
                            .foregroundStyle(set.spansDrives ? env.theme.accent.palette.accent : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(set.name).lineLimit(1)
                            Text("\(set.copies) copies · \(Format.bytes(set.logicalSize)) each")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(set.spansDrives ? "on \(set.driveCount) drives: \(set.driveList.joined(separator: ", "))"
                                                 : "on one drive: \(set.driveList.joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Format.bytes(set.reclaimable)).foregroundStyle(.orange).monospacedDigit()
                    }
                    .tag(set.id)
                }
                .onChange(of: selectedSetID) { _, _ in Task { await loadMembers() } }
            }
        }
    }

    private var membersPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedSet?.name ?? "Select a duplicate set").font(.headline)
                Spacer()
                if let set = selectedSet {
                    Button {
                        Task { verifying = true; await env.verify(set: set); await loadMembers(); verifying = false }
                    } label: {
                        if verifying { ProgressView().controlSize(.small) }
                        else { Label("Verify by content", systemImage: "checkmark.shield") }
                    }
                    .disabled(verifying || !anyMemberConnected)
                    .help(anyMemberConnected ? "Hash the connected copies to confirm they're truly identical"
                                             : "Connect a drive holding these files to verify")
                }
            }
            .padding(8)

            if members.isEmpty {
                Spacer()
                Text("No set selected").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(members) { member in
                    HStack {
                        Circle()
                            .fill(env.volumes.isConnected(key: member.volumeUuid ?? member.volumeName) ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(member.volumeName).font(.callout)
                            Text(member.relPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        hashLabel(member)
                    }
                }
            }
        }
    }

    private func hashLabel(_ member: DuplicateMember) -> some View {
        Group {
            if let hash = member.contentHash {
                let confirmed = confirmedHashes.contains(hash)
                Label(confirmed ? "Confirmed" : String(hash.prefix(10)),
                      systemImage: confirmed ? "checkmark.seal.fill" : "number")
                    .font(.caption)
                    .foregroundStyle(confirmed ? Color.green : Color.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private var selectedSet: DuplicateSet? {
        sets.first { $0.id == selectedSetID }
    }

    private var anyMemberConnected: Bool {
        members.contains { env.volumes.isConnected(key: $0.volumeUuid ?? $0.volumeName) }
    }

    /// Hashes shared by two or more members are confirmed byte-identical duplicates.
    private var confirmedHashes: Set<String> {
        var counts: [String: Int] = [:]
        for member in members {
            if let hash = member.contentHash { counts[hash, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    private func loadSets() async {
        sets = (try? await env.catalog.duplicates.duplicateSets(crossDriveOnly: crossDriveOnly)) ?? []
        if !sets.contains(where: { $0.id == selectedSetID }) { selectedSetID = sets.first?.id }
        await loadMembers()
    }

    private func loadMembers() async {
        guard let set = selectedSet else { members = []; return }
        members = (try? await env.catalog.duplicates.members(name: set.name, logicalSize: set.logicalSize)) ?? []
    }
}
