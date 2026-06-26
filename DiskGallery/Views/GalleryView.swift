import SwiftUI
import AppKit
import DiskGalleryCore

struct GalleryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var entries: [GalleryEntry] = []
    @State private var dupCounts: [String: Int] = [:]            // "name\u{1}size" -> copies
    @State private var annotations: [String: Annotation] = [:]   // "volumeKey\u{1}relPath" -> annotation
    @State private var selectedIds: Set<Int64> = []
    @State private var loaded = false

    private static let mediaCategories: [FileCategory] = [.photos, .raw, .video, .documents]
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ScrollView {
            if loaded && entries.isEmpty {
                ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle.angled",
                    description: Text("Scan a drive and generate previews to see your photos here."))
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { entry in
                        GalleryTile(entry: entry,
                                    dupCount: dupCounts["\(entry.name)\u{1}\(entry.logicalSize)"] ?? 0,
                                    annotation: annotations["\(entry.volumeKey)\u{1}\(entry.relPath)"],
                                    isSelected: selectedIds.contains(entry.id))
                            .contentShape(Rectangle())
                            .onTapGesture { handleTap(entry) }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Gallery")
        .task(id: env.dataVersion) { await load() }
    }

    private func load() async {
        let items = (try? await env.catalog.gallery.items(categories: Self.mediaCategories)) ?? []

        // Duplicate counts: one bulk query, keyed exactly like DuplicateSet.id ("name\u{1}logicalSize").
        let sets = (try? await env.catalog.duplicates.duplicateSets(minCopies: 2, limit: 2000)) ?? []
        var dups: [String: Int] = [:]
        for s in sets { dups["\(s.name)\u{1}\(s.logicalSize)"] = s.copies }

        // Annotations: bulk per drive.
        var annos: [String: Annotation] = [:]
        for (key, group) in Dictionary(grouping: items, by: \.volumeKey) {
            let map = (try? await env.catalog.annotations.annotations(
                volumeKey: key, relPaths: group.map(\.relPath))) ?? [:]
            for (relPath, anno) in map { annos["\(key)\u{1}\(relPath)"] = anno }
        }

        entries = items
        dupCounts = dups
        annotations = annos
        selectedIds = selectedIds.intersection(Set(items.map(\.id)))   // drop ids that vanished
        syncSelectionToEnv()
        loaded = true
    }

    private func handleTap(_ entry: GalleryEntry) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selectedIds.contains(entry.id) { selectedIds.remove(entry.id) } else { selectedIds.insert(entry.id) }
        } else if mods.contains(.shift), let anchor = selectedIds.first,
                  let a = entries.firstIndex(where: { $0.id == anchor }),
                  let b = entries.firstIndex(where: { $0.id == entry.id }) {
            let range = a <= b ? a...b : b...a
            selectedIds.formUnion(entries[range].map(\.id))
        } else {
            selectedIds = [entry.id]
        }
        syncSelectionToEnv()
    }

    private func syncSelectionToEnv() {
        env.selectedGalleryItems = entries.filter { selectedIds.contains($0.id) }.map {
            GalleryItemRef(id: $0.id, relPath: $0.relPath, name: $0.name,
                           logicalSize: $0.logicalSize, volumeKey: $0.volumeKey)
        }
    }
}

private struct GalleryTile: View {
    @Environment(AppEnvironment.self) private var env
    let entry: GalleryEntry
    let dupCount: Int
    let annotation: Annotation?
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var triedLoad = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                thumbnail
                if let tag = annotation?.tag, tag != .none {
                    decisionDot(tag).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                }
                if dupCount >= 2 {
                    Text("×\(dupCount)").font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? env.theme.accent.palette.accent : .clear, lineWidth: 3))

            Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Image(systemName: "externaldrive").font(.system(size: 9))
                Text(entry.volumeName).font(.system(size: 9)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
        .task(id: entry.id) { await loadThumbnail() }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                .overlay(Image(systemName: glyph).font(.system(size: 28)).foregroundStyle(.secondary))
        }
    }

    private func decisionDot(_ tag: Tag) -> some View {
        Circle().fill(tag.swiftUIColor).frame(width: 12, height: 12)
            .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
    }

    private var glyph: String {
        switch FileCategory.category(forExtension: entry.ext ?? "") {
        case .photos:    return "photo"
        case .raw:       return "camera.aperture"
        case .video:     return "film"
        case .documents: return "doc.text"
        case .audio:     return "music.note"
        case .all:       return "doc"
        }
    }

    private func loadThumbnail() async {
        guard image == nil, !triedLoad else { return }
        triedLoad = true
        guard let url = (try? await env.catalog.thumbnails.thumbnailURL(
            volumeKey: entry.volumeKey, relPath: entry.relPath)) ?? nil else { return }
        if let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value {
            image = loaded
        }
    }
}
