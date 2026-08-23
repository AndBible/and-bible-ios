// SearchIndexService.swift - transactional, canonical FTS5 Bible search index

import Foundation
import Observation
import SQLite3
import SwordKit

/** Thread-safe cancellation state shared between a Swift task and the serial SQLite mutation queue. */
private final class SearchIndexCancellationProbe: @unchecked Sendable {
    /// Protects the cancellation bit across task and GCD execution contexts.
    private let lock = NSLock()

    /// Whether the owning indexing task has requested cancellation.
    private var cancelled = false

    /** Records cancellation without blocking on the index mutation queue. */
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /** Throws before the next source read or generated-index write after cancellation. */
    func checkCancellation() throws {
        lock.lock()
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { throw CancellationError() }
    }
}

/**
 Explicitly transfers one backend source into the service's serialized indexing queue.

 Source adapters include mutable SWORD cursors and operation-owned SQLite readers that cannot claim
 general `Sendable` conformance. `createIndex` captures this box once and `buildIndex` is the only code
 that accesses its value after the handoff, entirely on `indexMutationQueue`.
 */
private final class SearchIndexSourceTransfer: @unchecked Sendable {
    /// Source value accessed only by the receiving serialized mutation closure.
    let value: any BibleSearchIndexSource

    /** Wraps one source without reading or mutating its backend. */
    init(_ value: any BibleSearchIndexSource) {
        self.value = value
    }
}

/**
 Opaque proof that one installed Search source was captured in a specific module-store generation.

 Search queues may retain source objects while earlier modules build. The token binds that retained
 source identity to the service instance, durable store generation, and monotonic in-memory
 invalidation epoch that were current at discovery. Callers can store and return the value only to
 the issuing `SearchIndexService`; they cannot construct or inspect its authorization fields.
 */
public struct SearchIndexSourceAuthorization: Sendable {
    /// Service instance that issued the authorization and is allowed to consume it.
    fileprivate let serviceIdentifier: UUID

    /// Exact source identity observed when the queue captured the source object.
    fileprivate let sourceIdentity: SearchIndexSourceIdentity

    /// Durable module-store generation observed with the source capture.
    fileprivate let storeGeneration: Int64

    /// In-memory invalidation epoch that detects a replacement even across an old SQLite snapshot.
    fileprivate let invalidationEpoch: UInt64
}

/**
 Tracks Android-compatible per-module Search mutation status across asynchronous queue handoffs.

 Android exposes a book as `SCHEDULED`/`CREATING`, rather than `DONE`, from the moment indexing is
 requested until its terminal outcome. Counts preserve that contract when duplicate requests for the
 same initials are queued: finishing the first request cannot make the module readable while another
 mutation remains scheduled.
 */
private final class SearchIndexModuleMutationState: @unchecked Sendable {
    /// Protects reference counts shared by callers, the mutation queue, Search tasks, and agent work.
    private let lock = NSLock()

    /// Number of scheduled or active mutations for each exact module initials value.
    private var countsByModule: [SwordJavaExactStringIdentity: Int] = [:]

    /**
     Marks one module unavailable before its mutation is handed to the serial SQLite queue.

     - Parameter moduleName: Exact generated-index owner entering scheduled/creating state.
     - Side effects: Increments one lock-protected reference count.
     - Failure modes: None; duplicate requests intentionally retain independent counts.
     - Important: Every call must be paired with `finishMutation(for:)` on every terminal path.
     */
    func beginMutation(for moduleName: String) {
        let identity = SwordJavaExactStringIdentity(moduleName)
        lock.lock()
        countsByModule[identity, default: 0] += 1
        lock.unlock()
    }

    /**
     Releases one scheduled/active mutation without clearing a later duplicate request.

     - Parameter moduleName: Exact generated-index owner reaching success, failure, or cancellation.
     - Side effects: Decrements or removes one lock-protected reference count.
     - Failure modes: An unmatched release is ignored defensively and cannot create a negative count.
     */
    func finishMutation(for moduleName: String) {
        let identity = SwordJavaExactStringIdentity(moduleName)
        lock.lock()
        if let count = countsByModule[identity] {
            if count > 1 {
                countsByModule[identity] = count - 1
            } else {
                countsByModule.removeValue(forKey: identity)
            }
        }
        lock.unlock()
    }

    /**
     Returns whether Android would currently expose one module as scheduled or creating.

     - Parameter moduleName: Exact generated-index owner queried by Search or agent code.
     - Returns: `true` while at least one mutation request remains pending or active.
     - Side effects: Acquires the state lock briefly; no database or observable state is changed.
     - Failure modes: None.
     */
    func isMutating(_ moduleName: String) -> Bool {
        let identity = SwordJavaExactStringIdentity(moduleName)
        lock.lock()
        let mutating = countsByModule[identity] != nil
        lock.unlock()
        return mutating
    }
}

/**
 Builds and queries Android-compatible Bible search indexes.

 Each indexed row stores localized display text alongside canonical OSIS identity, JSword book
 order, and canon section. Module-language analysis is applied before both indexing and querying.
 All index mutations run on one serial queue and publish explicit failure state; query failures are
 thrown to callers instead of being converted to empty result sets.
 */
@Observable
public final class SearchIndexService: @unchecked Sendable {
    /// Schema/content version for canonical metadata, analyzer identity, and attributed projection.
    public static let currentSchemaVersion = 10

    /// Android caps one module's Lucene result collection at 5,000 hits.
    public static let maximumResultsPerModule = 5_000

    private var db: OpaquePointer?
    @ObservationIgnored private let dbPath: String
    @ObservationIgnored private let indexMutationQueue = DispatchQueue(
        label: "org.andbible.ios.search-index.mutations",
        qos: .userInitiated
    )
    @ObservationIgnored private let indexMutationQueueSpecificKey = DispatchSpecificKey<Bool>()

    /// Unique owner embedded in opaque source authorizations so tokens cannot cross service instances.
    @ObservationIgnored private let sourceAuthorizationServiceIdentifier = UUID()

    /// Per-module scheduled/creating state that rejects newly admitted reads for the affected book.
    @ObservationIgnored private let moduleMutationState = SearchIndexModuleMutationState()

    /**
     Deterministic package-test checkpoint after metadata establishes a read snapshot.

     Runtime initializers leave this nil. Concurrency tests pause an already-authorized logical read
     while a writer rebuilds the same module, proving the result remains on one committed generation.
     */
    @ObservationIgnored private let readAuthorizationCheckpoint: (@Sendable (String) -> Void)?

    /** Deterministic package-test checkpoint after one aggregate readiness candidate is evaluated. */
    @ObservationIgnored private let aggregateReadinessCheckpoint: (@Sendable (String) -> Void)?

    /** Deterministic package-test checkpoint after one multi-module query operation completes. */
    @ObservationIgnored private let aggregateSearchCheckpoint: (@Sendable (String) -> Void)?

    /// Notification center carrying process-wide installed-module mutation events.
    @ObservationIgnored private let notificationCenter: NotificationCenter

    /// Observer token removed during service teardown.
    @ObservationIgnored private var moduleStoreObserver: NSObjectProtocol?

    /// Protects the fail-closed readiness bit and monotonic invalidation epoch across all readers.
    @ObservationIgnored private let moduleStoreInvalidationLock = NSLock()

    /// Number of overlapping notification handlers whose durable generation updates have not finished.
    @ObservationIgnored private var moduleStoreInvalidationsPending = 0

    /// Permanently retains fail-closed state when any durable invalidation cannot be persisted.
    @ObservationIgnored private var moduleStoreInvalidationFailed = false

    /// Advances before every store invalidation so already-pinned SQLite snapshots fail closed.
    @ObservationIgnored private var moduleStoreInvalidationEpoch: UInt64 = 0

    /// Main-thread generation that prevents a cancelled build from overwriting newer progress state.
    @ObservationIgnored private var indexingGeneration: UInt64 = 0

    /// Whether an index is currently being built.
    public var isIndexing = false

    /// Progress of the current indexing operation, from zero through one.
    public var indexProgress: Double = 0

    /// Human-readable description of the module currently being indexed.
    public var indexingModule = ""

    /// Current localized key being indexed.
    public var indexingKey = ""

    /// Most recent index creation or database-open failure shown by Search's retry UI.
    public private(set) var lastFailureDescription: String?

    /** Opens the shared Documents-backed search database and installs the current schema. */
    public init() {
        dbPath = Self.defaultDatabasePath()
        notificationCenter = .default
        readAuthorizationCheckpoint = nil
        aggregateReadinessCheckpoint = nil
        aggregateSearchCheckpoint = nil
        configureIndexMutationQueue()
        openDatabase()
        observeModuleStoreMutations()
    }

    /**
     Opens a caller-supplied search database.

     Tests use this initializer for isolated fixtures and failure injection. Runtime callers use
     `init()`.

     - Parameters:
       - databasePath: Isolated generated-index SQLite path to open or create.
       - notificationCenter: Center that publishes installed-module mutation events.
       - readAuthorizationCheckpoint: Optional deterministic pause after a logical query snapshot is
         authorized; runtime callers leave it nil.
       - aggregateReadinessCheckpoint: Optional deterministic pause after one multi-module readiness
         candidate is evaluated; runtime callers leave it nil.
       - aggregateSearchCheckpoint: Optional deterministic pause after one multi-module query completes;
         runtime callers leave it nil.
     - Side effects: Opens/migrates SQLite and registers one module-store observer.
     - Failure modes: Database initialization failure leaves the service fail-closed and publishes its
       diagnostic through `lastFailureDescription`; test checkpoints never run when nil.
     */
    init(
        databasePath: String,
        notificationCenter: NotificationCenter = .default,
        readAuthorizationCheckpoint: (@Sendable (String) -> Void)? = nil,
        aggregateReadinessCheckpoint: (@Sendable (String) -> Void)? = nil,
        aggregateSearchCheckpoint: (@Sendable (String) -> Void)? = nil
    ) {
        dbPath = databasePath
        self.notificationCenter = notificationCenter
        self.readAuthorizationCheckpoint = readAuthorizationCheckpoint
        self.aggregateReadinessCheckpoint = aggregateReadinessCheckpoint
        self.aggregateSearchCheckpoint = aggregateSearchCheckpoint
        configureIndexMutationQueue()
        openDatabase()
        observeModuleStoreMutations()
    }

    deinit {
        if let moduleStoreObserver {
            notificationCenter.removeObserver(moduleStoreObserver)
        }
        if let db { sqlite3_close(db) }
    }

    /** Marks the serial mutation queue so the synchronous compatibility delete cannot deadlock. */
    private func configureIndexMutationQueue() {
        indexMutationQueue.setSpecific(key: indexMutationQueueSpecificKey, value: true)
    }

    /**
     Observes the central installed-module mutation signal for this service's complete lifetime.

     The publisher fires after installs, restores, overwrites, and uninstalls have committed. The
     callback marks readiness unavailable synchronously, then advances the durable store generation
     on the serialized index queue before allowing another metadata check.

     - Side effects: Registers one `NotificationCenter` observer retained until `deinit`.
     - Failure modes: Durable invalidation failures leave Search fail-closed and publish the database
       error through `lastFailureDescription`.
     - Important: The callback may run on any posting thread and must not publish observable state
       directly outside the main queue.
     */
    private func observeModuleStoreMutations() {
        moduleStoreObserver = notificationCenter.addObserver(
            forName: SwordModuleStore.modulesDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidateReadinessAfterModuleStoreMutation()
        }
    }

