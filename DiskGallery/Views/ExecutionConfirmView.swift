import SwiftUI
import DiskGalleryCore

/// Confirm-once review sheet shown when a drive with ready copy/move operations connects.
struct ExecutionConfirmView: View {
    @Environment(AppEnvironment.self) private var env
    let prompt: AppEnvironment.ExecutionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to run", systemImage: "externaldrive.badge.checkmark")
                .font(.title2.bold())
            Text(summary).foregroundStyle(.secondary)
            Label("Backups and moves are copied and checksum-verified first; a move then trashes the original. A delete only happens when an identical copy is verified on a backup drive — otherwise it's skipped. Nothing is ever overwritten, and deletes go to the Trash.",
                  systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { env.executionPrompt = nil }
                Button("Run") { env.runConfirmedExecution() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var summary: String {
        var parts: [String] = []
        if prompt.copyCount > 0 { parts.append("\(prompt.copyCount) back up") }
        if prompt.moveCount > 0 { parts.append("\(prompt.moveCount) move") }
        if prompt.deleteCount > 0 { parts.append("\(prompt.deleteCount) delete") }
        let what = parts.isEmpty ? "\(prompt.fileCount) operations" : parts.joined(separator: " · ")
        return "\(what) · \(Format.bytes(prompt.totalBytes)) → \(prompt.driveNames.joined(separator: ", "))"
    }
}

/// Progress HUD shown while operations run.
struct ExecutionProgressView: View {
    @Environment(AppEnvironment.self) private var env
    let progress: AppEnvironment.ExecutionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Running…").font(.headline)
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            Text("\(progress.completed) of \(progress.total) · \(progress.currentName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel") { env.cancelExecution() }
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
