import Foundation
import GRDB

/// A cached thumbnail's catalog reference. The image bytes live in a sidecar file
/// (`cacheFile`) under the App-Support thumbnails dir; this row records the source
/// identity (`volumeKey`+`relPath`) and freshness (`srcModifiedAt`+`srcSize`).
public struct Thumbnail: Codable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "thumbnail"

    public var id: Int64?
    public var volumeKey: String
    public var relPath: String
    public var cacheFile: String
    public var srcModifiedAt: Date?
    public var srcSize: Int64
    public var generatedAt: Date

    public init(id: Int64? = nil, volumeKey: String, relPath: String, cacheFile: String,
                srcModifiedAt: Date?, srcSize: Int64, generatedAt: Date) {
        self.id = id
        self.volumeKey = volumeKey
        self.relPath = relPath
        self.cacheFile = cacheFile
        self.srcModifiedAt = srcModifiedAt
        self.srcSize = srcSize
        self.generatedAt = generatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
