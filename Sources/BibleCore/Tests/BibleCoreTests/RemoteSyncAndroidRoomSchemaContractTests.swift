// RemoteSyncAndroidRoomSchemaContractTests.swift -- Android Room export structural parity

import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

/**
 Proves every generated remote-sync database shell matches Android's checked-in Room export.

 The fixtures are exact copies from the sibling Android repository. These tests execute the schema
 used by both initial and sparse iOS writers, then compare SQLite's persisted tables, indexes, views,
 version, and Room identity metadata against Android rather than against another iOS-only constant.
 */
final class RemoteSyncAndroidRoomSchemaContractTests: XCTestCase {
    /** One source-controlled Android Room schema fixture and its iOS category. */
    private struct FixtureCase {
        let category: RemoteSyncCategory
        let fileName: String
    }

    /** Minimal decodable shape retained verbatim by Android's Room schema exporter. */
    private struct RoomSchemaExport: Decodable {
        let formatVersion: Int
        let database: Database

        struct Database: Decodable {
            let version: Int
            let identityHash: String
            let entities: [Entity]
            let views: [View]?
        }

        struct Entity: Decodable {
            let tableName: String
            let createSql: String
            let indices: [Index]?
        }

        struct Index: Decodable {
            let name: String
            let createSql: String
        }

        struct View: Decodable {
            let viewName: String
            let createSql: String
        }
    }

    /** Typed test-only failures for fixture, SQLite, and query corruption. */
    private enum ContractTestError: Error {
        case invalidFixture(String)
        case sqlite(String)
        case missingValue(String)
    }

    /**
     Verifies all five iOS database shells are structurally identical to Android Room exports.

     Each case checks the Android export format, schema version, Room identity hash, complete table
     DDL, explicit index DDL, and view DDL after removing only SQLite-insignificant formatting and
     `IF NOT EXISTS` text. Any missing or extra object fails the owning category independently.
     */
    func testGeneratedSchemasMatchCheckedInAndroidRoomExports() throws {
        let fixtures = [
            FixtureCase(category: .bookmarks, fileName: "BookmarkDatabase-v12.json"),
            FixtureCase(category: .workspaces, fileName: "WorkspaceDatabase-v24.json"),
            FixtureCase(category: .readingPlans, fileName: "ReadingPlanDatabase-v1.json"),
            FixtureCase(category: .myDocuments, fileName: "MyDocumentDatabase-v4.json"),
            FixtureCase(category: .progress, fileName: "ProgressDatabase-v9.json")
        ]

        for fixture in fixtures {
            try XCTContext.runActivity(named: fixture.category.rawValue) { _ in
                let exportedSchema = try loadFixture(named: fixture.fileName)
                XCTAssertEqual(exportedSchema.formatVersion, 1)
                XCTAssertEqual(
                    exportedSchema.database.version,
                    RemoteSyncAndroidDatabaseContract.schemaVersion(for: fixture.category)
                )
                XCTAssertEqual(
                    exportedSchema.database.identityHash,
                    RemoteSyncAndroidDatabaseContract.identityHash(for: fixture.category)
                )
                try withGeneratedDatabase(for: fixture.category) { database in
                    XCTAssertEqual(
                        try scalarInt("PRAGMA user_version", database: database),
                        Int64(exportedSchema.database.version)
                    )
                    XCTAssertEqual(
                        try scalarText(
                            "SELECT identity_hash FROM room_master_table WHERE id = 42",
                            database: database
                        ),
                        exportedSchema.database.identityHash
                    )
                    try assertSchemaObjects(
                        exportedSchema.database,
                        database: database
                    )
                }
            }
        }
    }

