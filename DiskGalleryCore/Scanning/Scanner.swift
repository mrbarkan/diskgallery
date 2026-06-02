import Foundation
import GRDB

public enum ScanError: Error, Sendable {
    case notADirectory
}

/// Walks a mounted volume read-only and records a snapshot of every file and folder.
///
/// The traversal is an explicit **directory work-queue** (`pendingDir`), so a scan
/// can be paused and resumed later — even across launches. Folder sizes are rolled
/// up from the database once the queue drains.
///
/// READ-ONLY: only ever reads the filesystem (`contentsOfDirectory`, resource
/// values). No file-mutating API. `MutationGuardTests` enforces this.
public struct Scanner: Sendable {
    let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    public static let defaultBatchSize = 8_000

    /// Starts a fresh scan of `volumeURL`.
    public func scan(volumeURL: URL, batchSize: Int = Scanner.defaultBatchSize)
        -> AsyncThrowingStream<ScanProgress, Error>
    {
        run(volumeURL: volumeURL, resumeSnapshotId: nil, batchSize: batchSize, maxBatches: nil)
    }

    /// Continues a previously-paused (incomplete) scan. `volumeURL` is the drive's
    /// current mount point.
    public func resume(snapshotId: Int64, volumeURL: URL, batchSize: Int = Scanner.defaultBatchSize)
        -> AsyncThrowingStream<ScanProgress, Error>
    {
        run(volumeURL: volumeURL, resumeSnapshotId: snapshotId, batchSize: batchSize, maxBatches: nil)
    }

    // MARK: - Implementation

    /// `maxBatches` stops after N batches without finalizing (used by tests to create
    /// a deterministic paused state).
    func run(volumeURL: URL, resumeSnapshotId: Int64?, batchSize: Int, maxBatches: Int?)
        -> AsyncThrowingStream<ScanProgress, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try await execute(volumeURL: volumeURL, resumeSnapshotId: resumeSnapshotId,
                                      batchSize: batchSize, maxBatches: maxBatches, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()   // paused — snapshot kept, resumable
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(volumeURL: URL,
                         resumeSnapshotId: Int64?,
                         batchSize: Int,
                         maxBatches: Int?,
                         continuation: AsyncThrowingStream<ScanProgress, Error>.Continuation) async throws
    {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volumeURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.notADirectory
        }
        let scanRoot = volumeURL.resolvingSymlinksInPath()
        let isBootVolume = scanRoot.path == "/"
        let now = Date()

        // Create (or locate, when resuming) the snapshot + its root + initial queue.
        let snapshotId: Int64
        if let resumeId = resumeSnapshotId {
            snapshotId = resumeId
        } else {
            let info = VolumeMetadata.read(scanRoot)
            snapshotId = try await db.writer.write { db -> Int64 in
                let volumeId = try Scanner.findOrCreateVolume(db, info: info, now: now)
                var snapshot = Snapshot(volumeId: volumeId, scannedAt: now,
                                        totalCapacity: info.totalCapacity, freeCapacity: info.freeCapacity,
                                        fsType: info.fsType, isComplete: false)
                try snapshot.insert(db)
                let sid = snapshot.id!
                let maxId = try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0
                let rootId = maxId + 1
                let root = Entry(id: rootId, snapshotId: sid, parentId: nil, name: info.name,
                                 relPath: "", isDir: true, logicalSize: 0, allocSize: 0)
                try root.insert(db)
                try db.execute(sql: "UPDATE snapshot SET rootEntryId = ? WHERE id = ?", arguments: [rootId, sid])
                var pending = PendingDir(snapshotId: sid, entryId: rootId, relPath: "")
                try pending.insert(db)
                return sid
            }
        }

        // Restore running counters (resume-safe).
        let restored = try await db.writer.read { db -> (Int, Int64, Int64) in
            let files = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM entry WHERE snapshotId = ? AND isDir = 0", arguments: [snapshotId]) ?? 0
            let bytes = try Int64.fetchOne(db, sql: "SELECT IFNULL(SUM(logicalSize), 0) FROM entry WHERE snapshotId = ? AND isDir = 0", arguments: [snapshotId]) ?? 0
            let nextId = (try Int64.fetchOne(db, sql: "SELECT IFNULL(MAX(id), 0) FROM entry") ?? 0) + 1
            return (files, bytes, nextId)
        }
        var filesSeen = restored.0
        var bytesSeen = restored.1
        var nextId = restored.2
        var unreadable = 0

        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                                      .contentModificationDateKey, .isPackageKey, .isSymbolicLinkKey]
        let keySet = Set(keys)
        let fm = FileManager.default

        continuation.yield(ScanProgress(filesSeen: filesSeen, bytesSeen: bytesSeen, snapshotId: snapshotId))

