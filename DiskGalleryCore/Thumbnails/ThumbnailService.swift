import Foundation
import GRDB
import CryptoKit
import QuickLookThumbnailing
import ImageIO
import CoreGraphics

/// Owns the offline thumbnail cache: sidecar image files under `cacheDirectory`, a
/// `thumbnail` row per file (key + freshness), and QuickLook generation. The cache is
/// the app's own storage — generation reads drive files but writes only here.
public struct PreviewEntry: Codable, Sendable, FetchableRecord {
    public var relPath: String
    public var modifiedAt: Date?
    public var size: Int64
}

public struct ThumbnailService: Sendable {
    let db: AppDatabase
    let cacheDirectory: URL

    init(db: AppDatabase, cacheDirectory: URL) {
        self.db = db
        self.cacheDirectory = cacheDirectory
    }

    /// Deterministic sidecar filename for a (volumeKey, relPath) pair.
    private func cacheFile(volumeKey: String, relPath: String) -> String {
        let digest = SHA256.hash(data: Data("\(volumeKey)|\(relPath)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".heic"
    }

    public func store(_ data: Data, volumeKey: String, relPath: String,
                      srcModifiedAt: Date?, srcSize: Int64) async throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let file = cacheFile(volumeKey: volumeKey, relPath: relPath)
        try data.write(to: cacheDirectory.appendingPathComponent(file), options: .atomic)
        try await db.writer.write { db in
            // Upsert by (volumeKey, relPath).
            try db.execute(sql: """
                INSERT INTO thumbnail (volumeKey, relPath, cacheFile, srcModifiedAt, srcSize, generatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(volumeKey, relPath) DO UPDATE SET
                    cacheFile = excluded.cacheFile, srcModifiedAt = excluded.srcModifiedAt,
                    srcSize = excluded.srcSize, generatedAt = excluded.generatedAt
                """, arguments: [volumeKey, relPath, file, srcModifiedAt, srcSize, Date()])
        }
    }

    public func thumbnailURL(volumeKey: String, relPath: String) async throws -> URL? {
        let row = try await db.writer.read { db in
            try Thumbnail.filter(Column("volumeKey") == volumeKey && Column("relPath") == relPath).fetchOne(db)
        }
        guard let row else { return nil }
        let url = cacheDirectory.appendingPathComponent(row.cacheFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func isFresh(volumeKey: String, relPath: String, srcModifiedAt: Date?, srcSize: Int64) async throws -> Bool {
        let row = try await db.writer.read { db in
            try Thumbnail.filter(Column("volumeKey") == volumeKey && Column("relPath") == relPath).fetchOne(db)
        }
        guard let row else { return false }
        return row.srcSize == srcSize && row.srcModifiedAt == srcModifiedAt
            && FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(row.cacheFile).path)
    }

    /// Files in the volume's latest snapshot whose extension is in `categories`.
    public func entriesNeedingPreview(volumeId: Int64, categories: [FileCategory]) async throws -> [PreviewEntry] {
        let exts = FileCategory.extensions(for: categories)
        guard !exts.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: exts.count).joined(separator: ",")
        return try await db.writer.read { db in
            try PreviewEntry.fetchAll(db, sql: """
                SELECT e.relPath AS relPath, e.modifiedAt AS modifiedAt, e.logicalSize AS size
                FROM entry e
                WHERE e.snapshotId = (
                    SELECT id FROM snapshot WHERE volumeId = ? AND isComplete = 1
                    ORDER BY scannedAt DESC, id DESC LIMIT 1
                )
                AND e.isDir = 0 AND LOWER(e.ext) IN (\(placeholders))
                """, arguments: StatementArguments([volumeId] + exts.map { $0 as DatabaseValueConvertible }))
        }
    }

    /// QuickLook thumbnail as HEIC data, capped at `maxPixel` longest edge. nil if QL
    /// can't render the file (e.g. plain audio) — the caller shows a type glyph instead.
    public func generate(fileURL: URL, maxPixel: CGFloat) async -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL, size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let cg = rep.cgImage
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public func clear() async throws {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try await db.writer.write { db in try db.execute(sql: "DELETE FROM thumbnail") }
    }
}