    /**
     Verifies inbound ReadingPlan and Progress databases require exact Room version and identity.

     A valid generated shell is accepted first. Separate databases then vary `user_version`, the
     identity hash storage class/value, and singleton identity cardinality; each must fail with the
     corresponding typed contract error before any row decoder can run.
     */
    func testInboundReadingPlanAndProgressRequireExactVersionAndIdentity() throws {
        for category in [RemoteSyncCategory.readingPlans, .progress] {
            try XCTContext.runActivity(named: "\(category.rawValue)-valid") { _ in
                try withGeneratedDatabase(for: category) { database in
                    XCTAssertNoThrow(
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    )
                }
            }

            try XCTContext.runActivity(named: "\(category.rawValue)-version") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute(
                        "PRAGMA user_version = \(RemoteSyncAndroidDatabaseContract.schemaVersion(for: category) + 1);",
                        database: database
                    )
                    assertContractError(
                        .invalidUserVersion(
                            expected: RemoteSyncAndroidDatabaseContract.schemaVersion(for: category),
                            actual: RemoteSyncAndroidDatabaseContract.schemaVersion(for: category) + 1
                        )
                    ) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }

            try XCTContext.runActivity(named: "\(category.rawValue)-identity-value") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute(
                        "UPDATE room_master_table SET identity_hash = 'wrong' WHERE id = 42;",
                        database: database
                    )
                    assertContractError(.invalidIdentityHash) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }

