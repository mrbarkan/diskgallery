import SwiftUI
import DiskGalleryCore

struct ScanProgressView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)

            Text("Cataloging \(env.activeScan?.volumeName ?? "")")
                .font(.headline)

            if let progress = env.activeScan?.progress {
                Text("\(progress.filesSeen.formatted()) files · \(Format.bytes(progress.bytesSeen))")
                    .monospacedDigit()
                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320)
                if progress.unreadableCount > 0 {
                    Text("\(progress.unreadableCount) items skipped (unreadable)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Cancel", role: .cancel) { env.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(minWidth: 400)
    }
}
