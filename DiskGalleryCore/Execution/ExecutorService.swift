import Foundation
import GRDB

/// The execution engine facade (`catalog.execution`). Materializes copy operations
/// from the Organize plan, persists them, and runs them with checksum verification.
/// This is the app's deliberate file-mutation surface (via `FileCopier`); cataloging
/// stays read-only.
public final class ExecutorService: Sendable {
    let db: AppDatabase
    let copier: FileCopier

    init(db: AppDatabase, hasher: HashVerifier) {
        self.db = db
        self.copier = FileCopier(hasher: hasher)
    }

    /// Build pending copy operations from a plan's copy steps, for source+destination
    /// drives that are currently connected. Destination path mirrors the source path.
    public static func copyDrafts(from steps: [PlanStep], isConnected: (String) -> Bool,
                                  now: Date) -> [FileOperation] {
        steps.compactMap { step in
            guard step.operation == .copy,
                  let srcKey = step.sourceDriveKey, let srcPath = step.sourcePath,
                  let dstKey = step.destinationDriveKey,
                  isConnected(srcKey), isConnected(dstKey) else { return nil }
            return FileOperation(type: .copy, sourceVolumeKey: srcKey, sourceRelPath: srcPath,
                             destVolumeKey: dstKey, destRelPath: srcPath, bytes: step.bytes,
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
                let outcome = try copier.copyVerified(from: src, to: dst)
                let updated: FileOperation?
                switch outcome {
                case .verified(let h), .skippedIdentical(let h):
                    updated = try await finish(id, status: .done, sourceHash: h, destHash: h)
                case .conflict:
                    updated = try await finish(id, status: .skipped,
                                               skipReason: "a different file already exists at the destination")
                case .checksumMismatch:
                    updated = try await finish(id, status: .failed, failureReason: "checksum mismatch after copy")
                }
                if let updated { await progress(updated) }
            } catch {
                if let updated = try? await finish(id, status: .failed, failureReason: error.localizedDescription) {
                    await progress(updated)
                }
            }
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
