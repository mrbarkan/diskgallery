import Foundation
import GRDB

/// A folder on another drive holding every file of a source folder — same paths (inside
/// the folder) and sizes — found purely from the catalog.
public struct FolderMatch: Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case exact                                          // same files, nothing extra
        case superset(extraFiles: Int, extraBytes: Int64)   // every source file + extras
    }

    /// Content-level confidence, from cached SHA-256 hashes of the matched files.
    public enum Verification: Sendable, Equatable {
        case unverified             // at least one matched pair lacks a cached hash
        case verified               // every pair hashed, all equal
        case mismatched([String])   // paths (inside the folder) whose hashes differ
    }

    public var volumeId: Int64
    public var volumeKey: String
    public var volumeName: String
    public var snapshotId: Int64
    public var scannedAt: Date
    public var relPath: String      // the candidate folder on its drive; "" = drive root
    public var kind: Kind
    public var fileCount: Int       // comparable (non-junk) files in the candidate
    public var totalBytes: Int64
    public var verification: Verification

    public var id: String { "\(volumeId)|\(relPath)" }
}

/// Outcome of a folder search. `isEmpty` means the source has nothing to compare (no
/// files, or only Finder junk) — distinct from an empty `matches` (no copies found).
public struct FolderMatchResult: Sendable, Equatable {
    public var sourceFileCount: Int
    public var sourceBytes: Int64
    public var matches: [FolderMatch]

    public var isEmpty: Bool { sourceFileCount == 0 }
}

/// One file present in both folders, located on each drive, for hash verification.
public struct FolderMatchPair: Sendable, Equatable {
    public var relativePath: String     // path inside the folder
    public var sourceEntryId: Int64
    public var sourceRelPath: String    // path on the source drive
    public var sourceHash: String?
    public var targetEntryId: Int64
    public var targetRelPath: String    // path on the target drive
    public var targetHash: String?
}

/// Finds copies of a folder on other drives, entirely from stored snapshots (works fully
/// offline). Picks the folder's largest file as an anchor, looks it up by name + size on
/// every other drive, derives each hit's enclosing folder, then diffs file manifests.
///
/// READ-ONLY: catalog queries only. `MutationGuardTests` enforces that no
/// file-mutating API appears here.
public struct FolderMatchService: Sendable {
    let db: AppDatabase

    /// Caps the candidate folders examined, so a ubiquitous anchor file can't turn one
    /// lookup into thousands of manifest loads.
    public static let candidateLimit = 50

    /// Each drive's most recent *complete* snapshot — a paused or in-progress rescan
    /// would otherwise make a superset look exact.
    private static let latestCompleteCTE = """
        WITH latest AS (
            SELECT s.id FROM snapshot s
            WHERE s.id = (
                SELECT id FROM snapshot s2 WHERE s2.volumeId = s.volumeId AND s2.isComplete = 1
                ORDER BY s2.scannedAt DESC, s2.id DESC LIMIT 1
            )
        )
        """

    struct ManifestFile {
        var entryId: Int64
        var relPath: String
        var size: Int64
        var hash: String?
    }

    /// Manifests are keyed by path inside the folder.
    typealias Manifest = [String: ManifestFile]

    struct Candidate {
        var volumeId: Int64
        var volumeKey: String
        var volumeName: String
        var snapshotId: Int64
        var scannedAt: Date
        var root: String
    }

    public func findMatches(snapshotId: Int64, folderRelPath: String) async throws -> FolderMatchResult {
        try await db.writer.read { db in
            let source = try Self.manifest(db, snapshotId: snapshotId, folder: folderRelPath)
            var result = FolderMatchResult(sourceFileCount: source.count,
                                           sourceBytes: source.values.reduce(0) { $0 + $1.size },
                                           matches: [])
            guard let anchor = Self.anchor(of: source),
                  let volumeId = try Int64.fetchOne(db, sql: "SELECT volumeId FROM snapshot WHERE id = ?",
                                                    arguments: [snapshotId])
            else { return result }

            let candidates = try Self.candidates(db, anchorPath: anchor.key, anchorSize: anchor.value.size,
                                                 excludingVolume: volumeId)
            result.matches = try candidates.compactMap { candidate in
                let target = try Self.manifest(db, snapshotId: candidate.snapshotId, folder: candidate.root)
                return Self.compare(source: source, target: target, candidate: candidate)
            }
            .sorted(by: Self.order)
            return result
        }
    }

    /// Every file in both folders, paired up so each side can be hashed.
    public func pairs(sourceSnapshotId: Int64, sourceFolder: String,
                      targetSnapshotId: Int64, targetFolder: String) async throws -> [FolderMatchPair] {
        try await db.writer.read { db in
            let source = try Self.manifest(db, snapshotId: sourceSnapshotId, folder: sourceFolder)
            let target = try Self.manifest(db, snapshotId: targetSnapshotId, folder: targetFolder)
            return source.keys.sorted().compactMap { path in
                guard let s = source[path], let t = target[path] else { return nil }
                return FolderMatchPair(relativePath: path,
                                       sourceEntryId: s.entryId, sourceRelPath: s.relPath, sourceHash: s.hash,
                                       targetEntryId: t.entryId, targetRelPath: t.relPath, targetHash: t.hash)
            }
        }
    }