        var batchCount = 0
        while true {
            try Task.checkCancellation()
            if let maxBatches, batchCount >= maxBatches { return }   // paused, snapshot left incomplete

            let pendingBatch = try await db.writer.read { db in
                try PendingDir.fetchAll(db, sql: "SELECT * FROM pendingDir WHERE snapshotId = ? ORDER BY id LIMIT 128",
                                        arguments: [snapshotId])
            }
            if pendingBatch.isEmpty { break }

            var toInsert: [Entry] = []
            var toEnqueue: [(entryId: Int64, relPath: String)] = []
            var processed: [Int64] = []
            var lastPath = ""

            for pdir in pendingBatch {
                let dirURL = pdir.relPath.isEmpty ? scanRoot : scanRoot.appendingPathComponent(pdir.relPath)
                lastPath = pdir.relPath
                let children: [URL]
                do {
                    children = try fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: keys, options: [])
                } catch {
                    unreadable += 1
                    processed.append(pdir.id!)
                    continue
                }
                for child in children {
                    let values = try? child.resourceValues(forKeys: keySet)
                    let isDir = values?.isDirectory ?? false
                    let name = values?.name ?? child.lastPathComponent
                    let logical = Int64(values?.fileSize ?? 0)
                    let alloc = Int64(values?.totalFileAllocatedSize ?? 0)
                    let rel = pdir.relPath.isEmpty ? name : pdir.relPath + "/" + name
                    if ScanExclusion.isExcluded(relPath: rel, isBootVolume: isBootVolume) { continue }
                    let id = nextId
                    nextId += 1
                    let ext = child.pathExtension.lowercased()
                    toInsert.append(Entry(id: id, snapshotId: snapshotId, parentId: pdir.entryId, name: name,
                                          relPath: rel, isDir: isDir, logicalSize: logical, allocSize: alloc,
                                          modifiedAt: values?.contentModificationDate, ext: ext.isEmpty ? nil : ext))
                    let isPackage = values?.isPackage ?? false
                    let isSymlink = values?.isSymbolicLink ?? false
                    if isDir && !isPackage && !isSymlink {
                        toEnqueue.append((id, rel))      // descend later; packages/symlinks stay leaves
                    }
                    if !isDir { filesSeen += 1; bytesSeen += logical }
                }
                processed.append(pdir.id!)
                if toInsert.count >= batchSize { break }
            }

            // One atomic step: insert entries, enqueue child dirs, drop processed dirs.
            let entriesToInsert = toInsert
            let dirsToEnqueue = toEnqueue
            let processedIds = processed
            try await db.writer.write { db in
                for entry in entriesToInsert { try entry.insert(db) }
                for item in dirsToEnqueue {
                    var pd = PendingDir(snapshotId: snapshotId, entryId: item.entryId, relPath: item.relPath)
                    try pd.insert(db)
                }
                for pid in processedIds {
                    try db.execute(sql: "DELETE FROM pendingDir WHERE id = ?", arguments: [pid])
                }
            }
            batchCount += 1
            continuation.yield(ScanProgress(filesSeen: filesSeen, bytesSeen: bytesSeen, currentPath: lastPath,
                                            unreadableCount: unreadable, snapshotId: snapshotId))
        }

        // Queue drained -> roll up folder sizes and mark complete.
        let rootLog = try await computeRollup(snapshotId: snapshotId)
        let finalFiles = filesSeen
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE snapshot SET isComplete = 1, fileCount = ?, totalLogical = ? WHERE id = ?",
                           arguments: [finalFiles, rootLog, snapshotId])
        }
        continuation.yield(ScanProgress(filesSeen: filesSeen, bytesSeen: bytesSeen, unreadableCount: unreadable,
                                        isComplete: true, snapshotId: snapshotId))
    }

    /// Computes each directory's subtree size from the stored tree in O(n) and
    /// returns the root's total. Children always have a higher id than their parent
    /// (ids are assigned in insertion order, parents before children), so descending
    /// id order visits every descendant before its ancestor.
    private func computeRollup(snapshotId: Int64) async throws -> Int64 {
        struct SizeRow: Decodable, FetchableRecord {
            var id: Int64
            var parentId: Int64?
            var isDir: Bool
            var logicalSize: Int64
            var allocSize: Int64
        }

        let dirSizes: [(id: Int64, log: Int64, alloc: Int64)] = try await db.writer.read { db in
            var subLog: [Int64: Int64] = [:]
            var subAlloc: [Int64: Int64] = [:]
            var dirs: [(id: Int64, log: Int64, alloc: Int64)] = []
            let cursor = try SizeRow.fetchCursor(db, sql: """
                SELECT id, parentId, isDir, logicalSize, allocSize FROM entry
                WHERE snapshotId = ? ORDER BY id DESC
                """, arguments: [snapshotId])
            while let row = try cursor.next() {
                let l = (subLog.removeValue(forKey: row.id) ?? 0) + row.logicalSize
                let a = (subAlloc.removeValue(forKey: row.id) ?? 0) + row.allocSize
                if row.isDir { dirs.append((row.id, l, a)) }
                if let parent = row.parentId {
                    subLog[parent, default: 0] += l
                    subAlloc[parent, default: 0] += a
                }
            }
            return dirs
        }

        let chunk = 5_000
        var i = 0
        while i < dirSizes.count {
            let slice = Array(dirSizes[i ..< min(i + chunk, dirSizes.count)])
            try await db.writer.write { db in
                for d in slice {
                    try db.execute(sql: "UPDATE entry SET subtreeLogicalSize = ?, subtreeAllocSize = ? WHERE id = ?",
                                   arguments: [d.log, d.alloc, d.id])
                }
            }
            i += chunk
        }

        return try await db.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT IFNULL(subtreeLogicalSize, 0) FROM entry WHERE snapshotId = ? AND parentId IS NULL",
                               arguments: [snapshotId]) ?? 0
        }
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
