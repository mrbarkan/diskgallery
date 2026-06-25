import Foundation
import GRDB

/// The execution engine facade (`catalog.execution`). Materializes copy operations
/// from the Organize plan, persists them, and runs them with checksum verification.
/// This is the app's deliberate file-mutation surface (via `FileCopier`); cataloging
/// stays read-only.
public final class ExecutorService: Sendable {
    let db: AppDatabase
    let copier: FileCopier
    let trasher: FileTrasher

    init(db: AppDatabase, hasher: HashVerifier) {
        self.db = db
        self.copier = FileCopier(hasher: hasher)
        self.trasher = FileTrasher()
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

    /// Runs the given operations in order. `resolve(volumeKey, relPath)` maps to the
    /// on-disk URL (nil when the drive isn't mounted). Honors task cancellation.
    public func run(_ ops: [FileOperation],
                    resolve: @Sendable (String, String) -> URL?,
                    progress: @Sendable @MainActor (FileOperation) -> Void) async {
        for op in ops {
            if Task.isCancelled { break }
            guard let id = op.id else { continue }

            guard let dstKey = op.destVolumeKey, let dstPath = op.destRelPath,
                  let src = resolve(op.sourceVolumeKey, op.sourceRelPath),
                  let dst = resolve(dstKey, dstPath) else {
                let updated = try? await finish(id, status: .skipped, skipReason: "drive not connected")
                if let updated { await progress(updated) }
                continue
            }

            _ = try? await update(id) { $0.status = .running; $0.startedAt = Date() }
            do {
                let updated: FileOperation?
                switch op.type {
                case .copy:
                    let outcome = try copier.copyVerified(from: src, to: dst)
                    updated = try await applyCopyOutcome(id, outcome)
                case .move:
                    updated = try await performMove(id, src: src, dst: dst)
                case .delete:
                    updated = try await finish(id, status: .skipped,
                                               skipReason: "delete is not available yet")
                }
                if let updated { await progress(updated) }
            } catch {
                if let updated = try? await finish(id, status: .failed, failureReason: error.localizedDescription) {
                    await progress(updated)
                }
            }
        }
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
