import SwiftUI
import DiskGalleryCore

/// Confirm-once review sheet shown when a drive with ready copy operations connects.
struct ExecutionConfirmView: View {
    @Environment(AppEnvironment.self) private var env
    let prompt: AppEnvironment.ExecutionPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Ready to back up", systemImage: "externaldrive.badge.checkmark")
                .font(.title2.bold())
            Text("\(prompt.fileCount) file\(prompt.fileCount == 1 ? "" : "s") · \(Format.bytes(prompt.totalBytes)) → \(prompt.driveNames.joined(separator: ", "))")
                .foregroundStyle(.secondary)
            Label("Files are copied and checksum-verified. Nothing is moved or deleted; existing files are never overwritten.",
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
        .frame(width: 440)
    }
}

/// Progress HUD shown while operations run.
struct ExecutionProgressView: View {
    @Environment(AppEnvironment.self) private var env
    let progress: AppEnvironment.ExecutionProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Backing up…").font(.headline)
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
