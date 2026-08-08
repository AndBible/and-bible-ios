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
 Builds and queries Android-compatible Bible search indexes.

 Each indexed row stores localized display text alongside canonical OSIS identity, JSword book
 order, and canon section. Module-language analysis is applied before both indexing and querying.
 All index mutations run on one serial queue and publish explicit failure state; query failures are
 thrown to callers instead of being converted to empty result sets.
 */
@Observable
public final class SearchIndexService: @unchecked Sendable {
    /// Schema version for canonical metadata, analyzer identity, and transactional completion.
    public static let currentSchemaVersion = 8

    /// Android caps one module's Lucene result collection at 5,000 hits.
    public static let maximumResultsPerModule = 5_000

    private var db: OpaquePointer?
    @ObservationIgnored private let dbPath: String
    @ObservationIgnored private let indexMutationQueue = DispatchQueue(
        label: "org.andbible.ios.search-index.mutations",
        qos: .userInitiated
    )
    @ObservationIgnored private let indexMutationQueueSpecificKey = DispatchSpecificKey<Bool>()

    /// Notification center carrying process-wide installed-module mutation events.
    @ObservationIgnored private let notificationCenter: NotificationCenter

    /// Observer token removed during service teardown.
    @ObservationIgnored private var moduleStoreObserver: NSObjectProtocol?

    /// Protects the fail-closed readiness bit while a module-store generation is being persisted.
    @ObservationIgnored private let moduleStoreInvalidationLock = NSLock()

