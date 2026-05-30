import Foundation

/// The public entry point to the catalog. Owns the database and vends the engines.
/// Construct one with `makeDefault()` (app) or `Catalog(databaseURL:)` (tests).
///
/// GRDB is fully encapsulated behind this facade — the app target never imports it.
public final class Catalog: Sendable {
    let database: AppDatabase

    public let library: LibraryService
    public let scanner: Scanner
    public let duplicates: DuplicateEngine
    public let annotations: AnnotationStore
    public let search: SearchService
    public let hasher: HashVerifier
    public let finderTags: FinderTagWriter

    public init(databaseURL: URL) throws {
        let pool = try AppDatabase.makePool(at: databaseURL)
        let db = try AppDatabase(pool)
        self.database = db
        self.library = LibraryService(db: db)
        self.scanner = Scanner(db: db)
        self.duplicates = DuplicateEngine(db: db)
        self.annotations = AnnotationStore(db: db)
        self.search = SearchService(db: db)
        self.hasher = HashVerifier()
        self.finderTags = FinderTagWriter()
    }

    /// Opens (creating if needed) the catalog at the default Application Support path.
    public static func makeDefault() throws -> Catalog {
        try Catalog(databaseURL: AppDatabase.defaultURL())
    }
}
