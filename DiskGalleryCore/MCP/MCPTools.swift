import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The MCP tool surface: read the catalog, and propose an organization by writing
/// annotations. Every handler is a thin call into `Catalog`.
///
/// The proposal convention: an agent does not emit a plan object. It tags files
/// (`review`/`delete`/`move`/`backup`) with a note explaining why; the user reviews those
/// tags in the app's Tagged lists and runs Organize. Nothing here can move or delete a byte.
struct MCPTools: Sendable {
    let catalog: Catalog

    /// Media types counted for a folder's `mediaCount` and browsed by default.
    static let mediaCategories: [FileCategory] = [.photos, .raw, .video, .documents, .audio]
    static let maxBatch = 200

    // MARK: - Tool definitions (tools/list)

    static let definitions: [JSONValue] = [
        tool("list_drives",
             "List every drive in the catalog: id, name, whether it is connected right now, file count, capacity, and when it was last scanned. Start here — every other tool takes a volumeId.",
             properties: [:], required: []),

        tool("browse_folder",
             "List one folder level on a drive: its subfolders (with how many media files live beneath each) and its own files (with size, date, existing tag/color/note, and whether a thumbnail is cached). Walk the tree one call at a time.",
             properties: [
                "volumeId": schema("integer", "Drive id from list_drives."),
                "relPath": schema("string", "Folder path relative to the drive root. Omit or pass \"\" for the root."),
                "limit": schema("integer", "Max files to return (default 200, max 1000)."),
                "offset": schema("integer", "Files to skip, for paging (default 0)."),
                "hideHidden": schema("boolean", "Skip dotfiles (default true)."),
             ], required: ["volumeId"]),

        tool("search",
             "Full-text search file and folder names across every drive in the catalog.",
             properties: [
                "query": schema("string", "Search text; each word is prefix-matched."),
                "limit": schema("integer", "Max results (default 100, max 1000)."),
                "hideHidden": schema("boolean", "Skip dotfiles (default true)."),
             ], required: ["query"]),

        tool("get_file",
             "Details for one file: size, dates, its annotation, and every other copy of it in the catalog (same name and size) with the drive each copy sits on.",
             properties: [
                "volumeId": schema("integer", "Drive id."),
                "relPath": schema("string", "File path relative to the drive root."),
             ], required: ["volumeId", "relPath"]),

        tool("list_duplicates",
             "Duplicate sets across the library: files sharing a name and size, how many copies, how much space reclaiming them would free, and which drives hold them.",
             properties: [
                "minCopies": schema("integer", "Minimum copies to report (default 2)."),
                "limit": schema("integer", "Max sets (default 100, max 500)."),
                "crossDriveOnly": schema("boolean", "Only sets whose copies span two or more drives (default false)."),
             ], required: []),

        tool("get_thumbnail",
             "The cached thumbnail for a file, as a JPEG image, so you can look at the photo rather than guess from its name. Works offline — the drive need not be connected — but only for files whose preview was generated in the app.",
             properties: [
                "volumeId": schema("integer", "Drive id."),
                "relPath": schema("string", "File path relative to the drive root."),
                "maxPixel": schema("integer", "Longest edge in pixels (default 512, max 512)."),
             ], required: ["volumeId", "relPath"]),

        tool("list_annotations",
             "Every decision currently recorded — the user's and yours — optionally filtered to one tag.",
             properties: [
                "tag": schema("string", "One of: keep, delete, review, move, backup. Omit for all."),
                "limit": schema("integer", "Max rows (default 200, max 1000)."),
                "offset": schema("integer", "Rows to skip (default 0)."),
             ], required: []),

        tool("set_annotations",
             "Propose an organization by tagging files and folders. Each item sets any of tag, color, and note; omitted fields keep their current value. This is a proposal: the user reviews these in DiskGallery and decides. It never moves, copies, or deletes anything on a drive.",
             properties: [
                "items": .of([
                    "type": .string("array"),
                    "description": .string("Up to 200 items."),
                    "items": .of([
                        "type": .string("object"),
                        "properties": .of([
                            "volumeId": schema("integer", "Drive id."),
                            "relPath": schema("string", "Path relative to the drive root."),
                            "tag": schema("string", "keep, delete, review, move, backup, or none to clear."),
                            "color": schema("string", "Finder color: none, gray, green, purple, blue, yellow, red, orange."),
                            "note": schema("string", "Why you are proposing this. Pass \"\" to clear."),
                        ]),
                        "required": .of([.string("volumeId"), .string("relPath")]),
                    ]),
                ]),
             ], required: ["items"]),
    ]

