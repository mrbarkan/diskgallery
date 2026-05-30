import SwiftUI
import DiskGalleryCore

struct ScanProgressView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)

            Text(title).font(.headline)

            if let progress = env.activeScan?.progress {
                Text("\(progress.filesSeen.formatted()) files · \(Format.bytes(progress.bytesSeen))")
                    .monospacedDigit()
                Text(progress.currentPath.isEmpty ? "…" : progress.currentPath)
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

            Button("Stop", role: .cancel) { env.requestStop() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(minWidth: 400)
        .confirmationDialog("Stop scanning “\(env.activeScan?.volumeName ?? "")”?",
                            isPresented: Binding(get: { env.stopRequested },
                                                 set: { if !$0 { env.continueScan() } }),
                            titleVisibility: .visible) {
            Button("Keep Going") { env.continueScan() }
            Button("Pause — Keep & Resume Later") { env.pauseScan() }
            Button("Discard Scan", role: .destructive) { env.discardScan() }
        } message: {
            Text("Pause keeps everything scanned so far and lets you resume right where it left off. Discard throws the partial scan away.")
        }
    }

    private var title: String {
        let name = env.activeScan?.volumeName ?? ""
        return (env.activeScan?.isResume == true ? "Resuming " : "Cataloging ") + name
    }
}