            try XCTContext.runActivity(named: "\(category.rawValue)-identity-type") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute(
                        "UPDATE room_master_table SET identity_hash = x'00' WHERE id = 42;",
                        database: database
                    )
                    assertContractError(.invalidIdentityHash) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }

            try XCTContext.runActivity(named: "\(category.rawValue)-identity-cardinality") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute(
                        "INSERT INTO room_master_table (id, identity_hash) VALUES (7, 'extra');",
                        database: database
                    )
                    assertContractError(.invalidIdentityHash) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }
        }
    }

    /**
     Verifies inbound ReadingPlan and Progress contracts reject index, column, and object drift.

     Each mutation starts from a valid Room shell. Dropping a required index, adding a column, or
     adding an unrelated table must be detected by semantic SQLite metadata rather than DDL text.
     */
    func testInboundReadingPlanAndProgressRejectCompleteSchemaDrift() throws {
        let cases: [(RemoteSyncCategory, String, String)] = [
            (.readingPlans, "index_ReadingPlan_planCode", "ReadingPlan"),
            (.progress, "index_MemorizedVerse_kjvOrdinal", "MemorizedVerse"),
        ]
        for (category, indexName, tableName) in cases {
            try XCTContext.runActivity(named: "\(category.rawValue)-index") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute("DROP INDEX \(indexName);", database: database)
                    assertContractError(
                        .schemaMismatch(
                            "objects:missing=[\"index:\(indexName)\"],unexpected=[]"
                        )
                    ) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }

            try XCTContext.runActivity(named: "\(category.rawValue)-column") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute(
                        "ALTER TABLE \(tableName) ADD COLUMN unexpected INTEGER DEFAULT 7;",
                        database: database
                    )
                    assertContractError(.schemaMismatch("table:\(tableName)")) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }

            try XCTContext.runActivity(named: "\(category.rawValue)-extra-table") { _ in
                try withGeneratedDatabase(for: category) { database in
                    try execute(
                        "CREATE TABLE UnexpectedInboundObject (id INTEGER PRIMARY KEY);",
                        database: database
                    )
                    assertContractError(
                        .schemaMismatch(
                            "objects:missing=[],unexpected=[\"table:UnexpectedInboundObject\"]"
                        )
                    ) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }
        }
    }

    /**
     Verifies row, text, visibility, and cycle bounds fail before inbound row materialization.

     ReadingPlan exceeds its row and identity-text ceilings in separate exact Room shells. Progress
     exceeds the singleton settings row bound and supplies unsupported visibility and negative cycle
     values, all of which must remain typed failures rather than normalization or silent loss.
     */
    func testInboundReadingPlanAndProgressRejectBoundedPayloadViolations() throws {
        try withGeneratedDatabase(for: .readingPlans) { database in
            try execute(
                """
                WITH RECURSIVE values_to_insert(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM values_to_insert WHERE value < 10001
                )
                INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id)
                SELECT printf('plan-%05d', value), 0, 1, randomblob(16) FROM values_to_insert;
                """,
                database: database
            )
            assertContractError(
                .tooManyRows(table: "ReadingPlan", count: 10_001, maximum: 10_000)
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .readingPlans
                )
            }
        }

        try withGeneratedDatabase(for: .readingPlans) { database in
            let oversizedCode = String(repeating: "x", count: 129)
            try execute(
                "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES ('\(oversizedCode)', 0, 1, randomblob(16));",
                database: database
            )
            assertContractError(.fieldTooLarge(table: "ReadingPlan", column: "planCode")) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .readingPlans
                )
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            try execute(
                """
                INSERT INTO GlobalReadingProgressSettings VALUES
                    (randomblob(16), 0, 1, 0, 'light', 1, 0, 1, 0),
                    (randomblob(16), 0, 1, 0, 'light', 1, 0, 1, 0);
                """,
                database: database
            )
            assertContractError(
                .tooManyRows(
                    table: "GlobalReadingProgressSettings",
                    count: 2,
                    maximum: 1
                )
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            try execute(
                "INSERT INTO GlobalReadingProgressSettings VALUES (X'B2000000000000000000000000000001', 0, 1, 0, 'unknown', 1, 0, 1, 0);",
                database: database
            )
            assertContractError(
                .invalidRowValue(
                    table: "GlobalReadingProgressSettings",
                    column: "memorizeWordVisibility"
                )
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            let firstBook = try XCTUnwrap(JSwordKJVAVersification.books.first)
            try execute(
                "INSERT INTO ChapterReadHistory VALUES (randomblob(16), \(firstBook.bibleBookOrdinal), 1, -1, 0, '', 'MANUAL');",
                database: database
            )
            assertContractError(
                .invalidRowValue(table: "ChapterReadHistory", column: "cycle")
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }
    }

    /**
     Accepts Android's complete runtime sync triggers and rejects any unrecognized trigger object.

     Workspace and Progress production databases carry fifteen and twelve generated triggers,
     respectively. Sparse fixture shells carry none, but no partial or augmented set is admissible.
     */
    func testWorkspaceAndProgressAcceptOnlyExactAndroidRuntimeSyncTriggers() throws {
        let cases: [(RemoteSyncCategory, Int)] = [(.workspaces, 15), (.progress, 12)]
        for (category, expectedCount) in cases {
            try XCTContext.runActivity(named: category.rawValue) { _ in
                try withGeneratedDatabase(for: category) { database in
                    for statement in AndroidRuntimeSyncTriggerFixture.statements(
                        for: category,
                        deviceIdentifier: "fixture-device"
                    ) {
                        try execute(statement, database: database)
                    }
                    XCTAssertEqual(
                        try scalarInt(
                            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'",
                            database: database
                        ),
                        Int64(expectedCount)
                    )
                    XCTAssertNoThrow(
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    )

                    try execute(
                        "CREATE TRIGGER UnexpectedRuntimeTrigger AFTER INSERT ON LogEntry BEGIN SELECT 1; END;",
                        database: database
                    )
                    assertContractError(.schemaMismatch("triggers")) {
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: category
                        )
                    }
                }
            }
        }
    }

    /**
     Enforces KJVA addressability, ordered ranges, and Android's fixed Progress singleton identity.

     Both ends of the KJVA progress domain remain valid. Values immediately outside it, reversed
     targets, nonexistent chapter tuples, arbitrary singleton IDs, and Boolean `2` fail visibly.
     */
    func testProgressRejectsInvalidKJVAAndSingletonDomains() throws {
        try withGeneratedDatabase(for: .progress) { database in
            let firstBook = try XCTUnwrap(JSwordKJVAVersification.books.first)
            try execute(
                """
                INSERT INTO MemorizedVerse VALUES (X'00000000000000000000000000000001', 1, 0);
                INSERT INTO MemorizedVerse VALUES (X'00000000000000000000000000000002', 38272, 0);
                INSERT INTO MemorizationTarget VALUES (X'00000000000000000000000000000003', 1, 38272, 0);
                INSERT INTO ChapterReadHistory VALUES (
                    X'00000000000000000000000000000004',
                    \(firstBook.bibleBookOrdinal),
                    \(firstBook.chapterCount),
                    0,
                    0,
                    'KJV',
                    'MANUAL'
                );
                INSERT INTO GlobalReadingProgressSettings VALUES (
                    X'B2000000000000000000000000000001', 0, 1, 0, 'light', 1, 0, 1, 0
                );
                """,
                database: database
            )
            XCTAssertNoThrow(
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            )
        }

        for ordinal in [0, 38_273] {
            try withGeneratedDatabase(for: .progress) { database in
                try execute(
                    "INSERT INTO MemorizedVerse VALUES (randomblob(16), \(ordinal), 0);",
                    database: database
                )
                assertContractError(
                    .invalidRowValue(table: "MemorizedVerse", column: "kjvOrdinal")
                ) {
                    try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                        database,
                        category: .progress
                    )
                }
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            try execute(
                "INSERT INTO MemorizationTarget VALUES (randomblob(16), 2, 1, 0);",
                database: database
            )
            assertContractError(
                .invalidRowValue(table: "MemorizationTarget", column: "kjvOrdinalEnd")
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            try execute(
                "INSERT INTO ChapterReadHistory VALUES (randomblob(16), 999, 1, 0, 0, 'KJV', 'MANUAL');",
                database: database
            )
            assertContractError(
                .invalidRowValue(table: "ChapterReadHistory", column: "kjvBookOrdinal")
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            try execute(
                "INSERT INTO GlobalReadingProgressSettings VALUES (randomblob(16), 0, 1, 0, 'light', 1, 0, 1, 0);",
                database: database
            )
            assertContractError(
                .invalidRowValue(table: "GlobalReadingProgressSettings", column: "id")
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }

        try withGeneratedDatabase(for: .progress) { database in
            try execute(
                "INSERT INTO GlobalReadingProgressSettings VALUES (X'B2000000000000000000000000000001', 2, 1, 0, 'light', 1, 0, 1, 0);",
                database: database
            )
            assertContractError(
                .invalidRowValue(
                    table: "GlobalReadingProgressSettings",
                    column: "autoTrackReading"
                )
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
            }
        }
    }

    /** Rejects Int32 overflow, Boolean `2`, and a noncanonical workspace singleton identifier. */
    func testWorkspaceRejectsInt32OverflowAndBooleanTwo() throws {
        try withGeneratedDatabase(for: .workspaces) { database in
            try execute(
                "INSERT INTO Workspace (name, id, orderNumber) VALUES ('overflow', randomblob(16), 2147483648);",
                database: database
            )
            assertContractError(.invalidRowValue(table: "Workspace", column: "orderNumber")) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .workspaces
                )
            }
        }

        try withGeneratedDatabase(for: .workspaces) { database in
            try execute(
                "INSERT INTO Workspace (name, id, orderNumber, workspace_settings_autoPin) VALUES ('boolean', randomblob(16), 0, 2);",
                database: database
            )
            assertContractError(
                .invalidRowValue(table: "Workspace", column: "workspace_settings_autoPin")
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .workspaces
                )
            }
        }

        try withGeneratedDatabase(for: .workspaces) { database in
            try execute(
                "INSERT INTO GlobalTextDisplaySettings (id) VALUES (randomblob(16));",
                database: database
            )
            assertContractError(
                .invalidRowValue(table: "GlobalTextDisplaySettings", column: "id")
            ) {
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .workspaces
                )
            }
        }
    }

    /**
     Rejects material table-DDL drift that column and foreign-key PRAGMAs do not describe.

     Each case rebuilds the empty table with the same columns and required index while changing one
     material SQL feature. That isolates the COLLATE, CHECK, and STRICT features the canonical DDL
     signature must protect without relying on SQLite's unsafe writable-schema escape hatch.
     */
    func testInboundSchemaRejectsMaterialTableDDLDrift() throws {
        let mutations: [(String) -> String] = [
            {
                $0.replacingOccurrences(
                    of: "`bookInitials` TEXT NOT NULL",
                    with: "`bookInitials` TEXT COLLATE NOCASE NOT NULL"
                )
            },
            {
                $0.replacingOccurrences(
                    of: "`cycle` INTEGER NOT NULL",
                    with: "`cycle` INTEGER NOT NULL CHECK (`cycle` >= 0)"
                )
            },
            { $0 + " STRICT" },
        ]
        for mutate in mutations {
            try withGeneratedDatabase(for: .progress) { database in
                let authoritySQL = try scalarText(
                    "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'ChapterReadHistory';",
                    database: database
                )
                let alteredSQL = mutate(authoritySQL)
                XCTAssertNotEqual(alteredSQL, authoritySQL)
                try execute(
                    """
                    DROP TABLE ChapterReadHistory;
                    \(alteredSQL);
                    CREATE INDEX `index_ChapterReadHistory_kjvBookOrdinal_chapter_cycle`
                        ON `ChapterReadHistory` (`kjvBookOrdinal`, `chapter`, `cycle`);
                    """,
                    database: database
                )
                assertContractError(.schemaMismatch("table:ChapterReadHistory")) {
                    try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                        database,
                        category: .progress
                    )
                }
            }
        }
    }

    /**
     Verifies initial restore validates complete Room structure before decoding generic sync metadata.

     Each database is missing a required index and also contains an invalid `LogEntry.type`. Restore
     must report the structural schema error first for both ReadingList and Progress, proving no
     metadata row is materialized before the category contract passes.
     */
    func testInitialRestoreValidatesReadingPlanAndProgressBeforeMetadataDecoding() throws {
        let cases: [(RemoteSyncCategory, String, String)] = [
            (.readingPlans, "index_ReadingPlan_planCode", "ReadingPlan"),
            (.progress, "index_MemorizedVerse_kjvOrdinal", "MemorizedVerse"),
        ]

        for (category, indexName, tableName) in cases {
            try XCTContext.runActivity(named: category.rawValue) { _ in
                let databaseURL = try makeGeneratedDatabase(for: category)
                defer { try? FileManager.default.removeItem(at: databaseURL) }
                var database: OpaquePointer?
                guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
                      let database else {
                    throw ContractTestError.sqlite("Could not reopen \(category.rawValue) database")
                }
                try execute("DROP INDEX \(indexName);", database: database)
                try execute(
                    """
                    INSERT INTO LogEntry
                        (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice)
                    VALUES ('\(tableName)', randomblob(16), '', 'BROKEN', 1, 'source');
                    """,
                    database: database
                )
                sqlite3_close(database)

                let container = try makeReadingPlanRestoreModelContainer()
                let context = ModelContext(container)
                let settingsStore = SettingsStore(modelContext: context)
                let stagedBackup = RemoteSyncStagedInitialBackup(
                    remoteFile: RemoteSyncFile(
                        id: "/sync/initial.sqlite3.gz",
                        name: "initial.sqlite3.gz",
                        size: 1,
                        timestamp: 1,
                        parentID: "/sync",
                        mimeType: NextCloudSyncAdapter.gzipMimeType
                    ),
                    databaseFileURL: databaseURL,
                    schemaVersion: RemoteSyncAndroidDatabaseContract.schemaVersion(for: category)
                )

                XCTAssertThrowsError(
                    try RemoteSyncInitialBackupRestoreService().restoreInitialBackup(
                        stagedBackup,
                        category: category,
                        modelContext: context,
                        settingsStore: settingsStore
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? RemoteSyncAndroidDatabaseContractError,
                        .schemaMismatch(
                            "objects:missing=[\"index:\(indexName)\"],unexpected=[]"
                        )
                    )
                }
                XCTAssertTrue(
                    RemoteSyncLogEntryStore(settingsStore: settingsStore)
                        .entries(for: category).isEmpty
                )
            }
        }
    }

    /** Loads and strictly decodes one exact Android Room export beside this test file. */
    private func loadFixture(named fileName: String) throws -> RoomSchemaExport {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("AndroidRoomSchemas", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        do {
            return try JSONDecoder().decode(RoomSchemaExport.self, from: Data(contentsOf: fixtureURL))
        } catch {
            throw ContractTestError.invalidFixture("\(fileName): \(error)")
        }
    }

    /** Creates one temporary SQLite database from the production remote-sync schema contract. */
    private func withGeneratedDatabase(
        for category: RemoteSyncCategory,
        body: (OpaquePointer) throws -> Void
    ) throws {
        let databaseURL = try makeGeneratedDatabase(for: category)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw ContractTestError.sqlite("Could not open \(category.rawValue) database")
        }
        defer { sqlite3_close(database) }

        try body(database)
    }

    /** Creates and closes one temporary exact Android Room database. */
    private func makeGeneratedDatabase(for category: RemoteSyncCategory) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-room-contract-\(category.rawValue)-\(UUID().uuidString).sqlite3"
        )
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw ContractTestError.sqlite("Could not create \(category.rawValue) database")
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(
            database,
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: category),
            nil,
            nil,
            &errorMessage
        )
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorMessage)
            throw ContractTestError.sqlite(message)
        }
        return databaseURL
    }

    /** Executes one fixture mutation and surfaces SQLite's exact diagnostic on failure. */
    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error \(result)"
            sqlite3_free(errorMessage)
            throw ContractTestError.sqlite(message)
        }
    }

    /** Asserts one exact typed inbound contract failure without accepting unrelated SQLite errors. */
    private func assertContractError(
        _ expected: RemoteSyncAndroidDatabaseContractError,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? RemoteSyncAndroidDatabaseContractError, expected)
        }
    }

    /** Compares complete persisted table, explicit-index, and view DDL with one Room export. */
    private func assertSchemaObjects(
        _ exportedDatabase: RoomSchemaExport.Database,
        database: OpaquePointer
    ) throws {
        let actualTables = try schemaObjects(
            type: "table",
            excludingNames: ["room_master_table"],
            database: database
        )
        let expectedTables = Dictionary(
            uniqueKeysWithValues: exportedDatabase.entities.map { entity in
                (
                    entity.tableName,
                    normalizedSQL(entity.createSql, replacing: "${TABLE_NAME}", with: entity.tableName)
                )
            }
        )
        XCTAssertEqual(Set(actualTables.keys), Set(expectedTables.keys))
        for (name, expectedSQL) in expectedTables {
            XCTAssertEqual(normalizedSQL(actualTables[name] ?? ""), expectedSQL, name)
        }

        let actualIndexes = try schemaObjects(type: "index", database: database)
        let expectedIndexes = Dictionary(
            uniqueKeysWithValues: exportedDatabase.entities.flatMap { entity in
                (entity.indices ?? []).map { index in
                    (
                        index.name,
                        normalizedSQL(index.createSql, replacing: "${TABLE_NAME}", with: entity.tableName)
                    )
                }
            }
        )
        XCTAssertEqual(Set(actualIndexes.keys), Set(expectedIndexes.keys))
        for (name, expectedSQL) in expectedIndexes {
            XCTAssertEqual(normalizedSQL(actualIndexes[name] ?? ""), expectedSQL, name)
        }

        let actualViews = try schemaObjects(type: "view", database: database)
        let expectedViews = Dictionary(
            uniqueKeysWithValues: (exportedDatabase.views ?? []).map { view in
                (
                    view.viewName,
                    normalizedSQL(view.createSql, replacing: "${VIEW_NAME}", with: view.viewName)
                )
            }
        )
        XCTAssertEqual(Set(actualViews.keys), Set(expectedViews.keys))
        for (name, expectedSQL) in expectedViews {
            XCTAssertEqual(normalizedSQL(actualViews[name] ?? ""), expectedSQL, name)
        }
    }

    /** Reads named SQLite schema objects while excluding internal auto-indexes and requested names. */
    private func schemaObjects(
        type: String,
        excludingNames: Set<String> = [],
        database: OpaquePointer
    ) throws -> [String: String] {
        let sql = "SELECT name, sql FROM sqlite_master WHERE type = ? AND sql IS NOT NULL ORDER BY name"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContractTestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, type, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameValue = sqlite3_column_text(statement, 0),
                  let sqlValue = sqlite3_column_text(statement, 1) else {
                throw ContractTestError.missingValue("sqlite_master.\(type)")
            }
            let name = String(cString: nameValue)
            guard !name.hasPrefix("sqlite_"), !excludingNames.contains(name) else { continue }
            result[name] = String(cString: sqlValue)
        }
        return result
    }

    /** Reads one required integer scalar from SQLite. */
    private func scalarInt(_ sql: String, database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContractTestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ContractTestError.missingValue(sql)
        }
        return sqlite3_column_int64(statement, 0)
    }

    /** Reads one required text scalar from SQLite. */
    private func scalarText(_ sql: String, database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ContractTestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw ContractTestError.missingValue(sql)
        }
        return String(cString: value)
    }

    /** Removes only formatting, quoting, and idempotency text that SQLite does not preserve. */
    private func normalizedSQL(
        _ sql: String,
        replacing placeholder: String? = nil,
        with objectName: String? = nil
    ) -> String {
        var value = sql
        if let placeholder, let objectName {
            value = value.replacingOccurrences(of: placeholder, with: objectName)
        }
        value = value.replacingOccurrences(of: "IF NOT EXISTS", with: "", options: .caseInsensitive)
        return value.lowercased().filter { character in
            !character.isWhitespace && character != "`" && character != "\"" && character != ";"
        }
    }
}

