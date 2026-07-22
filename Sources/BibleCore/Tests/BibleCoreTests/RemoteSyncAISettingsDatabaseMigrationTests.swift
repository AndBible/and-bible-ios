// RemoteSyncAISettingsDatabaseMigrationTests.swift -- Android AI settings Room migration parity

import Foundation
import SQLite3
import XCTest
@testable import BibleCore

/** Proves staged AI settings databases follow Android's authoritative Room migration contract. */
final class RemoteSyncAISettingsDatabaseMigrationTests: XCTestCase {
    /** Minimal generated Room export shape needed to materialize one authoritative generation. */
    private struct RoomSchemaExport: Decodable {
        let database: Database

        struct Database: Decodable {
            let version: Int
            let identityHash: String
            let entities: [Entity]
            let views: [View]?
            let setupQueries: [String]
        }

        struct Entity: Decodable {
            let tableName: String
            let createSql: String
            let indices: [Index]?
        }

        struct Index: Decodable {
            let createSql: String
        }

        struct View: Decodable {
            let viewName: String
            let createSql: String
        }
    }

    /** Typed fixture and SQLite failures used only by migration tests. */
    private enum TestError: Error {
        case invalidFixture(String)
        case sqlite(String)
    }

    /** Migrates every exported or exactly derived Android predecessor through Room v23. */
    func testEveryExportedAISettingsGenerationMigratesToExactRoomVersion23() throws {
        let fixtureVersions = try Set(fixtureVersions())
        XCTAssertEqual(
            fixtureVersions.subtracting([17]).union([12]),
            RemoteSyncAISettingsDatabaseMigrator.supportedSourceVersions
        )
        XCTAssertFalse(fixtureVersions.contains(12))
        XCTAssertTrue(fixtureVersions.contains(17))

        for version in RemoteSyncAISettingsDatabaseMigrator.supportedSourceVersions.sorted() {
            try XCTContext.runActivity(named: "ai-settings-v\(version)-to-v23") { _ in
                let databaseURL = try makeFixtureDatabase(version: version)
                defer { try? FileManager.default.removeItem(at: databaseURL) }

                do {
                    try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(
                        at: databaseURL,
                        expectedSourceVersion: version
                    )
                } catch {
                    XCTFail("AI settings v\(version) migration failed: \(error)")
                    return
                }

                try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
                    XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), 23)
                    XCTAssertEqual(
                        try scalarText(
                            "SELECT identity_hash FROM room_master_table WHERE id = 42;",
                            in: database
                        ),
                        RemoteSyncAndroidDatabaseContract.identityHash(for: .aiSettings)
                    )
                    XCTAssertNoThrow(
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: .aiSettings
                        )
                    )
                }
            }
        }
    }

    /**
     Verifies the missing v12 export is reconstructed only from Android's authoritative inputs.

     Android v12 is exported remotely even though its Room JSON was not checked in. The fixture
     starts from the exact v11 export, applies Android's two 11-to-12 `ALTER TABLE` statements, and
     pins the Room 2.7.2 compiler identity plus the production canonical-schema digest. Failure means
     iOS could reject a source Android itself migrates or accept an invented predecessor shape.
     */
    func testDerivedVersion12AuthorityMatchesAndroidMigrationAndRoomIdentity() throws {
        let databaseURL = try makeFixtureDatabase(version: 12)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), 12)
            XCTAssertEqual(
                try scalarText(
                    "SELECT identity_hash FROM room_master_table WHERE id = 42;",
                    in: database
                ),
                "ce84fdcfd2da69ec7a3dbb0a48598c5b"
            )
            XCTAssertEqual(
                try RemoteSyncAndroidDatabaseContract.schemaSHA256(
                    in: database,
                    excludingObjects: []
                ),
                "1fcdbebe0865065824e82c0a995c7c216bce2de8e483f90f6daec3746aa39149"
            )
        }
    }

    /**
     Compares every Swift migration statement with SQL extracted from the pinned Android Kotlin.

     The Python authority guard regenerates `AiSettingsMigrationSQL.json` semantically from each
     Android `db.execSQL` call. This test independently normalizes the executable Swift arrays and
     compares all 22 ordered edges. Failure means the hand-transcribed iOS chain drifted even when
     both source files remain individually valid.
     */
    func testSwiftMigrationStatementsMatchPinnedAndroidKotlinSQL() throws {
        let fixtureURL = fixtureRoot
            .deletingLastPathComponent()
            .appendingPathComponent("AiSettingsMigrationSQL.json")
        let expected = try JSONDecoder().decode(
            [String: [String]].self,
            from: Data(contentsOf: fixtureURL)
        )

        for version in 1...22 {
            XCTAssertEqual(
                RemoteSyncAISettingsDatabaseMigrator.migrationStatements(from: version).map(
                    normalizeMigrationSQL
                ),
                expected[String(version)],
                "Migration SQL drift at Android edge \(version)..\(version + 1)"
            )
        }
    }

    /** Rejects unversioned, Android-unmigratable, and future generations without mutation. */
    func testUnsupportedAISettingsSourceGenerationsAreNotMigrated() throws {
        for version in [0, 17, 24] {
            try XCTContext.runActivity(named: "unsupported-ai-settings-v\(version)") { _ in
                let databaseURL = try makeFixtureDatabase(version: version == 17 ? 17 : 23)
                defer { try? FileManager.default.removeItem(at: databaseURL) }
                if version != 17 {
                    try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
                        try execute("PRAGMA user_version = \(version);", in: database)
                    }
                }

                XCTAssertThrowsError(
                    try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(
                        at: databaseURL
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? RemoteSyncAISettingsDatabaseMigrationError,
                        .unsupportedSourceVersion(version)
                    )
                }
                try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
                    XCTAssertEqual(
                        try scalarInteger("PRAGMA user_version;", in: database),
                        Int64(version)
                    )
                    if version == 17 {
                        XCTAssertEqual(
                            try scalarInteger(
                                "SELECT COUNT(*) FROM pragma_table_info('GlobalAiSettings') WHERE name = 'builtInPromptCategories';",
                                in: database
                            ),
                            1
                        )
                        XCTAssertEqual(
                            try scalarInteger(
                                "SELECT COUNT(*) FROM pragma_table_info('GlobalAiSettings') WHERE name = 'hiddenBuiltInCategories';",
                                in: database
                            ),
                            0
                        )
                    }
                }
            }
        }
    }

    /** Requires archive metadata to agree with the staged source before migration begins. */
    func testExpectedSourceVersionMismatchFailsWithoutMutation() throws {
        let databaseURL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        XCTAssertThrowsError(
            try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(
                at: databaseURL,
                expectedSourceVersion: 21
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAISettingsDatabaseMigrationError,
                .sourceVersionMismatch(expected: 21, actual: 22)
            )
        }
        try assertVersion22RemainsUnmigrated(at: databaseURL)
    }

    /** Rejects predecessor identity and schema corruption before any migration statement runs. */
    func testPredecessorIdentityAndSchemaAreValidatedBeforeMigration() throws {
        let identityURL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: identityURL) }
        try withDatabase(at: identityURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                "UPDATE room_master_table SET identity_hash = 'wrong' WHERE id = 42;",
                in: database
            )
        }
        XCTAssertThrowsError(
            try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(
                at: identityURL
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .invalidIdentityHash
            )
        }
        try assertVersion22RemainsUnmigrated(at: identityURL)

        let schemaURL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: schemaURL) }
        try withDatabase(at: schemaURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute("DROP INDEX index_BuiltinPromptOverride_configuredModelId;", in: database)
        }
        XCTAssertThrowsError(
            try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(at: schemaURL)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .schemaMismatch("ai-settings-v22")
            )
        }
        try assertVersion22RemainsUnmigrated(at: schemaURL)
    }

    /** Preserves Android's destructive v8 model migration and its explicit data-loss contract. */
    func testVersion8ProviderAndPromptSurviveWhileUnmappableUsageIsDropped() throws {
        let databaseURL = try makeFixtureDatabase(version: 8)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO LlmProviderConfig (
                    id, providerType, displayName, endpoint, apiFormat, defaultModel, isDefault,
                    orderNumber, customInputPrice, customOutputPrice
                ) VALUES (
                    X'00000000000000000000000000000001', 'OPENAI', 'Legacy provider',
                    'https://example.test/v1', 'OPENAI', 'legacy-model', 1, 7, 1.25, 2.5
                );
                INSERT INTO AgentPrompt (
                    id, name, promptTemplate, showIn, providerConfigId, modelOverride
                ) VALUES (
                    X'00000000000000000000000000000002', 'Legacy prompt', 'Explain', 'BIBLE',
                    X'00000000000000000000000000000001', 'legacy-model'
                );
                INSERT INTO LlmUsageRecord (
                    id, providerConfigId, deviceId, inputTokens, outputTokens
                ) VALUES (
                    X'00000000000000000000000000000003',
                    X'00000000000000000000000000000001', 'legacy-device', 12, 34
                );
                """,
                in: database
            )
        }

        try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)

        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try scalarInteger("SELECT COUNT(*) FROM LlmProviderConfig;", in: database), 1)
            XCTAssertEqual(try scalarText("SELECT displayName FROM LlmProviderConfig;", in: database), "Legacy provider")
            XCTAssertEqual(try scalarText("SELECT endpoint FROM LlmProviderConfig;", in: database), "https://example.test/v1")
            XCTAssertEqual(try scalarInteger("SELECT COUNT(*) FROM AgentPrompt;", in: database), 1)
            XCTAssertEqual(
                try scalarInteger("SELECT configuredModelId IS NULL FROM AgentPrompt;", in: database),
                1
            )
            XCTAssertEqual(try scalarInteger("SELECT COUNT(*) FROM LlmConfiguredModel;", in: database), 0)
            XCTAssertEqual(try scalarInteger("SELECT COUNT(*) FROM LlmUsageRecord;", in: database), 0)
        }
    }

    /** Applies Android's two commentary-default normalizations and late global-setting defaults. */
    func testCommentaryAndLateGlobalDefaultsMatchAndroidMigrations() throws {
        let version4URL = try makeFixtureDatabase(version: 4)
        defer { try? FileManager.default.removeItem(at: version4URL) }
        try withDatabase(at: version4URL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO GlobalAiSettings (
                    id, aiExcludedDocuments, commentaryMaxResponseTokens
                ) VALUES (
                    X'A1000000000000000000000000000001', '', 0
                );
                """,
                in: database
            )
        }
        try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(at: version4URL)
        try withDatabase(at: version4URL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger("SELECT commentaryMaxResponseTokens FROM GlobalAiSettings;", in: database),
                15_000
            )
            XCTAssertEqual(
                try scalarInteger("SELECT rawLogRetentionDays FROM GlobalAiSettings;", in: database),
                30
            )
            XCTAssertEqual(
                try scalarInteger("SELECT autoHideAgentLogOnCompletion FROM GlobalAiSettings;", in: database),
                0
            )
        }

        let version9URL = try makeFixtureDatabase(version: 9)
        defer { try? FileManager.default.removeItem(at: version9URL) }
        try withDatabase(at: version9URL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO GlobalAiSettings (
                    id, aiExcludedDocuments, commentaryMaxResponseTokens,
                    hiddenBuiltInPrompts, commentaryDeselected
                ) VALUES (
                    X'A1000000000000000000000000000001', '', 4000, '', ''
                );
                """,
                in: database
            )
        }
        try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(at: version9URL)
        try withDatabase(at: version9URL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger("SELECT commentaryMaxResponseTokens FROM GlobalAiSettings;", in: database),
                15_000
            )
        }
    }

    /** Creates Android's v21 raw-log and v22 override tables while preserving their local-only role. */
    func testLateAISettingsTablesAndDefaultsAreCreatedExactly() throws {
        let databaseURL = try makeFixtureDatabase(version: 20)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO GlobalAiSettings (
                    id, aiExcludedDocuments, hiddenBuiltInPrompts, commentaryDeselected,
                    hiddenBuiltInCategories, favoritePrompts
                ) VALUES (
                    X'A1000000000000000000000000000001', '', '', '', '', ''
                );
                """,
                in: database
            )
        }

        try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)

        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'LlmRawLogRecord';",
                    in: database
                ),
                1
            )
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'BuiltinPromptOverride';",
                    in: database
                ),
                1
            )
            XCTAssertEqual(
                try scalarInteger("SELECT rawLogRetentionDays FROM GlobalAiSettings;", in: database),
                30
            )
            XCTAssertEqual(
                try scalarInteger("SELECT autoHideAgentLogOnCompletion FROM GlobalAiSettings;", in: database),
                0
            )
        }
    }

    /** Suppresses production-shaped sync triggers while data-changing AI migrations execute. */
    func testMigrationSuppressesRuntimeTriggersWithoutCreatingLogEntries() throws {
        let databaseURL = try makeFixtureDatabase(version: 4)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let existingTables: Set<String> = [
            "AgentPrompt",
            "LlmProviderConfig",
            "GlobalAiSettings",
            "LlmUsageRecord",
        ]
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO GlobalAiSettings (
                    id, aiExcludedDocuments, commentaryMaxResponseTokens
                ) VALUES (
                    X'A1000000000000000000000000000001', '', 0
                );
                """,
                in: database
            )
            for statement in AndroidRuntimeSyncTriggerFixture.statements(
                for: .aiSettings,
                deviceIdentifier: "migration-device",
                existingTables: existingTables
            ) {
                try execute(statement, in: database)
            }
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger';",
                    in: database
                ),
                12
            )
        }

        try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)

        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try scalarInteger("SELECT COUNT(*) FROM LogEntry;", in: database), 0)
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger';",
                    in: database
                ),
                0
            )
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM SyncConfiguration WHERE keyName = 'triggersDisabled';",
                    in: database
                ),
                0
            )
        }
    }

    /** Runs an older staged generation through the production restore reader before decoding rows. */
    func testRestoreReaderMigratesAdvertisedSourceBeforeDecoding() throws {
        let databaseURL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let snapshot = try RemoteSyncAISettingsRestoreService().readSnapshot(
            from: databaseURL,
            expectedSourceVersion: 22
        )

        XCTAssertTrue(snapshot.providers.isEmpty)
        XCTAssertTrue(snapshot.configuredModels.isEmpty)
        XCTAssertTrue(snapshot.agentPrompts.isEmpty)
        XCTAssertTrue(snapshot.globalSettings.isEmpty)
        XCTAssertTrue(snapshot.usageRecords.isEmpty)
        XCTAssertTrue(snapshot.promptCategories.isEmpty)
        XCTAssertTrue(snapshot.builtinOverrides.isEmpty)
        XCTAssertEqual(try readUserVersion(at: databaseURL), 23)
    }

    /** Proves a rejected v22 source never gains the v23 global-setting column. */
    private func assertVersion22RemainsUnmigrated(at databaseURL: URL) throws {
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), 22)
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM pragma_table_info('GlobalAiSettings') WHERE name = 'autoHideAgentLogOnCompletion';",
                    in: database
                ),
                0
            )
        }
    }

    /** Reads one SQLite user-version from a staged file after production migration. */
    private func readUserVersion(at databaseURL: URL) throws -> Int64 {
        var version = Int64.min
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            version = try scalarInteger("PRAGMA user_version;", in: database)
        }
        return version
    }

    /** Collapses formatting-only whitespace to match the Android-authority extraction fixture. */
    private func normalizeMigrationSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /** Returns all numeric authoritative AI settings fixture versions in deterministic order. */
    private func fixtureVersions() throws -> [Int] {
        let files = try FileManager.default.contentsOfDirectory(
            at: fixtureRoot,
            includingPropertiesForKeys: nil
        )
        return try files.filter { $0.pathExtension == "json" }.map { file in
            guard let version = Int(file.deletingPathExtension().lastPathComponent) else {
                throw TestError.invalidFixture(file.lastPathComponent)
            }
            return version
        }.sorted()
    }

    /** Creates one temporary SQLite database from an Android export or the exact derived v12 step. */
    private func makeFixtureDatabase(version: Int) throws -> URL {
        if version == 12 {
            let databaseURL = try makeFixtureDatabase(version: 11)
            do {
                try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
                    try execute(
                        "ALTER TABLE `AgentPrompt` ADD COLUMN `autoIncludeDocuments` INTEGER NOT NULL DEFAULT 0;",
                        in: database
                    )
                    try execute(
                        "ALTER TABLE `AgentPrompt` ADD COLUMN `autoIncludeCommentaries` INTEGER NOT NULL DEFAULT 0;",
                        in: database
                    )
                    try execute(
                        "UPDATE room_master_table SET identity_hash = 'ce84fdcfd2da69ec7a3dbb0a48598c5b' WHERE id = 42;",
                        in: database
                    )
                    try execute("PRAGMA user_version = 12;", in: database)
                }
                return databaseURL
            } catch {
                try? FileManager.default.removeItem(at: databaseURL)
                throw error
            }
        }
        let fixtureURL = fixtureRoot.appendingPathComponent("\(version).json")
        let fixture = try JSONDecoder().decode(
            RoomSchemaExport.self,
            from: Data(contentsOf: fixtureURL)
        )
        guard fixture.database.version == version else {
            throw TestError.invalidFixture("AI settings v\(version) version mismatch")
        }

        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ai-settings-room-v\(version)-\(UUID().uuidString).sqlite3"
        )
        do {
            try withDatabase(
                at: databaseURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
            ) { database in
                for entity in fixture.database.entities {
                    try execute(
                        entity.createSql.replacingOccurrences(
                            of: "${TABLE_NAME}",
                            with: entity.tableName
                        ),
                        in: database
                    )
                    for index in entity.indices ?? [] {
                        try execute(
                            index.createSql.replacingOccurrences(
                                of: "${TABLE_NAME}",
                                with: entity.tableName
                            ),
                            in: database
                        )
                    }
                }
                for view in fixture.database.views ?? [] {
                    try execute(
                        view.createSql.replacingOccurrences(
                            of: "${VIEW_NAME}",
                            with: view.viewName
                        ),
                        in: database
                    )
                }
                for query in fixture.database.setupQueries {
                    try execute(query, in: database)
                }
                try execute("PRAGMA user_version = \(version);", in: database)
            }
            return databaseURL
        } catch {
            try? FileManager.default.removeItem(at: databaseURL)
            throw error
        }
    }

    /** Opens one SQLite file for a scoped test operation and always closes it. */
    private func withDatabase(
        at url: URL,
        flags: Int32,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw TestError.sqlite("could not open \(url.path)")
        }
        defer { sqlite3_close(database) }
        try body(database)
    }

    /** Executes one fixture statement with SQLite's diagnostic on failure. */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw TestError.sqlite(message)
        }
    }

    /** Reads one required integer scalar from a query that must return exactly one row. */
    private func scalarInteger(_ sql: String, in database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw TestError.sqlite("missing integer scalar")
        }
        let value = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestError.sqlite("integer scalar returned multiple rows")
        }
        return value
    }

    /** Reads one required UTF-8 scalar from a query that must return exactly one row. */
    private func scalarText(_ sql: String, in database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, 0) else {
            throw TestError.sqlite("missing text scalar")
        }
        let value = String(cString: pointer)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TestError.sqlite("text scalar returned multiple rows")
        }
        return value
    }

    /// Directory containing exact Android `AiSettingsDatabase` generated exports.
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("AndroidRoomSchemas", isDirectory: true)
            .appendingPathComponent("AiSettingsDatabase", isDirectory: true)
    }
}
