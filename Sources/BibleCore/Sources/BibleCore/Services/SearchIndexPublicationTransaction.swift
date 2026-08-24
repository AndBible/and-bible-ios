// SearchIndexPublicationTransaction.swift — Atomic streamed publication of one generated index

import Foundation
import SQLite3
import SwordKit

/**
 Streams one authorized installed Bible source into an atomic generated Search transaction.

 The transaction owns SQL statement preparation, FTS/Strong's row projection, completion metadata,
 and pre-commit verification. `SearchIndexService` supplies operation authorization, store-generation
 access, deletion, and UI progress hooks while retaining queue and lifecycle ownership.

 - Side effects: Begins and commits one SQLite transaction, replaces one module's generated rows,
   and invokes progress after each 200 inserted entries.
 - Failure modes: Throws source, analyzer, cancellation, authorization, SQLite, empty-index, or
   verification failures. Every thrown path rolls back the open transaction before returning.
 */
enum SearchIndexPublicationTransaction {
    /**
     Removes one published module index as an all-or-nothing writer transaction.

     - Parameters:
       - db: Service-owned writer connection currently outside another transaction.
       - moduleName: Exact generated-index owner being removed.
       - deleteIndexData: Deletes every generated facet inside the transaction.
     - Side effects: Begins an immediate transaction, invokes deletion, and commits it.
     - Failure modes: Begin, deletion, and commit errors throw after rollback preserves the prior
       complete publication.
     */
    static func deleteCommittedIndex(
        db: OpaquePointer,
        moduleName: String,
        deleteIndexData: (OpaquePointer, String) throws -> Void
    ) throws {
        try execute(
            db: db,
            sql: "BEGIN IMMEDIATE TRANSACTION",
            operation: "starting \(moduleName) index deletion"
        )
        do {
            try deleteIndexData(db, moduleName)
            try execute(
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
     Builds and publishes one exact installed source generation.

     - Parameters:
       - db: Service-owned writer connection used only on its serial mutation queue.
       - source: Backend-neutral source streamed in canonical entry order.
       - sourceIdentity: Exact installed source generation recorded in completion metadata.
       - analyzer: Module-language analyzer profile.
       - languageCode: Exact installed language stored with completion metadata.
       - cancellationProbe: Cross-executor cancellation checkpoint.
       - currentStoreGeneration: Reads the durable module-store generation from `db`.
       - validateAuthorization: Replays token/store authorization against `db`.
       - deleteIndexData: Removes prior generated facets inside the current transaction.
       - indexIsReady: Performs pre-commit exact metadata/readiness verification.
       - progress: Publishes fractional progress and the current display key.
     - Side effects: Replaces one module's generated rows and commits once after exact verification.
     - Failure modes: Throws the failures described by the type contract after rolling back any
       transaction that reached `BEGIN` but did not commit.
     */
    static func publish(
        db: OpaquePointer,
        source: any BibleSearchIndexSource,
        sourceIdentity: SearchIndexSourceIdentity,
        analyzer: SearchAnalyzerProfile,
        languageCode: String,
        cancellationProbe: SearchIndexCancellationProbe,
        currentStoreGeneration: (OpaquePointer) throws -> sqlite3_int64,
        validateAuthorization: (OpaquePointer) throws -> Void,
        deleteIndexData: (OpaquePointer, String) throws -> Void,
        indexIsReady: (OpaquePointer, String, SearchIndexSourceIdentity) -> Bool,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        let moduleName = source.searchIndexModuleInfo.name
        guard SwordJavaStringIdentity.equals(sourceIdentity.moduleName, moduleName),
              !sourceIdentity.fingerprint.isEmpty else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        try cancellationProbe.checkCancellation()
        try execute(
            db: db,
            sql: "BEGIN IMMEDIATE TRANSACTION",
            operation: "starting \(moduleName) index"
        )
        var transactionIsOpen = true
        defer {
            if transactionIsOpen {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }
        let storeGeneration = try currentStoreGeneration(db)
        try validateAuthorization(db)
        try deleteIndexData(db, moduleName)

        var verseStatement: OpaquePointer?
        var strongsStatement: OpaquePointer?
        defer {
            sqlite3_finalize(verseStatement)
            sqlite3_finalize(strongsStatement)
        }
        try prepare(
            db: db,
            sql: """
                INSERT INTO verse_fts (
                    search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                    display_book, display_book_mode, chapter, verse, book_order, canon_scope
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            statement: &verseStatement,
            operation: "preparing verse insertion"
        )
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
        try source.forEachSearchIndexEntry { entry in
            try autoreleasepool {
                try cancellationProbe.checkCancellation()
                let analyzed = entry.indexText.isEmpty
                    ? ""
                    : try SearchTextAnalyzer.analyzedText(entry.indexText, profile: analyzer)
                let canonSection = SearchCanonicalBookCatalog.section(of: entry.osisBookId)
                let rawTokens = StrongsTokenNormalizer.canonicalTokens(
                    rawEntry: entry.sourceMarkup,
                    renderedTextProvider: { entry.taggedText },
                    isNewTestamentBook: canonSection == .newTestament
                )
                let taggedTokens = StrongsTokenNormalizer.canonicalTokens(taggedText: entry.taggedText)
                let highlightRangesByToken = SearchIndexQueryProjection
                    .strongHighlightRangesByToken(entry)
                let strongsTokens = SearchIndexQueryProjection.orderedUniqueTokens(
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
                bind(entry.previewText, to: verseStatement, at: 3)
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
                try stepDone(
                    db: db,
                    statement: verseStatement,
                    operation: "inserting \(entry.displayKey)"
                )

                for token in strongsTokens {
                    sqlite3_reset(strongsStatement)
                    sqlite3_clear_bindings(strongsStatement)
                    bind(moduleName, to: strongsStatement, at: 1)
                    bind(token, to: strongsStatement, at: 2)
                    bind(entry.displayKey, to: strongsStatement, at: 3)
                    sqlite3_bind_int64(strongsStatement, 4, sqlite3_int64(entry.entryOrder))
                    bind(
                        SearchIndexQueryProjection.encodeStrongHighlightRanges(
                            highlightRangesByToken[token] ?? []
                        ),
                        to: strongsStatement,
                        at: 5
                    )
                    try stepDone(
                        db: db,
                        statement: strongsStatement,
                        operation: "inserting Strong's token"
                    )
                }

                insertedVerseCount += 1
                if insertedVerseCount.isMultiple(of: 200) {
                    let total = max(source.searchIndexProgressTotal, 1)
                    progress(
                        min(Double(entry.sourcePosition) / Double(total), 0.99),
                        entry.displayKey
                    )
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
            throw SearchIndexError.databaseUnavailable(
                operation: "recording \(moduleName) completion"
            )
        }
        bind(moduleName, to: metadataStatement, at: 1)
        sqlite3_bind_int(metadataStatement, 2, Int32(insertedVerseCount))
        sqlite3_bind_int(metadataStatement, 3, Int32(SearchIndexService.currentSchemaVersion))
        bind(languageCode, to: metadataStatement, at: 4)
        bind(analyzer.identifier, to: metadataStatement, at: 5)
        bind(sourceIdentity.version, to: metadataStatement, at: 6)
        bind(sourceIdentity.fingerprint, to: metadataStatement, at: 7)
        sqlite3_bind_int64(metadataStatement, 8, storeGeneration)
        try cancellationProbe.checkCancellation()
        try stepDone(
            db: db,
            statement: metadataStatement,
            operation: "recording \(moduleName) completion"
        )
        guard indexIsReady(db, moduleName, sourceIdentity),
              indexedVerseCount(db: db, moduleName: moduleName) == insertedVerseCount else {
            throw SearchIndexError.indexVerificationFailed(moduleName: moduleName)
        }
        try validateAuthorization(db)
        try cancellationProbe.checkCancellation()
        try execute(
            db: db,
            sql: "COMMIT",
            operation: "committing \(moduleName) index"
        )
        transactionIsOpen = false
    }

    /// SQLite transient destructor used for bound Swift string storage.
    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /**
     Binds one UTF-8 Swift string for SQLite to copy before the call returns.

     - Parameters:
       - value: Swift string encoded by SQLite.
       - statement: Prepared publication statement.
       - index: One-based SQLite binding index.
     - Side effects: Replaces one statement binding.
     - Failure modes: SQLite binding errors surface when the statement is stepped.
     */
    private static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    /**
     Prepares one publication statement.

     - Parameters:
       - db: Open writer transaction connection.
       - sql: Trusted generated-index SQL.
       - statement: Output native statement handle finalized by the caller.
       - operation: Diagnostic operation attached to failure.
     - Side effects: Allocates one SQLite statement.
     - Throws: Typed SQLite error when preparation fails.
     */
    private static func prepare(
        db: OpaquePointer?,
        sql: String,
        statement: inout OpaquePointer?,
        operation: String
    ) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db: db, operation: operation)
        }
    }

    /**
     Steps one mutation statement to completion.

     - Parameters:
       - db: Open writer transaction connection.
       - statement: Prepared mutation statement with complete bindings.
       - operation: Diagnostic operation attached to failure.
     - Side effects: Applies the staged SQLite row mutation.
     - Throws: Typed SQLite error unless the statement returns `SQLITE_DONE`.
     */
    private static func stepDone(
        db: OpaquePointer?,
        statement: OpaquePointer?,
        operation: String
    ) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(db: db, operation: operation)
        }
    }

    /**
     Returns the exact number of FTS rows currently staged for one module.

     - Parameters:
       - db: Open writer transaction connection.
       - moduleName: Exact generated-index owner.
     - Returns: Staged row count, or zero when prepare/read fails.
     - Side effects: Executes one read statement inside the current transaction.
     - Failure modes: SQLite failure returns zero and causes caller verification to fail closed.
     */
    private static func indexedVerseCount(db: OpaquePointer?, moduleName: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM verse_fts WHERE module_name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return 0 }
        bind(moduleName, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /**
     Executes one transaction boundary and translates SQLite failures.

     - Parameters:
       - db: Open writer connection.
       - sql: Trusted BEGIN/COMMIT statement.
       - operation: Diagnostic operation attached to failure.
     - Side effects: Advances the SQLite transaction state.
     - Throws: Typed SQLite error unless SQLite returns `SQLITE_OK`.
     */
    private static func execute(
        db: OpaquePointer?,
        sql: String,
        operation: String
    ) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db: db, operation: operation)
        }
    }

    /**
     Builds one typed SQLite diagnostic for a transaction operation.

     - Parameters:
       - db: Connection supplying native error state.
       - operation: Caller-facing failed operation.
     - Returns: Typed Search index SQLite error.
     - Side effects: Reads connection error state.
     - Failure modes: Missing native message uses a deterministic fallback string.
     */
    private static func sqliteError(
        db: OpaquePointer?,
        operation: String
    ) -> SearchIndexError {
        SearchIndexError.sqlite(
            operation: operation,
            code: sqlite3_errcode(db),
            message: sqlite3_errmsg(db).map(String.init(cString:)) ?? "Unknown SQLite error"
        )
    }
}