/** Production-shaped Android runtime sync-trigger SQL used by schema and migration tests. */
enum AndroidRuntimeSyncTriggerFixture {
    /**
     Returns the exact trigger statements Android generates for one supported sync category.

     - Parameters:
       - category: Workspace or Progress database category.
       - deviceIdentifier: Stable source-device literal embedded in every generated trigger.
       - existingTables: Optional predecessor table set used to model older Workspace generations.
     - Returns: Three trigger statements per Android syncable table.
     - Side Effects: none.
     - Failure modes: Unsupported categories return an empty statement list.
     */
    static func statements(
        for category: RemoteSyncCategory,
        deviceIdentifier: String,
        existingTables: Set<String>? = nil
    ) -> [String] {
        let definitions: [(table: String, firstIdentifier: String, secondIdentifier: String?)]
        switch category {
        case .workspaces:
            definitions = [
                ("Workspace", "id", nil),
                ("Window", "id", nil),
                ("PageManager", "windowId", nil),
                ("WorkspaceLabelOverride", "workspaceId", "labelId"),
                ("GlobalTextDisplaySettings", "id", nil),
            ]
        case .progress:
            definitions = [
                ("MemorizedVerse", "id", nil),
                ("ChapterReadHistory", "id", nil),
                ("MemorizationTarget", "id", nil),
                ("GlobalReadingProgressSettings", "id", nil),
            ]
        case .bookmarks, .readingPlans, .myDocuments:
            return []
        }
        let applicableDefinitions = definitions.filter { definition in
            existingTables?.contains(definition.table) ?? true
        }
        return applicableDefinitions.flatMap { definition in
            ["inserts", "updates", "deletes"].map { event in
                statement(
                    table: definition.table,
                    firstIdentifier: definition.firstIdentifier,
                    secondIdentifier: definition.secondIdentifier,
                    event: event,
                    deviceIdentifier: deviceIdentifier
                )
            }
        }
    }

