// RemoteSyncWorkspaceDatabaseMigrationTests.swift -- Android workspace Room migration parity

import Foundation
import SQLite3
import XCTest
@testable import BibleCore

/** Proves staged workspace databases follow Android's authoritative migration and storage contract. */
final class RemoteSyncWorkspaceDatabaseMigrationTests: XCTestCase {
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
        case missingValue(String)
    }

    /**
     Migrates every advertised predecessor fixture through the Android chain to exact Room v24.

     The accepted set must equal the generated exports checked in by Android. Versions 10 and 12
     are intentionally absent as source fixtures even though migrations traverse both generations.
     */
    func testEveryAdvertisedWorkspaceGenerationMigratesToExactRoomVersion24() throws {
        let fixtureVersions = try Set(workspaceFixtureVersions())
        XCTAssertEqual(
            fixtureVersions,
            RemoteSyncWorkspaceDatabaseMigrator.supportedSourceVersions
        )
        XCTAssertFalse(fixtureVersions.contains(10))
        XCTAssertFalse(fixtureVersions.contains(12))

        for version in fixtureVersions.sorted() {
            try XCTContext.runActivity(named: "workspace-v\(version)-to-v24") { _ in
                let databaseURL = try makeFixtureDatabase(version: version)
                defer { try? FileManager.default.removeItem(at: databaseURL) }

                try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(
                    at: databaseURL,
                    expectedSourceVersion: version
                )

                try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
                    XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), 24)
                    XCTAssertEqual(
                        try scalarText(
                            "SELECT identity_hash FROM room_master_table WHERE id = 42;",
                            in: database
                        ),
                        "59b8635a1eb5125e32e2789eedd02ab2"
                    )
                    XCTAssertNoThrow(
                        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                            database,
                            category: .workspaces
                        )
                    )
                }
            }
        }
    }

    /**
     Rejects unexported, unversioned, and future generations before any staged schema mutation.

     A v24 fixture has only its `user_version` changed to model each unsupported claim. The
     migrator must reject from its authoritative set before attempting an incompatible SQL edge.
     */
    func testUnsupportedWorkspaceSourceGenerationsAreNotAdvertisedOrMigrated() throws {
        for version in [0, 10, 12, 25] {
            try XCTContext.runActivity(named: "unsupported-v\(version)") { _ in
                let databaseURL = try makeFixtureDatabase(version: 24)
                defer { try? FileManager.default.removeItem(at: databaseURL) }
                try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
                    try execute("PRAGMA user_version = \(version);", in: database)
                }

                XCTAssertThrowsError(
                    try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(
                        at: databaseURL
                    )
                ) { error in
                    XCTAssertEqual(
                        error as? RemoteSyncWorkspaceDatabaseMigrationError,
                        .unsupportedSourceVersion(version)
                    )
                }
                try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
                    XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), Int64(version))
                }
            }
        }
    }

    /**
     Requires archive metadata to match the database generation and leaves the staged file unchanged.

     This prevents a filename claiming one migration path from causing a differently shaped payload
     to be admitted under that claim.
     */
    func testExpectedSourceVersionMismatchFailsWithoutMutation() throws {
        let databaseURL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        XCTAssertThrowsError(
            try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(
                at: databaseURL,
                expectedSourceVersion: 23
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncWorkspaceDatabaseMigrationError,
                .sourceVersionMismatch(expected: 23, actual: 22)
            )
        }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), 22)
            XCTAssertEqual(
                try scalarText(
                    "SELECT identity_hash FROM room_master_table WHERE id = 42;",
                    in: database
                ),
                "4a38e9989c3075a4382c417b41f0c4a6"
            )
        }
    }

    /**
     Preserves Android's destructive transforms, default normalization, BLOB singleton, and defaults.

     The selected source generations exercise the behavior-bearing migrations rather than only
     proving that empty schemas reach v24.
     */
    func testAndroidWorkspaceMigrationDataTransformationsAndDefaults() throws {
        try assertVersion1ResetAndAddedDefaults()
        try assertVersion9StrongsRenumbering()
        try assertVersion14DefaultNormalization()
        try assertVersion15GlobalIdentifierMigration()
        try assertVersion22And23AddedFieldBehavior()
    }

    /**
     Mirrors Android's per-step `INSERT OR REPLACE` and unconditional cleanup behavior.

     A preexisting trigger-disable row with unrelated values is replaced during migration and then
     deleted, exactly as `Utilities.kt` does in its `finally` block.
     */
    func testMigrationUsesAndroidTriggerSuppressionConflictBehavior() throws {
        let databaseURL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO SyncConfiguration (keyName, stringValue, longValue, booleanValue)
                VALUES ('triggersDisabled', 'preexisting', 7, 0);
                """,
                in: database
            )
        }

        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)

        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM SyncConfiguration WHERE keyName = 'triggersDisabled';",
                    in: database
                ),
                0
            )
        }
    }

    /**
     Rejects a predecessor with the wrong Room identity or schema before any migration mutation.

     Both corrupt v22 files retain their original generation and lack the v23 column afterward,
     proving the failure precedes the transaction rather than relying on rollback after execution.
     */
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
            try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(
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
            try execute("DROP INDEX index_Window_workspaceId;", in: database)
        }
        XCTAssertThrowsError(
            try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: schemaURL)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .schemaMismatch("workspace-v22")
            )
        }
        try assertVersion22RemainsUnmigrated(at: schemaURL)
    }

    /**
     Runs real Android predecessor triggers through data-changing migrations without sync logs.

     Version 9 has three syncable tables and therefore nine production-shaped triggers. The
     strongs migration updates a Workspace row while trigger suppression is active; no LogEntry is
     emitted, and predecessor triggers are removed before the final v24 schema is admitted.
     */
    func testMigrationSuppressesProductionRuntimeTriggersWithoutLogEntries() throws {
        let databaseURL = try makeFixtureDatabase(version: 9)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (name, id, orderNumber, text_display_settings_strongsMode)
                VALUES ('Triggered', X'00000000000000000000000000000001', 0, 3);
                """,
                in: database
            )
            for statement in AndroidRuntimeSyncTriggerFixture.statements(
                for: .workspaces,
                deviceIdentifier: "migration-device",
                existingTables: ["Workspace", "Window", "PageManager"]
            ) {
                try execute(statement, in: database)
            }
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger';",
                    in: database
                ),
                9
            )
        }

        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)

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

    /**
     Resolves inherited values from a migrated Android backup through the production restore path.

     Android v14 explicit defaults are normalized to NULL during migration. The restored workspace
     must then inherit Android's true defaults for footnotes, cross references, justification, and
     memorization indicators rather than the former iOS false values.
     */
    func testMigratedRestoreResolvesAndroidInheritedDisplayDefaults() throws {
        let databaseURL = try makeFixtureDatabase(version: 14)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (
                    name,
                    id,
                    orderNumber,
                    text_display_settings_showFootNotes,
                    text_display_settings_showXrefs,
                    text_display_settings_justifyText
                ) VALUES (
                    'Inherited',
                    X'00000000000000000000000000000001',
                    0,
                    1,
                    1,
                    1
                );
                """,
                in: database
            )
        }

        let snapshot = try RemoteSyncWorkspaceRestoreService().readSnapshot(
            from: databaseURL,
            expectedSourceVersion: 14
        )
        let workspace = try XCTUnwrap(snapshot.workspaces.first)
        let resolved = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: workspace.textDisplaySettings,
            global: snapshot.globalTextDisplaySettings?.textDisplaySettings
        )
        XCTAssertEqual(resolved.showFootNotes, true)
        XCTAssertEqual(resolved.showXrefs, true)
        XCTAssertEqual(resolved.justifyText, true)
        XCTAssertEqual(resolved.showMemorizationIndicators, true)
    }

    /** Preserves embedded NUL bytes when the validated Android TEXT value is restored into Swift. */
    func testWorkspaceRestorePreservesEmbeddedNULText() throws {
        let databaseURL = try makeFixtureDatabase(version: 24)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (name, contentsText, id, orderNumber)
                VALUES (
                    CAST(X'61626300646566' AS TEXT),
                    CAST(X'6F6E650074776F' AS TEXT),
                    X'00000000000000000000000000000001',
                    0
                );
                """,
                in: database
            )
        }

        let snapshot = try RemoteSyncWorkspaceRestoreService().readSnapshot(from: databaseURL)
        let workspace = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertEqual(workspace.name, "abc\0def")
        XCTAssertEqual(workspace.contentsText, "one\0two")
    }

    /**
     Rejects workspace values whose SQLite storage class differs from Android converter output.

     BLOB bytes in a nullable TEXT field survive SQLite affinity unchanged, so v24 validation must
     fail rather than coercing or silently decoding them as a string.
     */
    func testCurrentWorkspaceSchemaRejectsWrongSQLiteStorageClass() throws {
        let databaseURL = try makeFixtureDatabase(version: 24)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (name, contentsText, id, orderNumber)
                VALUES ('Workspace', X'00FF', randomblob(16), 0);
                """,
                in: database
            )
        }

        XCTAssertThrowsError(
            try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .invalidRowValue(table: "Workspace", column: "contentsText")
            )
        }
    }

    /**
     Round-trips all v24 Android-only text-display values through the shared ordered wire projection.

     This contract is consumed by initial upload, sparse patch upload, snapshot fingerprints, and
     restore decoding, so one assertion protects every path from dropping the five new fields.
     */
    func testRoomVersion24TextDisplayFidelityRoundTripsAllNewFields() throws {
        let fidelity = RemoteSyncWorkspaceTextDisplaySettingsFidelity(
            autoTrackReading: true,
            scrollHelperLines: false,
            scrollHelperLineStyle: 3,
            showPageButtons: true,
            showReadingProgress: false,
            dayBackgroundImage: "day-image",
            nightBackgroundImage: "night-image",
            dayBackgroundImageOpacity: 37,
            nightBackgroundImageOpacity: 82
        )
        let wire = RemoteSyncWorkspaceTextDisplaySettingsWire(
            settings: nil,
            fidelity: fidelity
        )
        let values = try wire.sqliteValues()
        XCTAssertEqual(RemoteSyncWorkspaceTextDisplaySettingsWire.columnSuffixes.count, 46)
        XCTAssertEqual(values.count, 46)
        let valuesBySuffix = Dictionary(
            uniqueKeysWithValues: zip(
                RemoteSyncWorkspaceTextDisplaySettingsWire.columnSuffixes,
                values
            )
        )

        let decoded = try RemoteSyncWorkspaceTextDisplaySettingsWire.decode(
            integer: { suffix in
                valuesBySuffix[suffix]?.integerValue.flatMap(Int.init(exactly:))
            },
            boolean: { suffix in
                valuesBySuffix[suffix]?.integerValue.map { $0 != 0 }
            },
            text: { suffix in
                valuesBySuffix[suffix]?.textValue
            },
            hiddenLabels: { nil }
        )
        XCTAssertEqual(decoded.fidelity, fidelity)
        XCTAssertEqual(valuesBySuffix["showReadingProgress"]?.integerValue, 0)
        XCTAssertEqual(valuesBySuffix["colors_dayBackgroundImage"]?.textValue, "day-image")
        XCTAssertEqual(valuesBySuffix["colors_nightBackgroundImage"]?.textValue, "night-image")
        XCTAssertEqual(valuesBySuffix["colors_dayBackgroundImageOpacity"]?.integerValue, 37)
        XCTAssertEqual(valuesBySuffix["colors_nightBackgroundImageOpacity"]?.integerValue, 82)
    }

    /** Exercises the Android 1-to-2 reset and later nullable/default additions. */
    private func assertVersion1ResetAndAddedDefaults() throws {
        let databaseURL = try makeFixtureDatabase(version: 1)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (name, id, orderNumber, maximizedWindowId)
                VALUES ('Legacy', X'00000000000000000000000000000001', 0,
                        X'00000000000000000000000000000002');
                """,
                in: database
            )
        }
        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarText(
                    "SELECT typeof(maximizedWindowId) FROM Workspace;",
                    in: database
                ),
                "null"
            )
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT workspace_settings_restoreButtonsVisible FROM Workspace;",
                    in: database
                ),
                1
            )
            XCTAssertEqual(
                try scalarText(
                    "SELECT typeof(text_display_settings_showReadingProgress) FROM Workspace;",
                    in: database
                ),
                "null"
            )
        }
    }

    /** Exercises Android's strongs renumbering and later inherited-default normalization. */
    private func assertVersion9StrongsRenumbering() throws {
        let databaseURL = try makeFixtureDatabase(version: 9)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (name, id, orderNumber, text_display_settings_strongsMode)
                VALUES ('Legacy', randomblob(16), 0, 3);
                """,
                in: database
            )
        }
        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarText(
                    "SELECT typeof(text_display_settings_strongsMode) FROM Workspace;",
                    in: database
                ),
                "null"
            )
        }
    }

    /** Exercises Android's 14-to-15 hardcoded-default normalization to inherited NULL values. */
    private func assertVersion14DefaultNormalization() throws {
        let databaseURL = try makeFixtureDatabase(version: 14)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace (
                    name, id, orderNumber, text_display_settings_fontSize,
                    text_display_settings_fontFamily, text_display_settings_showFootNotes,
                    text_display_settings_colors_dayBackground,
                    text_display_settings_margin_size_maxWidth
                ) VALUES ('Defaults', randomblob(16), 0, 16, 'sans-serif', 1, -1, 170);
                """,
                in: database
            )
        }
        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger(
                    """
                    SELECT COUNT(*) FROM Workspace
                    WHERE text_display_settings_fontSize IS NULL
                      AND text_display_settings_fontFamily IS NULL
                      AND text_display_settings_showFootNotes IS NULL
                      AND text_display_settings_colors_dayBackground IS NULL
                      AND text_display_settings_margin_size_maxWidth IS NULL;
                    """,
                    in: database
                ),
                1
            )
        }
    }

    /** Exercises Android's 15-to-16 fixed BLOB singleton identity and value copy. */
    private func assertVersion15GlobalIdentifierMigration() throws {
        let databaseURL = try makeFixtureDatabase(version: 15)
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO GlobalTextDisplaySettings
                    (id, text_display_settings_fontSize, text_display_settings_fontFamily)
                VALUES (7, 19, 'serif');
                """,
                in: database
            )
        }
        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: databaseURL)
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarText("SELECT hex(id) FROM GlobalTextDisplaySettings;", in: database),
                "00000000000000000000000000000001"
            )
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT text_display_settings_fontSize FROM GlobalTextDisplaySettings;",
                    in: database
                ),
                19
            )
            XCTAssertEqual(
                try scalarText(
                    "SELECT text_display_settings_fontFamily FROM GlobalTextDisplaySettings;",
                    in: database
                ),
                "serif"
            )
        }
    }

    /** Exercises v22/v23 additions, preserving reading progress and defaulting image fields to NULL. */
    private func assertVersion22And23AddedFieldBehavior() throws {
        let version22URL = try makeFixtureDatabase(version: 22)
        defer { try? FileManager.default.removeItem(at: version22URL) }
        try withDatabase(at: version22URL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                "INSERT INTO Workspace (name, id, orderNumber) VALUES ('V22', randomblob(16), 0);",
                in: database
            )
        }
        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: version22URL)
        try withDatabase(at: version22URL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger(
                    """
                    SELECT COUNT(*) FROM Workspace
                    WHERE text_display_settings_showReadingProgress IS NULL
                      AND text_display_settings_colors_dayBackgroundImage IS NULL
                      AND text_display_settings_colors_nightBackgroundImage IS NULL
                      AND text_display_settings_colors_dayBackgroundImageOpacity IS NULL
                      AND text_display_settings_colors_nightBackgroundImageOpacity IS NULL;
                    """,
                    in: database
                ),
                1
            )
        }

        let version23URL = try makeFixtureDatabase(version: 23)
        defer { try? FileManager.default.removeItem(at: version23URL) }
        try withDatabase(at: version23URL, flags: SQLITE_OPEN_READWRITE) { database in
            try execute(
                """
                INSERT INTO Workspace
                    (name, id, orderNumber, text_display_settings_showReadingProgress)
                VALUES ('V23', randomblob(16), 0, 1);
                """,
                in: database
            )
        }
        try RemoteSyncWorkspaceDatabaseMigrator.migrateAndValidateStagedDatabase(at: version23URL)
        try withDatabase(at: version23URL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try scalarInteger(
                    "SELECT text_display_settings_showReadingProgress FROM Workspace;",
                    in: database
                ),
                1
            )
            XCTAssertEqual(
                try scalarText(
                    "SELECT typeof(text_display_settings_colors_dayBackgroundImage) FROM Workspace;",
                    in: database
                ),
                "null"
            )
        }
    }

    /** Requires a rejected v22 source to retain its generation and pre-v23 column set. */
    private func assertVersion22RemainsUnmigrated(at databaseURL: URL) throws {
        try withDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try scalarInteger("PRAGMA user_version;", in: database), 22)
            XCTAssertEqual(
                try scalarInteger(
                    """
                    SELECT COUNT(*) FROM pragma_table_info('Workspace')
                    WHERE name = 'text_display_settings_showReadingProgress';
                    """,
                    in: database
                ),
                0
            )
        }
    }

    /** Returns all numeric authoritative workspace fixture versions in deterministic order. */
    private func workspaceFixtureVersions() throws -> [Int] {
        let files = try FileManager.default.contentsOfDirectory(
            at: workspaceFixtureRoot,
            includingPropertiesForKeys: nil
        )
        return try files.filter { $0.pathExtension == "json" }.map { file in
            guard let version = Int(file.deletingPathExtension().lastPathComponent) else {
                throw TestError.invalidFixture(file.lastPathComponent)
            }
            return version
        }.sorted()
    }

    /** Creates one temporary SQLite database directly from an Android Room schema export. */
    private func makeFixtureDatabase(version: Int) throws -> URL {
        let fixtureURL = workspaceFixtureRoot.appendingPathComponent("\(version).json")
        let fixture: RoomSchemaExport
        do {
            fixture = try JSONDecoder().decode(
                RoomSchemaExport.self,
                from: Data(contentsOf: fixtureURL)
            )
        } catch {
            throw TestError.invalidFixture("workspace v\(version): \(error)")
        }
        guard fixture.database.version == version else {
            throw TestError.invalidFixture("workspace v\(version) version mismatch")
        }

        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "workspace-room-v\(version)-\(UUID().uuidString).sqlite3"
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

    /** Executes one fixture or assertion statement with SQLite's diagnostic on failure. */
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

    /** Reads one required integer scalar without SQLite coercion in the test harness. */
    private func scalarInteger(_ sql: String, in database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw TestError.missingValue(sql)
        }
        return sqlite3_column_int64(statement, 0)
    }

    /** Reads one required UTF-8 text scalar without C-string truncation. */
    private func scalarText(_ sql: String, in database: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw TestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_TEXT else {
            throw TestError.missingValue(sql)
        }
        let count = Int(sqlite3_column_bytes(statement, 0))
        if count == 0 { return "" }
        guard let bytes = sqlite3_column_text(statement, 0),
              let value = String(
                data: Data(bytes: bytes, count: count),
                encoding: .utf8
              ) else {
            throw TestError.missingValue(sql)
        }
        return value
    }

    /// Directory containing exact Android `WorkspaceDatabase` generated exports.
    private var workspaceFixtureRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("AndroidRoomSchemas", isDirectory: true)
            .appendingPathComponent("WorkspaceDatabase", isDirectory: true)
    }
}
