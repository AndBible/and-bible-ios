// RemoteSyncAndroidDatabaseContract.swift -- Canonical Android Room contracts for remote sync

import CryptoKit
import Foundation
import SQLite3

/** Fail-visible mismatches against an exact exported Android Room schema. */
enum RemoteSyncAndroidDatabaseContractError: Error, Equatable {
    /// SQLite metadata could not be queried safely.
    case invalidDatabase

    /// `PRAGMA user_version` differs from the exact supported Android schema.
    case invalidUserVersion(expected: Int, actual: Int)

    /// Room's sole identity row is missing, duplicated, mistyped, or carries another hash.
    case invalidIdentityHash

    /// Tables, columns, defaults, keys, indexes, foreign keys, views, or triggers differ.
    case schemaMismatch(String)

    /// A table exceeds the bounded row count accepted before materialization.
    case tooManyRows(table: String, count: Int64, maximum: Int64)

    /// One text or identifier field exceeds its bounded wire representation.
    case fieldTooLarge(table: String, column: String)

    /// One row uses an unsupported SQLite storage class or semantic value.
    case invalidRowValue(table: String, column: String)
}

/**
 Defines the exact Android Room database contract for every iOS-supported remote-sync category.

 The versions, identity hashes, tables, indexes, foreign keys, views, defaults, and primary keys are
 transcribed from Android's Room schema exports. The one omitted AI v12 export is reconstructed from
 exported v11, Android's exact migration, and Room's compiler identity algorithm. Initial and sparse
 databases must both be valid Room databases because Android opens every downloaded patch through
 its production Room factory before attaching it for reconciliation.
 */
enum RemoteSyncAndroidDatabaseContract {
    /** Immutable Room identity and canonical-schema digest for one exported predecessor generation. */
    private struct RoomSourceAuthority {
        /// Room identity written by Android's generated schema export.
        let identityHash: String

        /// SHA-256 of the canonical SQLite schema signature built from that export.
        let schemaSHA256: String
    }

    /**
     Returns the Android Room schema version for one sync category.

     - Parameter category: Remote-sync category whose wire schema is required.
     - Returns: Exact Android Room schema version supported by this build.
     - Side Effects: none.
     - Failure modes: This function cannot fail because every category is exhaustive.
     */
    static func schemaVersion(for category: RemoteSyncCategory) -> Int {
        switch category {
        case .bookmarks: 12
        case .workspaces: 24
        case .readingPlans: 1
        case .myDocuments: 4
        case .progress: 9
        case .aiSettings: 23
        }
    }

    /**
     Returns the Room identity hash for one category's supported Android schema.

     - Parameter category: Remote-sync category whose Room identity is required.
     - Returns: Lowercase Android Room identity hash.
     - Side Effects: none.
     - Failure modes: This function cannot fail because every category is exhaustive.
     */
    static func identityHash(for category: RemoteSyncCategory) -> String {
        switch category {
        case .bookmarks: "0492abbf5bd840e0fcc87744a8af6f11"
        case .workspaces: "59b8635a1eb5125e32e2789eedd02ab2"
        case .readingPlans: "d465b2a4bc2012fff3a69d3eaff9b5ff"
        case .myDocuments: "3f0946602099d896c8d47129233c1794"
        case .progress: "76330d8367020840e56e6b92d921522a"
        case .aiSettings: "c5b1820fd3dfb0390fa3122d2d6e139f"
        }
    }

    /**
     Returns executable DDL for a complete Android Room database shell.

     Sparse patches intentionally receive every Android entity, index, view, sync table, and Room
     identity row. Data writers then insert only changed rows into the otherwise-empty shell.

     - Parameter category: Remote-sync category whose schema should be created.
     - Returns: SQLite batch including `user_version` and `room_master_table` identity metadata.
     - Side Effects: none; callers execute the returned SQL against their own database.
     - Failure modes: This function cannot fail because every category is exhaustive.
     */
    static func createSchemaSQL(for category: RemoteSyncCategory) -> String {
        switch category {
        case .bookmarks:
            AndroidBookmarkDatabaseContract.createSchemaSQL
        case .workspaces:
            workspaceSchemaSQL
        case .readingPlans:
            readingPlanSchemaSQL
        case .myDocuments:
            myDocumentsSchemaSQL
        case .progress:
            progressSchemaSQL
        case .aiSettings:
            aiSettingsSchemaSQL
        }
    }

    /**
     Validates one open inbound database against the complete exported Android Room contract.

     - Parameters:
       - database: Open read-only or writable SQLite database.
       - category: Category whose exact schema is required.
     - Side effects: Creates and closes one in-memory expected-schema database; reads inbound metadata.
     - Throws: Typed version, identity, metadata, or complete-schema mismatches before row decoding.
     */
    static func validateInboundDatabase(
        _ database: OpaquePointer,
        category: RemoteSyncCategory
    ) throws {
        let actualVersion = try integerPragma("user_version", in: database)
        let expectedVersion = schemaVersion(for: category)
        guard actualVersion == expectedVersion else {
            throw RemoteSyncAndroidDatabaseContractError.invalidUserVersion(
                expected: expectedVersion,
                actual: actualVersion
            )
        }
        try validateIdentity(
            in: database,
            expectedHash: identityHash(for: category)
        )
        let runtimeTriggerNames = try validatedRuntimeSyncTriggerNames(
            in: database,
            category: category
        )

        var expectedDatabase: OpaquePointer?
        guard sqlite3_open(":memory:", &expectedDatabase) == SQLITE_OK,
              let expectedDatabase else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        defer { sqlite3_close(expectedDatabase) }
        guard sqlite3_exec(
            expectedDatabase,
            createSchemaSQL(for: category),
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }

        let expected = try schemaSignatures(
            in: expectedDatabase,
            excludingTables: [],
            excludingObjects: []
        )
        let actual = try schemaSignatures(
            in: database,
            excludingTables: [],
            excludingObjects: runtimeTriggerNames
        )
        guard Set(actual.keys) == Set(expected.keys) else {
            let unexpected = Set(actual.keys).subtracting(expected.keys).sorted()
            let missing = Set(expected.keys).subtracting(actual.keys).sorted()
            throw RemoteSyncAndroidDatabaseContractError.schemaMismatch(
                "objects:missing=\(missing),unexpected=\(unexpected)"
            )
        }
        for name in expected.keys.sorted() where expected[name] != actual[name] {
            throw RemoteSyncAndroidDatabaseContractError.schemaMismatch(name)
        }
        try validatePayloadBounds(
            in: database,
            category: category
        )
    }

    /**
     Validates one advertised workspace predecessor against its own exported Room generation.

     This check runs before migration mutates the staged database. It requires the claimed
     `user_version`, that generation's Room identity, the canonical authority schema, and either no
     runtime triggers or the complete Android trigger set applicable to tables in that generation.

     - Parameters:
       - database: Open staged workspace database.
       - sourceVersion: Advertised Android Room generation.
     - Returns: Exact validated runtime trigger names, which a migration may safely remove.
     - Side Effects: Reads SQLite metadata and computes an in-memory SHA-256 digest; does not mutate.
     - Throws: Typed version, identity, trigger, or schema errors before any migration statement runs.
     */
    static func validateWorkspaceSourceDatabase(
        _ database: OpaquePointer,
        sourceVersion: Int
    ) throws -> Set<String> {
        guard let authority = workspaceSourceAuthorities[sourceVersion] else {
            throw RemoteSyncAndroidDatabaseContractError.invalidUserVersion(
                expected: schemaVersion(for: .workspaces),
                actual: sourceVersion
            )
        }
        let actualVersion = try integerPragma("user_version", in: database)
        guard actualVersion == sourceVersion else {
            throw RemoteSyncAndroidDatabaseContractError.invalidUserVersion(
                expected: sourceVersion,
                actual: actualVersion
            )
        }
        try validateIdentity(in: database, expectedHash: authority.identityHash)
        let runtimeTriggerNames = try validatedRuntimeSyncTriggerNames(
            in: database,
            category: .workspaces
        )
        let actualDigest = try schemaSHA256(
            in: database,
            excludingObjects: runtimeTriggerNames
        )
        guard actualDigest == authority.schemaSHA256 else {
            throw RemoteSyncAndroidDatabaseContractError.schemaMismatch(
                "workspace-v\(sourceVersion)"
            )
        }
        return runtimeTriggerNames
    }

    /**
     Validates one advertised AI settings predecessor against its exported Room generation.

     - Parameters:
       - database: Open staged AI settings database.
       - sourceVersion: Advertised Android Room generation.
     - Returns: Exact validated runtime trigger names, which migration may safely remove.
     - Side Effects: Reads SQLite metadata and computes an in-memory schema digest only.
     - Throws: Typed version, identity, trigger, or schema errors before migration mutates the file.
     */
    static func validateAISettingsSourceDatabase(
        _ database: OpaquePointer,
        sourceVersion: Int
    ) throws -> Set<String> {
        guard let authority = aiSettingsSourceAuthorities[sourceVersion] else {
            throw RemoteSyncAndroidDatabaseContractError.invalidUserVersion(
                expected: schemaVersion(for: .aiSettings),
                actual: sourceVersion
            )
        }
        let actualVersion = try integerPragma("user_version", in: database)
        guard actualVersion == sourceVersion else {
            throw RemoteSyncAndroidDatabaseContractError.invalidUserVersion(
                expected: sourceVersion,
                actual: actualVersion
            )
        }
        try validateIdentity(in: database, expectedHash: authority.identityHash)
        let runtimeTriggerNames = try validatedRuntimeSyncTriggerNames(
            in: database,
            category: .aiSettings
        )
        let actualDigest = try schemaSHA256(
            in: database,
            excludingObjects: runtimeTriggerNames
        )
        guard actualDigest == authority.schemaSHA256 else {
            throw RemoteSyncAndroidDatabaseContractError.schemaMismatch(
                "ai-settings-v\(sourceVersion)"
            )
        }
        return runtimeTriggerNames
    }

    /** Validates bounded row and scalar domains before any caller materializes database content. */
    private static func validatePayloadBounds(
        in database: OpaquePointer,
        category: RemoteSyncCategory
    ) throws {
        switch category {
        case .workspaces:
            try validateWorkspacePayloadBounds(in: database)
        case .readingPlans:
            try requireRowCount("ReadingPlan", maximum: 10_000, in: database)
            try requireRowCount("ReadingPlanStatus", maximum: 100_000, in: database)
            try requireBlobUUID("ReadingPlan", column: "id", in: database)
            try requireBoundedText("ReadingPlan", column: "planCode", maximum: 128, permitsEmpty: false, in: database)
            try requireInteger("ReadingPlan", column: "planStartDate", in: database)
            try requireInteger("ReadingPlan", column: "planCurrentDay", range: 0...10_000, in: database)
            try requireBlobUUID("ReadingPlanStatus", column: "id", in: database)
            try requireBoundedText("ReadingPlanStatus", column: "planCode", maximum: 128, permitsEmpty: false, in: database)
            try requireInteger("ReadingPlanStatus", column: "planDay", range: 1...10_000, in: database)
            try requireBoundedText("ReadingPlanStatus", column: "readingStatus", maximum: 1_024 * 1_024, permitsEmpty: true, in: database)
            try validateSyncMetadataBounds(
                nativeTables: ["ReadingPlan", "ReadingPlanStatus"],
                in: database
            )
        case .progress:
            let progressOrdinalRange: ClosedRange<Int64> = Int64(
                JSwordKJVAVersification.progressOrdinalRange.lowerBound
            )...Int64(JSwordKJVAVersification.progressOrdinalRange.upperBound)
            try requireRowCount("MemorizedVerse", maximum: 100_000, in: database)
            try requireRowCount("ChapterReadHistory", maximum: 100_000, in: database)
            try requireRowCount("MemorizationTarget", maximum: 100_000, in: database)
            try requireRowCount("GlobalReadingProgressSettings", maximum: 1, in: database)
            try requireBlobUUID("MemorizedVerse", column: "id", in: database)
            try requireInteger(
                "MemorizedVerse",
                column: "kjvOrdinal",
                range: progressOrdinalRange,
                in: database
            )
            try requireInteger("MemorizedVerse", column: "memorizedAt", in: database)
            try requireBlobUUID("ChapterReadHistory", column: "id", in: database)
            try requireInt32("ChapterReadHistory", column: "kjvBookOrdinal", in: database)
            try requireInt32("ChapterReadHistory", column: "chapter", in: database)
            try validateProgressChapterReferences(in: database)
            try requireInteger("ChapterReadHistory", column: "cycle", range: 0...Int64(Int32.max), in: database)
            try requireInteger("ChapterReadHistory", column: "readAt", in: database)
            try requireBoundedText("ChapterReadHistory", column: "bookInitials", maximum: 4_096, permitsEmpty: true, in: database)
            try requireTextValue(
                "ChapterReadHistory",
                column: "source",
                allowed: ["MANUAL", "AUTO_SCROLL", "AUTO_TTS"],
                in: database
            )
            try requireBlobUUID("MemorizationTarget", column: "id", in: database)
            try requireInteger(
                "MemorizationTarget",
                column: "kjvOrdinalStart",
                range: progressOrdinalRange,
                in: database
            )
            try requireInteger(
                "MemorizationTarget",
                column: "kjvOrdinalEnd",
                range: progressOrdinalRange,
                in: database
            )
            try rejectAny(
                "SELECT 1 FROM MemorizationTarget WHERE kjvOrdinalEnd < kjvOrdinalStart LIMIT 1",
                error: .invalidRowValue(table: "MemorizationTarget", column: "kjvOrdinalEnd"),
                in: database
            )
            try requireInteger("MemorizationTarget", column: "createdAt", in: database)
            try requireFixedBlobIdentifier(
                "GlobalReadingProgressSettings",
                column: "id",
                hexadecimal: progressSettingsIdentifierHex,
                in: database
            )
            for column in [
                "autoTrackReading",
                "autoMarkMemorized",
                "memorizeTypeFullWords",
                "memorizeErrorHeatmap",
                "memorizeScrambleHideUsed",
                "memorizeIncludeReference",
            ] {
                try requireBoolean("GlobalReadingProgressSettings", column: column, in: database)
            }
            try requireTextValue(
                "GlobalReadingProgressSettings",
                column: "memorizeWordVisibility",
                allowed: Set(ReadingProgressSettingsSnapshot.wordVisibilityValues),
                in: database
            )
            try requireInteger(
                "GlobalReadingProgressSettings",
                column: "activeCycle",
                range: 0...Int64(Int32.max),
                in: database
            )
            try validateSyncMetadataBounds(
                nativeTables: [
                    "MemorizedVerse",
                    "ChapterReadHistory",
                    "MemorizationTarget",
                    "GlobalReadingProgressSettings",
                ],
                fixedIdentifiers: [
                    "GlobalReadingProgressSettings": progressSettingsIdentifierHex
                ],
                in: database
            )
        case .aiSettings:
            try validateAISettingsPayloadBounds(in: database)
        case .bookmarks, .myDocuments:
            break
        }
    }

