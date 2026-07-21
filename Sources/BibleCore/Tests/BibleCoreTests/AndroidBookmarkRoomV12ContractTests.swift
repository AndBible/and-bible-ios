import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

/**
 Android Room-v12 bookmark schema, row-fidelity, patch-apply, and conflict contract tests.
 */
final class AndroidBookmarkRoomV12ContractTests: XCTestCase {
    private let fixtureLabelID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let fixtureBibleID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private let fixtureGenericID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let fixtureStudyPadID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let fixtureStudyPadWithoutTextID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
    private let biblePromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!
    private let bibleNotePromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000002")!
    private let genericPromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000003")!
    private let genericNotePromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000004")!
    private let studyPadPromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000005")!
    private let studyPadWithoutTextPromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000006")!

    /**
     Verifies the checked-in Android-derived fixture carries the exact high-risk v12 row semantics.

     The assertion is intentionally structural: SQLite reports version, identity, null storage,
     provenance BLOBs, and secondary-key storage directly instead of matching SQL source text.
     */
    func testAndroidRoomV12FixtureCarriesStrictRows() throws {
        let fixtureURL = try makeAndroidBookmarkRoomV12Fixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let contract = try androidBookmarkSQLiteSchemaContract(at: fixtureURL)
        XCTAssertEqual(contract.userVersion, 12)
        XCTAssertEqual(contract.roomIdentityHash, "0492abbf5bd840e0fcc87744a8af6f11")
        XCTAssertEqual(
            contract.views,
            ["BibleBookmarkWithNotes", "GenericBookmarkWithNotes", "StudyPadTextEntryWithText"]
        )
        XCTAssertTrue(contract.indexes.contains { $0.name == "index_GenericBookmark_bookInitials_key" })
        XCTAssertTrue(contract.indexes.contains { $0.name == "index_LogEntry_lastUpdated" })
        XCTAssertTrue(contract.foreignKeys.contains {
            $0.tableName == "StudyPadTextEntryText" &&
                $0.referencedTable == "StudyPadTextEntry" &&
                $0.onDelete == "CASCADE"
        })

        try withAndroidBookmarkSQLiteDatabase(at: fixtureURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT typeof(ordinalStart) FROM GenericBookmark WHERE id = X'30000000000000000000000000000001'",
                    in: database
                ),
                "null"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM BibleBookmark WHERE id = X'20000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000001"
            )
            XCTAssertEqual(try androidBookmarkSQLiteInt("SELECT COUNT(*) FROM LogEntry WHERE entityId2 IS NULL", in: database), 0)
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT COUNT(*) FROM LogEntry WHERE tableName <> 'GenericBookmarkToLabel' AND (typeof(entityId2) <> 'text' OR length(entityId2) <> 0)",
                    in: database
                ),
                0
            )
        }

        let snapshot = try RemoteSyncBookmarkRestoreService().readSnapshot(from: fixtureURL)
        let bible = try XCTUnwrap(snapshot.bibleBookmarks.first { $0.id == fixtureBibleID })
        XCTAssertEqual(bible.sourcePromptId, biblePromptID)
        XCTAssertEqual(bible.notesSourcePromptId, bibleNotePromptID)
        let generic = try XCTUnwrap(snapshot.genericBookmarks.first { $0.id == fixtureGenericID })
        XCTAssertNil(generic.ordinalStart)
        XCTAssertNil(generic.ordinalEnd)
        XCTAssertEqual(generic.sourcePromptId, genericPromptID)
        XCTAssertEqual(generic.notesSourcePromptId, genericNotePromptID)
        XCTAssertEqual(snapshot.studyPadEntries.first { $0.id == fixtureStudyPadID }?.sourcePromptId, studyPadPromptID)
        let studyPadWithoutText = try XCTUnwrap(
            snapshot.studyPadEntries.first { $0.id == fixtureStudyPadWithoutTextID }
        )
        XCTAssertEqual(studyPadWithoutText.sourcePromptId, studyPadWithoutTextPromptID)
        XCTAssertNil(studyPadWithoutText.text)
        XCTAssertTrue(snapshot.logEntries.allSatisfy { entry in
            guard AndroidBookmarkDatabaseContract.singleIdentifierTables.contains(entry.tableName) else { return true }
            return entry.entityID2 == .text("")
        })
    }

    /**
     Verifies a legacy iOS bookmark baseline using a `NULL` secondary key is migrated as soon as
     initial-backup metadata is accepted, before any later upload or patch replay occurs.
     */
    func testBookmarkMetadataRestoreMigratesLegacyNullSecondaryKey() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let legacyEntry = RemoteSyncLogEntry(
            tableName: "GenericBookmark",
            entityID1: .blob(bookmarkUUIDBlob(fixtureGenericID)),
            entityID2: .null(),
            type: .upsert,
            lastUpdated: 100,
            sourceDevice: "legacy-ios"
        )

        _ = RemoteSyncInitialBackupMetadataRestoreService().replaceLocalMetadata(
            from: RemoteSyncAndroidSyncMetadataSnapshot(logEntries: [legacyEntry], patchStatuses: []),
            category: .bookmarks,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .bookmarks).first?.entityID2,
            .text("")
        )
    }

    /**
     Verifies restore canonicalizes Android's AI special label and rejects duplicate aliases before
     mutating SwiftData.
     */
    func testRestoreCanonicalizesAndDeduplicatesAIFixedLabel() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let remoteAIID = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        let service = RemoteSyncBookmarkRestoreService()

        _ = try service.replaceLocalBookmarks(
            from: bookmarkSnapshot(labels: [labelRow(id: remoteAIID, name: "__AI_LABEL__")]),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let aiLabels = try modelContext.fetch(FetchDescriptor<Label>()).filter { $0.name == "__AI_LABEL__" }
        XCTAssertEqual(aiLabels.map(\.id), [AndroidBookmarkDatabaseContract.aiLabelID])
        XCTAssertTrue(
            RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore).allAliases().contains {
                $0.remoteLabelID == remoteAIID && $0.localLabelID == AndroidBookmarkDatabaseContract.aiLabelID
            }
        )
        let outbound = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(
            outbound.labelRowsByKey.values.first { $0.name == "__AI_LABEL__" }?.id,
            AndroidBookmarkDatabaseContract.aiLabelID
        )

        let duplicateAIID = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        XCTAssertThrowsError(
            try service.replaceLocalBookmarks(
                from: bookmarkSnapshot(
                    labels: [
                        labelRow(id: remoteAIID, name: "__AI_LABEL__"),
                        labelRow(id: duplicateAIID, name: "__AI_LABEL__"),
                    ]
                ),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncBookmarkRestoreError,
                .duplicateSystemLabels(["__AI_LABEL__"])
            )
        }
    }

    /**
     Restores Android rows, exports them again, generates an iOS patch, and applies that patch to a
     strict populated Room-v12 fixture with foreign-key checks enabled.

     This protects source-prompt round trips, nullable generic ordinals, exact schema metadata,
     Android empty secondary keys, and missing-fingerprint upload behavior in one end-to-end path.
     */
    func testIOSPatchMatchesAndAppliesToAndroidRoomV12Fixture() async throws {
        let sourceFixtureURL = try makeAndroidBookmarkRoomV12Fixture()
        let applyFixtureURL = try makeAndroidBookmarkRoomV12Fixture()
        defer {
            try? FileManager.default.removeItem(at: sourceFixtureURL)
            try? FileManager.default.removeItem(at: applyFixtureURL)
        }

        let restoreService = RemoteSyncBookmarkRestoreService()
        let sourceSnapshot = try restoreService.readSnapshot(from: sourceFixtureURL)
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        _ = try restoreService.replaceLocalBookmarks(
            from: sourceSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let retainedLogEntries = sourceSnapshot.logEntries.map { entry in
            guard entry.tableName == "GenericBookmark" else { return entry }
            return RemoteSyncLogEntry(
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: .null(),
                type: entry.type,
                lastUpdated: entry.lastUpdated,
                sourceDevice: entry.sourceDevice
            )
        }
        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            retainedLogEntries,
            for: .bookmarks
        )

        let exportedURL = try RemoteSyncInitialBackupUploadService.buildAndroidDatabaseBackupDatabase(
            for: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: 12
        )
        defer { try? FileManager.default.removeItem(at: exportedURL) }
        let exportedSnapshot = try restoreService.readSnapshot(from: exportedURL)
        let exportedBible = try XCTUnwrap(exportedSnapshot.bibleBookmarks.first { $0.id == fixtureBibleID })
        XCTAssertEqual(exportedBible.sourcePromptId, biblePromptID)
        XCTAssertEqual(exportedBible.notesSourcePromptId, bibleNotePromptID)
        let exportedGeneric = try XCTUnwrap(exportedSnapshot.genericBookmarks.first { $0.id == fixtureGenericID })
        XCTAssertNil(exportedGeneric.ordinalStart)
        XCTAssertNil(exportedGeneric.ordinalEnd)
        XCTAssertEqual(exportedGeneric.sourcePromptId, genericPromptID)
        XCTAssertEqual(exportedGeneric.notesSourcePromptId, genericNotePromptID)
        XCTAssertEqual(exportedSnapshot.studyPadEntries.first { $0.id == fixtureStudyPadID }?.sourcePromptId, studyPadPromptID)
        XCTAssertNil(
            exportedSnapshot.studyPadEntries.first { $0.id == fixtureStudyPadWithoutTextID }?.text
        )
        XCTAssertEqual(exportedSnapshot.logEntries.count, sourceSnapshot.logEntries.count)
        try withAndroidBookmarkSQLiteDatabase(at: exportedURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try androidBookmarkSQLiteInt("SELECT COUNT(*) FROM LogEntry WHERE entityId2 IS NULL", in: database),
                0
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT typeof(entityId2) || ':' || length(entityId2) FROM LogEntry WHERE tableName = 'GenericBookmark'",
                    in: database
                ),
                "text:0"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT lastUpdated FROM LogEntry WHERE tableName = 'StudyPadTextEntryText' AND type = 'DELETE'",
                    in: database
                ),
                1_700_000_004_500
            )
        }
        let restoredStudyPadWithoutText = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>()).first {
                $0.id == fixtureStudyPadWithoutTextID
            }
        )
        XCTAssertNil(restoredStudyPadWithoutText.textEntry)

        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(bookmarkUploadResult(patchNumber: 1, timestamp: 2_000))
        let uploadService = RemoteSyncBookmarkPatchUploadService(adapter: adapter, nowProvider: { 2_000 })
        let report = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/sync/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNotNil(report, "A missing fingerprint baseline must be upload-needed")

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let firstUpload = try XCTUnwrap(uploadedFiles.first)
        let patchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-bookmark-room-v12-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: patchURL) }
        try gunzipTestData(firstUpload.data).write(to: patchURL, options: .atomic)

        XCTAssertEqual(
            try androidBookmarkSQLiteSchemaContract(at: patchURL),
            try androidBookmarkSQLiteSchemaContract(at: sourceFixtureURL)
        )
        try assertIOSPatchRows(at: patchURL)
        try applyIOSBookmarkPatch(patchURL, toAndroidFixture: applyFixtureURL)
        try assertAppliedRows(at: applyFixtureURL)

        let generic = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<GenericBookmark>()).first {
            $0.id == fixtureGenericID
        })
        generic.customIcon = "changed-after-baseline-loss"
        try modelContext.save()
        RemoteSyncRowFingerprintStore(settingsStore: settingsStore).removeFingerprint(
            for: .bookmarks,
            tableName: "GenericBookmark",
            entityID1: .blob(bookmarkUUIDBlob(fixtureGenericID)),
            entityID2: .text("")
        )
        await adapter.enqueueUploadResult(bookmarkUploadResult(patchNumber: 2, timestamp: 3_000))
        let secondUploadService = RemoteSyncBookmarkPatchUploadService(adapter: adapter, nowProvider: { 3_000 })
        let secondReport = try await secondUploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/sync/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(secondReport?.upsertedGenericBookmarkCount, 1)
        XCTAssertEqual(secondReport?.logEntryCount, 1)
    }

    /**
     Verifies manual import uses Android's strict incoming-log timestamp comparison, including
     equal timestamps and a newer local delete that must not be resurrected by an older backup.
     */
    func testManualImportMergeUsesAndroidLogTimestampSemantics() throws {
        let bookmarkID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        let sourcePromptID = UUID(uuidString: "a0000000-0000-0000-0000-000000000099")!
        let localRow = genericRow(id: bookmarkID, key: "local", sourcePromptID: nil, lastUpdated: 100)
        let importedRow = genericRow(id: bookmarkID, key: "imported", sourcePromptID: sourcePromptID, lastUpdated: 900)
        let localLog = bookmarkLog(id: bookmarkID, type: .upsert, timestamp: 200, secondary: .null())

        let olderImported = try AndroidBookmarkSnapshotMergeService().merge(
            local: bookmarkSnapshot(genericBookmarks: [localRow], logEntries: [localLog]),
            imported: bookmarkSnapshot(
                genericBookmarks: [importedRow],
                logEntries: [bookmarkLog(id: bookmarkID, type: .upsert, timestamp: 100)]
            )
        )
        XCTAssertEqual(olderImported.genericBookmarks.first?.key, "local")

        let newerImported = try AndroidBookmarkSnapshotMergeService().merge(
            local: bookmarkSnapshot(genericBookmarks: [localRow], logEntries: [localLog]),
            imported: bookmarkSnapshot(
                genericBookmarks: [importedRow],
                logEntries: [bookmarkLog(id: bookmarkID, type: .upsert, timestamp: 300)]
            )
        )
        XCTAssertEqual(newerImported.genericBookmarks.first?.key, "imported")
        XCTAssertNil(newerImported.genericBookmarks.first?.ordinalStart)
        XCTAssertEqual(newerImported.genericBookmarks.first?.sourcePromptId, sourcePromptID)

        let equalImported = try AndroidBookmarkSnapshotMergeService().merge(
            local: bookmarkSnapshot(genericBookmarks: [localRow], logEntries: [localLog]),
            imported: bookmarkSnapshot(
                genericBookmarks: [importedRow],
                logEntries: [bookmarkLog(id: bookmarkID, type: .upsert, timestamp: 200)]
            )
        )
        XCTAssertEqual(equalImported.genericBookmarks.first?.key, "local")

        let noResurrection = try AndroidBookmarkSnapshotMergeService().merge(
            local: bookmarkSnapshot(logEntries: [bookmarkLog(id: bookmarkID, type: .delete, timestamp: 400)]),
            imported: bookmarkSnapshot(
                genericBookmarks: [importedRow],
                logEntries: [bookmarkLog(id: bookmarkID, type: .upsert, timestamp: 300)]
            )
        )
        XCTAssertTrue(noResurrection.genericBookmarks.isEmpty)
    }

    /**
     Verifies accepted Android upsert metadata cannot silently discard a missing patch row.
     */
    func testManualImportMergeRejectsAcceptedLogWithoutRow() {
        let bookmarkID = UUID(uuidString: "50000000-0000-0000-0000-000000000002")!
        XCTAssertThrowsError(
            try AndroidBookmarkSnapshotMergeService().merge(
                local: bookmarkSnapshot(),
                imported: bookmarkSnapshot(
                    logEntries: [bookmarkLog(id: bookmarkID, type: .upsert, timestamp: 300)]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? AndroidBookmarkSnapshotMergeError,
                .missingUpsertRow(table: "GenericBookmark", entityID1: bookmarkID, entityID2: nil)
            )
        }
    }

    /**
     Verifies a newer Android deletion removes only the optional StudyPad text child and an older
     deletion cannot erase the newer local text.
     */
    func testManualImportMergePreservesStudyPadTextChildSemantics() throws {
        let entryID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
        let label = labelRow(id: fixtureLabelID, name: "Study")
        let localEntry = studyPadRow(id: entryID, labelID: fixtureLabelID, text: "local text")
        let importedEntry = studyPadRow(id: entryID, labelID: fixtureLabelID, text: nil)
        let localLog = studyPadTextLog(id: entryID, type: .upsert, timestamp: 200)

        let olderDelete = try AndroidBookmarkSnapshotMergeService().merge(
            local: bookmarkSnapshot(labels: [label], studyPadEntries: [localEntry], logEntries: [localLog]),
            imported: bookmarkSnapshot(
                labels: [label],
                studyPadEntries: [importedEntry],
                logEntries: [studyPadTextLog(id: entryID, type: .delete, timestamp: 100)]
            )
        )
        XCTAssertEqual(olderDelete.studyPadEntries.first?.text, "local text")

        let newerDelete = try AndroidBookmarkSnapshotMergeService().merge(
            local: bookmarkSnapshot(labels: [label], studyPadEntries: [localEntry], logEntries: [localLog]),
            imported: bookmarkSnapshot(
                labels: [label],
                studyPadEntries: [importedEntry],
                logEntries: [studyPadTextLog(id: entryID, type: .delete, timestamp: 300)]
            )
        )
        XCTAssertNil(newerDelete.studyPadEntries.first?.text)
    }

    private func assertIOSPatchRows(at patchURL: URL) throws {
        try withAndroidBookmarkSQLiteDatabase(at: patchURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(try androidBookmarkSQLiteInt("SELECT COUNT(*) FROM LogEntry WHERE entityId2 IS NULL", in: database), 0)
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT COUNT(*) FROM LogEntry WHERE tableName IN ('Label','BibleBookmark','BibleBookmarkNotes','GenericBookmark','GenericBookmarkNotes','StudyPadTextEntry','StudyPadTextEntryText') AND (typeof(entityId2) <> 'text' OR length(entityId2) <> 0)",
                    in: database
                ),
                0
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT typeof(ordinalStart) FROM GenericBookmark WHERE id = X'30000000000000000000000000000001'",
                    in: database
                ),
                "null"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT color FROM Label WHERE id = X'10000000000000000000000000000001'",
                    in: database
                ),
                -16_711_936
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM BibleBookmark WHERE id = X'20000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000001"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM BibleBookmarkNotes WHERE bookmarkId = X'20000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000002"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM GenericBookmark WHERE id = X'30000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000003"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM GenericBookmarkNotes WHERE bookmarkId = X'30000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000004"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM StudyPadTextEntry WHERE id = X'40000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000005"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM StudyPadTextEntry WHERE id = X'40000000000000000000000000000002'",
                    in: database
                ),
                "A0000000000000000000000000000006"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT COUNT(*) FROM StudyPadTextEntry WHERE id = X'40000000000000000000000000000002'",
                    in: database
                ),
                1
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT COUNT(*) FROM StudyPadTextEntryText WHERE studyPadTextEntryId = X'40000000000000000000000000000002'",
                    in: database
                ),
                0
            )
        }
    }

    private func assertAppliedRows(at fixtureURL: URL) throws {
        try withAndroidBookmarkSQLiteDatabase(at: fixtureURL, flags: SQLITE_OPEN_READONLY) { database in
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT typeof(ordinalEnd) FROM GenericBookmark WHERE id = X'30000000000000000000000000000001'",
                    in: database
                ),
                "null"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString(
                    "SELECT hex(sourcePromptId) FROM StudyPadTextEntry WHERE id = X'40000000000000000000000000000001'",
                    in: database
                ),
                "A0000000000000000000000000000005"
            )
            XCTAssertEqual(
                try androidBookmarkSQLiteInt(
                    "SELECT COUNT(*) FROM StudyPadTextEntryText WHERE studyPadTextEntryId = X'40000000000000000000000000000002'",
                    in: database
                ),
                0
            )
            XCTAssertEqual(try androidBookmarkSQLiteInt("SELECT COUNT(*) FROM pragma_foreign_key_check", in: database), 0)
            XCTAssertEqual(
                try androidBookmarkSQLiteOptionalString("PRAGMA integrity_check", in: database),
                "ok"
            )
        }
    }

    private func genericRow(
        id: UUID,
        key: String,
        sourcePromptID: UUID?,
        lastUpdated: TimeInterval
    ) -> RemoteSyncAndroidGenericBookmark {
        RemoteSyncAndroidGenericBookmark(
            id: id,
            key: key,
            createdAt: Date(timeIntervalSince1970: 10),
            bookInitials: "MHC",
            ordinalStart: nil,
            ordinalEnd: nil,
            startOffset: nil,
            endOffset: nil,
            primaryLabelID: nil,
            notes: nil,
            lastUpdatedOn: Date(timeIntervalSince1970: lastUpdated),
            wholeVerse: true,
            playbackSettingsJSON: nil,
            customIcon: nil,
            sourcePromptId: sourcePromptID,
            editAction: nil,
            labelLinks: []
        )
    }

    private func bookmarkLog(
        id: UUID,
        type: RemoteSyncLogEntryType,
        timestamp: Int64,
        secondary: RemoteSyncSQLiteValue = .text("")
    ) -> RemoteSyncLogEntry {
        RemoteSyncLogEntry(
            tableName: "GenericBookmark",
            entityID1: .blob(bookmarkUUIDBlob(id)),
            entityID2: secondary,
            type: type,
            lastUpdated: timestamp,
            sourceDevice: "fixture"
        )
    }

    private func studyPadTextLog(
        id: UUID,
        type: RemoteSyncLogEntryType,
        timestamp: Int64
    ) -> RemoteSyncLogEntry {
        RemoteSyncLogEntry(
            tableName: "StudyPadTextEntryText",
            entityID1: .blob(bookmarkUUIDBlob(id)),
            entityID2: .text(""),
            type: type,
            lastUpdated: timestamp,
            sourceDevice: "fixture"
        )
    }

    private func labelRow(id: UUID, name: String) -> RemoteSyncAndroidLabel {
        RemoteSyncAndroidLabel(
            id: id,
            name: name,
            color: 0,
            markerStyle: false,
            markerStyleWholeVerse: false,
            underlineStyle: false,
            underlineStyleWholeVerse: false,
            hideStyle: false,
            hideStyleWholeVerse: false,
            favourite: false,
            type: nil,
            customIcon: nil
        )
    }

    private func studyPadRow(
        id: UUID,
        labelID: UUID,
        text: String?
    ) -> RemoteSyncAndroidStudyPadEntry {
        RemoteSyncAndroidStudyPadEntry(
            id: id,
            labelID: labelID,
            orderNumber: 0,
            indentLevel: 0,
            contentType: nil,
            sourcePromptId: nil,
            text: text
        )
    }

    private func bookmarkSnapshot(
        labels: [RemoteSyncAndroidLabel] = [],
        genericBookmarks: [RemoteSyncAndroidGenericBookmark] = [],
        studyPadEntries: [RemoteSyncAndroidStudyPadEntry] = [],
        logEntries: [RemoteSyncLogEntry] = []
    ) -> RemoteSyncAndroidBookmarkSnapshot {
        RemoteSyncAndroidBookmarkSnapshot(
            labels: labels,
            bibleBookmarks: [],
            genericBookmarks: genericBookmarks,
            studyPadEntries: studyPadEntries,
            logEntries: logEntries
        )
    }

    private func bookmarkUploadResult(patchNumber: Int64, timestamp: Int64) -> RemoteSyncFile {
        RemoteSyncFile(
            id: "/sync/ios-device/\(patchNumber).12.sqlite3.gz",
            name: "\(patchNumber).12.sqlite3.gz",
            size: 0,
            timestamp: timestamp,
            parentID: "/sync/ios-device",
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
    }
}
