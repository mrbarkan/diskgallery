import SwiftUI
import DiskGalleryCore

/// Per-drive sheet for selecting preview types and triggering thumbnail generation.
/// Presented from the drive context menu in the sidebar.
struct ScanCacheView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let summary: VolumeSummary

    /// The four pickable categories (not .all — it's the universal matcher).
    private static let categories: [FileCategory] = [.photos, .raw, .video, .documents]

    @State private var selected: Set<FileCategory> = []
    @State private var loaded = false

    private var accent: Color { env.theme.accent.palette.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Previews / Scan Cache", systemImage: "photo.stack")
                .font(.title2.bold())
            Text("Choose which file types DiskGallery generates offline previews for. Thumbnails are cached on this Mac so you can browse the drive's images after it disconnects.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(selected.count)/\(Self.categories.count) types cached")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Self.categories, id: \.self) { category in
                    Toggle(isOn: binding(for: category)) {
                        Text(category.label)
                    }
                    .toggleStyle(.checkbox)
                }
            }

            if let progress = env.thumbnailProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(accent)
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Cancel") { env.cancelThumbnails() }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button("Generate Previews") {
                    guard env.thumbnailProgress == nil else { return }
                    env.generateThumbnails(for: summary)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!env.volumes.isConnected(key: summary.uuid ?? summary.name)
                          || env.thumbnailProgress != nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if !loaded {
                selected = Set(env.previewTypes(for: summary))
                loaded = true
            }
        }
        .onChange(of: env.dataVersion) {
            // Re-read if the summary was refreshed externally (e.g. after setPreviewTypes).
            if loaded, let fresh = env.volumeSummaries.first(where: { $0.id == summary.id }) {
                selected = Set(env.previewTypes(for: fresh))
            }
        }
    }

    private func binding(for category: FileCategory) -> Binding<Bool> {
        Binding(
            get: { selected.contains(category) },
            set: { on in
                if on { selected.insert(category) } else { selected.remove(category) }
                let types = Self.categories.filter { selected.contains($0) }
                env.setPreviewTypes(types, forVolume: summary)
            }
        )
    }
}
