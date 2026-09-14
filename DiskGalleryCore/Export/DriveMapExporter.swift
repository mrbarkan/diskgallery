import Foundation
import GRDB

/// A shareable picture of one drive: header facts, category totals, and the folder tree with
/// optional per-folder file samples. Embedded as JSON in the exported HTML so a later
/// "import a map and compare" feature can read the same file. Bump `format` on breaking changes.
public struct DriveMap: Codable, Sendable {
    public var format: Int = 1
    public var generatedAt: Date
    public var appVersion: String
    public var includesFiles: Bool
    public var filesPerFolder: Int?          // nil with includesFiles = every file
    public var drive: Drive
    public var categories: [CategoryTotal]
    /// Lowercased extension → category label, so the page colors files without its own table.
    public var extensionCategories: [String: String]
    public var root: Folder

    public struct Drive: Codable, Sendable {
        public var name: String
        public var uuid: String?
        public var fsType: String?
        public var totalCapacity: Int64?
        public var freeCapacity: Int64?
        public var scannedAt: Date
        public var connection: String?       // DriveHardware.Bus raw value; nil when unknown
        public var model: String?            // "vendor model"; nil when unknown
        public var fileCount: Int64
        public var folderCount: Int64
    }

    public struct CategoryTotal: Codable, Sendable, Equatable {
        public var name: String
        public var bytes: Int64
        public var count: Int64
    }

    public struct Folder: Codable, Sendable {
        public var name: String
        public var relPath: String
        public var modifiedAt: Date?
        public var bytes: Int64              // every visible file beneath, recursively
        public var fileCount: Int64          // every visible file beneath, recursively
        public var folders: [Folder]
        public var files: [File]             // sample of direct files, largest first
        public var moreFiles: Int64          // direct files left out of `files`
    }

    public struct File: Codable, Sendable {
        public var name: String
        public var bytes: Int64
        public var modifiedAt: Date?
        public var ext: String?
        public var hash: String?
    }
}

public struct DriveMapOptions: Sendable {
    public var includeFiles: Bool
    public var filesPerFolder: Int?          // nil = every file
    public var hideHidden: Bool
    public var appVersion: String

    public init(includeFiles: Bool = true, filesPerFolder: Int? = 20,
                hideHidden: Bool = true, appVersion: String = "") {
        self.includeFiles = includeFiles
        self.filesPerFolder = filesPerFolder
        self.hideHidden = hideHidden
        self.appVersion = appVersion
    }
}

public enum DriveMapError: LocalizedError {
    case noCompleteSnapshot

    public var errorDescription: String? {
        "This drive has no finished scan to export. Scan it, then try again."
    }
}

/// Builds and writes drive maps. Reads the catalog only; the single write is the output file.
public struct DriveMapExporter: Sendable {
    let db: AppDatabase

