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
    public let planning: PlanningService
    public let changes: ChangeService
    public let backup: BackupService
    public let driveRoles: DriveRolesService
    public let unified: UnifiedBrowserService
    public let execution: ExecutorService
    public let thumbnails: ThumbnailService

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
        self.planning = PlanningService(db: db)
        self.changes = ChangeService(db: db)
        self.backup = BackupService(db: db)
        self.driveRoles = DriveRolesService(db: db)
        self.unified = UnifiedBrowserService(db: db)
        self.execution = ExecutorService(db: db, hasher: self.hasher)
        let thumbsDir = databaseURL.deletingLastPathComponent().appendingPathComponent("thumbnails", isDirectory: true)
        self.thumbnails = ThumbnailService(db: db, cacheDirectory: thumbsDir)
    }

    /// Opens (creating if needed) the catalog at the default Application Support path.
    public static func makeDefault() throws -> Catalog {
        try Catalog(databaseURL: AppDatabase.defaultURL())
    }
}