    /// Every non-junk file under `folder` ("" = the whole snapshot).
    static func manifest(_ db: Database, snapshotId: Int64, folder: String) throws -> Manifest {
        let rows: [Row]
        if folder.isEmpty {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, relPath, logicalSize, contentHash FROM entry
                WHERE snapshotId = ? AND isDir = 0
                """, arguments: [snapshotId])
        } else {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, relPath, logicalSize, contentHash FROM entry
                WHERE snapshotId = ? AND isDir = 0 AND relPath LIKE ? ESCAPE '\\'
                """, arguments: [snapshotId, SQLPattern.childrenPrefix(of: folder)])
        }
        let prefix = folder.isEmpty ? "" : folder + "/"
        var manifest: Manifest = [:]
        for row in rows {
            let relPath: String = row["relPath"]
            // SQLite LIKE is ASCII case-insensitive, so `Photos/%` also matches `photos/…`.
            guard relPath.hasPrefix(prefix) else { continue }
            let inner = String(relPath.dropFirst(prefix.count))
            guard !JunkFiles.isJunk(relPath: inner) else { continue }
            manifest[inner] = ManifestFile(entryId: row["id"], relPath: relPath,
                                           size: row["logicalSize"], hash: row["contentHash"])
        }
        return manifest
    }

    /// The largest file (ties → path ascending): big files are the most distinctive, so
    /// they yield the fewest false candidates.
    static func anchor(of manifest: Manifest) -> (key: String, value: ManifestFile)? {
        manifest.max { a, b in
            a.value.size != b.value.size ? a.value.size < b.value.size : a.key > b.key
        }
    }

    /// Folders on other drives that hold a same-name, same-size copy of the anchor at the
    /// same path inside them.
    static func candidates(_ db: Database, anchorPath: String, anchorSize: Int64,
                           excludingVolume volumeId: Int64) throws -> [Candidate] {
        let name = anchorPath.split(separator: "/").last.map(String.init) ?? anchorPath
        let rows = try Row.fetchAll(db, sql: """
            \(latestCompleteCTE)
            SELECT e.relPath AS relPath, s.id AS snapshotId, s.scannedAt AS scannedAt,
                   v.id AS volumeId, v.uuid AS uuid, v.name AS volumeName
            FROM entry e
            JOIN snapshot s ON s.id = e.snapshotId
            JOIN volume v ON v.id = s.volumeId
            WHERE e.isDir = 0 AND e.name = ? AND e.logicalSize = ?
              AND e.snapshotId IN (SELECT id FROM latest) AND s.volumeId != ?
            ORDER BY v.name COLLATE NOCASE, e.relPath
            """, arguments: [name, anchorSize, volumeId])

        var seen = Set<String>()
        var candidates: [Candidate] = []
        for row in rows {
            let relPath: String = row["relPath"]
            let root: String
            if relPath == anchorPath {
                root = ""
            } else if relPath.hasSuffix("/" + anchorPath) {
                root = String(relPath.dropLast(anchorPath.count + 1))
            } else {
                continue
            }
            let candidateVolume: Int64 = row["volumeId"]
            guard seen.insert("\(candidateVolume)|\(root)").inserted else { continue }
            let volumeName: String = row["volumeName"]
            candidates.append(Candidate(volumeId: candidateVolume,
                                        volumeKey: AnnotationStore.volumeKey(uuid: row["uuid"], name: volumeName),
                                        volumeName: volumeName, snapshotId: row["snapshotId"],
                                        scannedAt: row["scannedAt"], root: root))
            if candidates.count == candidateLimit { break }
        }
        return candidates
    }

    /// Nil unless `target` holds every source file at the same path with the same size.
    static func compare(source: Manifest, target: Manifest, candidate: Candidate) -> FolderMatch? {
        var mismatched: [String] = []
        var allHashed = true
        for (path, file) in source {
            guard let other = target[path], other.size == file.size else { return nil }
            if let a = file.hash, let b = other.hash {
                if a != b { mismatched.append(path) }
            } else {
                allHashed = false
            }
        }
        let extras = target.filter { source[$0.key] == nil }
        let verification: FolderMatch.Verification =
            !mismatched.isEmpty ? .mismatched(mismatched.sorted()) : (allHashed ? .verified : .unverified)
        return FolderMatch(volumeId: candidate.volumeId, volumeKey: candidate.volumeKey,
                           volumeName: candidate.volumeName, snapshotId: candidate.snapshotId,
                           scannedAt: candidate.scannedAt, relPath: candidate.root,
                           kind: extras.isEmpty ? .exact
                               : .superset(extraFiles: extras.count,
                                           extraBytes: extras.values.reduce(0) { $0 + $1.size }),
                           fileCount: target.count,
                           totalBytes: target.values.reduce(0) { $0 + $1.size },
                           verification: verification)
    }

    /// Exact first, then supersets with the fewest extras, then drive name, path.
    static func order(_ a: FolderMatch, _ b: FolderMatch) -> Bool {
        func extras(_ m: FolderMatch) -> Int {
            if case .superset(let n, _) = m.kind { return n }
            return 0
        }
        if extras(a) != extras(b) { return extras(a) < extras(b) }
        let byName = a.volumeName.localizedCaseInsensitiveCompare(b.volumeName)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.relPath < b.relPath
    }
}