    /** Builds one statement copied from Android's `createTriggersForTable` template. */
    private static func statement(
        table: String,
        firstIdentifier: String,
        secondIdentifier: String?,
        event: String,
        deviceIdentifier: String
    ) -> String {
        let eventKeyword: String
        let rowAlias: String
        let operation: String
        switch event {
        case "inserts":
            eventKeyword = "INSERT"
            rowAlias = "NEW"
            operation = "UPSERT"
        case "updates":
            eventKeyword = "UPDATE"
            rowAlias = "OLD"
            operation = "UPSERT"
        default:
            eventKeyword = "DELETE"
            rowAlias = "OLD"
            operation = "DELETE"
        }
        let whereClause: String
        let insertedIdentifiers: String
        if let secondIdentifier {
            whereClause = "entityId1 = \(rowAlias).\(firstIdentifier) AND entityId2 = \(rowAlias).\(secondIdentifier)"
            insertedIdentifiers = "\(rowAlias).\(firstIdentifier),\(rowAlias).\(secondIdentifier)"
        } else {
            whereClause = "entityId1 = \(rowAlias).\(firstIdentifier)"
            insertedIdentifiers = "\(rowAlias).\(firstIdentifier),''"
        }
        return """
        CREATE TRIGGER IF NOT EXISTS \(table)_\(event) AFTER \(eventKeyword) ON \(table)
        WHEN (SELECT count(*) FROM SyncConfiguration WHERE keyName='triggersDisabled' AND booleanValue = 1 LIMIT 1) = 0
        BEGIN DELETE FROM LogEntry WHERE \(whereClause) AND tableName = '\(table)';
        INSERT INTO LogEntry VALUES ('\(table)', \(insertedIdentifiers), '\(operation)', CAST(UNIXEPOCH('subsec') * 1000 AS INTEGER), '\(deviceIdentifier)');
        END;
        """
    }
}
