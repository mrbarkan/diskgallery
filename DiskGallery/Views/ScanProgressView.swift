import SwiftUI
import DiskGalleryCore

struct ScanProgressView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 16) {
            if env.stopRequested {
                stopOptions
            } else {
                progress
            }
        }
        .padding(36)
        .frame(minWidth: 420)
        .animation(.default, value: env.stopRequested)
    }

    // MARK: Running

    private var progress: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)

            if let progress = env.activeScan?.progress {
                Text("\(progress.filesSeen.formatted()) files · \(Format.bytes(progress.bytesSeen))")
                    .monospacedDigit()
                Text(progress.currentPath.isEmpty ? "…" : progress.currentPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 320)
                if progress.unreadableCount > 0 {
                    Text("\(progress.unreadableCount) items skipped (unreadable)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Button("Stop") { env.requestStop() }
        }
    }

    // MARK: Stop prompt (inline)

    private var stopOptions: some View {
        VStack(spacing: 14) {
            Image(systemName: "pause.circle").font(.system(size: 34)).foregroundStyle(.orange)
            Text("Stop scanning “\(env.activeScan?.volumeName ?? "")”?")
                .font(.headline)
            Text("Pause keeps everything scanned so far and lets you resume right where it left off. Discard throws the partial scan away.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)

            VStack(spacing: 8) {
                Button { env.pauseScan() } label: {
                    Label("Pause — Keep & Resume Later", systemImage: "pause.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                Button(role: .destructive) { env.discardScan() } label: {
                    Label("Discard Scan", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Button { env.continueScan() } label: {
                    Text("Keep Going").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: 320)
        }
    }

    private var title: String {
        let name = env.activeScan?.volumeName ?? ""
        return (env.activeScan?.isResume == true ? "Resuming " : "Cataloging ") + name
    }
}