    /**
     Invalidates every completed index generation after installed module storage changes.

     The shared mutation notification intentionally has no module payload, so all generated indexes
     advance together. Existing rows remain reclaimable and are replaced transactionally on the next
     build, but metadata from the prior generation can no longer advertise readiness or authorize a
     query. Serial execution also orders this invalidation after any in-progress build.

     - Side effects: Updates `search_index_state.store_generation` and may publish a failure message.
     - Failure modes: Missing/unwritable SQLite keeps the in-memory fail-closed bit set permanently
       for this service instance rather than serving potentially stale rows.
     - Important: This method is synchronous so notification return implies stale readiness is blocked.
     */
    private func invalidateReadinessAfterModuleStoreMutation() {
        beginModuleStoreInvalidation()
        var invalidationError: Error?
        let mutation = {
            guard let db = self.db else {
                invalidationError = SearchIndexError.databaseUnavailable(
                    operation: "invalidating indexes after a module-store mutation"
                )
                return
            }
            do {
                try Self.execute(
                    db: db,
                    sql: "UPDATE search_index_state SET store_generation = store_generation + 1 WHERE id = 1",
                    operation: "invalidating indexes after a module-store mutation"
                )
            } catch {
                invalidationError = error
            }
        }
        if DispatchQueue.getSpecific(key: indexMutationQueueSpecificKey) == true {
            mutation()
        } else {
            indexMutationQueue.sync(execute: mutation)
        }

        guard let invalidationError else {
            completeModuleStoreInvalidation(succeeded: true)
            return
        }
        completeModuleStoreInvalidation(succeeded: false)
        DispatchQueue.main.async { [weak self] in
            self?.lastFailureDescription = invalidationError.localizedDescription
        }
    }

    /**
     Starts one store invalidation and permanently advances the in-memory read epoch.

     The epoch changes before durable work enters the mutation queue. A logical reader that already
     pinned the previous WAL snapshot can therefore detect the event even after durable invalidation
     succeeds and the transient blocked bit clears.

     - Side effects: Increments the lock-protected epoch and marks all readiness/read paths blocked.
     - Failure modes: None; the epoch intentionally remains advanced if durable persistence later fails.
     */
    private func beginModuleStoreInvalidation() {
        moduleStoreInvalidationLock.lock()
        moduleStoreInvalidationEpoch &+= 1
        moduleStoreInvalidationsPending += 1
        moduleStoreInvalidationLock.unlock()
    }

    /**
     Completes one overlapping durable invalidation without clearing another pending or failed event.

     - Parameter succeeded: Whether this notification's generation update committed durably.
     - Side effects: Decrements the pending count, permanently records failure when needed, and allows
       readers only after every overlapping update succeeds.
     - Failure modes: An unmatched completion cannot make the count negative; a failed completion keeps
       the service fail-closed for the rest of its lifetime.
     */
    private func completeModuleStoreInvalidation(succeeded: Bool) {
        moduleStoreInvalidationLock.lock()
        if moduleStoreInvalidationsPending > 0 {
            moduleStoreInvalidationsPending -= 1
        }
        if !succeeded {
            moduleStoreInvalidationFailed = true
        }
        moduleStoreInvalidationLock.unlock()
    }

    /** Returns whether readiness checks must fail while durable invalidation is pending or failed. */
    private func isModuleStoreInvalidationBlocked() -> Bool {
        moduleStoreInvalidationLock.lock()
        let blocked = moduleStoreInvalidationFailed || moduleStoreInvalidationsPending > 0
        moduleStoreInvalidationLock.unlock()
        return blocked
    }

    /**
     Captures the monotonic store epoch that authorizes one newly admitted logical read.

     - Returns: Current epoch when durable invalidation is settled, otherwise `nil` to fail closed.
     - Side effects: Acquires the invalidation lock briefly without reading SQLite.
     - Failure modes: Returns `nil` while persistence is pending or permanently failed.
     */
    private func captureModuleStoreReadEpoch() -> UInt64? {
        moduleStoreInvalidationLock.lock()
        defer { moduleStoreInvalidationLock.unlock() }
        guard !moduleStoreInvalidationFailed,
              moduleStoreInvalidationsPending == 0 else { return nil }
        return moduleStoreInvalidationEpoch
    }

    /**
     Validates that no module-store mutation overlapped an admitted logical read.

     - Parameter expectedEpoch: Epoch captured before the read-only SQLite snapshot opened.
     - Returns: `true` only when the epoch is unchanged and no durable invalidation remains blocked.
     - Side effects: Acquires the invalidation lock briefly without changing readiness state.
     - Failure modes: Returns false for any intervening, pending, or failed store mutation.
     */
    private func moduleStoreReadEpochIsCurrent(_ expectedEpoch: UInt64) -> Bool {
        moduleStoreInvalidationLock.lock()
        let current = !moduleStoreInvalidationFailed
            && moduleStoreInvalidationsPending == 0
            && moduleStoreInvalidationEpoch == expectedEpoch
        moduleStoreInvalidationLock.unlock()
        return current
    }

    /**
     Opens SQLite and creates or migrates every generated search table as one schema contract.

     Failure leaves `db` nil and records a user-visible message. Generated indexes are safe to drop
     during migration because installed SWORD and Android-compatible SQLite Bibles remain
     authoritative and can be re-indexed.
     */
    private func openDatabase() {
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            dbPath,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "SQLite error \(openCode)"
            if let handle { sqlite3_close(handle) }
            db = nil
            lastFailureDescription = SearchIndexError.sqlite(
                operation: "opening the database",
                code: openCode,
                message: message
            ).localizedDescription
            return
        }