    /// The map of `volumeId`'s latest complete snapshot.
    public func build(volumeId: Int64, options: DriveMapOptions = DriveMapOptions()) async throws -> DriveMap {
        try await db.writer.read { db in
            guard let volume = try Volume.fetchOne(db, key: volumeId),
                  let snapshot = try Snapshot
                    .filter(Column("volumeId") == volumeId && Column("isComplete") == true)
                    .order(Column("scannedAt").desc, Column("id").desc)
                    .fetchOne(db),
                  let snapshotId = snapshot.id
            else { throw DriveMapError.noCompleteSnapshot }

            var tree = DriveMapTree(options: options)
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, parentId, name, relPath, isDir, logicalSize, modifiedAt, ext, contentHash
                FROM entry WHERE snapshotId = ?
                """, arguments: [snapshotId])
            while let row = try rows.next() { tree.add(row) }
            return tree.map(volume: volume, snapshot: snapshot, generatedAt: Date())
        }
    }

    /// Writes the map of `volumeId` to `url` as one self-contained HTML file.
    public func export(volumeId: Int64, options: DriveMapOptions = DriveMapOptions(), to url: URL) async throws {
        let map = try await build(volumeId: volumeId, options: options)
        try Data(try Self.render(map).utf8).write(to: url, options: .atomic)
    }

    /// The full HTML document with `map` embedded as JSON.
    public static func render(_ map: DriveMap) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // `<` only ever appears inside JSON strings, so escaping it keeps a filename like
        // "</script>" or "<!--" from ending the data block early.
        let json = String(decoding: try encoder.encode(map), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        return DriveMapTemplate.html.replacingOccurrences(of: "__DRIVE_MAP_JSON__", with: json)
    }
}

/// One pass over a snapshot's entries, folded into the nested map.
/// ponytail: keeps every folder plus each folder's sample in memory. Fine for millions of
/// entries; stream the JSON if a catalog ever outgrows RAM.
struct DriveMapTree {
    struct Dir {
        var name: String
        var relPath: String
        var modifiedAt: Date?
        var parentId: Int64?
    }

    /// A folder's direct files: totals for all of them, a sample of the largest.
    struct Direct {
        var bytes: Int64 = 0
        var count: Int64 = 0
        var sample: [DriveMap.File] = []

        mutating func add(_ file: DriveMap.File, options: DriveMapOptions) {
            bytes += file.bytes
            count += 1
            guard options.includeFiles else { return }
            sample.append(file)
            // ponytail: trim at 2× the limit instead of keeping a heap; same result, less code.
            if let limit = options.filesPerFolder, sample.count >= max(limit, 1) * 2 {
                sample = DriveMapTree.largest(sample, limit)
            }
        }
    }

    let options: DriveMapOptions
    var dirs: [Int64: Dir] = [:]
    var direct: [Int64: Direct] = [:]
    var rootId: Int64?
    var categories: [FileCategory: DriveMap.CategoryTotal] = [:]

    init(options: DriveMapOptions) { self.options = options }

    mutating func add(_ row: Row) {
        let relPath: String = row["relPath"]
        if options.hideHidden && PathVisibility.isHidden(relPath: relPath) { return }
        let id: Int64 = row["id"]
        let parentId: Int64? = row["parentId"]
        let name: String = row["name"]
        let modifiedAt: Date? = row["modifiedAt"]
        let isDir: Bool = row["isDir"]
        if isDir {
            dirs[id] = Dir(name: name, relPath: relPath, modifiedAt: modifiedAt, parentId: parentId)
            if parentId == nil { rootId = id }
            return
        }
        guard let parentId else { return }
        let ext: String? = row["ext"]
        let file = DriveMap.File(name: name, bytes: row["logicalSize"], modifiedAt: modifiedAt,
                                 ext: ext, hash: row["contentHash"])
        let category = FileCategory.category(forExtension: ext ?? (name as NSString).pathExtension)
        var total = categories[category] ?? DriveMap.CategoryTotal(name: Self.label(category), bytes: 0, count: 0)
        total.bytes += file.bytes
        total.count += 1
        categories[category] = total
        direct[parentId, default: Direct()].add(file, options: options)
    }

    func map(volume: Volume, snapshot: Snapshot, generatedAt: Date) -> DriveMap {
        var children: [Int64: [Int64]] = [:]
        for (id, dir) in dirs {
            if let parent = dir.parentId { children[parent, default: []].append(id) }
        }
        var folderCount: Int64 = 0
        func folder(_ id: Int64) -> DriveMap.Folder {
            let dir = dirs[id]!
            let subfolders = (children[id] ?? []).map(folder)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            folderCount += Int64(subfolders.count)
            let acc = direct[id] ?? Direct()
            let files = Self.largest(acc.sample, options.filesPerFolder)
            return DriveMap.Folder(
                name: dir.name, relPath: dir.relPath, modifiedAt: dir.modifiedAt,
                bytes: acc.bytes + subfolders.reduce(0) { $0 + $1.bytes },
                fileCount: acc.count + subfolders.reduce(0) { $0 + $1.fileCount },
                folders: subfolders, files: files,
                moreFiles: options.includeFiles ? acc.count - Int64(files.count) : 0)
        }
        var root = rootId.map(folder) ?? DriveMap.Folder(
            name: volume.name, relPath: "", modifiedAt: nil, bytes: 0, fileCount: 0,
            folders: [], files: [], moreFiles: 0)
        root.name = volume.name

        let hardware = volume.hardware
        let model = [hardware?.vendor, hardware?.model]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let drive = DriveMap.Drive(
            name: volume.name, uuid: volume.uuid, fsType: snapshot.fsType,
            totalCapacity: snapshot.totalCapacity, freeCapacity: snapshot.freeCapacity,
            scannedAt: snapshot.scannedAt,
            connection: hardware.flatMap { $0.bus == .unknown ? nil : $0.bus.rawValue },
            model: model.isEmpty ? nil : model,
            fileCount: root.fileCount, folderCount: folderCount)
        let order: [FileCategory] = [.photos, .video, .raw, .audio, .documents, .all]
        return DriveMap(
            generatedAt: generatedAt, appVersion: options.appVersion,
            includesFiles: options.includeFiles,
            filesPerFolder: options.includeFiles ? options.filesPerFolder : nil,
            drive: drive, categories: order.compactMap { categories[$0] },
            extensionCategories: Self.extensionCategories, root: root)
    }

    /// Largest first; name breaks ties so the sample is deterministic.
    static func largest(_ files: [DriveMap.File], _ limit: Int?) -> [DriveMap.File] {
        let sorted = files.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        return limit.map { Array(sorted.prefix($0)) } ?? sorted
    }

    static func label(_ category: FileCategory) -> String {
        category == .all ? "Other" : category.label
    }

    static let extensionCategories: [String: String] = {
        var out: [String: String] = [:]
        for category in FileCategory.allCases where category != .all {
            for ext in FileCategory.extensions(for: [category]) { out[ext] = category.label }
        }
        return out
    }()
}