    /** Validates Android AI settings row domains without materializing unbounded prompt content. */
    private static func validateAISettingsPayloadBounds(in database: OpaquePointer) throws {
        let uuidTables = [
            "LlmProviderConfig",
            "LlmConfiguredModel",
            "AgentPrompt",
            "GlobalAiSettings",
            "LlmUsageRecord",
            "LlmRawLogRecord",
            "PromptCategory",
            "BuiltinPromptOverride",
        ]
        for table in uuidTables {
            let maximumRows: Int64
            switch table {
            case "GlobalAiSettings":
                maximumRows = 1
            case "LlmRawLogRecord":
                maximumRows = 100_000
            default:
                maximumRows = 100_000
            }
            try requireRowCount(table, maximum: maximumRows, in: database)
            try requireBlobUUID(table, column: "id", in: database)
        }
        try requireFixedBlobIdentifier(
            "GlobalAiSettings",
            column: "id",
            hexadecimal: "A1000000000000000000000000000001",
            in: database
        )

        try requireBoundedText("LlmProviderConfig", column: "providerType", maximum: 128, permitsEmpty: false, in: database)
        try requireBoundedText("LlmProviderConfig", column: "displayName", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireNullableText("LlmProviderConfig", column: "endpoint", maximum: 1_048_576, in: database)
        try requireNullableText("LlmProviderConfig", column: "apiFormat", maximum: 128, in: database)
        try requireInt32("LlmProviderConfig", column: "orderNumber", in: database)

        try requireBlobUUID("LlmConfiguredModel", column: "providerConfigId", in: database)
        try requireBoundedText("LlmConfiguredModel", column: "modelId", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireInt32("LlmConfiguredModel", column: "orderNumber", in: database)
        for column in [
            "inputPricePerMillion",
            "outputPricePerMillion",
            "cacheCreationPricePerMillion",
            "cacheReadPricePerMillion",
        ] {
            try requireNonnegativeFiniteReal("LlmConfiguredModel", column: column, in: database)
        }

        for column in ["name", "promptTemplate", "showIn"] {
            try requireBoundedText("AgentPrompt", column: column, maximum: 16_777_216, permitsEmpty: true, in: database)
        }
        for column in ["description", "permissionMode", "allowedTools", "deniedTools"] {
            try requireNullableText("AgentPrompt", column: column, maximum: 16_777_216, in: database)
        }
        try requireInt32("AgentPrompt", column: "orderNumber", in: database)
        try requireInteger("AgentPrompt", column: "createdAt", in: database)
        try requireNullableBlobUUID("AgentPrompt", column: "configuredModelId", in: database)
        try requireNullableBlobUUID("AgentPrompt", column: "categoryId", in: database)
        try requireNullableInt32("AgentPrompt", column: "maxIterations", in: database)
        for column in [
            "strictContextMatching",
            "editBeforeRun",
            "noDocumentCreation",
            "autoIncludeDocuments",
            "autoIncludeCommentaries",
            "bibleOnly",
            "isTextTransformation",
        ] {
            try requireBoolean("AgentPrompt", column: column, in: database)
        }

        for column in [
            "agentPermissionMode",
            "permanentlyAllowedTools",
            "permanentlyDeniedTools",
            "aiLanguage",
            "customAgentSystemPrompt",
            "customTextTransformationSystemPrompt",
        ] {
            try requireNullableText("GlobalAiSettings", column: column, maximum: 16_777_216, in: database)
        }
        for column in [
            "aiExcludedDocuments",
            "hiddenBuiltInPrompts",
            "commentaryDeselected",
            "hiddenBuiltInCategories",
            "favoritePrompts",
        ] {
            try requireBoundedText("GlobalAiSettings", column: column, maximum: 16_777_216, permitsEmpty: true, in: database)
        }
        try requireInt32("GlobalAiSettings", column: "commentaryMaxResponseTokens", in: database)
        try requireInt32("GlobalAiSettings", column: "maxIterations", in: database)
        try requireNullableInt32("GlobalAiSettings", column: "rawLogRetentionDays", in: database)
        try requireNullableBlobUUID("GlobalAiSettings", column: "defaultModelId", in: database)
        for column in ["askModelBeforeRun", "aiDisclaimerAccepted", "autoHideAgentLogOnCompletion"] {
            try requireBoolean("GlobalAiSettings", column: column, in: database)
        }

        try requireBlobUUID("LlmUsageRecord", column: "configuredModelId", in: database)
        try requireBoundedText("LlmUsageRecord", column: "deviceId", maximum: 512, permitsEmpty: true, in: database)
        for column in ["inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens"] {
            try requireInteger("LlmUsageRecord", column: column, range: 0...Int64.max, in: database)
        }
        try requireNonnegativeFiniteReal("LlmUsageRecord", column: "estimatedCostUsd", in: database)

        try requireBoundedText("PromptCategory", column: "name", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireInt32("PromptCategory", column: "orderNumber", in: database)
        try requireBoolean("PromptCategory", column: "hidden", in: database)
        try requireNullableBlobUUID("BuiltinPromptOverride", column: "configuredModelId", in: database)

        try rejectAny(
            "SELECT 1 FROM LlmRawLogRecord WHERE length(logData) > 67108864 LIMIT 1",
            error: .fieldTooLarge(table: "LlmRawLogRecord", column: "logData"),
            in: database
        )
        try validateSyncMetadataBounds(
            nativeTables: [
                "LlmProviderConfig",
                "LlmConfiguredModel",
                "AgentPrompt",
                "GlobalAiSettings",
                "LlmUsageRecord",
                "PromptCategory",
                "BuiltinPromptOverride",
            ],
            fixedIdentifiers: [
                "GlobalAiSettings": "A1000000000000000000000000000001"
            ],
            in: database
        )
    }

    /** Validates exact Android workspace row storage classes and bounded materialization sizes. */
    private static func validateWorkspacePayloadBounds(in database: OpaquePointer) throws {
        try requireRowCount("Workspace", maximum: 10_000, in: database)
        try requireRowCount("Window", maximum: 50_000, in: database)
        try requireRowCount("HistoryItem", maximum: 1_000_000, in: database)
        try requireRowCount("PageManager", maximum: 50_000, in: database)
        try requireRowCount("WorkspaceLabelOverride", maximum: 200_000, in: database)
        try requireRowCount("GlobalTextDisplaySettings", maximum: 1, in: database)

        try requireBoundedText("Workspace", column: "name", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireNullableText("Workspace", column: "contentsText", maximum: 16_777_216, in: database)
        try requireBlobUUID("Workspace", column: "id", in: database)
        try requireInt32("Workspace", column: "orderNumber", in: database)
        try requireNullableReal("Workspace", column: "unPinnedWeight", in: database)
        try requireNullableBlobUUID("Workspace", column: "maximizedWindowId", in: database)
        try requireNullableBlobUUID("Workspace", column: "primaryTargetLinksWindowId", in: database)
        try validateWorkspaceTextDisplayStorage(table: "Workspace", in: database)
        for column in [
            "workspace_settings_enableTiltToScroll",
            "workspace_settings_enableReverseSplitMode",
            "workspace_settings_autoPin",
            "workspace_settings_limitAmbiguousModalSize",
            "workspace_settings_restoreButtonsVisible",
        ] {
            try requireNullableBoolean("Workspace", column: column, in: database)
        }
        try requireNullableInt32(
            "Workspace",
            column: "workspace_settings_workspaceColor",
            in: database
        )
        for column in [
            "workspace_settings_speakSettings",
            "workspace_settings_recentLabels",
            "workspace_settings_autoAssignLabels",
            "workspace_settings_studyPadCursors",
            "workspace_settings_hideCompareDocuments",
        ] {
            try requireNullableText("Workspace", column: column, maximum: 16_777_216, in: database)
        }
        try requireNullableBlobUUID(
            "Workspace",
            column: "workspace_settings_autoAssignPrimaryLabel",
            in: database
        )

        try requireBlobUUID("Window", column: "workspaceId", in: database)
        for column in ["isSynchronized", "isPinMode", "isLinksWindow"] {
            try requireBoolean("Window", column: column, in: database)
        }
        for column in ["orderNumber", "syncGroup"] {
            try requireInt32("Window", column: column, in: database)
        }
        try requireBlobUUID("Window", column: "id", in: database)
        try requireNullableBlobUUID("Window", column: "targetLinksWindowId", in: database)
        try requireBoundedText("Window", column: "window_layout_state", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireReal("Window", column: "window_layout_weight", in: database)

        try requireBlobUUID("HistoryItem", column: "windowId", in: database)
        try requireInteger("HistoryItem", column: "createdAt", in: database)
        try requireBoundedText("HistoryItem", column: "document", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireBoundedText("HistoryItem", column: "key", maximum: 1_048_576, permitsEmpty: true, in: database)
        try requireNullableInt32("HistoryItem", column: "anchorOrdinal", in: database)
        try requireInteger("HistoryItem", column: "id", in: database)

        try requireBlobUUID("PageManager", column: "windowId", in: database)
        try requireBoundedText("PageManager", column: "currentCategoryName", maximum: 1_024, permitsEmpty: false, in: database)
        for column in [
            "jsState",
            "bible_document",
            "commentary_document",
            "commentary_sourceBookAndKey",
            "dictionary_document",
            "dictionary_key",
            "general_book_document",
            "general_book_key",
            "map_document",
            "map_key",
        ] {
            try requireNullableText("PageManager", column: column, maximum: 16_777_216, in: database)
        }
        try requireBoundedText(
            "PageManager",
            column: "bible_verse_versification",
            maximum: 4_096,
            permitsEmpty: true,
            in: database
        )
        for column in ["bible_verse_bibleBook", "bible_verse_chapterNo", "bible_verse_verseNo"] {
            try requireInt32("PageManager", column: column, in: database)
        }
        for column in [
            "commentary_anchorOrdinal",
            "dictionary_anchorOrdinal",
            "general_book_anchorOrdinal",
            "map_anchorOrdinal",
        ] {
            try requireNullableInt32("PageManager", column: column, in: database)
        }
        try validateWorkspaceTextDisplayStorage(table: "PageManager", in: database)

        try requireBlobUUID("WorkspaceLabelOverride", column: "workspaceId", in: database)
        try requireBlobUUID("WorkspaceLabelOverride", column: "labelId", in: database)
        try requireNullableInt32(
            "WorkspaceLabelOverride",
            column: "overrideMode",
            range: 0...3,
            in: database
        )
        try requireFixedBlobIdentifier(
            "GlobalTextDisplaySettings",
            column: "id",
            hexadecimal: workspaceGlobalSettingsIdentifierHex,
            in: database
        )
        try validateWorkspaceTextDisplayStorage(table: "GlobalTextDisplaySettings", in: database)
        try validateSyncMetadataBounds(
            nativeTables: [
                "Workspace",
                "Window",
                "PageManager",
                "WorkspaceLabelOverride",
                "GlobalTextDisplaySettings",
            ],
            compositeIdentifierTables: ["WorkspaceLabelOverride"],
            fixedIdentifiers: [
                "GlobalTextDisplaySettings": workspaceGlobalSettingsIdentifierHex
            ],
            in: database
        )
    }

    /** Validates nullable embedded text-display values using Room converter storage classes. */
    private static func validateWorkspaceTextDisplayStorage(
        table: String,
        in database: OpaquePointer
    ) throws {
        let textSuffixes: Set<String> = [
            "fontFamily",
            "bookmarksHideLabels",
            "colors_dayBackgroundImage",
            "colors_nightBackgroundImage",
        ]
        let booleanSuffixes: Set<String> = [
            "showMorphology",
            "showFootNotes",
            "showFootNotesInline",
            "expandXrefs",
            "showXrefs",
            "showRedLetters",
            "showSectionTitles",
            "showVerseNumbers",
            "showVersePerLine",
            "showBookmarks",
            "showMyNotes",
            "justifyText",
            "hyphenation",
            "showPageNumber",
            "infiniteScroll",
            "nonStrongsWordItalic",
            "showMarkAsReadButton",
            "showTitleScrollButton",
            "showMemorizationIndicators",
            "autoTrackReading",
            "showAiDocMarkers",
            "scrollHelperLines",
            "showPageButtons",
            "showOrdinals",
            "showReadingProgress",
        ]
        for suffix in RemoteSyncWorkspaceTextDisplaySettingsWire.columnSuffixes {
            let column = "text_display_settings_\(suffix)"
            if textSuffixes.contains(suffix) {
                try requireNullableText(table, column: column, maximum: 16_777_216, in: database)
            } else if booleanSuffixes.contains(suffix) {
                try requireNullableBoolean(table, column: column, in: database)
            } else {
                try requireNullableInt32(table, column: column, in: database)
            }
        }
    }

    /** Applies shared bounded `LogEntry`, `SyncConfiguration`, and `SyncStatus` contracts. */
    private static func validateSyncMetadataBounds(
        nativeTables: Set<String>,
        compositeIdentifierTables: Set<String> = [],
        fixedIdentifiers: [String: String] = [:],
        in database: OpaquePointer
    ) throws {
        try requireRowCount("LogEntry", maximum: 200_000, in: database)
        try requireRowCount("SyncConfiguration", maximum: 10_000, in: database)
        try requireRowCount("SyncStatus", maximum: 200_000, in: database)
        try requireBoundedText("LogEntry", column: "tableName", maximum: 128, permitsEmpty: false, in: database)
        try requireTextValue("LogEntry", column: "type", allowed: ["UPSERT", "DELETE"], in: database)
        try requireInteger("LogEntry", column: "lastUpdated", in: database)
        try requireBoundedText("LogEntry", column: "sourceDevice", maximum: 512, permitsEmpty: false, in: database)

        let singleIdentifierTables = nativeTables.subtracting(compositeIdentifierTables)
        let nativeList = singleIdentifierTables.sorted().map(sqlStringLiteral).joined(separator: ",")
        try rejectAny(
            """
            SELECT 1 FROM LogEntry
            WHERE tableName IN (\(nativeList))
              AND (typeof(entityId1) != 'blob' OR length(entityId1) != 16)
            LIMIT 1
            """,
            error: .invalidRowValue(table: "LogEntry", column: "entityId1"),
            in: database
        )
        if !compositeIdentifierTables.isEmpty {
            let compositeList = compositeIdentifierTables.sorted()
                .map(sqlStringLiteral)
                .joined(separator: ",")
            try rejectAny(
                """
                SELECT 1 FROM LogEntry
                WHERE tableName IN (\(compositeList))
                  AND (
                    typeof(entityId1) != 'blob' OR length(entityId1) != 16
                    OR typeof(entityId2) != 'blob' OR length(entityId2) != 16
                  )
                LIMIT 1
                """,
                error: .invalidRowValue(table: "LogEntry", column: "entityId2"),
                in: database
            )
        }
        try rejectAny(
            """
            SELECT 1 FROM LogEntry
            WHERE tableName IN (\(nativeList))
              AND NOT (typeof(entityId2) = 'text' AND length(CAST(entityId2 AS BLOB)) = 0)
            LIMIT 1
            """,
            error: .invalidRowValue(table: "LogEntry", column: "entityId2"),
            in: database
        )

        let admittedList = nativeTables.sorted().map(sqlStringLiteral).joined(separator: ",")
        try rejectAny(
            "SELECT 1 FROM LogEntry WHERE tableName NOT IN (\(admittedList)) LIMIT 1",
            error: .invalidRowValue(table: "LogEntry", column: "tableName"),
            in: database
        )
        for (table, hexadecimal) in fixedIdentifiers {
            try rejectAny(
                "SELECT 1 FROM LogEntry WHERE tableName = \(sqlStringLiteral(table)) AND hex(entityId1) != \(sqlStringLiteral(hexadecimal)) LIMIT 1",
                error: .invalidRowValue(table: "LogEntry", column: "entityId1"),
                in: database
            )
        }

        try requireBoundedText("SyncConfiguration", column: "keyName", maximum: 512, permitsEmpty: false, in: database)
        try rejectAny(
            """
            SELECT 1 FROM SyncConfiguration
            WHERE (stringValue IS NOT NULL AND (typeof(stringValue) != 'text' OR length(CAST(stringValue AS BLOB)) > 1048576))
               OR (longValue IS NOT NULL AND typeof(longValue) != 'integer')
               OR (booleanValue IS NOT NULL AND (typeof(booleanValue) != 'integer' OR booleanValue NOT IN (0, 1)))
            LIMIT 1
            """,
            error: .invalidRowValue(table: "SyncConfiguration", column: "value"),
            in: database
        )
        try requireBoundedText("SyncStatus", column: "sourceDevice", maximum: 512, permitsEmpty: false, in: database)
        try requireInteger("SyncStatus", column: "patchNumber", range: 0...Int64.max, in: database)
        try requireInteger("SyncStatus", column: "sizeBytes", range: 0...Int64.max, in: database)
        try requireInteger("SyncStatus", column: "appliedDate", in: database)
    }

    /** Rejects a table whose row count exceeds a category-specific allocation bound. */
    private static func requireRowCount(
        _ table: String,
        maximum: Int64,
        in database: OpaquePointer
    ) throws {
        let rows = try queryRows("SELECT COUNT(*) FROM \(sqlIdentifier(table));", in: database)
        guard rows.count == 1,
              rows[0].count == 1,
              rows[0][0].hasPrefix("i:"),
              let count = Int64(rows[0][0].dropFirst(2)) else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        guard count <= maximum else {
            throw RemoteSyncAndroidDatabaseContractError.tooManyRows(
                table: table,
                count: count,
                maximum: maximum
            )
        }
    }

    /** Requires every value in one column to be an exact 16-byte Android identifier BLOB. */
    private static func requireBlobUUID(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE typeof(\(sqlIdentifier(column))) != 'blob' OR length(\(sqlIdentifier(column))) != 16 LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires exact integer storage and, when supplied, a closed Android wire-value range. */
    private static func requireInteger(
        _ table: String,
        column: String,
        range: ClosedRange<Int64>? = nil,
        in database: OpaquePointer
    ) throws {
        var predicate = "typeof(\(sqlIdentifier(column))) != 'integer'"
        if let range {
            predicate += " OR \(sqlIdentifier(column)) < \(range.lowerBound) OR \(sqlIdentifier(column)) > \(range.upperBound)"
        }
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE \(predicate) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires every value in one Kotlin `Int` column to fit Android's signed 32-bit domain. */
    private static func requireInt32(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        try requireInteger(
            table,
            column: column,
            range: Int64(Int32.min)...Int64(Int32.max),
            in: database
        )
    }

    /** Requires every non-null Kotlin `Int` value to fit Android's signed 32-bit domain. */
    private static func requireNullableInt32(
        _ table: String,
        column: String,
        range: ClosedRange<Int64> = Int64(Int32.min)...Int64(Int32.max),
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE \(identifier) IS NOT NULL AND (typeof(\(identifier)) != 'integer' OR \(identifier) < \(range.lowerBound) OR \(identifier) > \(range.upperBound)) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires every Android Boolean to use exact SQLite INTEGER `0` or `1`. */
    private static func requireBoolean(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        try requireInteger(table, column: column, range: 0...1, in: database)
    }

    /** Requires every non-null Android Boolean to use exact SQLite INTEGER `0` or `1`. */
    private static func requireNullableBoolean(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        try requireNullableInt32(table, column: column, range: 0...1, in: database)
    }

    /** Requires every present singleton row to use one fixed Android 16-byte identifier. */
    private static func requireFixedBlobIdentifier(
        _ table: String,
        column: String,
        hexadecimal: String,
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE typeof(\(identifier)) != 'blob' OR length(\(identifier)) != 16 OR hex(\(identifier)) != \(sqlStringLiteral(hexadecimal)) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /**
     Requires every progress chapter tuple to identify a real KJVA book and chapter.

     - Parameter database: Open Progress Room database after row-count and INTEGER checks.
     - Side Effects: Iterates bounded chapter-history rows without mutating SQLite.
     - Throws: `invalidRowValue` when a JSword book ordinal is unknown or the chapter is outside that
       book's source-derived chapter count; `invalidDatabase` for malformed query results.
     */
    private static func validateProgressChapterReferences(in database: OpaquePointer) throws {
        let chapterCounts = Dictionary(
            uniqueKeysWithValues: JSwordKJVAVersification.books.map {
                (Int64($0.bibleBookOrdinal), Int64($0.chapterCount))
            }
        )
        for row in try queryRows(
            "SELECT kjvBookOrdinal, chapter FROM ChapterReadHistory",
            in: database
        ) {
            guard row.count == 2,
                  row[0].hasPrefix("i:"),
                  row[1].hasPrefix("i:"),
                  let bookOrdinal = Int64(row[0].dropFirst(2)),
                  let chapter = Int64(row[1].dropFirst(2)),
                  let chapterCount = chapterCounts[bookOrdinal] else {
                throw RemoteSyncAndroidDatabaseContractError.invalidRowValue(
                    table: "ChapterReadHistory",
                    column: "kjvBookOrdinal"
                )
            }
            guard (1...chapterCount).contains(chapter) else {
                throw RemoteSyncAndroidDatabaseContractError.invalidRowValue(
                    table: "ChapterReadHistory",
                    column: "chapter"
                )
            }
        }
    }

    /** Requires every value in one non-null column to use exact SQLite REAL storage. */
    private static func requireReal(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE typeof(\(sqlIdentifier(column))) != 'real' LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires exact SQLite REAL storage within the nonnegative finite IEEE-754 domain. */
    private static func requireNonnegativeFiniteReal(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE typeof(\(identifier)) != 'real' OR \(identifier) < 0.0 OR \(identifier) > 1.7976931348623157e308 LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires every non-null value in one column to use exact SQLite REAL storage. */
    private static func requireNullableReal(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        try requireNullableStorageClass("real", table: table, column: column, in: database)
    }

    /** Requires every non-null identifier in one column to be an exact 16-byte BLOB. */
    private static func requireNullableBlobUUID(
        _ table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE \(identifier) IS NOT NULL AND (typeof(\(identifier)) != 'blob' OR length(\(identifier)) != 16) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires every non-null value in one column to be bounded exact SQLite TEXT. */
    private static func requireNullableText(
        _ table: String,
        column: String,
        maximum: Int,
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE \(identifier) IS NOT NULL AND (typeof(\(identifier)) != 'text' OR length(CAST(\(identifier) AS BLOB)) > \(maximum)) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires every non-null value in one column to use one exact SQLite storage class. */
    private static func requireNullableStorageClass(
        _ storageClass: String,
        table: String,
        column: String,
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE \(identifier) IS NOT NULL AND typeof(\(identifier)) != \(sqlStringLiteral(storageClass)) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Requires bounded UTF-8-backed SQLite text before a caller copies bytes into Swift. */
    private static func requireBoundedText(
        _ table: String,
        column: String,
        maximum: Int,
        permitsEmpty: Bool,
        in database: OpaquePointer
    ) throws {
        let identifier = sqlIdentifier(column)
        let emptyPredicate = permitsEmpty ? "" : " OR length(CAST(\(identifier) AS BLOB)) = 0"
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE typeof(\(identifier)) != 'text' OR length(CAST(\(identifier) AS BLOB)) > \(maximum)\(emptyPredicate) LIMIT 1",
            error: .fieldTooLarge(table: table, column: column),
            in: database
        )
    }

    /** Requires one text column to contain only values constructible by current Android UI flows. */
    private static func requireTextValue(
        _ table: String,
        column: String,
        allowed: Set<String>,
        in database: OpaquePointer
    ) throws {
        let values = allowed.sorted().map(sqlStringLiteral).joined(separator: ",")
        let identifier = sqlIdentifier(column)
        try rejectAny(
            "SELECT 1 FROM \(sqlIdentifier(table)) WHERE typeof(\(identifier)) != 'text' OR \(identifier) NOT IN (\(values)) LIMIT 1",
            error: .invalidRowValue(table: table, column: column),
            in: database
        )
    }

    /** Throws a supplied bounded-contract error when a violation query returns any row. */
    private static func rejectAny(
        _ sql: String,
        error: RemoteSyncAndroidDatabaseContractError,
        in database: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return
        case SQLITE_ROW:
            throw error
        default:
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
    }

    /** Quotes one trusted text value as an SQLite string literal. */
    private static func sqlStringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /** Quotes one trusted SQLite identifier for a normal SQL expression. */
    private static func sqlIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /** Reads one scalar integer PRAGMA exactly. */
    private static func integerPragma(_ name: String, in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        let value = sqlite3_column_int64(statement, 0)
        guard sqlite3_step(statement) == SQLITE_DONE,
              let exact = Int(exactly: value) else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        return exact
    }

    /** Requires Room's exact singleton identity row and an authority-supplied generation hash. */
    private static func validateIdentity(
        in database: OpaquePointer,
        expectedHash: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, identity_hash FROM room_master_table",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw RemoteSyncAndroidDatabaseContractError.invalidIdentityHash
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == 42,
              sqlite3_column_type(statement, 1) == SQLITE_TEXT,
              columnText(statement, index: 1) == expectedHash,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncAndroidDatabaseContractError.invalidIdentityHash
        }
    }

    /**
     Validates Android's runtime-generated sync triggers without admitting arbitrary SQLite code.

     Runtime Android databases contain three triggers per syncable table, while sparse iOS patches
     and generated fixture shells contain none. Any nonempty trigger set must contain every trigger
     applicable to the category's existing tables, use the exact Android SQL template, and embed one
     consistent bounded device identifier.

     - Parameters:
       - database: Open Room database whose trigger objects should be inspected.
       - category: Workspace or Progress category; other categories currently admit no triggers here.
     - Returns: Empty when no runtime triggers exist, otherwise the exact validated trigger names.
     - Side Effects: Reads `sqlite_master`; does not execute or mutate trigger code.
     - Throws: `schemaMismatch` for missing, extra, or altered triggers and `invalidDatabase` for
       malformed SQLite metadata.
     */
    static func validatedRuntimeSyncTriggerNames(
        in database: OpaquePointer,
        category: RemoteSyncCategory
    ) throws -> Set<String> {
        let triggerRows = try queryRows(
            "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' ORDER BY name",
            in: database
        )
        if triggerRows.isEmpty { return [] }

        let tableRows = try queryRows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            in: database
        )
        let existingTables = try Set(tableRows.map { row -> String in
            guard row.count == 1 else {
                throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
            }
            return try serializedTextValue(row[0])
        })
        let definitions = runtimeSyncTableDefinitions(for: category).filter {
            existingTables.contains($0.table)
        }
        guard !definitions.isEmpty else {
            throw RemoteSyncAndroidDatabaseContractError.schemaMismatch("triggers")
        }

        let expectedNames = Set(definitions.flatMap { definition in
            ["inserts", "updates", "deletes"].map {
                "\(definition.table)_\($0)"
            }
        })
        var actualByName: [String: String] = [:]
        for row in triggerRows {
            guard row.count == 2 else {
                throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
            }
            let name = try serializedTextValue(row[0])
            let sql = try serializedTextValue(row[1])
            guard actualByName.updateValue(sql, forKey: name) == nil else {
                throw RemoteSyncAndroidDatabaseContractError.schemaMismatch("trigger:\(name)")
            }
        }
        guard Set(actualByName.keys) == expectedNames else {
            throw RemoteSyncAndroidDatabaseContractError.schemaMismatch("triggers")
        }

        var deviceIdentifier: String?
        for definition in definitions {
            for event in ["inserts", "updates", "deletes"] {
                let name = "\(definition.table)_\(event)"
                guard let sql = actualByName[name],
                      let extracted = runtimeTriggerDeviceIdentifier(
                        sql: sql,
                        table: definition.table,
                        firstIdentifier: definition.firstIdentifier,
                        secondIdentifier: definition.secondIdentifier,
                        event: event
                      ) else {
                    throw RemoteSyncAndroidDatabaseContractError.schemaMismatch("trigger:\(name)")
                }
                if let deviceIdentifier, deviceIdentifier != extracted {
                    throw RemoteSyncAndroidDatabaseContractError.schemaMismatch("triggers:device")
                }
                deviceIdentifier = extracted
            }
        }
        return expectedNames
    }

    /** Returns Android's current syncable table identifiers for Workspace and Progress databases. */
    private static func runtimeSyncTableDefinitions(
        for category: RemoteSyncCategory
    ) -> [(table: String, firstIdentifier: String, secondIdentifier: String?)] {
        switch category {
        case .workspaces:
            return [
                ("Workspace", "id", nil),
                ("Window", "id", nil),
                ("PageManager", "windowId", nil),
                ("WorkspaceLabelOverride", "workspaceId", "labelId"),
                ("GlobalTextDisplaySettings", "id", nil),
            ]
        case .progress:
            return [
                ("MemorizedVerse", "id", nil),
                ("ChapterReadHistory", "id", nil),
                ("MemorizationTarget", "id", nil),
                ("GlobalReadingProgressSettings", "id", nil),
            ]
        case .aiSettings:
            return [
                ("LlmProviderConfig", "id", nil),
                ("LlmConfiguredModel", "id", nil),
                ("AgentPrompt", "id", nil),
                ("GlobalAiSettings", "id", nil),
                ("LlmUsageRecord", "id", nil),
                ("PromptCategory", "id", nil),
                ("BuiltinPromptOverride", "id", nil),
            ]
        case .bookmarks, .readingPlans, .myDocuments:
            return []
        }
    }

    /** Extracts and validates the sole dynamic device literal from one Android trigger template. */
    private static func runtimeTriggerDeviceIdentifier(
        sql: String,
        table: String,
        firstIdentifier: String,
        secondIdentifier: String?,
        event: String
    ) -> String? {
        let marker = "__ANDBIBLE_DEVICE_IDENTIFIER__"
        let expected = normalizedSQL(
            runtimeTriggerSQL(
                table: table,
                firstIdentifier: firstIdentifier,
                secondIdentifier: secondIdentifier,
                event: event,
                deviceIdentifier: marker
            )
        )
        let markerLiteral = "'\(marker)'"
        let parts = expected.components(separatedBy: markerLiteral)
        guard parts.count == 2 else { return nil }

        let actual = normalizedSQL(sql)
        guard actual.hasPrefix(parts[0]), actual.hasSuffix(parts[1]) else { return nil }
        let start = actual.index(actual.startIndex, offsetBy: parts[0].count)
        let end = actual.index(actual.endIndex, offsetBy: -parts[1].count)
        guard start <= end else { return nil }
        let literal = String(actual[start..<end])
        guard literal.first == "'", literal.last == "'", literal.count >= 3 else { return nil }
        let value = String(literal.dropFirst().dropLast())
        guard !value.isEmpty, !value.contains("'"), value.utf8.count <= 512 else { return nil }
        return value
    }

    /** Builds the exact trigger SQL emitted by Android `SyncUtilities.createTriggersForTable`. */
    private static func runtimeTriggerSQL(
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
        case "deletes":
            eventKeyword = "DELETE"
            rowAlias = "OLD"
            operation = "DELETE"
        default:
            return ""
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
        CREATE TRIGGER \(table)_\(event) AFTER \(eventKeyword) ON \(table)
        WHEN (SELECT count(*) FROM SyncConfiguration WHERE keyName='triggersDisabled' AND booleanValue = 1 LIMIT 1) = 0
        BEGIN DELETE FROM LogEntry WHERE \(whereClause) AND tableName = '\(table)';
        INSERT INTO LogEntry VALUES ('\(table)', \(insertedIdentifiers), '\(operation)', CAST(UNIXEPOCH('subsec') * 1000 AS INTEGER), '\(deviceIdentifier)');
        END
        """
    }

    /**
     Builds Room-equivalent semantic signatures for every non-internal SQLite schema object.

     Table columns are keyed independently of physical `cid` order, matching Room's `TableInfo`
     comparison. Defaults remain exact except where Android migrations add a compatibility default
     that a later generated entity export omits; Room treats those migrated and fresh-install forms
     as equivalent. Raw table SQL is also tokenized for material features omitted by SQLite PRAGMAs,
     including collations, checks, conflict clauses, deferrability, autoincrement, strict tables, and
     `WITHOUT ROWID`.

     - Parameters:
       - database: Open SQLite database whose schema metadata should be canonicalized.
       - excludedTables: Private tables and their indexes omitted from the returned contract.
       - excludedObjects: Separately validated object names, such as Android runtime triggers.
     - Returns: Deterministic signatures keyed by SQLite object type and name.
     - Side effects: Reads SQLite metadata and index details without mutating the database.
     - Throws: `invalidDatabase` when metadata cannot be queried or represented losslessly.
     */
    private static func schemaSignatures(
        in database: OpaquePointer,
        excludingTables excludedTables: Set<String>,
        excludingObjects excludedObjectNames: Set<String>
    ) throws -> [String: String] {
        let objects = try queryRows(
            """
            SELECT type, name, tbl_name, COALESCE(sql, '')
            FROM sqlite_master
            WHERE type IN ('table', 'index', 'view', 'trigger')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """,
            in: database
        )
        var signatures: [String: String] = [:]
        for object in objects {
            guard object.count == 4 else {
                throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
            }
            let type = try serializedTextValue(object[0])
            let name = try serializedTextValue(object[1])
            let tableName = try serializedTextValue(object[2])
            if excludedTables.contains(name)
                || excludedTables.contains(tableName)
                || excludedObjectNames.contains(name) {
                continue
            }
            let key = "\(type):\(name)"
            switch type {
            case "table":
                let columns = try queryRows(
                    "PRAGMA table_xinfo(\(quotedIdentifier(name)));",
                    in: database
                ).map { row -> [String] in
                    guard row.count == 7 else {
                        throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
                    }
                    var semanticColumn = Array(row.dropFirst())
                    let columnName = try serializedTextValue(row[1])
                    let columnKey = "\(name).\(columnName)"
                    if defaultAbsentEquivalentValues[columnKey]?.contains(semanticColumn[3]) == true {
                        semanticColumn[3] = "n:"
                    }
                    return semanticColumn
                }.sorted { $0.serialized < $1.serialized }
                let foreignKeys = try queryRows(
                    "PRAGMA foreign_key_list(\(quotedIdentifier(name)));",
                    in: database
                )
                let indexes = try queryRows(
                    "PRAGMA index_list(\(quotedIdentifier(name)));",
                    in: database
                ).filter { row in
                    guard row.count > 1 else { return true }
                    guard let name = try? serializedTextValue(row[1]) else { return true }
                    return !name.hasPrefix("sqlite_autoindex_")
                }
                var indexDetails: [String] = []
                for index in indexes {
                    guard index.count > 1 else {
                        throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
                    }
                    let indexName = try serializedTextValue(index[1])
                    let columns = try queryRows(
                        "PRAGMA index_xinfo(\(quotedIdentifier(indexName)));",
                        in: database
                    )
                    indexDetails.append("\(Array(index.dropFirst()).serialized)|\(columns.serialized)")
                }
                signatures[key] = [
                    columns.serialized,
                    foreignKeys.serialized,
                    indexDetails.sorted().joined(separator: ";"),
                    try materialTableSQLSignature(
                        try serializedTextValue(object[3])
                    ),
                ].joined(separator: "#")
            case "index":
                signatures[key] = try queryRows(
                    "PRAGMA index_xinfo(\(quotedIdentifier(name)));",
                    in: database
                ).serialized
            case "view", "trigger":
                signatures[key] = normalizedSQL(try serializedTextValue(object[3]))
            default:
                throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
            }
        }
        return signatures
    }

    /**
     Computes a stable SHA-256 over length-delimited canonical schema signatures.

     Staged-database migrators use this internal authority digest before changing predecessor files;
     tests derive the pinned values from Android's checked-in Room exports.
     */
    static func schemaSHA256(
        in database: OpaquePointer,
        excludingObjects: Set<String>
    ) throws -> String {
        let signatures = try schemaSignatures(
            in: database,
            excludingTables: [],
            excludingObjects: excludingObjects
        )
        let canonical = signatures.keys.sorted().map { key in
            [key, signatures[key] ?? ""].serialized
        }.joined()
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /**
     Extracts material table-DDL features that SQLite PRAGMAs do not represent completely.

     - Parameter sql: Parsed table SQL retained by `sqlite_master`.
     - Returns: Deterministically sorted collations, checks, conflict policies, deferrability,
       autoincrement, strict-table, and without-rowid features.
     - Side Effects: none.
     - Throws: `invalidDatabase` when SQLite's retained SQL has an unterminated quoted token or CHECK.
     */
    private static func materialTableSQLSignature(_ sql: String) throws -> String {
        let tokens = try sqliteSQLTokens(sql)
        var features: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "w:COLLATE", index + 1 < tokens.count {
                features.append("COLLATE:\(tokens[index + 1])")
            } else if token == "w:CHECK", index + 1 < tokens.count,
                      tokens[index + 1] == "p:(" {
                var depth = 0
                var cursor = index + 1
                var expression: [String] = []
                var closed = false
                while cursor < tokens.count {
                    let value = tokens[cursor]
                    expression.append(value)
                    if value == "p:(" { depth += 1 }
                    if value == "p:)" {
                        depth -= 1
                        if depth == 0 {
                            closed = true
                            break
                        }
                    }
                    cursor += 1
                }
                guard closed else {
                    throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
                }
                features.append("CHECK:\(expression.serialized)")
                index = cursor
            } else if token == "w:ON", index + 2 < tokens.count,
                      tokens[index + 1] == "w:CONFLICT" {
                features.append("ON-CONFLICT:\(tokens[index + 2])")
            } else if token == "w:NOT", index + 1 < tokens.count,
                      tokens[index + 1] == "w:DEFERRABLE" {
                features.append("NOT-DEFERRABLE")
            } else if token == "w:DEFERRABLE" {
                features.append("DEFERRABLE")
            } else if token == "w:INITIALLY", index + 1 < tokens.count {
                features.append("INITIALLY:\(tokens[index + 1])")
            } else if token == "w:AUTOINCREMENT" {
                features.append("AUTOINCREMENT")
            } else if token == "w:STRICT" {
                features.append("STRICT")
            } else if token == "w:WITHOUT", index + 1 < tokens.count,
                      tokens[index + 1] == "w:ROWID" {
                features.append("WITHOUT-ROWID")
            }
            index += 1
        }
        return features.sorted().serialized
    }

    /** Tokenizes retained SQLite DDL while distinguishing keywords, identifiers, and literals. */
    private static func sqliteSQLTokens(_ sql: String) throws -> [String] {
        let characters = Array(sql)
        var tokens: [String] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "'" || character == "\"" || character == "`" || character == "[" {
                let terminator: Character = character == "[" ? "]" : character
                let prefix = character == "'" ? "s:" : "q:"
                index += 1
                var value = ""
                var closed = false
                while index < characters.count {
                    let current = characters[index]
                    if current == terminator {
                        if index + 1 < characters.count,
                           characters[index + 1] == terminator {
                            value.append(current)
                            index += 2
                            continue
                        }
                        closed = true
                        index += 1
                        break
                    }
                    value.append(current)
                    index += 1
                }
                guard closed else {
                    throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
                }
                tokens.append("\(prefix)\(value)")
                continue
            }
            if "(),;".contains(character) {
                tokens.append("p:\(character)")
                index += 1
                continue
            }
            let start = index
            while index < characters.count,
                  !characters[index].isWhitespace,
                  !"(),;'\"`[".contains(characters[index]) {
                index += 1
            }
            guard index > start else {
                tokens.append("o:\(character)")
                index += 1
                continue
            }
            tokens.append("w:\(String(characters[start..<index]).uppercased())")
        }
        return tokens
    }

    /** Executes one metadata query and losslessly serializes SQLite storage classes and values. */
    private static func queryRows(
        _ sql: String,
        in database: OpaquePointer
    ) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else {
                throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
            }
            var row: [String] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_NULL:
                    row.append("n:")
                case SQLITE_INTEGER:
                    row.append("i:\(sqlite3_column_int64(statement, index))")
                case SQLITE_FLOAT:
                    row.append("r:\(sqlite3_column_double(statement, index).bitPattern)")
                case SQLITE_TEXT:
                    row.append("t:\(columnText(statement, index: index) ?? "")")
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    let data: Data
                    if count == 0 {
                        data = Data()
                    } else {
                        guard let bytes = sqlite3_column_blob(statement, index) else {
                            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
                        }
                        data = Data(bytes: bytes, count: count)
                    }
                    row.append("b:\(data.base64EncodedString())")
                default:
                    throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
                }
            }
            rows.append(row)
        }
    }

    /** Decodes one typed query-row text value without erasing its payload bytes. */
    private static func serializedTextValue(_ value: String) throws -> String {
        guard value.hasPrefix("t:") else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        return String(value.dropFirst(2))
    }

    /** Quotes one trusted schema identifier for a PRAGMA argument. */
    private static func quotedIdentifier(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /** Normalizes insignificant SQL whitespace for view and trigger text comparison. */
    private static func normalizedSQL(_ sql: String) -> String {
        sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /** Decodes one SQLite text cell without C-string truncation. */
    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count >= 0 else { return nil }
        if count == 0 { return "" }
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }

    /// Android's fixed workspace global-text-settings identifier as SQLite uppercase hex.
    private static let workspaceGlobalSettingsIdentifierHex =
        "00000000000000000000000000000001"

    /// Android's fixed global-reading-progress identifier as SQLite uppercase hex.
    private static let progressSettingsIdentifierHex =
        "B2000000000000000000000000000001"

    /// Exact historical migration defaults that Room accepts as equivalent to no entity default.
    private static let defaultAbsentEquivalentValues: [String: Set<String>] = [
        "PageManager.jsState": ["t:NULL"],
        "GlobalAiSettings.hiddenBuiltInPrompts": ["t:''"],
        "GlobalAiSettings.commentaryDeselected": ["t:''"],
        "GlobalAiSettings.hiddenBuiltInCategories": ["t:''"],
        "GlobalAiSettings.favoritePrompts": ["t:''"],
        "LlmProviderConfig.endpoint": ["t:NULL"],
        "LlmProviderConfig.apiFormat": ["t:NULL"],
        "LlmRawLogRecord.promptId": ["t:NULL"],
        "LlmRawLogRecord.promptName": ["t:''"],
        "LlmRawLogRecord.promptDescription": ["t:NULL"],
        "LlmRawLogRecord.configuredModelId": ["t:NULL"],
        "LlmRawLogRecord.modelName": ["t:''"],
        "LlmRawLogRecord.providerType": ["t:''"],
        "LlmRawLogRecord.timestamp": ["t:0"],
        "LlmRawLogRecord.totalInputTokens": ["t:0"],
        "LlmRawLogRecord.totalOutputTokens": ["t:0"],
    ]

    /// Source-derived Room identities and canonical schema digests for supported workspace versions.
    private static let workspaceSourceAuthorities: [Int: RoomSourceAuthority] = [
        1: .init(identityHash: "4bf98e71faae835422c6aad319b3c3e6", schemaSHA256: "99057f0bb023884c8712d504809d48e4b681d62a3508aa9ba25af8f8a7dd8a4a"),
        2: .init(identityHash: "4bf98e71faae835422c6aad319b3c3e6", schemaSHA256: "99057f0bb023884c8712d504809d48e4b681d62a3508aa9ba25af8f8a7dd8a4a"),
        3: .init(identityHash: "039ea7732752b2ad4b4ef67168479e0d", schemaSHA256: "19580320104c86a1f6b1b3d0c5970c2c09a822ea554e10c9c86d4837e658f328"),
        4: .init(identityHash: "aa0999529b96f6f21ce256fb56ad141c", schemaSHA256: "ad1307178f9c2dcfdaee2fb8aeb0f9591dda2ab849f9fe0d47f876beca49f710"),
        5: .init(identityHash: "7f26c241e481c344934ea3ae3438ac07", schemaSHA256: "a31790e81760735f26378a5b824ecb3b09c1ecb8060f64b78617662899f24d29"),
        6: .init(identityHash: "5b39e74a3a669db14fbae9993786874a", schemaSHA256: "47ff392c743ad3cbda4ec2cfd205f1ef2b1e976aee7fb7f5991fd9ec00f0e95f"),
        7: .init(identityHash: "afd50ee932c9a4d70f9ff575c7040d33", schemaSHA256: "ada25595c2742a6860adeecfd9f52b65dc1cef313333245249ef6fb714231409"),
        8: .init(identityHash: "922c122774e82745f348cc48d2e7c56c", schemaSHA256: "5c6cd8c3eb2b9916e3b7b6c58064029c9ebdc1bb86bb2a3e04c2f52a13fd5bac"),
        9: .init(identityHash: "234b57ecb67dfb8b90e6d7cb3a1a410e", schemaSHA256: "3dbfec55a5310b1405407434e1fc71c7eb1f856fac456595324f5f36fbbca81b"),
        11: .init(identityHash: "3d65c61683ea9beae6300471d0974730", schemaSHA256: "7ae528dccd04fe38f354018273df1b45605abcad6d1b6e7d5b02b3c4743d2352"),
        13: .init(identityHash: "c6be5f20e8fd74fbe03460b0a07cc269", schemaSHA256: "caa9897ad471d7d25f7bb5e08292194bf3ac8a147383aba57f71fb9c16f8c147"),
        14: .init(identityHash: "aa085279aceeb81d2f9d28cbac5c893b", schemaSHA256: "b3ae02b4b9ac0ef4449e6f24a5ea110b1293b6beaf60747d1dc9dba17664b1c9"),
        15: .init(identityHash: "101cb14a44080439ff09292ec59653da", schemaSHA256: "325e6f893c0b7195f726438df421ccc0d2365170a1e3d742f37307f19be9ee92"),
        16: .init(identityHash: "e857e05550085d743220b08c55c4a6e6", schemaSHA256: "fe2a7769f2b36680a8ea6c20a020e0427288e5308b4f9c9121aec9f73498e329"),
        17: .init(identityHash: "9f399643fe9b4253922ecc9f4d7821ef", schemaSHA256: "d6ac95896e5b466922bde7636d9987f3cea9639a2ec10d3c386863b53871bb49"),
        18: .init(identityHash: "074d6db2eac52ddc84a3eb0275637df0", schemaSHA256: "aec0612a4332b10a56d0a4931ef87e3229bdfc6b752e63990f3461bbe60a9f28"),
        19: .init(identityHash: "2e9de163738a111f9798e98f2bc0c611", schemaSHA256: "e82a6f18f13bfd8c51fd62049fa8bf458c13125507ac8e10c90ea6a73f6a1754"),
        20: .init(identityHash: "3c0c765408e300c01f42a6e6f0798c4f", schemaSHA256: "110217750fe84d5397f99213b0c0e16df4a303001189910386c379d947328c44"),
        21: .init(identityHash: "414a9d8698c552d1a2de569dfba6bd55", schemaSHA256: "2aea30c90e6020e1f270298b36a5a9a9691d66e107d03980b3f21ac715fde79d"),
        22: .init(identityHash: "4a38e9989c3075a4382c417b41f0c4a6", schemaSHA256: "02bf74d0597649e20e8e687fb5ee5987048a0ed246022bb4832c70cddcacc904"),
        23: .init(identityHash: "7ba9fd73c4f856535b0ccf704686a631", schemaSHA256: "c9c377e975adaeb46be155fab7595019195c56bcf4c7994f7a9c7a54f517c6b2"),
        24: .init(identityHash: "59b8635a1eb5125e32e2789eedd02ab2", schemaSHA256: "033e08ef59637066efeeb2dec2dbbb5e6bb7700e41f48930ef099d421b96387a"),
    ]

    /// Exported or exactly derived Room identities and schema digests for AI settings generations.
    private static let aiSettingsSourceAuthorities: [Int: RoomSourceAuthority] = [
        1: .init(identityHash: "9acb139ce0350ae8d45abe791a34d5a6", schemaSHA256: "8317465a0a2d4ce6f303c1edb132bb363a81cbbf0eeada2179f0cc8c7e187152"),
        2: .init(identityHash: "959f762d0c6e5b46c0e2972d78da075b", schemaSHA256: "76437b02a23a03083fc290649609f03bf2eee7f51bb36a7f30aa4ff762af8594"),
        3: .init(identityHash: "8c4ba2db34ea934850985ef133401c84", schemaSHA256: "ebfa80f29e704e4213aad749dab68a43e809aa870d02c3ac1acd9d675a1b63f1"),
        4: .init(identityHash: "f2617a01e732d92655cc482da61ab59b", schemaSHA256: "79f66898cc6ab75b22a1469be7eedefca7cdf38ef45c4180561005be0d976174"),
        5: .init(identityHash: "79f56a8289168f6c523498ee304a77f7", schemaSHA256: "02f5f5b27e4dc1d04b90999833f4e3940aff25a4fb17dbd379d89f42c5728108"),
        6: .init(identityHash: "44771286d77cd66ed6bd171f22b85f48", schemaSHA256: "00372b77b0cf8d17fd1efc13cd965196981685688765665568f34cc63bfa473f"),
        7: .init(identityHash: "d7f999f5bfbe041800525de7ea079ced", schemaSHA256: "d3819c99432c935ce64086ebdd5459cfa70be782eda0dc6a664097ba9c056420"),
        8: .init(identityHash: "beaee5ab47416e0e33fe1b5648280860", schemaSHA256: "92c6f887f5e6d2242ece2fd1d08c09d9746c8616d7bdd7046791cc270249ca51"),
        9: .init(identityHash: "c72ce2565d4b73f61bfe567e97dfc07f", schemaSHA256: "f1f098dfc7889eeed4a7e8c7abf4e6c55891aa6ae95a7259c66e2049dba29165"),
        10: .init(identityHash: "4ac43f9df1b74a5aeb31ad2928ec31d9", schemaSHA256: "93297f28c42cf45ef5f8391740abbbea64d5e7f1ed49fda97ae2f1ec5b0bd632"),
        11: .init(identityHash: "ba66632b571047b0d26b028d68a09fd4", schemaSHA256: "d76f70c62584fb144a0b345d973d26603b24102c039f5c4bee023c6712146340"),
        12: .init(identityHash: "ce84fdcfd2da69ec7a3dbb0a48598c5b", schemaSHA256: "1fcdbebe0865065824e82c0a995c7c216bce2de8e483f90f6daec3746aa39149"),
        13: .init(identityHash: "7f78373ef09d4a39963a6d36fb1af07c", schemaSHA256: "8025bb17bd61933adaa64434a2479ea09579ae4494b576259d1c62bc2ed3c640"),
        14: .init(identityHash: "a58582f787ab00d65317d194b512d65d", schemaSHA256: "26a16acf0751f124dfe3315c966f2011803535dfce863b35bf991914df6bbe65"),
        15: .init(identityHash: "74162a4c9fee3d05e66dea913f3a8ecc", schemaSHA256: "fe2dd0d8b2ad5660576b195c937744fbc8e2f8fbbaf30751eabeb4f37a9ba8f5"),
        16: .init(identityHash: "44ee4b49c2dc4b97f4d47d5d05f9c106", schemaSHA256: "90bf4c6f2794dcc2271c8e2bbaf02ff5699f28237e24d1f3b96057b0042f2a32"),
        17: .init(identityHash: "db8c5d0eaebf6bb8660ad4bffdd5e634", schemaSHA256: "c90ed042f68c6b84ceae4d0d87449930c141e080dd5983419745337a1c86b15d"),
        18: .init(identityHash: "94c3097da2ba84700e7a99b45be93354", schemaSHA256: "472beb6e51dc3cf12877d9c014263ad2cdd5c40492c00d4d3697f01e77152175"),
        19: .init(identityHash: "9ebbedb251fc0892363a38ef2f3aa314", schemaSHA256: "bb099daf645b7909bff6c3f3cc1c5ec12c0b8a573d7f91e0f9a9431729266006"),
        20: .init(identityHash: "2fb949a3f2269f9ea913d71ec86e9a2c", schemaSHA256: "f777f05ca16b0982802cd559d935a43761e9d2ad8fda5d1302863f5df53f2cab"),
        21: .init(identityHash: "78dc0aed47cda9c269d076d4bff4353e", schemaSHA256: "1b8a59bcc8acb858597ab678088ed7e23cd33d6bc57809696e009e0b6973bdd0"),
        22: .init(identityHash: "cd5d541ba5aee11ecf5cf66642675607", schemaSHA256: "6893f3914273d7b6cb22147d0faf5f4b190df3c24abbe285b22a8b3129076093"),
        23: .init(identityHash: "c5b1820fd3dfb0390fa3122d2d6e139f", schemaSHA256: "43904463fc915222308d336b104b42f042178d53602eef65f6de5c196da0f7f9"),
    ]

    /// Shared Android Room sync metadata tables and indexes.
    private static let syncMetadataSQL = """
    CREATE TABLE IF NOT EXISTS `LogEntry` (`tableName` TEXT NOT NULL, `entityId1` BLOB NOT NULL, `entityId2` BLOB NOT NULL, `type` TEXT NOT NULL, `lastUpdated` INTEGER NOT NULL DEFAULT 0, `sourceDevice` TEXT NOT NULL, PRIMARY KEY(`tableName`, `entityId1`, `entityId2`));
    CREATE INDEX IF NOT EXISTS `index_LogEntry_lastUpdated` ON `LogEntry` (`lastUpdated`);
    CREATE INDEX IF NOT EXISTS `index_LogEntry_sourceDevice` ON `LogEntry` (`sourceDevice`);
    CREATE TABLE IF NOT EXISTS `SyncConfiguration` (`keyName` TEXT NOT NULL, `stringValue` TEXT, `longValue` INTEGER, `booleanValue` INTEGER, PRIMARY KEY(`keyName`));
    CREATE TABLE IF NOT EXISTS `SyncStatus` (`sourceDevice` TEXT NOT NULL, `patchNumber` INTEGER NOT NULL, `sizeBytes` INTEGER NOT NULL, `appliedDate` INTEGER NOT NULL, PRIMARY KEY(`sourceDevice`, `patchNumber`));
    """

    /// Complete Android `ReadingPlanDatabase` version 1 schema.
    private static let readingPlanSchemaSQL = """
    PRAGMA user_version = 1;
    CREATE TABLE IF NOT EXISTS `ReadingPlan` (`planCode` TEXT NOT NULL, `planStartDate` INTEGER NOT NULL, `planCurrentDay` INTEGER NOT NULL DEFAULT 1, `id` BLOB NOT NULL, PRIMARY KEY(`id`));
    CREATE UNIQUE INDEX IF NOT EXISTS `index_ReadingPlan_planCode` ON `ReadingPlan` (`planCode`);
    CREATE TABLE IF NOT EXISTS `ReadingPlanStatus` (`planCode` TEXT NOT NULL, `planDay` INTEGER NOT NULL, `readingStatus` TEXT NOT NULL, `id` BLOB NOT NULL, PRIMARY KEY(`id`));
    CREATE UNIQUE INDEX IF NOT EXISTS `index_ReadingPlanStatus_planCode_planDay` ON `ReadingPlanStatus` (`planCode`, `planDay`);
    \(syncMetadataSQL)
    CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
    INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, 'd465b2a4bc2012fff3a69d3eaff9b5ff');
    """

    /// Complete Android `ProgressDatabase` version 9 schema.
    private static let progressSchemaSQL = """
    PRAGMA user_version = 9;
    CREATE TABLE IF NOT EXISTS `MemorizedVerse` (`id` BLOB NOT NULL, `kjvOrdinal` INTEGER NOT NULL, `memorizedAt` INTEGER NOT NULL, PRIMARY KEY(`id`));
    CREATE UNIQUE INDEX IF NOT EXISTS `index_MemorizedVerse_kjvOrdinal` ON `MemorizedVerse` (`kjvOrdinal`);
    CREATE TABLE IF NOT EXISTS `ChapterReadHistory` (`id` BLOB NOT NULL, `kjvBookOrdinal` INTEGER NOT NULL, `chapter` INTEGER NOT NULL, `cycle` INTEGER NOT NULL, `readAt` INTEGER NOT NULL, `bookInitials` TEXT NOT NULL, `source` TEXT NOT NULL DEFAULT 'MANUAL', PRIMARY KEY(`id`));
    CREATE INDEX IF NOT EXISTS `index_ChapterReadHistory_kjvBookOrdinal_chapter_cycle` ON `ChapterReadHistory` (`kjvBookOrdinal`, `chapter`, `cycle`);
    CREATE TABLE IF NOT EXISTS `MemorizationTarget` (`id` BLOB NOT NULL, `kjvOrdinalStart` INTEGER NOT NULL, `kjvOrdinalEnd` INTEGER NOT NULL, `createdAt` INTEGER NOT NULL, PRIMARY KEY(`id`));
    CREATE TABLE IF NOT EXISTS `GlobalReadingProgressSettings` (`id` BLOB NOT NULL, `autoTrackReading` INTEGER NOT NULL DEFAULT 0, `autoMarkMemorized` INTEGER NOT NULL DEFAULT 1, `memorizeTypeFullWords` INTEGER NOT NULL DEFAULT 0, `memorizeWordVisibility` TEXT NOT NULL DEFAULT 'light', `memorizeErrorHeatmap` INTEGER NOT NULL DEFAULT 1, `memorizeScrambleHideUsed` INTEGER NOT NULL DEFAULT 0, `memorizeIncludeReference` INTEGER NOT NULL DEFAULT 1, `activeCycle` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`));
    \(syncMetadataSQL)
    CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
    INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, '76330d8367020840e56e6b92d921522a');
    """

    /// Complete Android `MyDocumentDatabase` version 4 schema.
    private static let myDocumentsSchemaSQL = """
    PRAGMA user_version = 4;
    CREATE TABLE IF NOT EXISTS `MyDocument` (`id` BLOB NOT NULL, `name` TEXT NOT NULL, `description` TEXT, `initials` TEXT NOT NULL, `orderNumber` INTEGER NOT NULL, `createdAt` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL, `sourcePromptId` BLOB, PRIMARY KEY(`id`));
    CREATE UNIQUE INDEX IF NOT EXISTS `index_MyDocument_initials` ON `MyDocument` (`initials`);
    CREATE TABLE IF NOT EXISTS `MyDocumentPage` (`id` BLOB NOT NULL, `documentId` BLOB NOT NULL, `title` TEXT NOT NULL, `pageKey` TEXT NOT NULL, `contentType` TEXT NOT NULL, `orderNumber` INTEGER NOT NULL, `createdAt` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL, `sourcePromptId` BLOB, `languageCode` TEXT, PRIMARY KEY(`id`), FOREIGN KEY(`documentId`) REFERENCES `MyDocument`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE INDEX IF NOT EXISTS `index_MyDocumentPage_documentId` ON `MyDocumentPage` (`documentId`);
    CREATE UNIQUE INDEX IF NOT EXISTS `index_MyDocumentPage_documentId_pageKey` ON `MyDocumentPage` (`documentId`, `pageKey`);
    CREATE TABLE IF NOT EXISTS `MyDocumentPageContent` (`pageId` BLOB NOT NULL, `content` TEXT NOT NULL, PRIMARY KEY(`pageId`), FOREIGN KEY(`pageId`) REFERENCES `MyDocumentPage`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE TABLE IF NOT EXISTS `AiPageCacheEntry` (`pageId` BLOB NOT NULL, `sourcePromptId` BLOB NOT NULL, `sourceContext` TEXT, `kjvOrdinalStart` INTEGER, `kjvOrdinalEnd` INTEGER, `contextHash` TEXT, `usedWriteTools` INTEGER NOT NULL, `sourceModelName` TEXT, `sourceBookInitials` TEXT, `sourceBookKey` TEXT, PRIMARY KEY(`pageId`), FOREIGN KEY(`pageId`) REFERENCES `MyDocumentPage`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE INDEX IF NOT EXISTS `index_AiPageCacheEntry_sourcePromptId_contextHash` ON `AiPageCacheEntry` (`sourcePromptId`, `contextHash`);
    CREATE INDEX IF NOT EXISTS `index_AiPageCacheEntry_sourcePromptId_kjvOrdinalStart_kjvOrdinalEnd` ON `AiPageCacheEntry` (`sourcePromptId`, `kjvOrdinalStart`, `kjvOrdinalEnd`);
    CREATE INDEX IF NOT EXISTS `index_AiPageCacheEntry_kjvOrdinalStart_kjvOrdinalEnd` ON `AiPageCacheEntry` (`kjvOrdinalStart`, `kjvOrdinalEnd`);
    CREATE INDEX IF NOT EXISTS `index_AiPageCacheEntry_sourceBookInitials_sourceBookKey` ON `AiPageCacheEntry` (`sourceBookInitials`, `sourceBookKey`);
    \(syncMetadataSQL)
    CREATE VIEW `MyDocumentPageWithContent` AS SELECT p.*, c.content FROM MyDocumentPage p LEFT OUTER JOIN MyDocumentPageContent c ON p.id = c.pageId;
    CREATE VIEW `AiCachedPageWithContent` AS SELECT c.pageId, c.sourcePromptId, c.sourceContext, c.kjvOrdinalStart, c.kjvOrdinalEnd, c.contextHash, c.usedWriteTools, c.sourceModelName, c.sourceBookInitials, c.sourceBookKey, p.title, p.pageKey, p.contentType, p.documentId, p.orderNumber, p.createdAt, p.updatedAt, p.languageCode, cnt.content FROM AiPageCacheEntry c INNER JOIN MyDocumentPage p ON c.pageId = p.id LEFT OUTER JOIN MyDocumentPageContent cnt ON p.id = cnt.pageId;
    CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
    INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, '3f0946602099d896c8d47129233c1794');
    """

    /// Complete Android `AiSettingsDatabase` version 23 schema.
    private static let aiSettingsSchemaSQL = """
    PRAGMA user_version = 23;
    CREATE TABLE IF NOT EXISTS `AgentPrompt` (`id` BLOB NOT NULL, `name` TEXT NOT NULL, `description` TEXT DEFAULT NULL, `promptTemplate` TEXT NOT NULL, `showIn` TEXT NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT 0, `createdAt` INTEGER NOT NULL DEFAULT 0, `strictContextMatching` INTEGER NOT NULL DEFAULT 1, `permissionMode` TEXT DEFAULT NULL, `allowedTools` TEXT DEFAULT NULL, `deniedTools` TEXT DEFAULT NULL, `configuredModelId` BLOB DEFAULT NULL, `editBeforeRun` INTEGER NOT NULL DEFAULT 0, `noDocumentCreation` INTEGER NOT NULL DEFAULT 0, `maxIterations` INTEGER DEFAULT NULL, `autoIncludeDocuments` INTEGER NOT NULL DEFAULT 0, `autoIncludeCommentaries` INTEGER NOT NULL DEFAULT 0, `bibleOnly` INTEGER NOT NULL DEFAULT 0, `isTextTransformation` INTEGER NOT NULL DEFAULT 0, `categoryId` BLOB DEFAULT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`configuredModelId`) REFERENCES `LlmConfiguredModel`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL );
    CREATE INDEX IF NOT EXISTS `index_AgentPrompt_orderNumber` ON `AgentPrompt` (`orderNumber`);
    CREATE INDEX IF NOT EXISTS `index_AgentPrompt_createdAt` ON `AgentPrompt` (`createdAt`);
    CREATE INDEX IF NOT EXISTS `index_AgentPrompt_configuredModelId` ON `AgentPrompt` (`configuredModelId`);
    CREATE INDEX IF NOT EXISTS `index_AgentPrompt_categoryId` ON `AgentPrompt` (`categoryId`);
    CREATE TABLE IF NOT EXISTS `LlmProviderConfig` (`id` BLOB NOT NULL, `providerType` TEXT NOT NULL, `displayName` TEXT NOT NULL, `endpoint` TEXT, `apiFormat` TEXT, `orderNumber` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`));
    CREATE INDEX IF NOT EXISTS `index_LlmProviderConfig_orderNumber` ON `LlmProviderConfig` (`orderNumber`);
    CREATE TABLE IF NOT EXISTS `LlmConfiguredModel` (`id` BLOB NOT NULL, `providerConfigId` BLOB NOT NULL, `modelId` TEXT NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT 0, `inputPricePerMillion` REAL NOT NULL DEFAULT 0.0, `outputPricePerMillion` REAL NOT NULL DEFAULT 0.0, `cacheCreationPricePerMillion` REAL NOT NULL DEFAULT 0.0, `cacheReadPricePerMillion` REAL NOT NULL DEFAULT 0.0, PRIMARY KEY(`id`), FOREIGN KEY(`providerConfigId`) REFERENCES `LlmProviderConfig`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE INDEX IF NOT EXISTS `index_LlmConfiguredModel_providerConfigId` ON `LlmConfiguredModel` (`providerConfigId`);
    CREATE UNIQUE INDEX IF NOT EXISTS `index_LlmConfiguredModel_providerConfigId_modelId` ON `LlmConfiguredModel` (`providerConfigId`, `modelId`);
    CREATE TABLE IF NOT EXISTS `GlobalAiSettings` (`id` BLOB NOT NULL, `agentPermissionMode` TEXT DEFAULT NULL, `permanentlyAllowedTools` TEXT DEFAULT NULL, `permanentlyDeniedTools` TEXT DEFAULT NULL, `aiExcludedDocuments` TEXT NOT NULL, `commentaryMaxResponseTokens` INTEGER NOT NULL DEFAULT 15000, `hiddenBuiltInPrompts` TEXT NOT NULL, `maxIterations` INTEGER NOT NULL DEFAULT 10, `commentaryDeselected` TEXT NOT NULL, `defaultModelId` BLOB DEFAULT NULL, `aiLanguage` TEXT DEFAULT NULL, `askModelBeforeRun` INTEGER NOT NULL DEFAULT 0, `aiDisclaimerAccepted` INTEGER NOT NULL DEFAULT 0, `hiddenBuiltInCategories` TEXT NOT NULL, `customAgentSystemPrompt` TEXT DEFAULT NULL, `customTextTransformationSystemPrompt` TEXT DEFAULT NULL, `favoritePrompts` TEXT NOT NULL, `rawLogRetentionDays` INTEGER DEFAULT 30, `autoHideAgentLogOnCompletion` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`));
    CREATE TABLE IF NOT EXISTS `LlmUsageRecord` (`id` BLOB NOT NULL, `configuredModelId` BLOB NOT NULL, `deviceId` TEXT NOT NULL, `inputTokens` INTEGER NOT NULL DEFAULT 0, `outputTokens` INTEGER NOT NULL DEFAULT 0, `cacheCreationTokens` INTEGER NOT NULL DEFAULT 0, `cacheReadTokens` INTEGER NOT NULL DEFAULT 0, `estimatedCostUsd` REAL NOT NULL DEFAULT 0.0, PRIMARY KEY(`id`));
    CREATE INDEX IF NOT EXISTS `index_LlmUsageRecord_configuredModelId` ON `LlmUsageRecord` (`configuredModelId`);
    CREATE UNIQUE INDEX IF NOT EXISTS `index_LlmUsageRecord_configuredModelId_deviceId` ON `LlmUsageRecord` (`configuredModelId`, `deviceId`);
    CREATE TABLE IF NOT EXISTS `LlmRawLogRecord` (`id` BLOB NOT NULL, `promptId` BLOB, `promptName` TEXT NOT NULL, `promptDescription` TEXT, `configuredModelId` BLOB, `modelName` TEXT NOT NULL, `providerType` TEXT NOT NULL, `timestamp` INTEGER NOT NULL, `totalInputTokens` INTEGER NOT NULL, `totalOutputTokens` INTEGER NOT NULL, `estimatedCostUsd` REAL NOT NULL DEFAULT 0.0, `logData` BLOB NOT NULL, `iterationCount` INTEGER NOT NULL DEFAULT 0, `wasError` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`));
    CREATE INDEX IF NOT EXISTS `index_LlmRawLogRecord_timestamp` ON `LlmRawLogRecord` (`timestamp`);
    CREATE INDEX IF NOT EXISTS `index_LlmRawLogRecord_promptId` ON `LlmRawLogRecord` (`promptId`);
    CREATE INDEX IF NOT EXISTS `index_LlmRawLogRecord_configuredModelId` ON `LlmRawLogRecord` (`configuredModelId`);
    CREATE TABLE IF NOT EXISTS `PromptCategory` (`id` BLOB NOT NULL, `name` TEXT NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT 0, `hidden` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`));
    CREATE TABLE IF NOT EXISTS `BuiltinPromptOverride` (`id` BLOB NOT NULL, `configuredModelId` BLOB DEFAULT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`configuredModelId`) REFERENCES `LlmConfiguredModel`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL );
    CREATE INDEX IF NOT EXISTS `index_BuiltinPromptOverride_configuredModelId` ON `BuiltinPromptOverride` (`configuredModelId`);
    \(syncMetadataSQL)
    CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
    INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, 'c5b1820fd3dfb0390fa3122d2d6e139f');
    """

    /// Complete Android `WorkspaceDatabase` version 24 schema.
    private static let workspaceSchemaSQL = """
    PRAGMA user_version = 24;
    CREATE TABLE IF NOT EXISTS `Workspace` (`name` TEXT NOT NULL, `contentsText` TEXT, `id` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT 0, `unPinnedWeight` REAL DEFAULT NULL, `maximizedWindowId` BLOB, `primaryTargetLinksWindowId` BLOB DEFAULT NULL, `text_display_settings_strongsMode` INTEGER DEFAULT NULL, `text_display_settings_showMorphology` INTEGER DEFAULT NULL, `text_display_settings_showFootNotes` INTEGER DEFAULT NULL, `text_display_settings_showFootNotesInline` INTEGER DEFAULT NULL, `text_display_settings_expandXrefs` INTEGER DEFAULT NULL, `text_display_settings_showXrefs` INTEGER DEFAULT NULL, `text_display_settings_showRedLetters` INTEGER DEFAULT NULL, `text_display_settings_showSectionTitles` INTEGER DEFAULT NULL, `text_display_settings_showVerseNumbers` INTEGER DEFAULT NULL, `text_display_settings_showVersePerLine` INTEGER DEFAULT NULL, `text_display_settings_showBookmarks` INTEGER DEFAULT NULL, `text_display_settings_showMyNotes` INTEGER DEFAULT NULL, `text_display_settings_justifyText` INTEGER DEFAULT NULL, `text_display_settings_hyphenation` INTEGER DEFAULT NULL, `text_display_settings_topMargin` INTEGER DEFAULT NULL, `text_display_settings_fontSize` INTEGER DEFAULT NULL, `text_display_settings_fontFamily` TEXT DEFAULT NULL, `text_display_settings_lineSpacing` INTEGER DEFAULT NULL, `text_display_settings_bookmarksHideLabels` TEXT DEFAULT NULL, `text_display_settings_showPageNumber` INTEGER DEFAULT NULL, `text_display_settings_infiniteScroll` INTEGER DEFAULT NULL, `text_display_settings_nonStrongsWordItalic` INTEGER DEFAULT NULL, `text_display_settings_showMarkAsReadButton` INTEGER DEFAULT NULL, `text_display_settings_showTitleScrollButton` INTEGER DEFAULT NULL, `text_display_settings_showMemorizationIndicators` INTEGER DEFAULT NULL, `text_display_settings_autoTrackReading` INTEGER DEFAULT NULL, `text_display_settings_showAiDocMarkers` INTEGER DEFAULT NULL, `text_display_settings_pageScrollAmount` INTEGER DEFAULT NULL, `text_display_settings_scrollHelperLines` INTEGER DEFAULT NULL, `text_display_settings_scrollHelperLineStyle` INTEGER DEFAULT NULL, `text_display_settings_showPageButtons` INTEGER DEFAULT NULL, `text_display_settings_showOrdinals` INTEGER DEFAULT NULL, `text_display_settings_showReadingProgress` INTEGER DEFAULT NULL, `text_display_settings_margin_size_marginLeft` INTEGER DEFAULT NULL, `text_display_settings_margin_size_marginRight` INTEGER DEFAULT NULL, `text_display_settings_margin_size_maxWidth` INTEGER DEFAULT NULL, `text_display_settings_colors_dayTextColor` INTEGER DEFAULT NULL, `text_display_settings_colors_dayBackground` INTEGER DEFAULT NULL, `text_display_settings_colors_dayNoise` INTEGER DEFAULT NULL, `text_display_settings_colors_nightTextColor` INTEGER DEFAULT NULL, `text_display_settings_colors_nightBackground` INTEGER DEFAULT NULL, `text_display_settings_colors_nightNoise` INTEGER DEFAULT NULL, `text_display_settings_colors_dayBackgroundImage` TEXT DEFAULT NULL, `text_display_settings_colors_nightBackgroundImage` TEXT DEFAULT NULL, `text_display_settings_colors_dayBackgroundImageOpacity` INTEGER DEFAULT NULL, `text_display_settings_colors_nightBackgroundImageOpacity` INTEGER DEFAULT NULL, `workspace_settings_enableTiltToScroll` INTEGER DEFAULT 0, `workspace_settings_enableReverseSplitMode` INTEGER DEFAULT 0, `workspace_settings_autoPin` INTEGER DEFAULT 1, `workspace_settings_speakSettings` TEXT DEFAULT NULL, `workspace_settings_recentLabels` TEXT DEFAULT NULL, `workspace_settings_autoAssignLabels` TEXT DEFAULT NULL, `workspace_settings_autoAssignPrimaryLabel` BLOB DEFAULT NULL, `workspace_settings_studyPadCursors` TEXT DEFAULT NULL, `workspace_settings_hideCompareDocuments` TEXT DEFAULT NULL, `workspace_settings_limitAmbiguousModalSize` INTEGER DEFAULT 0, `workspace_settings_workspaceColor` INTEGER DEFAULT NULL, `workspace_settings_restoreButtonsVisible` INTEGER DEFAULT 1, PRIMARY KEY(`id`));
    CREATE TABLE IF NOT EXISTS `Window` (`workspaceId` BLOB NOT NULL, `isSynchronized` INTEGER NOT NULL, `isPinMode` INTEGER NOT NULL, `isLinksWindow` INTEGER NOT NULL, `id` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL, `targetLinksWindowId` BLOB DEFAULT NULL, `syncGroup` INTEGER NOT NULL DEFAULT 0, `window_layout_state` TEXT NOT NULL, `window_layout_weight` REAL NOT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`workspaceId`) REFERENCES `Workspace`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE INDEX IF NOT EXISTS `index_Window_workspaceId` ON `Window` (`workspaceId`);
    CREATE TABLE IF NOT EXISTS `HistoryItem` (`windowId` BLOB NOT NULL, `createdAt` INTEGER NOT NULL, `document` TEXT NOT NULL, `key` TEXT NOT NULL, `anchorOrdinal` INTEGER DEFAULT NULL, `id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, FOREIGN KEY(`windowId`) REFERENCES `Window`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE INDEX IF NOT EXISTS `index_HistoryItem_windowId` ON `HistoryItem` (`windowId`);
    CREATE TABLE IF NOT EXISTS `PageManager` (`windowId` BLOB NOT NULL, `currentCategoryName` TEXT NOT NULL, `jsState` TEXT, `bible_document` TEXT, `bible_verse_versification` TEXT NOT NULL, `bible_verse_bibleBook` INTEGER NOT NULL, `bible_verse_chapterNo` INTEGER NOT NULL, `bible_verse_verseNo` INTEGER NOT NULL, `commentary_document` TEXT, `commentary_anchorOrdinal` INTEGER DEFAULT NULL, `commentary_sourceBookAndKey` TEXT DEFAULT NULL, `dictionary_document` TEXT, `dictionary_key` TEXT, `dictionary_anchorOrdinal` INTEGER DEFAULT NULL, `general_book_document` TEXT, `general_book_key` TEXT, `general_book_anchorOrdinal` INTEGER DEFAULT NULL, `map_document` TEXT, `map_key` TEXT, `map_anchorOrdinal` INTEGER DEFAULT NULL, `text_display_settings_strongsMode` INTEGER DEFAULT NULL, `text_display_settings_showMorphology` INTEGER DEFAULT NULL, `text_display_settings_showFootNotes` INTEGER DEFAULT NULL, `text_display_settings_showFootNotesInline` INTEGER DEFAULT NULL, `text_display_settings_expandXrefs` INTEGER DEFAULT NULL, `text_display_settings_showXrefs` INTEGER DEFAULT NULL, `text_display_settings_showRedLetters` INTEGER DEFAULT NULL, `text_display_settings_showSectionTitles` INTEGER DEFAULT NULL, `text_display_settings_showVerseNumbers` INTEGER DEFAULT NULL, `text_display_settings_showVersePerLine` INTEGER DEFAULT NULL, `text_display_settings_showBookmarks` INTEGER DEFAULT NULL, `text_display_settings_showMyNotes` INTEGER DEFAULT NULL, `text_display_settings_justifyText` INTEGER DEFAULT NULL, `text_display_settings_hyphenation` INTEGER DEFAULT NULL, `text_display_settings_topMargin` INTEGER DEFAULT NULL, `text_display_settings_fontSize` INTEGER DEFAULT NULL, `text_display_settings_fontFamily` TEXT DEFAULT NULL, `text_display_settings_lineSpacing` INTEGER DEFAULT NULL, `text_display_settings_bookmarksHideLabels` TEXT DEFAULT NULL, `text_display_settings_showPageNumber` INTEGER DEFAULT NULL, `text_display_settings_infiniteScroll` INTEGER DEFAULT NULL, `text_display_settings_nonStrongsWordItalic` INTEGER DEFAULT NULL, `text_display_settings_showMarkAsReadButton` INTEGER DEFAULT NULL, `text_display_settings_showTitleScrollButton` INTEGER DEFAULT NULL, `text_display_settings_showMemorizationIndicators` INTEGER DEFAULT NULL, `text_display_settings_autoTrackReading` INTEGER DEFAULT NULL, `text_display_settings_showAiDocMarkers` INTEGER DEFAULT NULL, `text_display_settings_pageScrollAmount` INTEGER DEFAULT NULL, `text_display_settings_scrollHelperLines` INTEGER DEFAULT NULL, `text_display_settings_scrollHelperLineStyle` INTEGER DEFAULT NULL, `text_display_settings_showPageButtons` INTEGER DEFAULT NULL, `text_display_settings_showOrdinals` INTEGER DEFAULT NULL, `text_display_settings_showReadingProgress` INTEGER DEFAULT NULL, `text_display_settings_margin_size_marginLeft` INTEGER DEFAULT NULL, `text_display_settings_margin_size_marginRight` INTEGER DEFAULT NULL, `text_display_settings_margin_size_maxWidth` INTEGER DEFAULT NULL, `text_display_settings_colors_dayTextColor` INTEGER DEFAULT NULL, `text_display_settings_colors_dayBackground` INTEGER DEFAULT NULL, `text_display_settings_colors_dayNoise` INTEGER DEFAULT NULL, `text_display_settings_colors_nightTextColor` INTEGER DEFAULT NULL, `text_display_settings_colors_nightBackground` INTEGER DEFAULT NULL, `text_display_settings_colors_nightNoise` INTEGER DEFAULT NULL, `text_display_settings_colors_dayBackgroundImage` TEXT DEFAULT NULL, `text_display_settings_colors_nightBackgroundImage` TEXT DEFAULT NULL, `text_display_settings_colors_dayBackgroundImageOpacity` INTEGER DEFAULT NULL, `text_display_settings_colors_nightBackgroundImageOpacity` INTEGER DEFAULT NULL, PRIMARY KEY(`windowId`), FOREIGN KEY(`windowId`) REFERENCES `Window`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE UNIQUE INDEX IF NOT EXISTS `index_PageManager_windowId` ON `PageManager` (`windowId`);
    CREATE TABLE IF NOT EXISTS `WorkspaceLabelOverride` (`workspaceId` BLOB NOT NULL, `labelId` BLOB NOT NULL, `overrideMode` INTEGER DEFAULT NULL, PRIMARY KEY(`workspaceId`, `labelId`), FOREIGN KEY(`workspaceId`) REFERENCES `Workspace`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
    CREATE INDEX IF NOT EXISTS `index_WorkspaceLabelOverride_workspaceId` ON `WorkspaceLabelOverride` (`workspaceId`);
    CREATE TABLE IF NOT EXISTS `GlobalTextDisplaySettings` (`id` BLOB NOT NULL, `text_display_settings_strongsMode` INTEGER DEFAULT NULL, `text_display_settings_showMorphology` INTEGER DEFAULT NULL, `text_display_settings_showFootNotes` INTEGER DEFAULT NULL, `text_display_settings_showFootNotesInline` INTEGER DEFAULT NULL, `text_display_settings_expandXrefs` INTEGER DEFAULT NULL, `text_display_settings_showXrefs` INTEGER DEFAULT NULL, `text_display_settings_showRedLetters` INTEGER DEFAULT NULL, `text_display_settings_showSectionTitles` INTEGER DEFAULT NULL, `text_display_settings_showVerseNumbers` INTEGER DEFAULT NULL, `text_display_settings_showVersePerLine` INTEGER DEFAULT NULL, `text_display_settings_showBookmarks` INTEGER DEFAULT NULL, `text_display_settings_showMyNotes` INTEGER DEFAULT NULL, `text_display_settings_justifyText` INTEGER DEFAULT NULL, `text_display_settings_hyphenation` INTEGER DEFAULT NULL, `text_display_settings_topMargin` INTEGER DEFAULT NULL, `text_display_settings_fontSize` INTEGER DEFAULT NULL, `text_display_settings_fontFamily` TEXT DEFAULT NULL, `text_display_settings_lineSpacing` INTEGER DEFAULT NULL, `text_display_settings_bookmarksHideLabels` TEXT DEFAULT NULL, `text_display_settings_showPageNumber` INTEGER DEFAULT NULL, `text_display_settings_infiniteScroll` INTEGER DEFAULT NULL, `text_display_settings_nonStrongsWordItalic` INTEGER DEFAULT NULL, `text_display_settings_showMarkAsReadButton` INTEGER DEFAULT NULL, `text_display_settings_showTitleScrollButton` INTEGER DEFAULT NULL, `text_display_settings_showMemorizationIndicators` INTEGER DEFAULT NULL, `text_display_settings_autoTrackReading` INTEGER DEFAULT NULL, `text_display_settings_showAiDocMarkers` INTEGER DEFAULT NULL, `text_display_settings_pageScrollAmount` INTEGER DEFAULT NULL, `text_display_settings_scrollHelperLines` INTEGER DEFAULT NULL, `text_display_settings_scrollHelperLineStyle` INTEGER DEFAULT NULL, `text_display_settings_showPageButtons` INTEGER DEFAULT NULL, `text_display_settings_showOrdinals` INTEGER DEFAULT NULL, `text_display_settings_showReadingProgress` INTEGER DEFAULT NULL, `text_display_settings_margin_size_marginLeft` INTEGER DEFAULT NULL, `text_display_settings_margin_size_marginRight` INTEGER DEFAULT NULL, `text_display_settings_margin_size_maxWidth` INTEGER DEFAULT NULL, `text_display_settings_colors_dayTextColor` INTEGER DEFAULT NULL, `text_display_settings_colors_dayBackground` INTEGER DEFAULT NULL, `text_display_settings_colors_dayNoise` INTEGER DEFAULT NULL, `text_display_settings_colors_nightTextColor` INTEGER DEFAULT NULL, `text_display_settings_colors_nightBackground` INTEGER DEFAULT NULL, `text_display_settings_colors_nightNoise` INTEGER DEFAULT NULL, `text_display_settings_colors_dayBackgroundImage` TEXT DEFAULT NULL, `text_display_settings_colors_nightBackgroundImage` TEXT DEFAULT NULL, `text_display_settings_colors_dayBackgroundImageOpacity` INTEGER DEFAULT NULL, `text_display_settings_colors_nightBackgroundImageOpacity` INTEGER DEFAULT NULL, PRIMARY KEY(`id`));
    \(syncMetadataSQL)
    CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
    INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, '59b8635a1eb5125e32e2789eedd02ab2');
    """
}

/** Length-delimited deterministic serialization for one SQLite metadata row. */
private extension Array where Element == String {
    var serialized: String {
        map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/** Length-delimited deterministic serialization for ordered SQLite metadata rows. */
private extension Array where Element == [String] {
    var serialized: String {
        map(\.serialized).map { "\($0.utf8.count):\($0)" }.joined()
    }
}