    /// Blocks readiness immediately when durable module-store invalidation has not completed.
    @ObservationIgnored private var moduleStoreInvalidationPendingOrFailed = false

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
        configureIndexMutationQueue()
        openDatabase()
        observeModuleStoreMutations()
    }

    /**
     Opens a caller-supplied search database.

     Tests use this initializer for isolated fixtures and failure injection. Runtime callers use
     `init()`.
     */
    init(databasePath: String, notificationCenter: NotificationCenter = .default) {
        dbPath = databasePath
        self.notificationCenter = notificationCenter
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
        setModuleStoreInvalidationBlocked(true)
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
            setModuleStoreInvalidationBlocked(false)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.lastFailureDescription = invalidationError.localizedDescription
        }
    }

    /** Updates or reads the lock-protected fail-closed module-store invalidation state. */
    private func setModuleStoreInvalidationBlocked(_ blocked: Bool) {
        moduleStoreInvalidationLock.lock()
        moduleStoreInvalidationPendingOrFailed = blocked
        moduleStoreInvalidationLock.unlock()
    }

    /** Returns whether readiness checks must fail while durable invalidation is pending or failed. */
    private func isModuleStoreInvalidationBlocked() -> Bool {
        moduleStoreInvalidationLock.lock()
        let blocked = moduleStoreInvalidationPendingOrFailed
        moduleStoreInvalidationLock.unlock()
        return blocked
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
        let metadataColumns = tableColumns(db: db, tableName: "indexed_modules")
        let stateColumns = tableColumns(db: db, tableName: "search_index_state")
        guard !ftsColumns.isEmpty || !metadataColumns.isEmpty else { return false }

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
        let requiredState: Set<String> = ["id", "store_generation"]
        return !requiredFTS.isSubset(of: ftsColumns)
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
     - Side effects: Executes a read-only SQLite statement on the serialized connection.
     - Failure modes: Every database, schema, identity, or concurrent-invalidation failure returns false.
     */
    private func hasIndex(
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?
    ) -> Bool {
        guard !isModuleStoreInvalidationBlocked(), let db else { return false }
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
           (expectedIdentity.moduleName != moduleName
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
        let textReady = expectedIdentity.map(hasIndex(for:)) ?? hasIndex(for: moduleName)
        guard textReady, !isModuleStoreInvalidationBlocked(), let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
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
        return sqlite3_column_int(statement, 0) != 0 || sqlite3_column_int(statement, 1) != 0
    }

    /** Returns requested module names whose required current-schema facet is incomplete. */
    public func modulesNeedingIndex(
        from moduleNames: [String],
        requirement: SearchIndexRequirement = .text
    ) -> [String] {
        moduleNames.filter { moduleName in
            switch requirement {
            case .text:
                return !hasIndex(for: moduleName)
            case .strongs:
                return !hasStrongsIndex(for: moduleName)
            }
        }
    }

    /**
     Returns exact installed source generations whose requested facet is not ready.

     - Parameters:
       - sourceIdentities: Selected source generations in caller order.
       - requirement: Text or Strong's completion contract to inspect.
     - Returns: Unready identities in the same order, including duplicate inputs when supplied.
     - Side effects: Performs one or more read-only SQLite readiness queries per source.
     - Failure modes: Database and identity failures classify the affected source as needing an index.
     */
    public func modulesNeedingIndex(
        from sourceIdentities: [SearchIndexSourceIdentity],
        requirement: SearchIndexRequirement = .text
    ) -> [SearchIndexSourceIdentity] {
        sourceIdentities.filter { sourceIdentity in
            switch requirement {
            case .text:
                return !hasIndex(for: sourceIdentity)
            case .strongs:
                return !hasStrongsIndex(for: sourceIdentity)
            }
        }
    }

    /**
     Builds and verifies one backend-neutral Bible index transactionally.

     The source streams canonical verse values while this service owns analyzer application, Strong's
     extraction, SQLite writes, cancellation checkpoints, and completion metadata. A cancellation or
     source failure rolls back all generated rows, so a partial index can never be advertised ready.

     - Parameter source: Installed SWORD or Android-compatible SQLite Bible source.
     - Side effects: Mutates the generated Search database on its serial queue and publishes guarded
       progress state on the main actor.
     - Throws: Cancellation, source failures, unavailable SQLite, statement/transaction failures, a
       source with no searchable verses, or failed post-commit verification.
     */
    public func createIndex(source: any BibleSearchIndexSource) async throws {
        let moduleInfo = source.searchIndexModuleInfo
        let moduleName = moduleInfo.name
        let sourceIdentity = source.searchIndexSourceIdentity
        let languageCode = moduleInfo.language
        let analyzer = SearchTextAnalyzer.profile(for: languageCode)
        let cancellationProbe = SearchIndexCancellationProbe()
        let sourceTransfer = SearchIndexSourceTransfer(source)

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
     Writes one streamed source into the current transaction and records completion atomically.

     - Parameters:
       - db: Service-owned generated Search database.
       - source: Backend-neutral Bible source streamed in canonical verse order.
       - sourceIdentity: Exact installed source generation recorded with completion metadata.
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
        analyzer: SearchAnalyzerProfile,
        languageCode: String,
        cancellationProbe: SearchIndexCancellationProbe,
        generation: UInt64
    ) throws {
        let moduleName = source.searchIndexModuleInfo.name
        guard sourceIdentity.moduleName == moduleName, !sourceIdentity.fingerprint.isEmpty else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        try cancellationProbe.checkCancellation()
        try Self.execute(db: db, sql: "BEGIN IMMEDIATE TRANSACTION", operation: "starting \(moduleName) index")
        let storeGeneration = try currentStoreGeneration(db: db)
        try deleteIndexData(db: db, moduleName: moduleName, strict: true)

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
                INSERT OR IGNORE INTO verse_strongs (module_name, token, verse_key, entry_order)
                VALUES (?, ?, ?, ?)
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
                let cleaned = entry.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                let analyzed = cleaned.isEmpty
                    ? ""
                    : try SearchTextAnalyzer.analyzedText(cleaned, profile: analyzer)
                guard source.searchIndexIncludesEmptyVisibleText
                        || (!cleaned.isEmpty && !analyzed.isEmpty) else {
                    return true
                }
                guard let verseStatement, let strongsStatement else {
                    throw SearchIndexError.databaseUnavailable(operation: "indexing \(moduleName)")
                }

                sqlite3_reset(verseStatement)
                sqlite3_clear_bindings(verseStatement)
                bind(analyzed, to: verseStatement, at: 1)
                bind(entry.displayKey, to: verseStatement, at: 2)
                bind(cleaned, to: verseStatement, at: 3)
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
                let canonSection = SearchCanonicalBookCatalog.section(of: entry.osisBookId)
                bind(canonSection.rawValue, to: verseStatement, at: 12)
                try stepDone(db: db, statement: verseStatement, operation: "inserting \(entry.displayKey)")

                let rawTokens = StrongsTokenNormalizer.canonicalTokens(
                    rawEntry: entry.sourceMarkup,
                    renderedTextProvider: { entry.taggedText },
                    isNewTestamentBook: canonSection == .newTestament
                )
                let taggedTokens = StrongsTokenNormalizer.canonicalTokens(taggedText: entry.taggedText)
                for token in Self.orderedUnique(rawTokens + taggedTokens) {
                    sqlite3_reset(strongsStatement)
                    sqlite3_clear_bindings(strongsStatement)
                    bind(moduleName, to: strongsStatement, at: 1)
                    bind(token, to: strongsStatement, at: 2)
                    bind(entry.displayKey, to: strongsStatement, at: 3)
                    sqlite3_bind_int64(strongsStatement, 4, sqlite3_int64(entry.entryOrder))
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
        try cancellationProbe.checkCancellation()
        try Self.execute(db: db, sql: "COMMIT", operation: "committing \(moduleName) index")

        guard hasIndex(for: sourceIdentity),
              indexedVerseCount(db: db, moduleName: moduleName) == insertedVerseCount else {
            try? deleteIndexData(db: db, moduleName: moduleName, strict: false)
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
    }

    /** Deletes one module's generated search rows after earlier queued mutations complete. */
    public func deleteIndex(for moduleName: String) async {
        await withCheckedContinuation { continuation in
            indexMutationQueue.async { [weak self] in
                if let self, let db = self.db {
                    do {
                        try self.deleteIndexData(db: db, moduleName: moduleName, strict: true)
                    } catch {
                        DispatchQueue.main.async { self.lastFailureDescription = error.localizedDescription }
                    }
                }
                continuation.resume()
            }
        }
    }

    /** Synchronous compatibility deletion; new callers should use the async overload. */
    @available(*, deprecated, message: "Use await deleteIndex(for:) so deletion can suspend instead of blocking.")
    public func deleteIndex(for moduleName: String) {
        let mutation = {
            guard let db = self.db else { return }
            try? self.deleteIndexData(db: db, moduleName: moduleName, strict: false)
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

    private func deleteIndexData(
        db: OpaquePointer,
        moduleName: String,
        strict: Bool
    ) throws {
        for (sql, operation) in [
            ("DELETE FROM verse_strongs WHERE module_name = ?", "deleting Strong's rows"),
            ("DELETE FROM verse_fts WHERE module_name = ?", "deleting text rows"),
            ("DELETE FROM indexed_modules WHERE module_name = ?", "deleting index metadata"),
        ] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            do {
                try prepare(db: db, sql: sql, statement: &statement, operation: operation)
                guard let statement else { continue }
                bind(moduleName, to: statement, at: 1)
                try stepDone(db: db, statement: statement, operation: operation)
            } catch {
                if strict { throw error }
            }
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

    /** Compiles and executes one text query after optional exact source validation. */
    private func search(
        query: String,
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?,
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope
    ) throws -> SearchModuleResults {
        let metadata = try indexMetadata(for: moduleName, expectedIdentity: expectedIdentity)
        let analyzer = SearchTextAnalyzer.profile(for: metadata.languageCode)
        guard analyzer.identifier == metadata.analyzerIdentifier else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        let ftsQuery = try SearchQueryCompiler.compile(query: query, wordMode: wordMode, analyzer: analyzer)
        let results = try executeTextSearch(
            ftsQuery: ftsQuery,
            moduleName: moduleName,
            scope: scope
        )
        try validateCurrentStoreGeneration(metadata.storeGeneration, moduleName: moduleName)
        return results
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

    /** Executes one Strong's query after optional exact source validation. */
    private func searchStrongs(
        canonicalTokens: [String],
        moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity?,
        scope: SearchCanonicalScope
    ) throws -> SearchModuleResults {
        let db = try requireDatabase(operation: "searching Strong's numbers")
        let metadata = try indexMetadata(for: moduleName, expectedIdentity: expectedIdentity)
        let tokens = Self.orderedUnique(canonicalTokens).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw SearchIndexError.emptyQuery }

        let placeholders = Array(repeating: "?", count: tokens.count).joined(separator: ",")
        let scopeSQL = Self.scopeSQL(scope, tableAlias: "f")
        let sql = """
            SELECT f.verse_key, f.plain_text, f.module_name, f.osis_book, f.display_book,
                   CAST(f.chapter AS INTEGER), CAST(f.verse AS INTEGER), CAST(f.book_order AS INTEGER),
                   f.display_book_mode, MIN(CAST(s.entry_order AS INTEGER)) AS sort_order
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
        try prepare(db: db, sql: sql, statement: &statement, operation: "preparing Strong's search")
        guard let statement else { throw SearchIndexError.databaseUnavailable(operation: "searching Strong's numbers") }
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
        let results = try readSearchResults(db: db, statement: statement, moduleName: moduleName)
        try validateCurrentStoreGeneration(metadata.storeGeneration, moduleName: moduleName)
        return results
    }

    /** Searches selected modules and groups equivalent localized keys by canonical OSIS verse. */
    public func searchMultiple(
        query: String,
        moduleNames: [String],
        wordMode: SearchWordMode,
        scope: SearchCanonicalScope = .wholeBible
    ) throws -> SearchGroupedResults {
        let orderedNames = Self.orderedUnique(moduleNames)
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
            uniqueKeysWithValues: orderedIdentities.map { ($0.moduleName, $0) }
        )
        return try collectGroupedResults(moduleNames: orderedIdentities.map(\.moduleName)) { moduleName in
            guard let identity = identitiesByName[moduleName] else {
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
        let orderedNames = Self.orderedUnique(moduleNames)
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
            uniqueKeysWithValues: orderedIdentities.map { ($0.moduleName, $0) }
        )
        return try collectGroupedResults(moduleNames: orderedIdentities.map(\.moduleName)) { moduleName in
            guard let identity = identitiesByName[moduleName] else {
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
     Executes selected modules independently and groups every successful result.

     - Parameters:
       - moduleNames: De-duplicated selected order.
       - operation: Throwing single-module query operation.
     - Returns: Grouped successful results plus ordered module failure descriptions.
     - Side effects: Executes the supplied read-only query once per selected module.
     - Throws: Re-throws the first module error only when every non-empty selected module fails.
     */
    private func collectGroupedResults(
        moduleNames: [String],
        operation: (String) throws -> SearchModuleResults
    ) throws -> SearchGroupedResults {
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
        }
        if !moduleNames.isEmpty, moduleResults.isEmpty, let firstFailure {
            throw firstFailure
        }
        return SearchGroupedResults(
            moduleResults: moduleResults,
            moduleOrder: moduleNames,
            moduleFailures: moduleFailures
        )
    }

    private func executeTextSearch(
        ftsQuery: String,
        moduleName: String,
        scope: SearchCanonicalScope
    ) throws -> SearchModuleResults {
        let db = try requireDatabase(operation: "searching \(moduleName)")
        let scopeSQL = Self.scopeSQL(scope, tableAlias: "verse_fts")
        let sql = """
            SELECT verse_key, plain_text, module_name, osis_book, display_book,
                   CAST(chapter AS INTEGER), CAST(verse AS INTEGER), CAST(book_order AS INTEGER),
                   display_book_mode
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
        return try readSearchResults(db: db, statement: statement, moduleName: moduleName)
    }

    private func readSearchResults(
        db: OpaquePointer,
        statement: OpaquePointer,
        moduleName: String
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
            hits.append(SearchModuleHit(
                moduleName: storedModule,
                key: key,
                displayBook: displayBook,
                snippet: String(text.prefix(240)),
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

    private struct IndexMetadata {
        let languageCode: String
        let analyzerIdentifier: String
        let sourceVersion: String
        let sourceFingerprint: String
        let storeGeneration: sqlite3_int64
    }

    /**
     Loads completion metadata in the active module-store generation and optionally matches a source.

     - Parameters:
       - moduleName: Exact generated-index owner.
       - expectedIdentity: Installed source generation required by production Search, or `nil` for
         compatibility callers protected by central generation invalidation.
     - Returns: Analyzer, source, and store-generation metadata authorizing one query.
     - Side effects: Executes one read-only SQLite statement.
     - Throws: `indexUnavailable` for stale, mismatched, missing, or concurrently invalidated metadata.
     */
    private func indexMetadata(
        for moduleName: String,
        expectedIdentity: SearchIndexSourceIdentity? = nil
    ) throws -> IndexMetadata {
        guard !isModuleStoreInvalidationBlocked() else {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        let db = try requireDatabase(operation: "checking \(moduleName) index")
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
           (expectedIdentity.moduleName != moduleName
                || expectedIdentity.version != sourceVersion
                || expectedIdentity.fingerprint != sourceFingerprint) {
            throw SearchIndexError.indexUnavailable(moduleName: moduleName)
        }
        try validateCurrentStoreGeneration(storeGeneration, moduleName: moduleName)
        return IndexMetadata(
            languageCode: language,
            analyzerIdentifier: analyzer,
            sourceVersion: sourceVersion,
            sourceFingerprint: sourceFingerprint,
            storeGeneration: storeGeneration
        )
    }

    /** Rejects results if the installed module store changed during metadata/query execution. */
    private func validateCurrentStoreGeneration(
        _ expectedGeneration: sqlite3_int64,
        moduleName: String
    ) throws {
        guard !isModuleStoreInvalidationBlocked(), let db,
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

    // MARK: - Text Cleaning

    /// Compiled once because text cleanup runs for every verse of a full-Bible index build.
    private static let inlineStrongsTagRegex = try? NSRegularExpression(pattern: "<[HGhgW]\\d+>")

    /// Compiled once because text cleanup runs for every verse of a full-Bible index build.
    private static let repeatedSpaceRegex = try? NSRegularExpression(pattern: "  +")

    /** Removes inline Strong's tags from user-visible indexed text. */
    public static func cleanText(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = text
        if let regex = inlineStrongsTagRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        if let regex = repeatedSpaceRegex {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - SQLite Helpers

    private static let schemaVersion = currentSchemaVersion

    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func requireDatabase(operation: String) throws -> OpaquePointer {
        guard let db else { throw SearchIndexError.databaseUnavailable(operation: operation) }
        return db
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

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /** Keeps the first exact source identity for each selected module name. */
    private static func orderedUniqueIdentities(
        _ values: [SearchIndexSourceIdentity]
    ) -> [SearchIndexSourceIdentity] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.moduleName).inserted }
    }
}
