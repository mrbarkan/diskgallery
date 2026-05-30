import Foundation
import GRDB

public enum ScanError: Error, Sendable {
    case cannotEnumerate
    case notADirectory
}

/// Walks a mounted volume read-only and records a snapshot of every file and
/// folder into the catalog. Folder sizes are rolled up and stored so the tree
/// browses instantly when the drive is later disconnected.
///
/// READ-ONLY: this type only ever *reads* the filesystem (resource values via the
/// enumerator). It contains no file-mutating API. The only writes are to the
/// catalog database. `MutationGuardTests` enforces this.
public struct Scanner: Sendable {
    let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    /// Default rows per insert transaction. Large batches amortise transaction cost.
    public static let defaultBatchSize = 8_000

    public func scan(volumeURL: URL, batchSize: Int = Scanner.defaultBatchSize)
        -> AsyncThrowingStream<ScanProgress, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try await runScan(volumeURL: volumeURL, batchSize: batchSize, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    private struct RollupNode {
        let id: Int64
        let parentId: Int64        // 0 == no parent (root)
        let isDir: Bool
        let log: Int64
        let alloc: Int64
    }

    private final class ErrorCounter: @unchecked Sendable { var count = 0 }

    private func runScan(volumeURL: URL,
                         batchSize: Int,
                         continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation) async throws
    {
        // Validate up front (read-only stat) so a bad path never creates a row.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volumeURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.notADirectory
        }

        let info = VolumeMetadata.read(volumeURL)
        let now = Date()

        // Create the volume (or reuse it) + a fresh snapshot + the root entry.
        let (snapshotId, rootId, startId) = try await db.writer.write { db -> (Int64, Int64, Int64) in
            let volumeId = try Scanner.findOrCreateVolume(db, info: info, now: now)
            var snapshot = Snapshot(volumeId: volumeId, scannedAt: now,
                                    totalCapacity: info.totalCapacity,
                                    freeCapacity: info.freeCapacity,
                                    fsType: info.fsType)
            try snapshot.insert(db)
            let sid = snapshot.id!
            let maxId = try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0
            let rootId = maxId + 1
            let root = Entry(id: rootId, snapshotId: sid, parentId: nil, name: info.name,
                             relPath: "", isDir: true, logicalSize: 0, allocSize: 0)
            try root.insert(db)
            return (sid, rootId, rootId + 1)
        }

        do {
            try await enumerateAndInsert(volumeURL: volumeURL, batchSize: batchSize,
                                         snapshotId: snapshotId, rootId: rootId, startId: startId,
                                         volumeName: info.name, continuation: continuation)
        } catch {
            // Roll back the whole partial snapshot (cascade deletes its entries).
            try? await db.writer.write { db in
                _ = try Snapshot.deleteOne(db, key: snapshotId)
            }
            throw error
        }
    }

    private func enumerateAndInsert(volumeURL: URL,
                                    batchSize: Int,
                                    snapshotId: Int64,
                                    rootId: Int64,
                                    startId: Int64,
                                    volumeName: String,
                                    continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation) async throws
    {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .nameKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .isSymbolicLinkKey, .isPackageKey,
        ]
        let keySet = Set(keys)
        let errors = ErrorCounter()