    private static func tool(_ name: String, _ description: String,
                             properties: [String: JSONValue], required: [String]) -> JSONValue {
        .of([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .of([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .of(required.map { JSONValue.string($0) }),
            ]),
        ])
    }

    private static func schema(_ type: String, _ description: String) -> JSONValue {
        .of(["type": .string(type), "description": .string(description)])
    }

    // MARK: - Dispatch

    func call(name: String, arguments: JSONValue) async -> JSONValue {
        do {
            switch name {
            case "list_drives":      return try await listDrives()
            case "browse_folder":    return try await browseFolder(arguments)
            case "search":           return try await search(arguments)
            case "get_file":         return try await getFile(arguments)
            case "list_duplicates":  return try await listDuplicates(arguments)
            case "get_thumbnail":    return try await getThumbnail(arguments)
            case "list_annotations": return try await listAnnotations(arguments)
            case "set_annotations":  return try await setAnnotations(arguments)
            default:                 return Self.failure("Unknown tool: \(name)")
            }
        } catch let error as ToolError {
            return Self.failure(error.message)
        } catch {
            return Self.failure("\(error)")
        }
    }

    struct ToolError: Error { var message: String }

    private static func fail(_ message: String) -> ToolError { ToolError(message: message) }

    /// MCP tool results are content blocks; we hand back one JSON text block.
    private static func success(_ value: JSONValue) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .of([
            "content": .of([.of(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(false),
        ])
    }

    private static func failure(_ message: String) -> JSONValue {
        .of([
            "content": .of([.of(["type": .string("text"), "text": .string(message)])]),
            "isError": .bool(true),
        ])
    }

    // MARK: - Handlers

    private func listDrives() async throws -> JSONValue {
        let volumes = try await catalog.library.volumes()
        let mounted = Self.mountedKeys()
        return Self.success(.of(["drives": .of(volumes.map { v in
            .of([
                "volumeId": .int(v.id),
                "name": .string(v.name),
                "uuid": .string(v.uuid),
                "connected": .bool(mounted.contains(v.uuid ?? v.name)),
                "scanned": .bool(v.latestSnapshotId != nil),
                "lastScannedAt": .date(v.scannedAt),
                "fileCount": .int(v.fileCount),
                "totalCapacity": .int(v.totalCapacity),
                "freeCapacity": .int(v.freeCapacity),
            ])
        })]))
    }

    private func browseFolder(_ args: JSONValue) async throws -> JSONValue {
        let volumeId = try Self.requireInt(args, "volumeId")
        let relPath = args["relPath"]?.stringValue ?? ""
        let limit = min(args["limit"]?.intValue ?? 200, 1000)
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        let hideHidden = args["hideHidden"]?.boolValue ?? true

        let (volume, snapshotId) = try await requireScannedVolume(volumeId)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        // Folder entry → its direct children (reuses the app browser's own query).
        let folderEntry: Entry?
        if relPath.isEmpty {
            folderEntry = try await catalog.library.rootEntry(snapshotId: snapshotId)
        } else {
            folderEntry = try await catalog.library.entry(snapshotId: snapshotId, relPath: relPath)
        }
        guard let folderEntry, folderEntry.isDir else {
            throw Self.fail("No folder “\(relPath)” on \(volume.name).")
        }

        let subfolders = try await catalog.gallery.folders(
            volumeId: volumeId, underRelPath: relPath,
            categories: Self.mediaCategories, hideHidden: hideHidden)

        let children = try await catalog.library.children(
            parentId: folderEntry.id, snapshotId: snapshotId, hideHidden: hideHidden)
        let allFiles = children.filter { !$0.isDir }
        let page = Array(allFiles.dropFirst(offset).prefix(limit))

        let annotations = try await catalog.annotations.annotations(
            volumeKey: key, relPaths: page.map(\.relPath))
        let cached = try await catalog.thumbnails.cachedRelPaths(
            volumeKey: key, relPaths: page.map(\.relPath))

        return Self.success(.of([
            "drive": .string(volume.name),
            "volumeId": .int(volume.id),
            "relPath": .string(relPath),
            "subfolders": .of(subfolders.map { f in
                .of(["name": .string(f.name), "relPath": .string(f.relPath),
                     "mediaCount": .int(Int64(f.mediaCount))])
            }),
            "files": .of(page.map { entry in
                var fields: [String: JSONValue?] = [
                    "name": .string(entry.name),
                    "relPath": .string(entry.relPath),
                    "ext": .string(entry.ext),
                    "size": .int(entry.logicalSize),
                    "modifiedAt": .date(entry.modifiedAt),
                    "hasThumbnail": .bool(cached.contains(entry.relPath)),
                ]
                if let a = annotations[entry.relPath] {
                    fields["tag"] = .string(a.tag.mcpName)
                    fields["color"] = .string(a.color.mcpName)
                    fields["note"] = .string(a.note)
                }
                return .of(fields)
            }),
            "fileCount": .int(Int64(allFiles.count)),
            "offset": .int(Int64(offset)),
            "hasMore": .bool(offset + page.count < allFiles.count),
        ]))
    }

    private func search(_ args: JSONValue) async throws -> JSONValue {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            throw Self.fail("`query` is required.")
        }
        let limit = min(args["limit"]?.intValue ?? 100, 1000)
        let hideHidden = args["hideHidden"]?.boolValue ?? true
        let results = try await catalog.search.search(query, limit: limit, hideHidden: hideHidden)
        let volumes = try await catalog.library.volumes()
        let idByKey = Dictionary(volumes.map { ($0.uuid ?? $0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        return Self.success(.of(["matches": .of(results.map { r in
            .of([
                "name": .string(r.name),
                "relPath": .string(r.relPath),
                "isDir": .bool(r.isDir),
                "size": .int(r.displaySize),
                "drive": .string(r.volumeName),
                "volumeId": .int(idByKey[r.volumeUuid ?? r.volumeName]),
            ])
        })]))
    }

    private func getFile(_ args: JSONValue) async throws -> JSONValue {
        let volumeId = try Self.requireInt(args, "volumeId")
        let relPath = try Self.requireString(args, "relPath")
        let (volume, snapshotId) = try await requireScannedVolume(volumeId)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        guard let entry = try await catalog.library.entry(snapshotId: snapshotId, relPath: relPath) else {
            throw Self.fail("No file “\(relPath)” on \(volume.name).")
        }
        let annotation = try await catalog.annotations.annotation(volumeKey: key, relPath: relPath)
        let copies = entry.isDir ? [] : try await catalog.duplicates.members(
            name: entry.name, logicalSize: entry.logicalSize)
        let cached = try await catalog.thumbnails.cachedRelPaths(volumeKey: key, relPaths: [relPath])

        return Self.success(.of([
            "name": .string(entry.name),
            "relPath": .string(entry.relPath),
            "drive": .string(volume.name),
            "volumeId": .int(volume.id),
            "isDir": .bool(entry.isDir),
            "ext": .string(entry.ext),
            "size": .int(entry.isDir ? (entry.subtreeLogicalSize ?? 0) : entry.logicalSize),
            "modifiedAt": .date(entry.modifiedAt),
            "hasThumbnail": .bool(!cached.isEmpty),
            "tag": .string(annotation?.tag.mcpName ?? Tag.none.mcpName),
            "color": .string(annotation?.color.mcpName ?? FinderColor.none.mcpName),
            "note": .string(annotation?.note),
            "copies": .of(copies.map { m in
                .of(["drive": .string(m.volumeName), "relPath": .string(m.relPath),
                     "modifiedAt": .date(m.modifiedAt)])
            }),
        ]))
    }

    private func listDuplicates(_ args: JSONValue) async throws -> JSONValue {
        let minCopies = max(args["minCopies"]?.intValue ?? 2, 2)
        let limit = min(args["limit"]?.intValue ?? 100, 500)
        let crossDriveOnly = args["crossDriveOnly"]?.boolValue ?? false
        let sets = try await catalog.duplicates.duplicateSets(
            minCopies: minCopies, limit: limit, crossDriveOnly: crossDriveOnly, hideHidden: true)
        return Self.success(.of(["sets": .of(sets.map { s in
            .of([
                "name": .string(s.name),
                "size": .int(s.logicalSize),
                "copies": .int(Int64(s.copies)),
                "reclaimable": .int(s.reclaimable),
                "drives": .string(s.driveNames),
                "spansDrives": .bool(s.spansDrives),
            ])
        })]))
    }

    private func getThumbnail(_ args: JSONValue) async throws -> JSONValue {
        let volumeId = try Self.requireInt(args, "volumeId")
        let relPath = try Self.requireString(args, "relPath")
        let maxPixel = min(args["maxPixel"]?.intValue ?? 512, 512)
        let volume = try await requireVolume(volumeId)
        let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

        guard let url = try await catalog.thumbnails.thumbnailURL(volumeKey: key, relPath: relPath) else {
            throw Self.fail("No cached preview for “\(relPath)”. Generate previews for this drive in DiskGallery first.")
        }
        guard let jpeg = Self.jpegData(from: url, maxPixel: maxPixel) else {
            throw Self.fail("Could not read the cached preview for “\(relPath)”.")
        }
        return .of([
            "content": .of([.of([
                "type": .string("image"),
                "data": .string(jpeg.base64EncodedString()),
                "mimeType": .string("image/jpeg"),
            ])]),
            "isError": .bool(false),
        ])
    }

    private func listAnnotations(_ args: JSONValue) async throws -> JSONValue {
        let limit = min(args["limit"]?.intValue ?? 200, 1000)
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        let tags: [Tag]
        if let name = args["tag"]?.stringValue {
            guard let tag = Tag(mcpName: name) else { throw Self.fail("Unknown tag “\(name)”.") }
            tags = [tag]
        } else {
            tags = [.keep, .delete, .review, .move, .backup]
        }
        let all = try await catalog.annotations.taggedEntries(in: tags)
        let page = Array(all.dropFirst(offset).prefix(limit))
        return Self.success(.of([
            "annotations": .of(page.map { e in
                .of([
                    "drive": .string(e.volumeName),
                    "relPath": .string(e.relPath),
                    "name": .string(e.displayName),
                    "tag": .string(e.tag.mcpName),
                    "color": .string(e.color.mcpName),
                    "note": .string(e.note),
                    "size": .int(e.displaySize),
                ])
            }),
            "total": .int(Int64(all.count)),
            "offset": .int(Int64(offset)),
            "hasMore": .bool(offset + page.count < all.count),
        ]))
    }

    private func setAnnotations(_ args: JSONValue) async throws -> JSONValue {
        guard let items = args["items"]?.arrayValue, !items.isEmpty else {
            throw Self.fail("`items` must be a non-empty array.")
        }
        guard items.count <= Self.maxBatch else {
            throw Self.fail("Too many items (\(items.count)); send at most \(Self.maxBatch) per call.")
        }
        // Resolve every drive once.
        let volumes = try await catalog.library.volumes()
        let byId = Dictionary(volumes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var results: [JSONValue] = []
        var applied = 0
        for item in items {
            do {
                let volumeId = try Self.requireInt(item, "volumeId")
                let relPath = try Self.requireString(item, "relPath")
                guard let volume = byId[volumeId] else { throw Self.fail("No drive with id \(volumeId).") }
                let key = AnnotationStore.volumeKey(uuid: volume.uuid, name: volume.name)

                // Each setter preserves the dimensions the agent didn't mention.
                if let name = item["tag"]?.stringValue {
                    guard let tag = Tag(mcpName: name) else { throw Self.fail("Unknown tag “\(name)”.") }
                    try await catalog.annotations.setDecision(tag, volumeKey: key, relPath: relPath)
                }
                if let name = item["color"]?.stringValue {
                    guard let color = FinderColor(mcpName: name) else { throw Self.fail("Unknown color “\(name)”.") }
                    try await catalog.annotations.setColor(color, volumeKey: key, relPath: relPath)
                }
                if let note = item["note"]?.stringValue {
                    try await catalog.annotations.setNote(note, volumeKey: key, relPath: relPath)
                }
                applied += 1
                results.append(.of(["relPath": .string(relPath), "ok": .bool(true)]))
            } catch let error as ToolError {
                results.append(.of([
                    "relPath": .string(item["relPath"]?.stringValue ?? ""),
                    "ok": .bool(false),
                    "error": .string(error.message),
                ]))
            }
        }
        return Self.success(.of([
            "applied": .int(Int64(applied)),
            "failed": .int(Int64(items.count - applied)),
            "results": .of(results),
            "note": .string("These are proposals. The user reviews them in DiskGallery's Tagged lists and decides what runs."),
        ]))
    }

    // MARK: - Helpers

    private func requireVolume(_ id: Int64) async throws -> VolumeSummary {
        guard let volume = try await catalog.library.volume(id: id) else {
            throw Self.fail("No drive with id \(id). Call list_drives first.")
        }
        return volume
    }

    private func requireScannedVolume(_ id: Int64) async throws -> (VolumeSummary, Int64) {
        let volume = try await requireVolume(id)
        guard let snapshotId = volume.latestSnapshotId else {
            throw Self.fail("“\(volume.name)” has not been scanned yet.")
        }
        return (volume, snapshotId)
    }

    private static func requireInt(_ args: JSONValue, _ key: String) throws -> Int64 {
        guard let value = args[key]?.intValue else { throw fail("`\(key)` is required.") }
        return Int64(value)
    }

    private static func requireString(_ args: JSONValue, _ key: String) throws -> String {
        guard let value = args[key]?.stringValue else { throw fail("`\(key)` is required.") }
        return value
    }

    /// Currently-mounted volume keys (uuid, else name) — same keying the app uses.
    private static func mountedKeys() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        return Set(urls.map { url in
            let info = VolumeMetadata.read(url)
            return info.uuid ?? info.name
        })
    }

    /// Decodes the cached sidecar (HEIC) and re-encodes JPEG at `maxPixel`, so the image
    /// travels as something every MCP client can render.
    private static func jpegData(from url: URL, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - Wire names for the enums an agent reads and writes

extension Tag {
    var mcpName: String {
        switch self {
        case .none: return "none"; case .keep: return "keep"; case .delete: return "delete"
        case .review: return "review"; case .move: return "move"; case .backup: return "backup"
        }
    }
    init?(mcpName: String) {
        guard let match = Tag.allCases.first(where: { $0.mcpName == mcpName.lowercased() }) else { return nil }
        self = match
    }
}

extension FinderColor {
    var mcpName: String {
        switch self {
        case .none: return "none"; case .gray: return "gray"; case .green: return "green"
        case .purple: return "purple"; case .blue: return "blue"; case .yellow: return "yellow"
        case .red: return "red"; case .orange: return "orange"
        }
    }
    init?(mcpName: String) {
        guard let match = FinderColor.allCases.first(where: { $0.mcpName == mcpName.lowercased() }) else { return nil }
        self = match
    }
}
