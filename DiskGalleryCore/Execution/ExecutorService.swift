import Foundation
import GRDB

/// A copy of a file located on a backup-role drive — used to verify that deleting
/// the source is safe (an identical copy survives elsewhere).
public struct BackupCandidate: Codable, Sendable, FetchableRecord {
    public var volumeKey: String
    public var relPath: String
}

/// The execution engine facade (`catalog.execution`). Materializes copy operations
/// from the Organize plan, persists them, and runs them with checksum verification.
/// This is the app's deliberate file-mutation surface (via `FileCopier`); cataloging
/// stays read-only.
public final class ExecutorService: Sendable {
    let db: AppDatabase
    let copier: FileCopier
    let trasher: FileTrasher
    let hasher: HashVerifier

    init(db: AppDatabase, hasher: HashVerifier) {
        self.db = db
        self.copier = FileCopier(hasher: hasher)
        self.trasher = FileTrasher()
        self.hasher = hasher
    }

    /// Build pending operations from a plan's steps of a given operation, for
    /// source+destination drives that are currently connected. Destination path
    /// mirrors the source path.
    private static func drafts(from steps: [PlanStep], planOp: PlanOperation, opType: OpType,
                              isConnected: (String) -> Bool, now: Date) -> [FileOperation] {
        steps.compactMap { step in
            guard step.operation == planOp,
                  let srcKey = step.sourceDriveKey, let srcPath = step.sourcePath,
                  let dstKey = step.destinationDriveKey,
                  isConnected(srcKey), isConnected(dstKey) else { return nil }
            return FileOperation(type: opType, sourceVolumeKey: srcKey, sourceRelPath: srcPath,
                                 destVolumeKey: dstKey, destRelPath: srcPath, bytes: step.bytes,
                                 status: .pending, createdAt: now)
        }
    }