        let fm = FileManager.default
        // Resolve symlinks on the root so its prefix matches the paths the
        // enumerator yields (macOS reports e.g. /private/var, not /var).
        let scanRoot = volumeURL.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: scanRoot,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsPackageDescendants],
                                             errorHandler: { _, _ in errors.count += 1; return true })
        else { throw ScanError.cannotEnumerate }

        // macOS reports the same location as both /var/… and /private/var/…; the
        // root and the enumerated children can disagree. Normalize both sides.
        let rootPath = Scanner.normalizePrivate(scanRoot.path)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        var dirIds: [String: Int64] = ["": rootId]
        var nodes: [RollupNode] = [RollupNode(id: rootId, parentId: 0, isDir: true, log: 0, alloc: 0)]
        var buffer: [Entry] = []
        buffer.reserveCapacity(batchSize)
        var nextId = startId
        var filesSeen = 0
        var bytesSeen: Int64 = 0

        continuation.yield(ScanProgress(currentPath: volumeName))

        // `nextObject()` rather than for-in: the Sequence iterator is unavailable
        // from async contexts.
        while let object = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let url = object as? URL else { continue }

            let values = try? url.resourceValues(forKeys: keySet)
            let isDir = values?.isDirectory ?? false
            let name = values?.name ?? url.lastPathComponent
            let logical = Int64(values?.fileSize ?? 0)
            let alloc = Int64(values?.totalFileAllocatedSize ?? 0)
            let path = Scanner.normalizePrivate(url.path)
            let rel = path.hasPrefix(prefix)
                ? String(path.dropFirst(prefix.count))
                : (path as NSString).lastPathComponent
            let parentRel = (rel as NSString).deletingLastPathComponent
            let parentId = dirIds[parentRel] ?? rootId
            let id = nextId
            nextId += 1
            let ext = url.pathExtension.lowercased()

            buffer.append(Entry(id: id, snapshotId: snapshotId, parentId: parentId, name: name,
                                relPath: rel, isDir: isDir, logicalSize: logical, allocSize: alloc,
                                modifiedAt: values?.contentModificationDate,
                                ext: ext.isEmpty ? nil : ext))
            nodes.append(RollupNode(id: id, parentId: parentId, isDir: isDir, log: logical, alloc: alloc))
            if isDir { dirIds[rel] = id }
            else { filesSeen += 1; bytesSeen += logical }

            if buffer.count >= batchSize {
                try await insert(buffer)
                buffer.removeAll(keepingCapacity: true)
                continuation.yield(ScanProgress(filesSeen: filesSeen, bytesSeen: bytesSeen,
                                                currentPath: rel, unreadableCount: errors.count))
            }
        }
        if !buffer.isEmpty { try await insert(buffer) }

        // Bottom-up folder rollup in O(n): a pre-order walk reversed visits every
        // descendant before its ancestor, so each node's subtree total is complete
        // by the time we reach it.
        var subLog: [Int64: Int64] = [:]
        var subAlloc: [Int64: Int64] = [:]
        var dirRollups: [(id: Int64, log: Int64, alloc: Int64)] = []
        var rootLog: Int64 = 0
        for node in nodes.reversed() {
            let l = (subLog.removeValue(forKey: node.id) ?? 0) + node.log
            let a = (subAlloc.removeValue(forKey: node.id) ?? 0) + node.alloc
            if node.isDir { dirRollups.append((node.id, l, a)) }
            if node.id == rootId { rootLog = l }
            if node.parentId != 0 {
                subLog[node.parentId, default: 0] += l
                subAlloc[node.parentId, default: 0] += a
            }
        }

        try await writeDirRollups(dirRollups)

        let finalFileCount = filesSeen
        let finalRootLog = rootLog
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE snapshot SET rootEntryId = ?, fileCount = ?, totalLogical = ? WHERE id = ?",
                           arguments: [rootId, finalFileCount, finalRootLog, snapshotId])
        }

        continuation.yield(ScanProgress(filesSeen: filesSeen, bytesSeen: bytesSeen,
                                        unreadableCount: errors.count, isComplete: true, snapshotId: snapshotId))
    }

    private func insert(_ batch: [Entry]) async throws {
        try await db.writer.write { db in
            for entry in batch { try entry.insert(db) }
        }
    }

    private func writeDirRollups(_ rollups: [(id: Int64, log: Int64, alloc: Int64)]) async throws {
        let chunk = 5_000
        var i = 0
        while i < rollups.count {
            let slice = Array(rollups[i ..< min(i + chunk, rollups.count)])
            try await db.writer.write { db in
                for r in slice {
                    try db.execute(sql: "UPDATE entry SET subtreeLogicalSize = ?, subtreeAllocSize = ? WHERE id = ?",
                                   arguments: [r.log, r.alloc, r.id])
                }
            }
            i += chunk
        }
    }

    /// Collapses a leading `/private` so /var and /private/var paths compare equal.
    static func normalizePrivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path
    }

    static func findOrCreateVolume(_ db: Database, info: VolumeInfo, now: Date) throws -> Int64 {
        if let uuid = info.uuid {
            if let existing = try Volume.filter(Column("uuid") == uuid).fetchOne(db) {
                return existing.id!
            }
        } else if let existing = try Volume
            .filter(Column("uuid") == nil && Column("name") == info.name).fetchOne(db) {
            return existing.id!
        }
        var volume = Volume(uuid: info.uuid, name: info.name, createdAt: now)
        try volume.insert(db)
        return volume.id!
    }
}