        do {
            try Self.execute(db: handle, sql: "PRAGMA journal_mode=WAL", operation: "enabling WAL")
            if Self.searchSchemaNeedsRebuild(db: handle) {
                try Self.dropGeneratedSchema(db: handle)
            }
            try Self.createSchema(db: handle)
            db = handle
            lastFailureDescription = nil
        } catch {
            sqlite3_close(handle)
            db = nil
            lastFailureDescription = error.localizedDescription
        }
    }

    /**
     Detects any persisted schema that cannot represent the canonical analyzer contracts.

     A legacy table missing even one required column is rebuilt. Metadata is checked separately so
     a partially upgraded database cannot advertise stale indexes as complete.
     */
    private static func searchSchemaNeedsRebuild(db: OpaquePointer?) -> Bool {
        let ftsColumns = tableColumns(db: db, tableName: "verse_fts")
        let strongsColumns = tableColumns(db: db, tableName: "verse_strongs")
        let metadataColumns = tableColumns(db: db, tableName: "indexed_modules")
        let stateColumns = tableColumns(db: db, tableName: "search_index_state")
        guard !ftsColumns.isEmpty
                || !strongsColumns.isEmpty
                || !metadataColumns.isEmpty
                || !stateColumns.isEmpty else { return false }

        let requiredFTS: Set<String> = [
            "search_text", "verse_key", "plain_text", "module_name", "entry_order",
            "osis_book", "display_book", "display_book_mode", "chapter", "verse", "book_order",
            "canon_scope",
        ]
        let requiredMetadata: Set<String> = [
            "module_name", "verse_count", "indexed_at", "schema_version", "language_code",
            "analyzer_id", "strongs_complete", "source_version", "source_fingerprint",
            "store_generation",
        ]
        let requiredStrongs: Set<String> = [
            "module_name", "token", "verse_key", "entry_order", "highlight_ranges",
        ]
        let requiredState: Set<String> = ["id", "store_generation"]
        return !requiredFTS.isSubset(of: ftsColumns)
            || !requiredStrongs.isSubset(of: strongsColumns)
            || !requiredMetadata.isSubset(of: metadataColumns)
            || !requiredState.isSubset(of: stateColumns)
    }

    private static func tableColumns(db: OpaquePointer?, tableName: String) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 1) {
            columns.insert(String(cString: pointer))
        }
        return columns
    }

    private static func dropGeneratedSchema(db: OpaquePointer?) throws {
        try execute(db: db, sql: "DROP TABLE IF EXISTS verse_strongs", operation: "dropping Strong's index")
        try execute(db: db, sql: "DROP TABLE IF EXISTS verse_fts", operation: "dropping text index")
        try execute(db: db, sql: "DROP TABLE IF EXISTS indexed_modules", operation: "dropping index metadata")
        try execute(db: db, sql: "DROP TABLE IF EXISTS search_index_state", operation: "dropping index state")
    }

    private static func createSchema(db: OpaquePointer?) throws {
        try execute(db: db, sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS verse_fts USING fts5(
                search_text,
                verse_key UNINDEXED,
                plain_text UNINDEXED,
                module_name UNINDEXED,
                entry_order UNINDEXED,
                osis_book UNINDEXED,
                display_book UNINDEXED,
                display_book_mode UNINDEXED,
                chapter UNINDEXED,
                verse UNINDEXED,
                book_order UNINDEXED,
                canon_scope UNINDEXED,
                tokenize='ascii'
            )
        """, operation: "creating the text index")
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS verse_strongs (
                module_name TEXT NOT NULL,
                token TEXT NOT NULL,
                verse_key TEXT NOT NULL,
                entry_order INTEGER NOT NULL,
                highlight_ranges TEXT NOT NULL,
                PRIMARY KEY (module_name, token, verse_key)
            )
        """, operation: "creating the Strong's index")
        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_verse_strongs_module_token
            ON verse_strongs (module_name, token, entry_order)
        """, operation: "creating the Strong's lookup")
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS search_index_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                store_generation INTEGER NOT NULL
            )
        """, operation: "creating search index state")
        try execute(db: db, sql: """
            INSERT OR IGNORE INTO search_index_state (id, store_generation) VALUES (1, 0)
        """, operation: "initializing search index state")
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS indexed_modules (
                module_name TEXT PRIMARY KEY,
                verse_count INTEGER NOT NULL,
                indexed_at TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                language_code TEXT NOT NULL,
                analyzer_id TEXT NOT NULL,
                strongs_complete INTEGER NOT NULL DEFAULT 0,
                source_version TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                store_generation INTEGER NOT NULL
            )
        """, operation: "creating index metadata")
        try execute(db: db, sql: """
            DELETE FROM indexed_modules
            WHERE schema_version != \(currentSchemaVersion) OR verse_count <= 0 OR analyzer_id = ''
               OR source_fingerprint = ''
        """, operation: "invalidating stale indexes")
    }

    /** Resolves the default Documents-backed index path and creates its parent directory. */
    private static func defaultDatabasePath() -> String {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let databaseURL = documents.appendingPathComponent("search_indexes.sqlite")
        try? fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return databaseURL.path
    }

    // MARK: - Index Management

    /**
     Returns whether current-schema completion metadata exists in the active module-store generation.

     This compatibility overload cannot compare source metadata directly, but central generation
     invalidation still prevents rows created before any observed install, overwrite, restore, or
     uninstall from advertising readiness.
     */
    public func hasIndex(for moduleName: String) -> Bool {
        hasIndex(moduleName: moduleName, expectedIdentity: nil)
    }

    /**
     Returns whether completion metadata exactly matches one installed source generation.

     - Parameter sourceIdentity: Current source version/fingerprint and exact module initials.
     - Returns: `true` only for current schema, non-empty rows, matching source metadata, and the active
       durable module-store generation.
     - Side effects: Performs a read-only SQLite metadata query.
     - Failure modes: Missing SQLite, invalidation in progress, SQL failure, or any mismatch returns
       `false`; readiness never falls back to initials alone.
     */
    public func hasIndex(for sourceIdentity: SearchIndexSourceIdentity) -> Bool {
        hasIndex(moduleName: sourceIdentity.moduleName, expectedIdentity: sourceIdentity)
    }

    /**
     Performs one fail-closed readiness lookup with an optional exact source comparison.

     - Parameters:
       - moduleName: Exact metadata owner.
       - expectedIdentity: Installed generation to compare, or `nil` for lifecycle-protected callers.
     - Returns: Whether metadata is complete and belongs to the active store generation.
     - Side effects: Opens and closes one operation-owned read snapshot.
     - Failure modes: Scheduled/active mutation, database, schema, identity, or invalidation failures
       return false instead of reading the writer connection's uncommitted transaction.
     */
    private func hasIndex(
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?
    ) -> Bool {
        do {
            return try withReadSnapshot(
                for: moduleName,
                operation: "checking \(moduleName) index"
            ) { readDatabase in
                indexIsReady(
                    db: readDatabase,
                    moduleName: moduleName,
                    expectedIdentity: expectedIdentity
                )
            }
        } catch {
            return false
        }
    }

    /**
     Validates completion metadata on a caller-owned SQLite connection.

     Public readiness calls supply a committed read snapshot; build verification supplies the writer
     before `COMMIT`, so a failed row-count or metadata check can roll back without publishing corrupt
     state. Keeping the SQL connection-explicit prevents reads from silently falling back to the writer.

     - Parameters:
       - db: Operation-owned read snapshot or pre-commit build writer connection.
       - moduleName: Exact metadata owner.
       - expectedIdentity: Installed generation to compare, or `nil` for lifecycle-protected callers.
     - Returns: Whether complete metadata matches schema, source identity, and store generation.
     - Side effects: Executes metadata and generation reads on `db`.
     - Failure modes: SQL, identity, schema, or concurrent module-store invalidation returns false.
     */
    private func indexIsReady(
        db: OpaquePointer,
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?
    ) -> Bool {
        guard !isModuleStoreInvalidationBlocked() else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT m.verse_count, m.source_version, m.source_fingerprint, m.store_generation
            FROM indexed_modules m
            JOIN search_index_state s ON s.id = 1 AND s.store_generation = m.store_generation
            WHERE m.module_name = ? AND m.schema_version = ? AND m.verse_count > 0
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, moduleName, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(Self.currentSchemaVersion))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let sourceVersion = Self.columnText(statement, index: 1),
              let sourceFingerprint = Self.columnText(statement, index: 2) else {
            return false
        }
        let storedGeneration = sqlite3_column_int64(statement, 3)
        if let expectedIdentity,
           (!SwordJavaStringIdentity.equals(expectedIdentity.moduleName, moduleName)
                || expectedIdentity.version != sourceVersion
                || expectedIdentity.fingerprint != sourceFingerprint) {
            return false
        }
        guard !isModuleStoreInvalidationBlocked(),
              (try? currentStoreGeneration(db: db)) == storedGeneration else {
            return false
        }
        return true
    }

    /**
     Returns whether a module's Strong's facet was completed transactionally.

     A completed module can legitimately contain zero Strong's tokens. The row-existence fallback
     keeps deterministic direct fixtures honest while `strongs_complete` distinguishes a scanned,
     empty module from a text-only partial index.
     */
    public func hasStrongsIndex(for moduleName: String) -> Bool {
        hasStrongsIndex(moduleName: moduleName, expectedIdentity: nil)
    }

    /**
     Returns whether the Strong's facet exactly matches one installed source generation.

     - Parameter sourceIdentity: Current source identity whose text and lexical facets are required.
     - Returns: `true` when exact text readiness and completed Strong's scanning both hold.
     - Side effects: Performs read-only SQLite readiness queries.
     - Failure modes: Missing metadata, source mismatch, pending invalidation, or SQL failure returns false.
     */
    public func hasStrongsIndex(for sourceIdentity: SearchIndexSourceIdentity) -> Bool {
        hasStrongsIndex(moduleName: sourceIdentity.moduleName, expectedIdentity: sourceIdentity)
    }

    /**
     Performs one Strong's readiness lookup after validating the corresponding text generation.

     - Parameters:
       - moduleName: Exact metadata and lexical-row owner.
       - expectedIdentity: Installed source generation, or `nil` for compatibility callers.
     - Returns: Whether the scan completed, including a completed zero-token module.
     - Side effects: Executes read-only SQLite metadata and row-existence statements.
     - Failure modes: Any text-readiness, SQL, or concurrent-invalidation failure returns false.
     */
    private func hasStrongsIndex(
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?
    ) -> Bool {
        do {
            return try withReadSnapshot(
                for: moduleName,
                operation: "checking \(moduleName) Strong's index"
            ) { readDatabase in
                guard indexIsReady(
                    db: readDatabase,
                    moduleName: moduleName,
                    expectedIdentity: expectedIdentity
                ) else {
                    return false
                }
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(
                    readDatabase,
                    """
                    SELECT m.strongs_complete,
                           EXISTS(SELECT 1 FROM verse_strongs WHERE module_name = ? LIMIT 1)
                    FROM indexed_modules m
                    JOIN search_index_state s ON s.id = 1 AND s.store_generation = m.store_generation
                    WHERE m.module_name = ? AND m.schema_version = ? AND m.verse_count > 0
                    """,
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK else { return false }
                sqlite3_bind_text(statement, 1, moduleName, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, moduleName, -1, sqliteTransient)
                sqlite3_bind_int(statement, 3, Int32(Self.currentSchemaVersion))
                guard sqlite3_step(statement) == SQLITE_ROW else { return false }
                guard !isModuleStoreInvalidationBlocked() else { return false }
                return sqlite3_column_int(statement, 0) != 0
                    || sqlite3_column_int(statement, 1) != 0
            }
        } catch {
            return false
        }
    }

    /**
     Returns module names whose requested facet is incomplete within one stable store epoch.

     - Parameters:
       - moduleNames: Exact generated-index owners in caller order.
       - requirement: Text or Strong's completion contract to inspect.
     - Returns: Unready names in input order. If store invalidation overlaps the aggregate, every
       input is returned so no module observed ready in an older generation can be omitted.
     - Side effects: Performs one committed readiness lookup per name.
     - Failure modes: Database, mutation, or cross-generation aggregate failures classify affected
       inputs, or the complete input after invalidation, as needing an index.
     */
    public func modulesNeedingIndex(
        from moduleNames: [String],
        requirement: SearchIndexRequirement = .text
    ) -> [String] {
        valuesNeedingIndexAcrossStableStoreEpoch(
            moduleNames,
            moduleName: { $0 }
        ) { moduleName in
            switch requirement {
            case .text: return hasIndex(for: moduleName)
            case .strongs: return hasStrongsIndex(for: moduleName)
            }
        }
    }

    /**
     Returns exact installed source generations whose requested facet is not ready.

     - Parameters:
       - sourceIdentities: Selected source generations in caller order.
       - requirement: Text or Strong's completion contract to inspect.
     - Returns: Unready identities in input order, including duplicates. If store invalidation
       overlaps the aggregate, every input is returned rather than mixing readiness generations.
     - Side effects: Performs one or more read-only SQLite readiness queries per source.
     - Failure modes: Database and identity failures classify the affected source as needing an index;
       cross-generation aggregation fails closed for the complete selection.
     */
    public func modulesNeedingIndex(
        from sourceIdentities: [SearchIndexSourceIdentity],
        requirement: SearchIndexRequirement = .text
    ) -> [SearchIndexSourceIdentity] {
        valuesNeedingIndexAcrossStableStoreEpoch(
            sourceIdentities,
            moduleName: \.moduleName
        ) { sourceIdentity in
            switch requirement {
            case .text: return hasIndex(for: sourceIdentity)
            case .strongs: return hasStrongsIndex(for: sourceIdentity)
            }
        }
    }

    /**
     Evaluates a multi-module readiness set without mixing module-store generations.

     Each item still owns an independent committed WAL snapshot so module-local mutations remain
     isolated. A surrounding in-memory epoch binds those snapshots into one logical aggregate: if a
     store notification occurs between any two checks, the helper returns the complete input and lets
     the caller retry or rebuild instead of omitting values observed ready in the old generation.

     - Parameters:
       - values: Ordered module names or exact source identities to evaluate.
       - moduleName: Extracts the exact initials used by the deterministic checkpoint.
       - isReady: Performs the requirement-specific committed readiness lookup.
     - Returns: Values that are not ready, or all values when invalidation is pending, failed, or
       overlaps the aggregate.
     - Side effects: Captures and validates the invalidation epoch and invokes the package-test
       checkpoint after each candidate without retaining a SQLite transaction.
     - Failure modes: The helper itself does not throw; readiness failures are reported by `isReady`
       as false and invalidation fails closed for the complete input.
     */
    private func valuesNeedingIndexAcrossStableStoreEpoch<Value>(
        _ values: [Value],
        moduleName: (Value) -> String,
        isReady: (Value) -> Bool
    ) -> [Value] {
        guard !values.isEmpty else { return [] }
        guard let aggregateEpoch = captureModuleStoreReadEpoch() else { return values }
        var missing: [Value] = []
        missing.reserveCapacity(values.count)
        for value in values {
            if !isReady(value) { missing.append(value) }
            aggregateReadinessCheckpoint?(moduleName(value))
        }
        guard moduleStoreReadEpochIsCurrent(aggregateEpoch) else { return values }
        return missing
    }

    /**
     Captures an opaque authorization for one source admitted immediately by `createIndex(source:)`.

     Queued production sources use the public resolver handshakes below so the epoch is captured
     before source discovery. This private compatibility path is safe only because its caller obtains
     the token and admits the same source in one uninterrupted method call.

     - Parameter source: Exact source passed directly to the immediate creation API.
     - Returns: Service-owned token consumed by that same creation invocation.
     - Side effects: Opens one operation-owned read snapshot to capture the durable store generation.
     - Throws: Invalid source identity, affected-module mutation, unavailable SQLite, or any module-store
       invalidation overlapping authorization capture.
     - Important: Callers that resolved or retained a source earlier must use
       `captureIndexCreationSource(named:resolving:)` or its batch form instead.
     */
    private func captureIndexCreationAuthorization(
        for source: any BibleSearchIndexSource
    ) throws -> SearchIndexSourceAuthorization {
        guard let invalidationEpoch = captureModuleStoreReadEpoch() else {
            throw SearchIndexError.indexUnavailable(
                moduleName: source.searchIndexModuleInfo.name
            )
        }
        return try captureIndexCreationAuthorization(
            for: source,
            expectedInvalidationEpoch: invalidationEpoch
        )
    }

    /**
     Resolves and authorizes a queued source inside one module-store epoch handshake.

     The epoch is captured before `resolve` executes and validated after both source inspection and
     durable generation capture. A replacement that completes after an old native handle is resolved
     but before it receives a token therefore rejects that handle even when its metadata fingerprint
     is identical to the replacement.

     - Parameters:
       - moduleName: Exact selected initials the resolver must return.
       - resolve: Synchronous current-store resolver. It is executed once and never retained.
     - Returns: Resolved source plus opaque authorization, or nil when the resolver has no exact source.
     - Side effects: Executes caller resolution and opens one committed SQLite generation snapshot.
     - Throws: Pending/overlapping store invalidation, mismatched source initials, invalid identity, or
       SQLite failure. No source content is streamed or generated rows mutated.
     - Important: Callers retaining sources across other builds must use this handshake instead of
       resolving first and calling `captureIndexCreationAuthorization(for:)` afterward.
     */
    public func captureIndexCreationSource(
        named moduleName: String,
        resolving resolve: () -> (any BibleSearchIndexSource)?
    ) throws -> (
        source: any BibleSearchIndexSource,
        authorization: SearchIndexSourceAuthorization
    )? {
        guard let invalidationEpoch = captureModuleStoreReadEpoch() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        guard let source = resolve() else { return nil }
        guard SwordJavaStringIdentity.equals(
            source.searchIndexModuleInfo.name,
            moduleName
        ) else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        let authorization = try captureIndexCreationAuthorization(
            for: source,
            expectedInvalidationEpoch: invalidationEpoch
        )
        return (source, authorization)
    }

    /**
     Resolves and authorizes one ordered batch of queued sources inside a single store epoch.

     Search first checks immutable presentation identities to determine which selected translations
     are missing an index. It then calls this method once for that missing subset, allowing the
     resolver to open one current native inventory and share its owner across every queued source.
     Capturing the epoch before the batch resolver executes prevents either a pre-resolution or an
     intra-batch module replacement from blessing retained stale handles.

     - Parameters:
       - moduleNames: Ordered exact initials requiring current-store source resolution.
       - resolve: Synchronous batch resolver executed exactly once for a non-empty input. It must
         return one exact source per requested name in the same order, or nil when current ownership
         cannot be established for the complete batch.
     - Returns: Ordered sources paired with service-owned authorizations, an empty array for empty
       input, or nil when the resolver cannot prove the complete current batch.
     - Side effects: Executes caller resolution once and opens one committed SQLite generation
       snapshot per resolved source; it does not stream content or mutate generated index rows.
     - Throws: Pending/overlapping store invalidation, incomplete or reordered resolver output,
       mismatched source identity, affected-module mutation, or SQLite failure. A failure returns no
       partial authorized batch.
     - Important: Every returned authorization shares the epoch captured before resolution. A queued
       build still validates its token before admission, inside its transaction, and before commit.
     */
    public func captureIndexCreationSources(
        named moduleNames: [String],
        resolving resolve: () -> [(name: String, source: any BibleSearchIndexSource)]?
    ) throws -> [(
        name: String,
        source: any BibleSearchIndexSource,
        authorization: SearchIndexSourceAuthorization
    )]? {
        guard !moduleNames.isEmpty else { return [] }
        guard let invalidationEpoch = captureModuleStoreReadEpoch() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleNames[0])
        }
        guard let resolved = resolve() else { return nil }
        guard resolved.count == moduleNames.count else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleNames[0])
        }

        var authorized: [(
            name: String,
            source: any BibleSearchIndexSource,
            authorization: SearchIndexSourceAuthorization
        )] = []
        authorized.reserveCapacity(resolved.count)
        for (expectedName, resolvedItem) in zip(moduleNames, resolved) {
            guard SwordJavaStringIdentity.equals(resolvedItem.name, expectedName),
                  SwordJavaStringIdentity.equals(
                    resolvedItem.source.searchIndexModuleInfo.name,
                    expectedName
                  ) else {
                throw SearchIndexError.indexVerificationFailed(moduleName: expectedName)
            }
            let authorization = try captureIndexCreationAuthorization(
                for: resolvedItem.source,
                expectedInvalidationEpoch: invalidationEpoch
            )
            authorized.append((expectedName, resolvedItem.source, authorization))
        }
        guard moduleStoreReadEpochIsCurrent(invalidationEpoch) else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleNames[0])
        }
        return authorized
    }

    /**
     Binds one already-resolved source to a caller-captured invalidation epoch and durable generation.

     - Parameters:
       - source: Exact source object whose identity will be retained in the authorization.
       - expectedInvalidationEpoch: Epoch captured before source discovery or immediate admission.
     - Returns: Opaque authorization owned by this service and source identity.
     - Side effects: Opens one committed generation snapshot.
     - Throws: Identity mismatch, SQLite failure, or any invalidation since the supplied epoch.
     - Important: The epoch is checked before and after the SQLite snapshot so resolution and token
       creation form one optimistic, fail-closed handshake without holding a lock across caller code.
     */
    private func captureIndexCreationAuthorization(
        for source: any BibleSearchIndexSource,
        expectedInvalidationEpoch: UInt64
    ) throws -> SearchIndexSourceAuthorization {
        let sourceIdentity = source.searchIndexSourceIdentity
        let moduleName = source.searchIndexModuleInfo.name
        guard SwordJavaStringIdentity.equals(sourceIdentity.moduleName, moduleName),
              !sourceIdentity.fingerprint.isEmpty else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        guard moduleStoreReadEpochIsCurrent(expectedInvalidationEpoch) else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        let storeGeneration = try withReadSnapshot(
            for: moduleName,
            operation: "authorizing \(moduleName) index creation"
        ) { readDatabase in
            try currentStoreGeneration(db: readDatabase)
        }
        guard moduleStoreReadEpochIsCurrent(expectedInvalidationEpoch) else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        return SearchIndexSourceAuthorization(
            serviceIdentifier: sourceAuthorizationServiceIdentifier,
            sourceIdentity: sourceIdentity,
            storeGeneration: storeGeneration,
            invalidationEpoch: expectedInvalidationEpoch
        )
    }

    /**
     Builds and verifies one immediately admitted backend-neutral Bible index transactionally.

     The source streams canonical verse values while this service owns analyzer application, Strong's
     extraction, SQLite writes, cancellation checkpoints, and completion metadata. A cancellation or
     source failure rolls back all generated rows, so a partial index can never be advertised ready.
     Production queues that retain sources across other builds use the authorization overload below.

     - Parameter source: Installed SWORD or Android-compatible SQLite Bible source.
     - Side effects: Mutates the generated Search database on its serial queue and publishes guarded
       progress state on the main actor.
     - Throws: Cancellation, source failures, unavailable SQLite, statement/transaction failures, a
       source with no searchable verses, failed authorization, or failed pre-commit verification.
     - Important: Authorization is captured immediately. Callers that retained `source` before this
       method was entered must instead capture and pass a queue-discovery authorization explicitly.
     */
    public func createIndex(source: any BibleSearchIndexSource) async throws {
        let authorization = try captureIndexCreationAuthorization(for: source)
        try await createIndex(source: source, authorization: authorization)
    }

    /**
     Builds one retained source only while its queue-discovery authorization remains current.

     Android resolves the book scheduled for indexing from the current installed-book state. iOS can
     retain multiple backend objects while building them serially, so the authorization makes that
     equivalent contract explicit and prevents a stale queued object from being blessed by a newer
     store generation.

     - Parameters:
       - source: Exact source object retained when `authorization` was captured.
       - authorization: Opaque token issued by this service for the same identity and store generation.
     - Side effects: Marks only the source module scheduled/creating, mutates its generated rows on the
       serial writer, and publishes guarded progress state on the main actor.
     - Throws: Stale, mismatched, or foreign authorization; cancellation; source failure; unavailable
       SQLite; transaction failure; empty source; or failed pre-commit verification.
     - Important: Authorization is checked before queue admission, after writer handoff, and before
       `COMMIT`. Any module-store notification overlapping those phases rolls back or rejects the build.
     */
    public func createIndex(
        source: any BibleSearchIndexSource,
        authorization: SearchIndexSourceAuthorization
    ) async throws {
        let moduleInfo = source.searchIndexModuleInfo
        let moduleName = moduleInfo.name
        let sourceIdentity = source.searchIndexSourceIdentity
        try validateIndexCreationAuthorization(
            authorization,
            sourceIdentity: sourceIdentity,
            moduleName: moduleName
        )
        let languageCode = moduleInfo.language
        let analyzer = SearchTextAnalyzer.profile(for: languageCode)
        let cancellationProbe = SearchIndexCancellationProbe()
        let sourceTransfer = SearchIndexSourceTransfer(source)
        moduleMutationState.beginMutation(for: moduleName)
        defer { moduleMutationState.finishMutation(for: moduleName) }

        let generation = await MainActor.run {
            indexingGeneration &+= 1
            isIndexing = true
            indexProgress = 0
            indexingModule = moduleInfo.description.isEmpty ? moduleName : moduleInfo.description
            indexingKey = ""
            lastFailureDescription = nil
            return indexingGeneration
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    indexMutationQueue.async { [weak self] in
                        guard let self, let db = self.db else {
                            continuation.resume(throwing: SearchIndexError.databaseUnavailable(operation: "creating \(moduleName)"))
                            return
                        }
                        do {
                            try self.buildIndex(
                                db: db,
                                source: sourceTransfer.value,
                                sourceIdentity: sourceIdentity,
                                authorization: authorization,
                                analyzer: analyzer,
                                languageCode: languageCode,
                                cancellationProbe: cancellationProbe,
                                generation: generation
                            )
                            continuation.resume()
                        } catch {
                            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                cancellationProbe.cancel()
            }
            try Task.checkCancellation()
            await MainActor.run {
                guard indexingGeneration == generation else { return }
                indexProgress = 1
                isIndexing = false
                lastFailureDescription = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                guard indexingGeneration == generation else { return }
                isIndexing = false
                indexProgress = 0
                indexingKey = ""
            }
            throw CancellationError()
        } catch {
            await MainActor.run {
                guard indexingGeneration == generation else { return }
                isIndexing = false
                lastFailureDescription = error.localizedDescription
            }
            throw error
        }
    }

    /**
     Preserves the original SWORD-specific creation entry point for existing callers.

     - Parameter module: Installed SWORD Bible adapted through `BibleSearchIndexSource`.
     - Side effects: Delegates transactional mutation and progress publication to
       `createIndex(source:)`.
     - Throws: Re-throws cancellation, source, analyzer, SQLite, and verification failures.
     */
    public func createIndex(module: SwordModule) async throws {
        try await createIndex(source: module)
    }

    /**
     Validates that one opaque source authorization still belongs to the current installed generation.

     - Parameters:
       - authorization: Token issued when the source object entered a creation queue.
       - sourceIdentity: Identity read again from the exact source object being submitted.
       - moduleName: Exact generated-index owner read from that source's module metadata.
       - db: Optional writer transaction whose durable generation must match the captured generation.
     - Side effects: Reads lock-protected invalidation state and, when supplied, one SQLite generation.
     - Throws: `indexUnavailable` for a foreign, mismatched, stale, pending, or durably superseded token.
     - Important: Callers validate before queue admission and again inside the writer transaction so a
       notification cannot race either scheduling or publication.
     */
    private func validateIndexCreationAuthorization(
        _ authorization: SearchIndexSourceAuthorization,
        sourceIdentity: SearchIndexSourceIdentity,
        moduleName: String,
        db: OpaquePointer? = nil
    ) throws {
        guard authorization.serviceIdentifier == sourceAuthorizationServiceIdentifier,
              authorization.sourceIdentity == sourceIdentity,
              SwordJavaStringIdentity.equals(sourceIdentity.moduleName, moduleName),
              !sourceIdentity.fingerprint.isEmpty,
              moduleStoreReadEpochIsCurrent(authorization.invalidationEpoch) else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        if let db,
           try currentStoreGeneration(db: db) != authorization.storeGeneration {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
    }

    /**
     Writes one streamed source into the current transaction and records completion atomically.

     Canonical `indexText` is analyzed into FTS `search_text`; independently projected `previewText`
     is stored as unindexed `plain_text`. Strong's tokens are collected independently of body text,
     matching JSword's field-by-field document assembly so a lexical-only row remains searchable.
     The split mirrors Android's JSword index and structured `MultiSearchItemAdapter` presentation
     rather than trusting SWORD render filters.

     - Parameters:
       - db: Service-owned generated Search database.
       - source: Backend-neutral Bible source streamed in canonical verse order.
       - sourceIdentity: Exact installed source generation recorded with completion metadata.
       - authorization: Queue-discovery generation that must remain current through publication.
       - analyzer: Language profile used to derive searchable FTS text.
       - languageCode: Exact module language recorded with completion metadata.
       - cancellationProbe: Cross-executor cancellation state checked before source reads and writes.
       - generation: Main-thread progress generation that owns UI publication.
     - Side effects: Replaces one module's rows and completion metadata inside a SQLite transaction.
     - Throws: Source, analyzer, cancellation, SQLite, empty-index, or verification failures.
     */
    private func buildIndex(
        db: OpaquePointer,
        source: any BibleSearchIndexSource,
        sourceIdentity: SearchIndexSourceIdentity,
        authorization: SearchIndexSourceAuthorization,
        analyzer: SearchAnalyzerProfile,
        languageCode: String,
        cancellationProbe: SearchIndexCancellationProbe,
        generation: UInt64
    ) throws {
        let moduleName = source.searchIndexModuleInfo.name
        guard SwordJavaStringIdentity.equals(sourceIdentity.moduleName, moduleName),
              !sourceIdentity.fingerprint.isEmpty else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        try cancellationProbe.checkCancellation()
        try Self.execute(db: db, sql: "BEGIN IMMEDIATE TRANSACTION", operation: "starting \(moduleName) index")
        let storeGeneration = try currentStoreGeneration(db: db)
        try validateIndexCreationAuthorization(
            authorization,
            sourceIdentity: sourceIdentity,
            moduleName: moduleName,
            db: db
        )
        try deleteIndexData(db: db, moduleName: moduleName)

        var verseStatement: OpaquePointer?
        var strongsStatement: OpaquePointer?
        defer {
            sqlite3_finalize(verseStatement)
            sqlite3_finalize(strongsStatement)
        }

        let verseSQL = """
            INSERT INTO verse_fts (
                search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                display_book, display_book_mode, chapter, verse, book_order, canon_scope
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try prepare(db: db, sql: verseSQL, statement: &verseStatement, operation: "preparing verse insertion")
        try prepare(
            db: db,
            sql: """
                INSERT OR IGNORE INTO verse_strongs (
                    module_name, token, verse_key, entry_order, highlight_ranges
                ) VALUES (?, ?, ?, ?, ?)
            """,
            statement: &strongsStatement,
            operation: "preparing Strong's insertion"
        )

        var insertedVerseCount = 0
        // Drained per entry: one Bible streams tens of thousands of verses through regex and
        // analyzer calls inside a single dispatch block, and undrained autoreleased temporaries
        // grow until iOS terminates the app mid-build.
        try source.forEachSearchIndexEntry { entry in
            try autoreleasepool {
                try cancellationProbe.checkCancellation()
                let indexText = entry.indexText
                let previewText = entry.previewText
                let analyzed = indexText.isEmpty
                    ? ""
                    : try SearchTextAnalyzer.analyzedText(indexText, profile: analyzer)
                let canonSection = SearchCanonicalBookCatalog.section(of: entry.osisBookId)
                let rawTokens = StrongsTokenNormalizer.canonicalTokens(
                    rawEntry: entry.sourceMarkup,
                    renderedTextProvider: { entry.taggedText },
                    isNewTestamentBook: canonSection == .newTestament
                )
                let taggedTokens = StrongsTokenNormalizer.canonicalTokens(taggedText: entry.taggedText)
                let highlightRangesByToken = Self.strongHighlightRangesByToken(entry)
                let strongsTokens = Self.orderedUnique(
                    rawTokens + taggedTokens + highlightRangesByToken.keys.sorted()
                )
                guard source.searchIndexIncludesEmptyIndexText
                        || !analyzed.isEmpty
                        || !strongsTokens.isEmpty else {
                    return true
                }
                guard let verseStatement, let strongsStatement else {
                    throw SearchIndexError.databaseUnavailable(operation: "indexing \(moduleName)")
                }

                sqlite3_reset(verseStatement)
                sqlite3_clear_bindings(verseStatement)
                bind(analyzed, to: verseStatement, at: 1)
                bind(entry.displayKey, to: verseStatement, at: 2)
                bind(previewText, to: verseStatement, at: 3)
                bind(moduleName, to: verseStatement, at: 4)
                sqlite3_bind_int64(verseStatement, 5, sqlite3_int64(entry.entryOrder))
                bind(entry.osisBookId, to: verseStatement, at: 6)
                bind(entry.displayBook, to: verseStatement, at: 7)
                bind(entry.bookNamePresentation.rawValue, to: verseStatement, at: 8)
                sqlite3_bind_int(verseStatement, 9, Int32(entry.chapter))
                sqlite3_bind_int(verseStatement, 10, Int32(entry.verse))
                sqlite3_bind_int64(
                    verseStatement,
                    11,
                    sqlite3_int64(SearchCanonicalBookCatalog.order(of: entry.osisBookId))
                )
                bind(canonSection.rawValue, to: verseStatement, at: 12)
                try stepDone(db: db, statement: verseStatement, operation: "inserting \(entry.displayKey)")

                for token in strongsTokens {
                    sqlite3_reset(strongsStatement)
                    sqlite3_clear_bindings(strongsStatement)
                    bind(moduleName, to: strongsStatement, at: 1)
                    bind(token, to: strongsStatement, at: 2)
                    bind(entry.displayKey, to: strongsStatement, at: 3)
                    sqlite3_bind_int64(strongsStatement, 4, sqlite3_int64(entry.entryOrder))
                    bind(
                        Self.encodeStrongHighlightRanges(highlightRangesByToken[token] ?? []),
                        to: strongsStatement,
                        at: 5
                    )
                    try stepDone(db: db, statement: strongsStatement, operation: "inserting Strong's token")
                }

                insertedVerseCount += 1
                if insertedVerseCount.isMultiple(of: 200) {
                    let total = max(source.searchIndexProgressTotal, 1)
                    let progress = min(Double(entry.sourcePosition) / Double(total), 0.99)
                    DispatchQueue.main.async {
                        guard self.indexingGeneration == generation else { return }
                        self.indexProgress = progress
                        self.indexingKey = entry.displayKey
                    }
                }
                return true
            }
        }

        try cancellationProbe.checkCancellation()
        guard insertedVerseCount > 0 else {
            throw SearchIndexError.indexContainsNoVerses(moduleName: moduleName)
        }

        var metadataStatement: OpaquePointer?
        defer { sqlite3_finalize(metadataStatement) }
        try prepare(
            db: db,
            sql: """
                INSERT INTO indexed_modules (
                    module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
                    strongs_complete, source_version, source_fingerprint, store_generation
                ) VALUES (?, ?, datetime('now'), ?, ?, ?, 1, ?, ?, ?)
            """,
            statement: &metadataStatement,
            operation: "preparing index completion metadata"
        )
        guard let metadataStatement else {
            throw SearchIndexError.databaseUnavailable(operation: "recording \(moduleName) completion")
        }
        bind(moduleName, to: metadataStatement, at: 1)
        sqlite3_bind_int(metadataStatement, 2, Int32(insertedVerseCount))
        sqlite3_bind_int(metadataStatement, 3, Int32(Self.currentSchemaVersion))
        bind(languageCode, to: metadataStatement, at: 4)
        bind(analyzer.identifier, to: metadataStatement, at: 5)
        bind(sourceIdentity.version, to: metadataStatement, at: 6)
        bind(sourceIdentity.fingerprint, to: metadataStatement, at: 7)
        sqlite3_bind_int64(metadataStatement, 8, storeGeneration)
        try cancellationProbe.checkCancellation()
        try stepDone(db: db, statement: metadataStatement, operation: "recording \(moduleName) completion")
        guard indexIsReady(
            db: db,
            moduleName: moduleName,
            expectedIdentity: sourceIdentity
        ),
              indexedVerseCount(db: db, moduleName: moduleName) == insertedVerseCount else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        try validateIndexCreationAuthorization(
            authorization,
            sourceIdentity: sourceIdentity,
            moduleName: moduleName,
            db: db
        )
        try cancellationProbe.checkCancellation()
        try Self.execute(db: db, sql: "COMMIT", operation: "committing \(moduleName) index")
    }

    /**
     Deletes one module's published index after every earlier queued mutation completes.

     - Parameter moduleName: Exact generated-index owner whose text, Strong's, and metadata rows are
       removed together.
     - Side effects: Marks only `moduleName` unavailable before queue handoff, executes one atomic
       deletion transaction on the serial writer, publishes SQLite failure text, then always clears the
       per-module mutation gate.
     - Failure modes: This async API is intentionally nonthrowing. SQLite failures roll back every facet and
       update `lastFailureDescription`; an unavailable writer leaves its initialization failure intact.
     - Concurrency: Suspension replaces caller blocking, while the gate prevents Search and agent reads
       from observing either the queued or active deletion. Unrelated modules remain readable.
     */
    public func deleteIndex(for moduleName: String) async {
        moduleMutationState.beginMutation(for: moduleName)
        defer { moduleMutationState.finishMutation(for: moduleName) }
        await withCheckedContinuation { continuation in
            indexMutationQueue.async { [weak self] in
                if let self, let db = self.db {
                    do {
                        try self.deleteCommittedIndexData(db: db, moduleName: moduleName)
                    } catch {
                        DispatchQueue.main.async { self.lastFailureDescription = error.localizedDescription }
                    }
                }
                continuation.resume()
            }
        }
    }

    /**
     Deletes one module synchronously for legacy callers while preserving atomic publication.

     - Parameter moduleName: Exact generated-index owner whose text, Strong's, and metadata rows are
       removed together.
     - Side effects: Applies the same per-module unavailable gate and atomic writer transaction as the
       async overload, blocking the caller until queued mutations finish unless already on the writer.
     - Failure modes: Database and transaction errors are intentionally suppressed for source
       compatibility; rollback preserves the prior complete index. New code should use the async API so
       failures can remain observable through `lastFailureDescription`.
     - Concurrency: Detects re-entry on `indexMutationQueue` to avoid synchronous self-deadlock and
       always clears the module gate after the deletion attempt. Unrelated modules remain readable.
     */
    @available(*, deprecated, message: "Use await deleteIndex(for:) so deletion can suspend instead of blocking.")
    public func deleteIndex(for moduleName: String) {
        moduleMutationState.beginMutation(for: moduleName)
        defer { moduleMutationState.finishMutation(for: moduleName) }
        let mutation = {
            guard let db = self.db else { return }
            try? self.deleteCommittedIndexData(db: db, moduleName: moduleName)
        }
        if DispatchQueue.getSpecific(key: indexMutationQueueSpecificKey) == true {
            mutation()
        } else {
            indexMutationQueue.sync(execute: mutation)
        }
    }

    #if DEBUG
    /**
     Runs a test fixture mutation on the production serial index queue.

     An unavailable database now throws instead of reporting false success, allowing forced-failure
     tests to prove the explicit index-mutation failure contract.
     */
    func performIndexMutationForTesting(
        _ mutation: @escaping (OpaquePointer) throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            indexMutationQueue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(throwing: SearchIndexError.databaseUnavailable(operation: "running a fixture mutation"))
                    return
                }
                do {
                    try mutation(db)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif

    /**
     Removes one published module index as an all-or-nothing transaction.

     Standalone deletion runs after any build transaction has ended. The Strong's rows, FTS rows, and
     readiness metadata must therefore commit together: retaining metadata after only one generated
     facet was removed would publish a corrupt index as Android-compatible `DONE` state. Build
     verification runs before its original transaction commits and never needs post-publication cleanup.

     - Parameters:
       - db: Service-owned writer connection, currently outside another transaction.
       - moduleName: Exact owner whose generated rows and completion metadata are removed.
     - Side effects: Begins an immediate transaction, deletes every generated facet, and commits it.
     - Throws: Explicit begin, delete, or commit errors. Every failure rolls back before returning.
     - Important: Transactional replacement calls `deleteIndexData` directly inside its existing build
       transaction and must not call this wrapper.
     */
    private func deleteCommittedIndexData(
        db: OpaquePointer,
        moduleName: String
    ) throws {
        try Self.execute(
            db: db,
            sql: "BEGIN IMMEDIATE TRANSACTION",
            operation: "starting \(moduleName) index deletion"
        )
        do {
            try deleteIndexData(db: db, moduleName: moduleName)
            try Self.execute(
                db: db,
                sql: "COMMIT",
                operation: "committing \(moduleName) index deletion"
            )
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /**
     Deletes each generated facet using the caller's existing SQLite transaction boundary.

     - Parameters:
       - db: Service-owned writer connection.
       - moduleName: Exact generated-index owner to remove.
     - Side effects: Deletes lexical rows, text rows, then completion metadata on `db`.
     - Throws: The first SQLite prepare or execution failure.
     - Important: Callers publishing deletion must provide a transaction or use
       `deleteCommittedIndexData`; build replacement already owns its encompassing transaction.
     */
    private func deleteIndexData(
        db: OpaquePointer,
        moduleName: String
    ) throws {
        for (sql, operation) in [
            ("DELETE FROM verse_strongs WHERE module_name = ?", "deleting Strong's rows"),
            ("DELETE FROM verse_fts WHERE module_name = ?", "deleting text rows"),
            ("DELETE FROM indexed_modules WHERE module_name = ?", "deleting index metadata"),
        ] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(db: db, sql: sql, statement: &statement, operation: operation)
            guard let statement else { continue }
            bind(moduleName, to: statement, at: 1)
            try stepDone(db: db, statement: statement, operation: operation)
        }
    }

    // MARK: - Search

    /** Searches one indexed module with validated Lucene-compatible semantics. */
    public func search(
        query: String,
        moduleName: String,
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchModuleResults {
        try search(
            query: query,
            moduleName: moduleName,
            expectedIdentity: nil,
            wordMode: wordMode,
            scope: scope
        )
    }

    /**
     Searches one module only when its generated index matches the installed source generation.

     - Parameters:
       - query: Raw Android/Lucene-compatible user query.
       - sourceIdentity: Exact current source generation authorizing generated rows.
       - wordMode: Android word decoration mode applied before parsing.
       - scope: Canonical OSIS/canon restriction.
     - Returns: Bounded, canonically ordered hits for the exact module.
     - Side effects: Performs read-only metadata and FTS5 queries.
     - Throws: Source/schema mismatch, invalid syntax, analyzer resource failure, SQLite failure, or a
       module-store generation change during execution.
     */
    public func search(
        query: String,
        sourceIdentity: SearchIndexSourceIdentity,
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchModuleResults {
        try search(
            query: query,
            moduleName: sourceIdentity.moduleName,
            expectedIdentity: sourceIdentity,
            wordMode: wordMode,
            scope: scope
        )
    }

    /**
     Compiles and executes one text query inside a single committed SQLite read snapshot.

     - Parameters:
       - query: Raw Search query compiled with the persisted module analyzer.
       - moduleName: Exact generated-index owner.
       - expectedIdentity: Installed source generation required by production callers, when known.
       - wordMode: Android word decoration mode.
       - scope: Canonical book/canon restriction.
     - Returns: Bounded results from one committed index generation.
     - Side effects: Opens and closes an operation-owned read-only SQLite connection.
     - Throws: Scheduled/active indexing, source mismatch, query compilation, SQLite, or module-store
       invalidation errors. A writer's uncommitted rows are never visible.
     */
    private func search(
        query: String,
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?,
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope
    ) throws -> SearchModuleResults {
        try withReadSnapshot(
            for: moduleName,
            operation: "checking \(moduleName) index"
        ) { readDatabase in
            let metadata = try indexMetadata(
                db: readDatabase,
                for: moduleName,
                expectedIdentity: expectedIdentity
            )
            readAuthorizationCheckpoint?(moduleName)
            let analyzer = SearchTextAnalyzer.profile(for: metadata.languageCode)
            guard analyzer.identifier == metadata.analyzerIdentifier else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            let compiled = try SearchQueryCompiler.compileWithHighlightPlan(
                query: query,
                wordMode: wordMode,
                analyzer: analyzer
            )
            let results = try executeTextSearch(
                db: readDatabase,
                ftsQuery: compiled.ftsQuery,
                moduleName: moduleName,
                scope: scope,
                highlightProjection: .text(
                    plan: compiled.highlightPlan,
                    analyzer: analyzer
                )
            )
            try validateCurrentStoreGeneration(
                metadata.storeGeneration,
                moduleName: moduleName,
                db: readDatabase
            )
            return results
        }
    }

    /**
     Searches one module's canonical Strong's facet, requiring every supplied token.

     Scope predicates use persisted OSIS/canon fields from `verse_fts`; localized keys are display
     data only. SQL failures and unavailable indexes are thrown explicitly.
     */
    public func searchStrongs(
        canonicalTokens: [String],
        moduleName: String,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchModuleResults {
        try searchStrongs(
            canonicalTokens: canonicalTokens,
            moduleName: moduleName,
            expectedIdentity: nil,
            scope: scope
        )
    }

    /**
     Searches Strong's tokens only when the index matches the installed source generation.

     - Parameters:
       - canonicalTokens: Non-empty normalized Strong's identifiers, all of which must match.
       - sourceIdentity: Exact current source generation authorizing generated lexical rows.
       - scope: Canonical OSIS/canon restriction.
     - Returns: Bounded, canonically ordered matching verses.
     - Side effects: Performs read-only metadata, lexical, and verse-row SQLite queries.
     - Throws: Empty tokens, source/schema mismatch, SQLite failure, or a module-store generation change.
     */
    public func searchStrongs(
        canonicalTokens: [String],
        sourceIdentity: SearchIndexSourceIdentity,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchModuleResults {
        try searchStrongs(
            canonicalTokens: canonicalTokens,
            moduleName: sourceIdentity.moduleName,
            expectedIdentity: sourceIdentity,
            scope: scope
        )
    }

    /**
     Executes one Strong's query inside the same committed snapshot that authorized its metadata.

     - Parameters:
       - canonicalTokens: Canonical Strong's identifiers, all required.
       - moduleName: Exact generated-index owner.
       - expectedIdentity: Installed source generation required by production callers, when known.
       - scope: Canonical book/canon restriction.
     - Returns: Bounded lexical matches from one committed index generation.
     - Side effects: Opens and closes an operation-owned read-only SQLite connection.
     - Throws: Scheduled/active indexing, empty tokens, source mismatch, SQLite, or module-store
       invalidation errors. Staged lexical/text rows are never exposed.
     */
    private func searchStrongs(
        canonicalTokens: [String],
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?,
        scope: SearchCanonicalScope
    ) throws -> SearchModuleResults {
        try withReadSnapshot(
            for: moduleName,
            operation: "checking \(moduleName) index"
        ) { readDatabase in
            let metadata = try indexMetadata(
                db: readDatabase,
                for: moduleName,
                expectedIdentity: expectedIdentity
            )
            readAuthorizationCheckpoint?(moduleName)
            let tokens = Self.orderedUnique(canonicalTokens).filter { !$0.isEmpty }
            guard !tokens.isEmpty else { throw SearchIndexError.emptyQuery }

            let placeholders = Array(repeating: "?", count: tokens.count).joined(separator: ",")
            let scopeSQL = Self.scopeSQL(scope, tableAlias: "f")
            let sql = """
                SELECT f.verse_key, f.plain_text, f.module_name, f.osis_book, f.display_book,
                       CAST(f.chapter AS INTEGER), CAST(f.verse AS INTEGER), CAST(f.book_order AS INTEGER),
                       f.display_book_mode, GROUP_CONCAT(s.highlight_ranges, ';') AS highlight_ranges,
                       MIN(CAST(s.entry_order AS INTEGER)) AS sort_order
                FROM verse_strongs s
                JOIN verse_fts f ON f.verse_key = s.verse_key AND f.module_name = s.module_name
                WHERE s.module_name = ? AND s.token IN (\(placeholders)) \(scopeSQL.clause)
                GROUP BY f.module_name, f.osis_book, f.chapter, f.verse
                HAVING COUNT(DISTINCT s.token) = ?
                ORDER BY CAST(f.book_order AS INTEGER), CAST(f.chapter AS INTEGER),
                         CAST(f.verse AS INTEGER), sort_order
                LIMIT ?
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            try prepare(
                db: readDatabase,
                sql: sql,
                statement: &statement,
                operation: "preparing Strong's search"
            )
            guard let statement else {
                throw SearchIndexError.databaseUnavailable(operation: "searching Strong's numbers")
            }
            var binding: Int32 = 1
            bind(moduleName, to: statement, at: binding)
            binding += 1
            for token in tokens {
                bind(token, to: statement, at: binding)
                binding += 1
            }
            for value in scopeSQL.bindings {
                bind(value, to: statement, at: binding)
                binding += 1
            }
            sqlite3_bind_int(statement, binding, Int32(tokens.count))
            sqlite3_bind_int(statement, binding + 1, Int32(Self.maximumResultsPerModule + 1))
            let results = try readSearchResults(
                db: readDatabase,
                statement: statement,
                moduleName: moduleName,
                highlightProjection: .strong
            )
            try validateCurrentStoreGeneration(
                metadata.storeGeneration,
                moduleName: moduleName,
                db: readDatabase
            )
            return results
        }
    }

    /** Searches selected modules and groups equivalent localized keys by canonical OSIS verse. */
    public func searchMultiple(
        query: String,
        moduleNames: [String],
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchGroupedResults {
        let orderedNames = Self.orderedUniqueModuleNames(moduleNames)
        return try collectGroupedResults(moduleNames: orderedNames) { moduleName in
            try search(query: query, moduleName: moduleName, wordMode: wordMode, scope: scope)
        }
    }

    /**
     Searches exact installed generations independently and preserves every successful result bucket.

     - Parameters:
       - query: Raw Android/Lucene-compatible user query.
       - sourceIdentities: Selected generations in desired grouping order; duplicate initials keep first.
       - wordMode: Android word decoration mode.
       - scope: Canonical OSIS/canon restriction.
     - Returns: Grouped successful modules plus explicit ordered module failures.
     - Side effects: Executes one bounded read-only search per unique module.
     - Throws: Re-throws the first module failure only when every non-empty selected module fails.
     */
    public func searchMultiple(
        query: String,
        sourceIdentities: [SearchIndexSourceIdentity],
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchGroupedResults {
        let orderedIdentities = Self.orderedUniqueIdentities(sourceIdentities)
        let identitiesByName = Dictionary(
            uniqueKeysWithValues: orderedIdentities.map {
                (SwordJavaExactStringIdentity($0.moduleName), $0)
            }
        )
        return try collectGroupedResults(moduleNames: orderedIdentities.map(\.moduleName)) { moduleName in
            guard let identity = identitiesByName[SwordJavaExactStringIdentity(moduleName)] else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            return try search(
                query: query,
                sourceIdentity: identity,
                wordMode: wordMode,
                scope: scope
            )
        }
    }

    /** Searches Strong's facets across every selected capable module and groups by canonical verse. */
    public func searchStrongsMultiple(
        canonicalTokens: [String],
        moduleNames: [String],
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchGroupedResults {
        let orderedNames = Self.orderedUniqueModuleNames(moduleNames)
        return try collectGroupedResults(moduleNames: orderedNames) { moduleName in
            try searchStrongs(canonicalTokens: canonicalTokens, moduleName: moduleName, scope: scope)
        }
    }

    /**
     Searches Strong's facets for exact installed generations while preserving partial success.

     - Parameters:
       - canonicalTokens: Normalized Strong's identifiers required in each matching verse.
       - sourceIdentities: Selected generations in desired grouping order; duplicate initials keep first.
       - scope: Canonical OSIS/canon restriction.
     - Returns: Grouped successful modules plus explicit ordered module failures.
     - Side effects: Executes one bounded read-only lexical search per unique module.
     - Throws: Re-throws the first module failure only when every non-empty selected module fails.
     */
    public func searchStrongsMultiple(
        canonicalTokens: [String],
        sourceIdentities: [SearchIndexSourceIdentity],
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchGroupedResults {
        let orderedIdentities = Self.orderedUniqueIdentities(sourceIdentities)
        let identitiesByName = Dictionary(
            uniqueKeysWithValues: orderedIdentities.map {
                (SwordJavaExactStringIdentity($0.moduleName), $0)
            }
        )
        return try collectGroupedResults(moduleNames: orderedIdentities.map(\.moduleName)) { moduleName in
            guard let identity = identitiesByName[SwordJavaExactStringIdentity(moduleName)] else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            return try searchStrongs(
                canonicalTokens: canonicalTokens,
                sourceIdentity: identity,
                scope: scope
            )
        }
    }

    /**
     Executes selected modules independently while binding the aggregate to one store epoch.

     Per-module failures remain visible when installed storage is stable, preserving Android-style
     partial diagnostics for a corrupt individual index. A module-store replacement or uninstall is
     different: if it overlaps any two snapshots, every accumulated result is discarded because an
     earlier successful bucket may now belong to removed source content.

     - Parameters:
       - moduleNames: De-duplicated selected order.
       - operation: Throwing single-module query operation.
     - Returns: Grouped successful results plus ordered module failure descriptions from one stable
       module-store epoch.
     - Side effects: Executes the supplied read-only query once per selected module and invokes the
       package-test aggregate checkpoint after each operation.
     - Throws: Re-throws the first module error when every non-empty selected module fails, or
       `indexUnavailable` for the complete aggregate when store invalidation overlaps collection.
     */
    private func collectGroupedResults(
        moduleNames: [String],
        operation: (String) throws -> SearchModuleResults
    ) throws -> SearchGroupedResults {
        guard !moduleNames.isEmpty else {
            return SearchGroupedResults(
                moduleResults: [],
                moduleOrder: [],
                moduleFailures: []
            )
        }
        guard let aggregateEpoch = captureModuleStoreReadEpoch() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleNames[0])
        }
        var moduleResults: [SearchModuleResults] = []
        var moduleFailures: [SearchModuleFailure] = []
        var firstFailure: Error?

        for moduleName in moduleNames {
            do {
                moduleResults.append(try operation(moduleName))
            } catch {
                if firstFailure == nil { firstFailure = error }
                moduleFailures.append(SearchModuleFailure(
                    moduleName: moduleName,
                    message: error.localizedDescription
                ))
            }
            aggregateSearchCheckpoint?(moduleName)
        }
        guard moduleStoreReadEpochIsCurrent(aggregateEpoch) else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleNames[0])
        }
        if moduleResults.isEmpty, let firstFailure {
            throw firstFailure
        }
        return SearchGroupedResults(
            moduleResults: moduleResults,
            moduleOrder: moduleNames,
            moduleFailures: moduleFailures
        )
    }

    /**
     Executes one compiled FTS query on the snapshot that authorized its module metadata.

     - Parameters:
       - db: Operation-owned committed read snapshot.
       - ftsQuery: Validated FTS5 expression produced by `SearchQueryCompiler`.
       - moduleName: Exact generated-index owner.
       - scope: Canonical book/canon restriction.
     - Returns: Ordered, capped results from the snapshot.
     - Side effects: Prepares, binds, advances, and finalizes one read-only SQLite statement.
     - Throws: Explicit SQLite or malformed-row errors; no fallback query is attempted.
     */
    private func executeTextSearch(
        db: OpaquePointer,
        ftsQuery: String,
        moduleName: String,
        scope: SearchCanonicalScope,
        highlightProjection: ResultHighlightProjection
    ) throws -> SearchModuleResults {
        let scopeSQL = Self.scopeSQL(scope, tableAlias: "verse_fts")
        let sql = """
            SELECT verse_key, plain_text, module_name, osis_book, display_book,
                   CAST(chapter AS INTEGER), CAST(verse AS INTEGER), CAST(book_order AS INTEGER),
                   display_book_mode, NULL AS highlight_ranges
            FROM verse_fts
            WHERE verse_fts MATCH ? AND module_name = ? \(scopeSQL.clause)
            ORDER BY CAST(book_order AS INTEGER), CAST(chapter AS INTEGER),
                     CAST(verse AS INTEGER), CAST(entry_order AS INTEGER)
            LIMIT ?
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(db: db, sql: sql, statement: &statement, operation: "preparing text search")
        guard let statement else { throw SearchIndexError.databaseUnavailable(operation: "searching \(moduleName)") }
        bind(ftsQuery, to: statement, at: 1)
        bind(moduleName, to: statement, at: 2)
        var binding: Int32 = 3
        for value in scopeSQL.bindings {
            bind(value, to: statement, at: binding)
            binding += 1
        }
        sqlite3_bind_int(statement, binding, Int32(Self.maximumResultsPerModule + 1))
        return try readSearchResults(
            db: db,
            statement: statement,
            moduleName: moduleName,
            highlightProjection: highlightProjection
        )
    }

    /** Query-specific authority used to materialize plain preview emphasis. */
    private enum ResultHighlightProjection {
        /// Analyzer-bound ordinary Search query plan.
        case text(plan: SearchTextHighlightPlan, analyzer: SearchAnalyzerProfile)

        /// Structured lemma ranges selected by the active Strong's SQL join.
        case strong
    }

    /**
     Materializes complete stored previews from one ordered Search statement.

     - Parameters:
       - db: Service-owned generated Search database used for diagnostics.
       - statement: Prepared text or Strong's query positioned before its first row.
       - moduleName: Exact module owner used when reporting a database failure.
       - highlightProjection: Query-specific source of visible UTF-16 emphasis ranges.
     - Returns: At most the Android-compatible result cap plus an explicit truncation flag; every
       retained hit carries its full persisted preview so single and expanded UI rows can reveal it.
     - Side effects: Advances `statement` through completion without mutating index storage.
     - Throws: A typed SQLite error for malformed rows or failed statement execution.
     */
    private func readSearchResults(
        db: OpaquePointer,
        statement: OpaquePointer,
        moduleName: String,
        highlightProjection: ResultHighlightProjection
    ) throws -> SearchModuleResults {
        var hits: [SearchModuleHit] = []
        var stepCode = sqlite3_step(statement)
        while stepCode == SQLITE_ROW {
            guard let key = Self.columnText(statement, index: 0),
                  let text = Self.columnText(statement, index: 1),
                  let storedModule = Self.columnText(statement, index: 2),
                  let osisBookId = Self.columnText(statement, index: 3),
                  let displayBook = Self.columnText(statement, index: 4),
                  let displayBookModeValue = Self.columnText(statement, index: 8),
                  let displayBookMode = SearchBookNamePresentation(rawValue: displayBookModeValue) else {
                throw Self.sqliteError(db: db, operation: "reading search results")
            }
            let highlightRanges: [SearchTextHighlightRange]
            switch highlightProjection {
            case .text(let plan, let analyzer):
                highlightRanges = try plan.ranges(in: text, analyzer: analyzer)
            case .strong:
                highlightRanges = Self.decodeStrongHighlightRanges(
                    Self.columnText(statement, index: 9) ?? ""
                )
            }
            hits.append(SearchModuleHit(
                moduleName: storedModule,
                key: key,
                displayBook: displayBook,
                snippet: text,
                highlightRanges: highlightRanges,
                identity: SearchVerseIdentity(
                    osisBookId: osisBookId,
                    canonicalBookOrder: Int(sqlite3_column_int64(statement, 7)),
                    chapter: Int(sqlite3_column_int(statement, 5)),
                    verse: Int(sqlite3_column_int(statement, 6))
                ),
                bookNamePresentation: displayBookMode
            ))
            stepCode = sqlite3_step(statement)
        }
        guard stepCode == SQLITE_DONE else {
            throw Self.sqliteError(db: db, operation: "executing search")
        }
        let truncated = hits.count > Self.maximumResultsPerModule
        if truncated { hits.removeLast(hits.count - Self.maximumResultsPerModule) }
        return SearchModuleResults(moduleName: moduleName, hits: hits, isTruncated: truncated)
    }

    /// Metadata that authorizes analyzer selection and one exact committed index generation.
    private struct IndexMetadata {
        /// Module language used to reconstruct the analyzer profile.
        let languageCode: String

        /// Persisted analyzer contract that must match the current profile.
        let analyzerIdentifier: String

        /// Installed source version recorded when the index committed.
        let sourceVersion: String

        /// Durable installed-source fingerprint recorded when the index committed.
        let sourceFingerprint: String

        /// Module-store generation shared with the result rows in the current read snapshot.
        let storeGeneration: sqlite3_int64
    }

    /**
     Loads completion metadata in the active module-store generation and optionally matches a source.

     - Parameters:
       - db: Operation-owned SQLite read snapshot established before metadata authorization.
       - moduleName: Exact generated-index owner.
       - expectedIdentity: Installed source generation required by production Search, or `nil` for
         compatibility callers protected by central generation invalidation.
     - Returns: Analyzer, source, and store-generation metadata authorizing one query.
     - Side effects: Executes one read-only SQLite statement.
     - Throws: `indexUnavailable` for stale, mismatched, missing, or concurrently invalidated metadata.
     */
    private func indexMetadata(
        db: OpaquePointer,
        for moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity? = nil
    ) throws -> IndexMetadata {
        guard !isModuleStoreInvalidationBlocked() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            db: db,
            sql: """
                SELECT m.language_code, m.analyzer_id, m.source_version, m.source_fingerprint,
                       m.store_generation
                FROM indexed_modules m
                JOIN search_index_state s ON s.id = 1 AND s.store_generation = m.store_generation
                WHERE m.module_name = ? AND m.schema_version = ? AND m.verse_count > 0
            """,
            statement: &statement,
            operation: "checking index metadata"
        )
        guard let statement else { throw SearchIndexError.indexUnavailable(moduleName: moduleName) }
        bind(moduleName, to: statement, at: 1)
        sqlite3_bind_int(statement, 2, Int32(Self.currentSchemaVersion))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let language = Self.columnText(statement, index: 0),
              let analyzer = Self.columnText(statement, index: 1),
              let sourceVersion = Self.columnText(statement, index: 2),
              let sourceFingerprint = Self.columnText(statement, index: 3) else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        let storeGeneration = sqlite3_column_int64(statement, 4)
        if let expectedIdentity,
           (!SwordJavaStringIdentity.equals(expectedIdentity.moduleName, moduleName)
                || expectedIdentity.version != sourceVersion
                || expectedIdentity.fingerprint != sourceFingerprint) {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        try validateCurrentStoreGeneration(
            storeGeneration,
            moduleName: moduleName,
            db: db
        )
        return IndexMetadata(
            languageCode: language,
            analyzerIdentifier: analyzer,
            sourceVersion: sourceVersion,
            sourceFingerprint: sourceFingerprint,
            storeGeneration: storeGeneration
        )
    }

    /**
     Rejects a snapshot whose durable module-store generation does not match authorized metadata.

     - Parameters:
       - expectedGeneration: Generation persisted with the selected module metadata.
       - moduleName: Exact index owner used for the typed unavailable error.
       - db: Same read snapshot used for metadata and result rows.
     - Side effects: Reads the singleton store-generation row and the in-memory invalidation bit.
     - Throws: `indexUnavailable` when notification invalidation is active or generations differ.
     */
    private func validateCurrentStoreGeneration(
        _ expectedGeneration: sqlite3_int64,
        moduleName: String,
        db: OpaquePointer
    ) throws {
        guard !isModuleStoreInvalidationBlocked(),
              try currentStoreGeneration(db: db) == expectedGeneration else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
    }

    private static func scopeSQL(
        _ scope: SearchCanonicalScope,
        tableAlias: String
    ) -> (clause: String, bindings: [String]) {
        switch scope {
        case .wholeBible:
            return ("", [])
        case .oldTestament:
            return ("AND \(tableAlias).canon_scope = ?", [SearchCanonSection.oldTestament.rawValue])
        case .newTestament:
            return ("AND \(tableAlias).canon_scope = ?", [SearchCanonSection.newTestament.rawValue])
        case .currentBook(let osisBookId):
            return ("AND \(tableAlias).osis_book = ?", [osisBookId])
        }
    }

    // MARK: - SQLite Helpers

    private static let schemaVersion = currentSchemaVersion

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /**
     Runs one logical readiness or Search operation against a committed SQLite snapshot.

     A separate read-only connection is essential: `SQLITE_OPEN_FULLMUTEX` only serializes calls on
     the writer connection and does not hide that connection's own uncommitted transaction. WAL lets
     an already-admitted read retain its old committed snapshot while the writer builds a new one.

     - Parameters:
       - moduleName: Exact index owner whose scheduled/creating state gates new reads.
       - operation: Diagnostic operation used when the backing database is unavailable.
       - body: Complete logical metadata/result read; all statements must use the supplied connection.
     - Returns: Value produced from one committed snapshot.
     - Side effects: Opens a read-only connection, begins/commits a read transaction, and closes it.
     - Throws: `indexUnavailable` while the affected module is scheduled/creating or store invalidation
       is active or when the monotonic store epoch changes during the read; otherwise explicit database,
       transaction, or body errors. Failures roll back an active read transaction before closing it.
     - Important: A mutation beginning after admission does not cancel the reader; the independent WAL
       snapshot remains complete. A module-store mutation is different because its installed source is
       already authoritative; even a complete old snapshot must be rejected through the in-memory epoch.
     */
    private func withReadSnapshot<Result>(
        for moduleName: String,
        operation: String,
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        guard !moduleMutationState.isMutating(moduleName),
              let readEpoch = captureModuleStoreReadEpoch() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        let readDatabase = try openReadDatabase(operation: operation)
        defer { sqlite3_close(readDatabase) }
        var transactionIsOpen = false
        try Self.execute(
            db: readDatabase,
            sql: "BEGIN DEFERRED TRANSACTION",
            operation: "starting read snapshot for \(moduleName)"
        )
        transactionIsOpen = true
        do {
            let result = try body(readDatabase)
            guard moduleStoreReadEpochIsCurrent(readEpoch) else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            try Self.execute(
                db: readDatabase,
                sql: "COMMIT",
                operation: "committing read snapshot for \(moduleName)"
            )
            transactionIsOpen = false
            guard moduleStoreReadEpochIsCurrent(readEpoch) else {
                throw SearchIndexError.indexUnavailable(moduleName: moduleName)
            }
            return result
        } catch {
            if transactionIsOpen {
                sqlite3_exec(readDatabase, "ROLLBACK", nil, nil, nil)
            }
            throw error
        }
    }

    /**
     Opens one operation-owned read-only connection to the generated Search database.

     - Parameter operation: Caller-facing diagnostic operation preserved for unavailable-database errors.
     - Returns: Independent SQLite handle whose caller must close after its logical snapshot ends.
     - Side effects: Opens the database file read-only with serialized SQLite call protection.
     - Throws: `databaseUnavailable` when initialization never produced a writer, or a typed SQLite
       open error when the existing database cannot be reopened read-only.
     */
    private func openReadDatabase(operation: String) throws -> OpaquePointer {
        guard db != nil else {
            throw SearchIndexError.databaseUnavailable(operation: operation)
        }
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            dbPath,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "SQLite error \(openCode)"
            if let handle { sqlite3_close(handle) }
            throw SearchIndexError.sqlite(
                operation: "opening a read snapshot for \(operation)",
                code: openCode,
                message: message
            )
        }
        return handle
    }

    /**
     Reads the durable installed-module store generation used to authorize index metadata.

     - Parameter db: Open service-owned SQLite handle.
     - Returns: Monotonic generation advanced after every observed module-store mutation.
     - Side effects: Executes one read-only SQLite statement.
     - Throws: Explicit SQLite errors for prepare, missing singleton state, or read failure.
     */
    private func currentStoreGeneration(db: OpaquePointer) throws -> sqlite3_int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try prepare(
            db: db,
            sql: "SELECT store_generation FROM search_index_state WHERE id = 1",
            statement: &statement,
            operation: "reading search index state"
        )
        guard let statement, sqlite3_step(statement) == SQLITE_ROW else {
            throw Self.sqliteError(db: db, operation: "reading search index state")
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func prepare(
        db: OpaquePointer?,
        sql: String,
        statement: inout OpaquePointer?,
        operation: String
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Self.sqliteError(db: db, operation: operation)
        }
    }

    private func stepDone(db: OpaquePointer?, statement: OpaquePointer?, operation: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw Self.sqliteError(db: db, operation: operation)
        }
    }

    private func indexedVerseCount(db: OpaquePointer?, moduleName: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM verse_fts WHERE module_name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return -1 }
        bind(moduleName, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func execute(db: OpaquePointer?, sql: String, operation: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db: db, operation: operation)
        }
    }

    private static func sqliteError(db: OpaquePointer?, operation: String) -> SearchIndexError {
        SearchIndexError.sqlite(
            operation: operation,
            code: sqlite3_errcode(db),
            message: sqlite3_errmsg(db).map(String.init(cString:)) ?? "Unknown SQLite error"
        )
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    /**
     Maps structured Strong's lemma tokens to exact visible-preview ranges for one verse.

     - Parameter entry: Backend-neutral row whose lemma spans came from the same source-filtered
       projection as `previewText`.
     - Returns: Canonical base/full Strong's tokens mapped to sorted unique valid ranges.
     - Side effects: None.
     - Failure modes: Invalid/out-of-bounds spans and malformed lemma tokens are omitted; raw/tagged
       Strong's indexing remains available without a highlight rather than guessing visible text.
     */
    private static func strongHighlightRangesByToken(
        _ entry: BibleSearchIndexEntry
    ) -> [String: [SearchTextHighlightRange]] {
        let previewLength = entry.previewText.utf16.count
        var result: [String: [SearchTextHighlightRange]] = [:]
        for span in entry.lemmaSpans {
            let (upper, overflow) = span.location.addingReportingOverflow(span.length)
            guard !overflow,
                  span.location >= 0,
                  span.length > 0,
                  upper <= previewLength else { continue }
            let range = SearchTextHighlightRange(location: span.location, length: span.length)
            for token in StrongsTokenNormalizer.canonicalTokens(lemmaAttribute: span.lemma) {
                if !result[token, default: []].contains(range) {
                    result[token, default: []].append(range)
                }
            }
        }
        for token in Array(result.keys) {
            result[token]?.sort {
                $0.location == $1.location
                    ? $0.length < $1.length
                    : $0.location < $1.location
            }
        }
        return result
    }

    /**
     Encodes one Strong's token's visible ranges into deterministic SQLite text.

     - Parameter ranges: Valid sorted UTF-16 ranges for one token/verse row.
     - Returns: Comma-delimited `location:length` pairs; no ranges produce an empty string.
     - Side effects: None.
     - Failure modes: None; values are emitted as base-10 integers without locale formatting.
     */
    private static func encodeStrongHighlightRanges(
        _ ranges: [SearchTextHighlightRange]
    ) -> String {
        ranges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
    }

    /**
     Decodes all Strong's token ranges selected by one grouped lexical query.

     - Parameter encoded: Semicolon-separated token rows containing comma-separated range pairs.
     - Returns: Sorted unique nonnegative ranges; final preview validation occurs in
       `SearchModuleHit.snippetSegments`.
     - Side effects: None.
     - Failure modes: Malformed/overflowing pairs are ignored individually; storage corruption
       cannot produce an out-of-bounds string slice.
     */
    private static func decodeStrongHighlightRanges(
        _ encoded: String
    ) -> [SearchTextHighlightRange] {
        var result: [SearchTextHighlightRange] = []
        for row in encoded.split(separator: ";", omittingEmptySubsequences: true) {
            for pair in row.split(separator: ",", omittingEmptySubsequences: true) {
                let fields = pair.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 2,
                      let location = Int(fields[0]),
                      let length = Int(fields[1]),
                      location >= 0,
                      length > 0 else { continue }
                let range = SearchTextHighlightRange(location: location, length: length)
                if !result.contains(range) { result.append(range) }
            }
        }
        return result.sorted {
            $0.location == $1.location
                ? $0.length < $1.length
                : $0.location < $1.location
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /**
     Keeps the first selected module for each exact Java UTF-16 initials value.

     - Parameter values: Caller-ordered installed module names.
     - Returns: First-occurrence order with only Java `String.equals` duplicates removed.
     - Side effects: None.
     - Failure modes: None; canonically equivalent Swift strings intentionally remain separate.
     */
    private static func orderedUniqueModuleNames(_ values: [String]) -> [String] {
        var seen = Set<SwordJavaExactStringIdentity>()
        return values.filter {
            seen.insert(SwordJavaExactStringIdentity($0)).inserted
        }
    }

    /**
     Keeps the first exact source identity for each selected Java module name.

     - Parameter values: Caller-ordered installed source generations.
     - Returns: First source for each code-unit-identical module initials value.
     - Side effects: None.
     - Failure modes: None; different generations of the same exact initials keep the first, while
       canonically equivalent Java-distinct initials both remain selected.
     */
    private static func orderedUniqueIdentities(
        _ values: [SearchIndexSourceIdentity]
    ) -> [SearchIndexSourceIdentity] {
        var seen = Set<SwordJavaExactStringIdentity>()
        return values.filter {
            seen.insert(SwordJavaExactStringIdentity($0.moduleName)).inserted
        }
    }
}
