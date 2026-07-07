import SwiftUI
import AppKit
import DiskGalleryCore

/// Media-type filter chips for the Gallery.
enum GalleryFilter: String, CaseIterable, Identifiable {
    case all, photos, raw, video, docs, audio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"; case .photos: return "Photos"; case .raw: return "RAW"
        case .video: return "Video"; case .docs: return "Docs"; case .audio: return "Audio"
        }
    }
    var categories: [FileCategory] {
        switch self {
        case .all:    return [.photos, .raw, .video, .documents, .audio]
        case .photos: return [.photos]
        case .raw:    return [.raw]
        case .video:  return [.video]
        case .docs:   return [.documents]
        case .audio:  return [.audio]
        }
    }
}

/// How the Gallery grid is grouped into sections.
enum GalleryGrouping: String, CaseIterable, Identifiable {
    case none, shoot, drive, type
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"; case .shoot: return "Shoot"
        case .drive: return "Drive"; case .type: return "Type"
        }
    }
}

struct GalleryView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var entries: [GalleryEntry] = []
    @State private var dupCounts: [String: Int] = [:]            // "name\u{1}size" -> copies
    @State private var annotations: [String: Annotation] = [:]   // "volumeKey\u{1}relPath" -> annotation
    @State private var selectedIds: Set<Int64> = []
    @State private var loaded = false
    @State private var cachedCount = 0
    @State private var driveFilter: Int64?    // selected volume id, nil = all drives

    private var filter: GalleryFilter { env.viewPrefs.galleryFilter }
    private var grouping: GalleryGrouping { env.viewPrefs.galleryGrouping }

    private var columns: [GridItem] {
        let size = env.viewPrefs.galleryTileSize
        return [GridItem(.adaptive(minimum: size.gridMin, maximum: size.gridMax), spacing: 12)]
    }

    var body: some View {
        VStack(spacing: 0) {
            driveShelf
            Divider()
            controlBar
            Divider()
            ScrollView {
                if loaded && entries.isEmpty {
                    ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle.angled",
                        description: Text("Scan a drive and generate previews to see your photos here."))
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 12, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.title) { section in
                            Section {
                                ForEach(section.items) { entry in
                                    GalleryTile(entry: entry,
                                                dupCount: dupCounts["\(entry.name)\u{1}\(entry.logicalSize)"] ?? 0,
                                                annotation: annotations["\(entry.volumeKey)\u{1}\(entry.relPath)"],
                                                isSelected: selectedIds.contains(entry.id))
                                        .contentShape(Rectangle())
                                        .onTapGesture { handleTap(entry) }
                                }
                            } header: {
                                if !section.title.isEmpty {
                                    HStack {
                                        Text(section.title).font(.headline)
                                        Spacer()
                                        Text("\(section.items.count)").foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4).padding(.horizontal, 4)
                                    .frame(maxWidth: .infinity)
                                    .background(.regularMaterial)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Gallery")
        .task(id: "\(env.dataVersion)-\(filter.rawValue)-\(driveFilter ?? -1)-\(env.viewPrefs.hideHidden)") { await load() }
    }

    @ViewBuilder private var driveShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                driveCard(title: "All Drives", systemImage: "square.grid.2x2",
                          subtitle: "\(env.volumeSummaries.count) drives",
                          fraction: nil, connected: true, selected: driveFilter == nil) {
                    driveFilter = nil
                }
                ForEach(env.volumeSummaries) { summary in
                    let used = (summary.totalCapacity ?? 0) - (summary.freeCapacity ?? 0)
                    let frac = (summary.totalCapacity ?? 0) > 0 ? Double(used) / Double(summary.totalCapacity!) : nil
                    driveCard(title: summary.name, systemImage: "externaldrive.fill",
                              subtitle: Format.count(summary.fileCount),
                              fraction: frac,
                              connected: env.volumes.isConnected(key: summary.uuid ?? summary.name),
                              selected: driveFilter == summary.id) {
                        driveFilter = (driveFilter == summary.id) ? nil : summary.id
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func driveCard(title: String, systemImage: String, subtitle: String,
                           fraction: Double?, connected: Bool, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: systemImage).font(.system(size: 11))
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Circle().fill(connected ? .green : .secondary).frame(width: 6, height: 6)
                }
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: min(max(fraction, 0), 1)).controlSize(.mini).frame(width: 110)
                }
            }
            .padding(8)
            .frame(width: 150, alignment: .leading)
            .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? env.theme.accent.palette.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var controlBar: some View {
        @Bindable var prefs = env.viewPrefs
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(GalleryFilter.allCases) { f in
                        Button { env.viewPrefs.galleryFilter = f } label: {
                            Text(f.label).font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(filter == f ? env.theme.accent.palette.accent : Color(.controlBackgroundColor),
                                            in: Capsule())
                                .foregroundStyle(filter == f ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 8)
            Text("\(cachedCount) of \(entries.count) cached")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            Picker("Group", selection: $prefs.galleryGrouping) {
                ForEach(GalleryGrouping.allCases) { g in Text(g.label).tag(g) }
            }
            .pickerStyle(.menu).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func load() async {
        let items = (try? await env.catalog.gallery.items(
            categories: filter.categories, volumeId: driveFilter,
            hideHidden: env.viewPrefs.hideHidden)) ?? []

        // Duplicate counts (one bulk query), keyed like DuplicateSet.id.
        let sets = (try? await env.catalog.duplicates.duplicateSets(minCopies: 2, limit: 2000)) ?? []
        var dups: [String: Int] = [:]
        for s in sets { dups["\(s.name)\u{1}\(s.logicalSize)"] = s.copies }

        // Annotations + cached-thumbnail counts, bulk per drive.
        var annos: [String: Annotation] = [:]
        var cached = 0
        for (key, group) in Dictionary(grouping: items, by: \.volumeKey) {
            let relPaths = group.map(\.relPath)
            let map = (try? await env.catalog.annotations.annotations(volumeKey: key, relPaths: relPaths)) ?? [:]
            for (relPath, anno) in map { annos["\(key)\u{1}\(relPath)"] = anno }
            let hit = (try? await env.catalog.thumbnails.cachedRelPaths(volumeKey: key, relPaths: relPaths)) ?? []
            cached += hit.count
        }

        entries = items
        dupCounts = dups
        annotations = annos
        cachedCount = cached
        selectedIds = selectedIds.intersection(Set(items.map(\.id)))
        syncSelectionToEnv()
        loaded = true
    }

    /// The grid split into titled sections per the current grouping ("" title = no header).
    private var sections: [(title: String, items: [GalleryEntry])] {
        switch grouping {
        case .none:
            return entries.isEmpty ? [] : [("", entries)]
        case .drive:
            return grouped { $0.volumeName }
        case .type:
            return grouped { FileCategory.category(forExtension: $0.ext ?? "").label }
        case .shoot:
            return grouped { shoot(of: $0.relPath) }
        }
    }

    private func grouped(_ key: (GalleryEntry) -> String) -> [(title: String, items: [GalleryEntry])] {
        Dictionary(grouping: entries, by: key)
            .map { (title: $0.key, items: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The "shoot" = the file's parent folder name (or "—" at the volume root).
    private func shoot(of relPath: String) -> String {
        let parent = (relPath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "—" : (parent as NSString).lastPathComponent
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

            if env.viewPrefs.galleryShowLabels {
                Text(entry.name).font(.caption).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Image(systemName: "externaldrive").font(.system(size: 9))
                    Text(entry.volumeName).font(.system(size: 9)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
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
