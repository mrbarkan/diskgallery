import SwiftUI
import DiskGalleryCore

/// "Find Copies on Other Drives" — folders on other drives that hold the same files as
/// the chosen one. Matching is catalog-only (works with drives offline); Verify hashes
/// both sides when both drives are connected.
struct FolderCopiesSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let target: FolderCopiesTarget

    @State private var result: FolderMatchResult?
    @State private var failed = false
    @State private var verifyingId: String?
    @State private var verifyDone = 0
    @State private var verifyTotal = 0
    @State private var verifyTask: Task<Void, Never>?
    @State private var unreadable: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Copies of “\(target.folder.name)”").font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 480)
        .task { await load() }
        .onDisappear { verifyTask?.cancel() }
    }

    private var subtitle: String {
        guard let result, !result.isEmpty else { return "On \(target.volumeName)" }
        let files = result.sourceFileCount == 1 ? "1 file" : "\(Format.count(result.sourceFileCount)) files"
        return "\(files) · \(Format.bytes(result.sourceBytes)) · on \(target.volumeName)"
    }

    @ViewBuilder
    private var content: some View {
        if let result {
            if result.isEmpty {
                ContentUnavailableView("Nothing to compare", systemImage: "folder",
                                       description: Text("This folder has no files to compare."))
            } else if result.matches.isEmpty {
                ContentUnavailableView("No copies found", systemImage: "externaldrive.badge.questionmark",
                                       description: Text("No copies found on other scanned drives. Results reflect each drive's latest scan."))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(result.matches) { matchRow($0) }
                    }
                    .padding(16)
                }
            }
        } else if failed {
            ContentUnavailableView("Couldn't search the catalog", systemImage: "exclamationmark.triangle")
        } else {
            ProgressView()
        }
    }

    private func matchRow(_ match: FolderMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(match.volumeName).fontWeight(.semibold).lineLimit(1)
                kindBadge(match)
                trustBadge(match)
                if !env.volumes.isConnected(key: match.volumeKey) { badge("Offline", .secondary) }
                Spacer(minLength: 8)
                Text(Format.size2(match.totalBytes))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(match.relPath.isEmpty ? "Drive root" : match.relPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text("scanned \(Format.relativeDate(match.scannedAt))")
                .font(.caption2).foregroundStyle(.tertiary)
            if case .mismatched(let paths) = match.verification {
                DisclosureGroup("\(paths.count) file\(paths.count == 1 ? "" : "s") differ") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(paths, id: \.self) { path in
                            Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.orange)
            }
            if let count = unreadable[match.id], count > 0 {
                Text("Couldn't verify \(count) file\(count == 1 ? "" : "s") — they may have moved or be unreadable.")
                    .font(.caption).foregroundStyle(.orange)
            }
            actions(match)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func actions(_ match: FolderMatch) -> some View {
        HStack(spacing: 8) {
            if verifyingId == match.id {
                ProgressView(value: Double(verifyDone), total: Double(max(verifyTotal, 1)))
                    .frame(width: 140)
                Text("\(verifyDone) of \(verifyTotal) files")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { verifyTask?.cancel() }
            } else {
                Button("Verify") { verify(match) }
                    .disabled(verifyingId != nil || missingDrive(for: match) != nil
                              || match.verification == .verified)
                    .help(missingDrive(for: match).map { "Connect “\($0)” to verify" }
                          ?? "Compare SHA-256 hashes of every file on both drives")
            }
            Spacer()
            Button("Reveal in Finder") {
                env.revealInFinder(volumeKey: match.volumeKey, relPath: match.relPath)
            }
            .disabled(!env.canReveal(volumeKey: match.volumeKey))
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func kindBadge(_ match: FolderMatch) -> some View {
        switch match.kind {
        case .exact:
            badge("Identical", .green)
        case .superset(let extraFiles, let extraBytes):
            badge("Contains all + \(extraFiles) extra file\(extraFiles == 1 ? "" : "s") (\(Format.bytes(extraBytes)))", .blue)
        }
    }

    @ViewBuilder
    private func trustBadge(_ match: FolderMatch) -> some View {
        switch match.verification {
        case .unverified: badge("Likely identical (catalog)", .secondary)
        case .verified:   badge("Verified ✓", .green)
        case .mismatched: badge("Differs", .orange)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }

    /// The drive that must be connected before this match can be verified, if any.
    private func missingDrive(for match: FolderMatch) -> String? {
        if !env.volumes.isConnected(key: target.volumeKey) { return target.volumeName }
        if !env.volumes.isConnected(key: match.volumeKey) { return match.volumeName }
        return nil
    }

    private func verify(_ match: FolderMatch) {
        verifyingId = match.id
        verifyDone = 0
        verifyTotal = 0
        verifyTask = Task {
            let outcome = await env.verifyFolderMatch(match, target: target) { done, total in
                verifyDone = done
                verifyTotal = total
            }
            if let outcome { unreadable[match.id] = outcome.unreadable }
            verifyingId = nil
            verifyTask = nil
            await load()
        }
    }

    private func load() async {
        if let found = await env.findFolderCopies(target) {
            result = found
        } else {
            failed = true
        }
    }
}