    public static func copyDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                  now: Date) -> [FileOperation] {
        drafts(from: steps, planOp: .copy, opType: .copy, isConnected: isConnected, now: now)
    }

    public static func moveDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                  now: Date) -> [FileOperation] {
        drafts(from: steps, planOp: .move, opType: .move, isConnected: isConnected, now: now)
    }

    /// Build pending delete operations from a plan's delete steps, for source drives
    /// that are currently connected. Delete has no destination.
    public static func deleteDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                    now: Date) -> [FileOperation] {
        steps.compactMap { step in
            guard step.operation == .delete,
                  let srcKey = step.sourceDriveKey, let srcPath = step.sourcePath,
                  isConnected(srcKey) else { return nil }
            return FileOperation(type: .delete, sourceVolumeKey: srcKey, sourceRelPath: srcPath,
                                 destVolumeKey: nil, destRelPath: nil, bytes: step.bytes,
                                 status: .pending, createdAt: now)
        }
    }

    /// Persists drafts as pending rows; returns them with assigned ids.
    public func enqueue(_ ops: [FileOperation]) async throws -> [FileOperation] {
        try await db.writer.write { db in
            try ops.map { var o = $0; try o.insert(db); return o }
        }
    }

    public func pendingCopies() async throws -> [FileOperation] {
        try await db.writer.read { db in
            try FileOperation
                .filter(Column("status") == OpStatus.pending.rawValue
                        && Column("type") == OpType.copy.rawValue)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    /// All operations, newest first — the audit log / history.
    public func history() async throws -> [FileOperation] {
        try await db.writer.read { db in
            try FileOperation.order(Column("id").desc).fetchAll(db)
        }
    }

    /// Copies of `(name, size)` on backup-role drives OTHER than `excludingVolumeKey`,
    /// from each volume's latest snapshot. The volume key matches the catalog's
    /// `uuid ?? name` convention. Used by Delete to confirm a surviving copy exists
    /// on a backup before trashing the source.
    public func backupCandidates(name: String, size: Int64,
                                 excludingVolumeKey: String) async throws -> [BackupCandidate] {
        try await db.writer.read { db in
            try BackupCandidate.fetchAll(db, sql: """
                WITH latest AS (
                    SELECT s.id FROM snapshot s
                    WHERE s.id = (
                        SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId
                        ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
                    )
                )
                SELECT (CASE WHEN v.uuid IS NOT NULL THEN v.uuid ELSE v.name END) AS volumeKey,
                       e.relPath AS relPath
                FROM entry e
                JOIN snapshot s ON s.id = e.snapshotId
                JOIN volume v ON v.id = s.volumeId
                JOIN driveRole r ON (r.volumeKey = v.uuid OR (v.uuid IS NULL AND r.volumeKey = v.name))
                WHERE e.isDir = 0 AND e.name = ? AND e.logicalSize = ?
                      AND e.snapshotId IN (SELECT id FROM latest)
                      AND r.role IN (?, ?)
                      AND (CASE WHEN v.uuid IS NOT NULL THEN v.uuid ELSE v.name END) <> ?
                ORDER BY v.name COLLATE NOCASE, e.relPath
                """, arguments: [name, size, DriveRole.mainBackup.rawValue,
                                 DriveRole.fallbackBackup.rawValue, excludingVolumeKey])
        }
    }

    /// Runs the given operations in order. `resolve(volumeKey, relPath)` maps to the
    /// on-disk URL (nil when the drive isn't mounted). Honors task cancellation.
    public func run(_ ops: [FileOperation],
                    resolve: @Sendable (String, String) -> URL?,
                    progress: @Sendable @MainActor (FileOperation) -> Void) async {
        for op in ops {
            if Task.isCancelled { break }
            guard let id = op.id else { continue }

            // Every operation needs its source drive connected.
            guard let src = resolve(op.sourceVolumeKey, op.sourceRelPath) else {
                if let u = try? await finish(id, status: .skipped, skipReason: "drive not connected") {
                    await progress(u)
                }
                continue
            }

            _ = try? await update(id) { $0.status = .running; $0.startedAt = Date() }
            do {
                let updated: FileOperation?
                switch op.type {
                case .copy, .move:
                    // Copy and Move additionally need the destination drive connected.
                    guard let dstKey = op.destVolumeKey, let dstPath = op.destRelPath,
                          let dst = resolve(dstKey, dstPath) else {
                        if let u = try? await finish(id, status: .skipped,
                                                     skipReason: "destination drive not connected") {
                            await progress(u)
                        }
                        continue
                    }
                    if op.type == .copy {
                        updated = try await applyCopyOutcome(id, copier.copyVerified(from: src, to: dst))
                    } else {
                        updated = try await performMove(id, src: src, dst: dst)
                    }
                case .delete:
                    updated = try await performDelete(id, op: op, src: src, resolve: resolve)
                }
                if let updated { await progress(updated) }
            } catch {
                if let u = try? await finish(id, status: .failed, failureReason: error.localizedDescription) {
                    await progress(u)
                }
            }
        }
    }

    /// Trashes the source ONLY after finding a SHA-256-identical copy on a connected
    /// backup-role drive (a different volume — so the surviving copy is never the last).
    /// Idempotent: if the source is already gone, the delete is treated as done.
    /// If no verified backup copy is reachable, the source is left untouched (skipped).
    private func performDelete(_ id: Int64, op: FileOperation, src: URL,
                               resolve: @Sendable (String, String) -> URL?) async throws -> FileOperation? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: src.path, isDirectory: &isDir)
        if !exists {
            return try await finish(id, status: .done)       // already deleted (idempotent)
        }
        if isDir.boolValue {
            return try await finish(id, status: .skipped,
                                    skipReason: "folders aren't supported for verified delete")
        }
        let srcHash = try hasher.sha256(fileURL: src)
        let name = (op.sourceRelPath as NSString).lastPathComponent
        let candidates = try await backupCandidates(name: name, size: op.bytes,
                                                     excludingVolumeKey: op.sourceVolumeKey)
        for candidate in candidates {
            guard let url = resolve(candidate.volumeKey, candidate.relPath),
                  fm.fileExists(atPath: url.path) else { continue }
            if try hasher.sha256(fileURL: url) == srcHash {
                try trasher.trash(src)        // safe: a verified copy survives on a backup drive
                return try await finish(id, status: .done, sourceHash: srcHash)
            }
        }
        return try await finish(id, status: .skipped,
                                skipReason: "no checksum-verified copy on a connected backup drive")
    }

    /// A verified copy then trashes the source. The source is trashed ONLY after the
    /// destination copy is checksum-verified. Idempotent: if the source is already gone
    /// but the destination exists, the move is treated as already completed.
    private func performMove(_ id: Int64, src: URL, dst: URL) async throws -> FileOperation? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: src.path) {
            if fm.fileExists(atPath: dst.path) {
                return try await finish(id, status: .done)
            }
            return try await finish(id, status: .failed, failureReason: "source not found")
        }
        let outcome = try copier.copyVerified(from: src, to: dst)
        switch outcome {
        case .verified(let h), .skippedIdentical(let h):
            try trasher.trash(src)                 // safe: destination copy is verified
            return try await finish(id, status: .done, sourceHash: h, destHash: h)
        case .conflict:
            return try await finish(id, status: .skipped,
                                    skipReason: "a different file already exists at the destination")
        case .checksumMismatch:
            return try await finish(id, status: .failed, failureReason: "checksum mismatch after copy")
        }
    }

    /// Maps a copy outcome to a terminal status (used by `.copy` and the copy phase of `.move`).
    private func applyCopyOutcome(_ id: Int64, _ outcome: FileCopier.Outcome) async throws -> FileOperation? {
        switch outcome {
        case .verified(let h), .skippedIdentical(let h):
            return try await finish(id, status: .done, sourceHash: h, destHash: h)
        case .conflict:
            return try await finish(id, status: .skipped,
                                    skipReason: "a different file already exists at the destination")
        case .checksumMismatch:
            return try await finish(id, status: .failed, failureReason: "checksum mismatch after copy")
        }
    }

    // MARK: - Persistence helpers

    @discardableResult
    private func update(_ id: Int64, _ mutate: @Sendable @escaping (inout FileOperation) -> Void) async throws -> FileOperation? {
        try await db.writer.write { db in
            guard var op = try FileOperation.fetchOne(db, key: id) else { return nil }
            mutate(&op)
            try op.update(db)
            return op
        }
    }

    private func finish(_ id: Int64, status: OpStatus, sourceHash: String? = nil,
                        destHash: String? = nil, failureReason: String? = nil,
                        skipReason: String? = nil) async throws -> FileOperation? {
        try await update(id) {
            $0.status = status
            $0.finishedAt = Date()
            if let sourceHash { $0.sourceHash = sourceHash }
            if let destHash { $0.destHash = destHash }
            $0.failureReason = failureReason
            $0.skipReason = skipReason
        }
    }
}
