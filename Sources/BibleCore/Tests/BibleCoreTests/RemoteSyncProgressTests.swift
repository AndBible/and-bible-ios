import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

private let progressSyncTestSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class RemoteSyncProgressTests: XCTestCase {
    /**
     Protects Android's Progress initial-backup contract and the local typed accepted generation.

     Android initial databases leave `LogEntry` empty. iOS must do the same while separately accepting
     typed row identities and fingerprints at one revision so later local deletion still emits a sparse
     delete. A deterministic clock also proves `lastPatchWritten` uses the archive generation watermark.
     */
    func testProgressInitialBackupKeepsLogEmptyAndAcceptsTypedBaseline() async throws {
        let container = try makeInMemorySettingsContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000000101")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 1_700_000_100),
            ],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 2)
        )

        let syncFolderID = "/org.andbible.ios-sync-progress"
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        var nextTimestamp: Int64 = 1_900
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            nowProvider: {
                defer { nextTimestamp += 1 }
                return nextTimestamp
            }
        )

        _ = try await service.uploadInitialBackup(
            for: .progress,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: 9
        )

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploaded = try XCTUnwrap(uploadedFiles.first)
        let databaseURL = try materializeProgressArchive(uploaded.data)
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let uploadedEntries = try RemoteSyncInitialBackupMetadataRestoreService()
            .readSnapshot(from: databaseURL)
            .logEntries
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let localEntries = logEntryStore.entries(for: .progress)
        let snapshotService = RemoteSyncProgressSnapshotService()
        let acceptedBaseline = try XCTUnwrap(
            snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
        )
        let projected = try snapshotService.snapshotCurrentStateStrict(settingsStore: settingsStore)

        XCTAssertTrue(uploadedEntries.isEmpty)
        XCTAssertTrue(localEntries.isEmpty)
        XCTAssertEqual(acceptedBaseline.revision, 1)
        XCTAssertEqual(
            acceptedBaseline.generation,
            snapshotService.acceptedGeneration(from: projected)
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(
                RemoteSyncStateStore(settingsStore: settingsStore)
                    .progressState(for: .progress).lastPatchWritten
            ),
            1_900
        )
    }

    /**
     Verifies an initial Progress backup leaves the accepted-key manifest needed for later deletes.

     After the full initial backup accepts one memorized verse, local content removes it without any
     intervening sparse upload. The next patch must contain a `DELETE` for that initial-baseline key.
     Failure means rows present only in the initial backup can survive remotely forever.
     */
    func testProgressPatchUploadDeletesRowsRecordedByInitialBackupManifest() async throws {
        let container = try makeInMemorySettingsContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000000201")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let initialAdapter = RemoteSyncMockAdapter()
        await initialAdapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/progress/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 900,
                parentID: "/progress",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        _ = try await RemoteSyncInitialBackupUploadService(
            adapter: initialAdapter,
            deviceIdentifier: "device-initial",
            nowProvider: { 800 }
        ).uploadInitialBackup(
            for: .progress,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/progress"),
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: 9
        )

        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let patchAdapter = RemoteSyncMockAdapter()
        await patchAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-initial", patchNumber: 1)
        )
        let report = try await RemoteSyncProgressPatchUploadService(
            adapter: patchAdapter,
            nowProvider: { 1_000 }
        ).uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-initial"),
            settingsStore: settingsStore
        )
        let uploads = await patchAdapter.uploadedFilesSnapshot()
        let databaseURL = try materializeProgressArchive(try XCTUnwrap(uploads.first?.data))
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        XCTAssertEqual(report?.deletedRowCount, 1)
        XCTAssertEqual(
            try progressSQLiteInteger("SELECT COUNT(*) FROM LogEntry WHERE type = 'DELETE';", at: databaseURL),
            1
        )
    }

    func testProgressPatchUploadWritesSparseAndroidPatchAndRefreshesBaseline() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001001")!
        let historyID = UUID(uuidString: "15000000-0000-0000-0000-000000001002")!
        let targetID = UUID(uuidString: "15000000-0000-0000-0000-000000001003")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 1_700_000_100),
            ],
            chapterHistory: [
                .init(
                    id: historyID,
                    kjvBookOrdinal: 2,
                    chapter: 1,
                    cycle: 2,
                    readAt: 1_700_000_200,
                    bookInitials: "",
                    source: .manual
                ),
            ],
            targets: [
                .init(id: targetID, kjvOrdinalStart: 20, kjvOrdinalEnd: 22, createdAt: 1_700_000_300),
            ],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 2)
        )
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/progress/device-ios/1.9.sqlite3.gz",
                name: "1.9.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/progress/device-ios",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncProgressPatchUploadService(
            adapter: adapter,
            nowProvider: { 1_800_000_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-ios"),
            settingsStore: settingsStore
        )

        let uploadReport = try XCTUnwrap(report)
        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedMemorizedVerseCount, 1)
        XCTAssertEqual(uploadReport.upsertedChapterHistoryCount, 1)
        XCTAssertEqual(uploadReport.upsertedTargetCount, 1)
        XCTAssertEqual(uploadReport.upsertedSettingsCount, 1)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 4)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploaded = try XCTUnwrap(uploadedFiles.first)
        XCTAssertEqual(uploaded.name, "1.9.sqlite3.gz")
        XCTAssertEqual(uploaded.parentID, "/progress/device-ios")
        let patchDatabaseURL = try materializeProgressArchive(uploaded.data)
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizedVerse WHERE id = x'\(hex(memorizedID))';", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM ChapterReadHistory WHERE id = x'\(hex(historyID))';", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizationTarget WHERE id = x'\(hex(targetID))';", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM GlobalReadingProgressSettings;", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM LogEntry;", at: patchDatabaseURL), 4)

        let secondReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-ios"),
            settingsStore: settingsStore
        )
        XCTAssertNil(secondReport)
        let uploadedFilesAfterSecondRun = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFilesAfterSecondRun.count, 1)

        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 2)
        )
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/progress/device-ios/2.9.sqlite3.gz",
                name: "2.9.sqlite3.gz",
                size: 0,
                timestamp: 3_000,
                parentID: "/progress/device-ios",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let deleteReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-ios"),
            settingsStore: settingsStore
        )

        let deleteUploadReport = try XCTUnwrap(deleteReport)
        XCTAssertEqual(deleteUploadReport.patchNumber, 2)
        XCTAssertEqual(deleteUploadReport.upsertedMemorizedVerseCount, 0)
        XCTAssertEqual(deleteUploadReport.upsertedChapterHistoryCount, 0)
        XCTAssertEqual(deleteUploadReport.upsertedTargetCount, 0)
        XCTAssertEqual(deleteUploadReport.upsertedSettingsCount, 0)
        XCTAssertEqual(deleteUploadReport.deletedRowCount, 3)
        XCTAssertEqual(deleteUploadReport.logEntryCount, 3)

        let uploadedFilesAfterDelete = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFilesAfterDelete.count, 2)
        let deleteUpload = try XCTUnwrap(uploadedFilesAfterDelete.last)
        XCTAssertEqual(deleteUpload.name, "2.9.sqlite3.gz")
        let deletePatchDatabaseURL = try materializeProgressArchive(deleteUpload.data)
        defer { try? FileManager.default.removeItem(at: deletePatchDatabaseURL) }
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizedVerse;", at: deletePatchDatabaseURL), 0)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM ChapterReadHistory;", at: deletePatchDatabaseURL), 0)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizationTarget;", at: deletePatchDatabaseURL), 0)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM LogEntry WHERE type = 'DELETE';", at: deletePatchDatabaseURL), 3)
    }

    /**
     Verifies outbound Progress generation refuses to read or upload from a non-atomic preflight.

     An unsaved `Setting` mutation makes the owned context ineligible for `performAtomicBatch`. The
     service must surface that strict failure before creating a remote upload. Failure means a soft
     settings read could be mistaken for an empty baseline and publish a destructive patch.
     */
    func testProgressPatchUploadAbortsBeforeNetworkWhenAtomicPreflightCannotStart() async throws {
        let container = try makeInMemorySettingsContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(
                    id: UUID(uuidString: "15000000-0000-0000-0000-000000001101")!,
                    kjvOrdinal: 15,
                    memorizedAt: 100
                ),
            ],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        modelContext.insert(Setting(key: "progress_preflight_pending_change", value: "unsaved"))
        let adapter = RemoteSyncMockAdapter()
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_000 })

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-preflight"),
                settingsStore: settingsStore
            )
            XCTFail("Expected the strict preflight transaction to reject pending model changes")
        } catch {
            XCTAssertEqual(error as? SettingsStoreAtomicBatchError, .pendingModelChanges)
        }

        let uploads = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploads.isEmpty)
        modelContext.rollback()
    }

    /**
     Verifies malformed Progress content or sync metadata cannot degrade into an empty preflight.

     The first attempt corrupts chapter-progress JSON, the second corrupts an Android log payload,
     and the third corrupts accepted `SyncStatus`. Every case must fail before publication. Missing
     status remains a valid empty history; malformed status cannot be treated as missing.
     */
    func testProgressPatchUploadRejectsMalformedContentAndMetadataBeforeNetwork() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let adapter = RemoteSyncMockAdapter()
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_050 })
        let bootstrapState = RemoteSyncBootstrapState(deviceFolderID: "/progress/device-invalid")
        settingsStore.setString(ReadingProgressStore.settingsKey, value: "{invalid-reading-progress")

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: bootstrapState,
                settingsStore: settingsStore
            )
            XCTFail("Expected malformed Progress content to abort preflight")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncProgressSnapshotError,
                .invalidReadingProgressSnapshot
            )
        }

        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001151")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let logEntry = progressMemorizedVerseLogEntry(
            id: memorizedID,
            lastUpdated: 100,
            sourceDevice: "device-invalid"
        )
        settingsStore.setString(
            logEntryStore.key(for: .progress, entry: logEntry),
            value: "{invalid-log-entry"
        )

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: bootstrapState,
                settingsStore: settingsStore
            )
            XCTFail("Expected malformed Progress metadata to abort preflight")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncProgressPatchUploadError,
                .invalidLocalMetadata
            )
        }

        settingsStore.remove(logEntryStore.key(for: .progress, entry: logEntry))
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let malformedStatusKey = patchStatusStore.key(
            for: .progress,
            sourceDevice: "device-invalid",
            patchNumber: 4
        )
        settingsStore.setString(malformedStatusKey, value: "{invalid-patch-status")

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: bootstrapState,
                settingsStore: settingsStore
            )
            XCTFail("Expected malformed accepted patch status to abort preflight")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncPatchStatusStoreError,
                .invalidStoredStatus(malformedStatusKey)
            )
        }

        let uploads = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploads.isEmpty)
    }

    /**
     Verifies unsupported Progress settings and nonrepresentable wire integers fail before transport.

     Raw persisted JSON bypasses convenience-initializer normalization so an unknown visibility and
     negative active/history cycles reach the strict persistence boundary exactly as stored. A final
     valid snapshot uses `Int.max` for `activeCycle`, proving SQLite emission reports the checked
     `Int32` conversion failure instead of trapping or truncating the Android wire value.

     - Side Effects: Replaces local Progress JSON and inspects the deterministic mock transport.
     - Failure modes: Rethrows fixture/store setup failures; assertions fail if invalid semantics are
       normalized, if integer overflow loses its typed field/value, or if any request reaches transport.
     */
    func testProgressPatchUploadRejectsUnsupportedSettingsAndWireOverflowBeforeNetwork() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let adapter = RemoteSyncMockAdapter()
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_075 })
        let bootstrapState = RemoteSyncBootstrapState(deviceFolderID: "/progress/device-bounds")
        let settingsJSON: (_ visibility: String, _ activeCycle: Int) -> String = {
            visibility,
            activeCycle in
            """
            {"autoMarkMemorized":true,"autoTrackReading":false,"memorizeErrorHeatmap":true,"memorizeIncludeReference":true,"memorizeScrambleHideUsed":false,"memorizeTypeFullWords":false,"memorizeWordVisibility":"\(visibility)","activeCycle":\(activeCycle)}
            """
        }
        let snapshotJSON: (_ settings: String, _ history: String) -> String = { settings, history in
            "{\"history\":\(history),\"settings\":\(settings)}"
        }
        let invalidSnapshots: [(String, String)] = [
            (
                "unknown visibility",
                snapshotJSON(settingsJSON("future", 1), "[]")
            ),
            (
                "negative active cycle",
                snapshotJSON(settingsJSON("light", -1), "[]")
            ),
            (
                "negative history cycle",
                snapshotJSON(
                    settingsJSON("light", 1),
                    """
                    [{"bookInitials":"KJV","chapter":1,"cycle":-1,"id":"15000000-0000-0000-0000-000000001099","kjvBookOrdinal":1,"readAt":1,"source":"MANUAL","startOrdinal":0}]
                    """
                )
            ),
        ]

        for (label, payload) in invalidSnapshots {
            settingsStore.setString(ReadingProgressStore.settingsKey, value: payload)
            do {
                _ = try await service.uploadPendingPatch(
                    bootstrapState: bootstrapState,
                    settingsStore: settingsStore
                )
                XCTFail("Expected \(label) to abort Progress preflight")
            } catch {
                XCTAssertEqual(
                    error as? RemoteSyncProgressSnapshotError,
                    .invalidReadingProgressSnapshot,
                    label
                )
            }
        }

        settingsStore.setString(
            ReadingProgressStore.settingsKey,
            value: snapshotJSON(settingsJSON("light", Int.max), "[]")
        )
        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: bootstrapState,
                settingsStore: settingsStore
            )
            XCTFail("Expected a nonrepresentable active cycle to fail SQLite emission")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncWireIntegerError,
                .outOfRange(
                    field: "GlobalReadingProgressSettings.activeCycle",
                    value: String(Int.max)
                )
            )
        }

        let uploads = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploads.isEmpty)
    }

    /**
     Verifies a preserved Android key without a fingerprint is uploaded rather than assumed unchanged.

     The fixture has a valid accepted `LogEntry` manifest but deliberately omits its fingerprint.
     Publishing the row and then establishing its baseline is the conservative recovery behavior.
     Failure means incomplete local metadata can silently suppress real Progress content.
     */
    func testProgressPatchUploadPublishesRowsWhenAcceptedFingerprintIsMissing() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001201")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [progressMemorizedVerseLogEntry(id: memorizedID, lastUpdated: 100, sourceDevice: "android")],
            for: .progress
        )
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(progressUploadResult(parentID: "/progress/device-missing", patchNumber: 1))
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_100 })

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-missing"),
            settingsStore: settingsStore
        )

        XCTAssertEqual(report?.upsertedMemorizedVerseCount, 1)
        XCTAssertNotNil(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                for: .progress,
                tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(memorizedID)),
                entityID2: .text("")
            )
        )
    }

    /**
     Verifies missing local patch status cannot reuse a filename already present in the device folder.

     The local accepted-status history is genuinely empty while remote patch seven exists. Fresh
     generation must allocate patch eight from `max(local, remote) + 1`, preserving remote patch seven.
     */
    func testProgressPatchUploadAllocatesAfterRemoteHistoryWhenLocalStatusIsMissing() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(
                    id: UUID(uuidString: "15000000-0000-0000-0000-000000001251")!,
                    kjvOrdinal: 15,
                    memorizedAt: 200
                ),
            ],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        XCTAssertTrue(
            try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statusesStrict(for: .progress).isEmpty
        )

        let remotePatchSeven = RemoteSyncFile(
            id: "/progress/device-remote/7.9.sqlite3.gz",
            name: "7.9.sqlite3.gz",
            size: 77,
            timestamp: 700,
            parentID: "/progress/device-remote",
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueListFilesResult([remotePatchSeven])
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-remote", patchNumber: 8)
        )

        let report = try await RemoteSyncProgressPatchUploadService(
            adapter: adapter,
            nowProvider: { 1_150 }
        ).uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-remote"),
            settingsStore: settingsStore
        )
        let uploads = await adapter.uploadedFilesSnapshot()

        XCTAssertEqual(report?.patchNumber, 8)
        XCTAssertEqual(uploads.map(\.name), ["8.9.sqlite3.gz"])
    }

    /**
     Verifies an occupied generated filename with different bytes fails closed without overwrite.

     Remote enumeration is empty when patch one is reserved, then a concurrent writer appears before
     create. Exact-name reconciliation downloads the winner and must reject its different generation.
     */
    func testProgressPatchUploadRejectsConflictingRemoteGeneration() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(
                    id: UUID(uuidString: "15000000-0000-0000-0000-000000001252")!,
                    kjvOrdinal: 15,
                    memorizedAt: 200
                ),
            ],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let conflictingFile = RemoteSyncFile(
            id: "/progress/device-collision/conflict",
            name: "1.9.sqlite3.gz",
            size: 3,
            timestamp: 800,
            parentID: "/progress/device-collision",
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueListFilesResult([conflictingFile])
        await adapter.setDownloadData(Data([0x01, 0x02, 0x03]), forID: conflictingFile.id)
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_175 })
        defer { try? service.discardPendingPatchForDestinationReplacement(settingsStore: settingsStore) }

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-collision"),
                settingsStore: settingsStore
            )
            XCTFail("Expected occupied patch bytes from another generation to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncRemotePatchReconciliationError,
                .conflictingRemotePatch("1.9.sqlite3.gz")
            )
        }

        let conflictingUploads = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(conflictingUploads.isEmpty)
        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .progress,
                sourceDevice: "device-collision",
                patchNumber: 1
            )
        )
    }

    /**
     Verifies a newer Progress value written while upload is suspended remains pending afterward.

     The accepted baseline starts at timestamp 100. Generation one captures timestamp 200, while the
     adapter changes the same row to 300 before returning remote success. The next patch must contain
     300, proving acceptance used the immutable 200 fingerprint rather than a post-upload live snapshot.
     */
    func testProgressPatchUploadLeavesInFlightProgressChangeForNextPatch() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001301")!
        seedAcceptedMemorizedVerseBaseline(
            settingsStore: settingsStore,
            id: memorizedID,
            kjvOrdinal: 15,
            memorizedAt: 100,
            sourceDevice: "device-inflight",
            lastUpdated: 100
        )
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )

        let recordingAdapter = RemoteSyncMockAdapter()
        await recordingAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-inflight", patchNumber: 1)
        )
        await recordingAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-inflight", patchNumber: 2)
        )
        let adapter = ProgressMutatingUploadAdapter(delegate: recordingAdapter) {
            seedProgress(
                settingsStore: settingsStore,
                memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 300)],
                chapterHistory: [],
                targets: [],
                settings: ReadingProgressSettingsSnapshot()
            )
        }
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_200 })

        let firstReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-inflight"),
            settingsStore: settingsStore
        )
        let firstUploads = await recordingAdapter.uploadedFilesSnapshot()
        let firstDatabaseURL = try materializeProgressArchive(try XCTUnwrap(firstUploads.first?.data))
        defer { try? FileManager.default.removeItem(at: firstDatabaseURL) }

        let secondReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-inflight"),
            settingsStore: settingsStore
        )
        let allUploads = await recordingAdapter.uploadedFilesSnapshot()
        let secondDatabaseURL = try materializeProgressArchive(try XCTUnwrap(allUploads.last?.data))
        defer { try? FileManager.default.removeItem(at: secondDatabaseURL) }

        XCTAssertEqual(firstReport?.patchNumber, 1)
        XCTAssertEqual(secondReport?.patchNumber, 2)
        XCTAssertEqual(
            try progressSQLiteInteger("SELECT memorizedAt FROM MemorizedVerse;", at: firstDatabaseURL),
            200
        )
        XCTAssertEqual(
            try progressSQLiteInteger("SELECT memorizedAt FROM MemorizedVerse;", at: secondDatabaseURL),
            300
        )
    }

    /**
     Verifies an accepted baseline revision advanced during transport cannot be overwritten.

     Generation captures revision one, then the adapter publishes revision two before returning remote
     success. Local acceptance must fail its compare-and-swap and retain the pending outbox for explicit
     reconciliation rather than replacing newer accepted identities and fingerprints.
     */
    func testProgressPatchUploadRejectsStaleAcceptedBaselineRevision() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001351")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let snapshotService = RemoteSyncProgressSnapshotService()
        try settingsStore.performAtomicBatch {
            let snapshot = try snapshotService.snapshotCurrentStateStrict(settingsStore: settingsStore)
            try snapshotService.acceptBaselineFingerprints(
                snapshotService.acceptedGeneration(from: snapshot),
                settingsStore: settingsStore
            )
        }
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )

        let recordingAdapter = RemoteSyncMockAdapter()
        await recordingAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-cas", patchNumber: 1)
        )
        let adapter = ProgressMutatingUploadAdapter(delegate: recordingAdapter) {
            try settingsStore.performAtomicBatch {
                let snapshot = try snapshotService.snapshotCurrentStateStrict(settingsStore: settingsStore)
                try snapshotService.acceptBaselineFingerprints(
                    snapshotService.acceptedGeneration(from: snapshot),
                    settingsStore: settingsStore
                )
            }
        }
        let service = RemoteSyncProgressPatchUploadService(adapter: adapter, nowProvider: { 1_250 })
        defer { try? service.discardPendingPatchForDestinationReplacement(settingsStore: settingsStore) }

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-cas"),
                settingsStore: settingsStore
            )
            XCTFail("Expected accepted baseline compare-and-swap to reject stale generation")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncProgressSnapshotError,
                .staleAcceptedBaseline(expected: 1, actual: 2)
            )
        }
        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .progress,
                sourceDevice: "device-cas",
                patchNumber: 1
            )
        )
    }

    /**
     Verifies remote success followed by local acceptance failure remains restart-safe and idempotent.

     The final acceptance checkpoint throws after all bookkeeping changes are staged. A fresh service
     instance must resume patch four before creating new work, verify the already-remote gzip bytes by
     digest, and accept without another PUT. Failure means a process death can fork patch history.
     */
    func testProgressPatchUploadRetriesDurableGenerationAfterAcceptanceRollback() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001401")!
        seedAcceptedMemorizedVerseBaseline(
            settingsStore: settingsStore,
            id: memorizedID,
            kjvOrdinal: 15,
            memorizedAt: 100,
            sourceDevice: "device-restart",
            lastUpdated: 100,
            patchNumber: 3
        )
        var oldProgressState = RemoteSyncProgressState()
        oldProgressState.lastPatchWritten = 333
        RemoteSyncStateStore(settingsStore: settingsStore).setProgressState(oldProgressState, for: .progress)
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )

        let firstAdapter = RemoteSyncMockAdapter()
        await firstAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-restart", patchNumber: 4)
        )
        let firstService = RemoteSyncProgressPatchUploadService(adapter: firstAdapter, nowProvider: { 1_300 })
        do {
            _ = try await firstService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-restart"),
                settingsStore: settingsStore,
                acceptanceCheckpoint: {
                    throw NSError(domain: "ProgressUploadAcceptance", code: 91)
                }
            )
            XCTFail("Expected the final acceptance checkpoint to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ProgressUploadAcceptance")
            XCTAssertEqual((error as NSError).code, 91)
        }

        let pendingMutationTimestamp = try XCTUnwrap(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entries(for: .progress).first?.lastUpdated
        )
        XCTAssertGreaterThan(pendingMutationTimestamp, 1_300)
        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .progress,
                sourceDevice: "device-restart",
                patchNumber: 4
            )
        )
        XCTAssertEqual(
            RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .progress).lastPatchWritten,
            333
        )

        let firstUploads = await firstAdapter.uploadedFilesSnapshot()
        let firstUpload = try XCTUnwrap(firstUploads.first)
        let existingRemotePatch = RemoteSyncFile(
            id: "/progress/device-restart/existing-4",
            name: "4.9.sqlite3.gz",
            size: Int64(firstUpload.data.count),
            timestamp: 2_104,
            parentID: "/progress/device-restart",
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let secondAdapter = RemoteSyncMockAdapter()
        await secondAdapter.setListFilesResult([existingRemotePatch])
        await secondAdapter.setDownloadData(firstUpload.data, forID: existingRemotePatch.id)
        let restartedService = RemoteSyncProgressPatchUploadService(adapter: secondAdapter, nowProvider: { 9_999 })
        let retryReport = try await restartedService.resumePendingPatchIfPresent(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-restart"),
            settingsStore: settingsStore
        )
        let retryUploads = await secondAdapter.uploadedFilesSnapshot()
        let acceptedStatus = RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
            for: .progress,
            sourceDevice: "device-restart",
            patchNumber: 4
        )

        XCTAssertEqual(retryReport?.patchNumber, 4)
        let resumedTimestamp = try XCTUnwrap(retryReport?.lastUpdated)
        XCTAssertGreaterThan(resumedTimestamp, pendingMutationTimestamp)
        XCTAssertEqual(firstUpload.name, "4.9.sqlite3.gz")
        XCTAssertTrue(retryUploads.isEmpty)
        XCTAssertEqual(retryReport?.uploadedFile, existingRemotePatch)
        XCTAssertEqual(acceptedStatus?.sizeBytes, Int64(firstUpload.data.count))
        XCTAssertEqual(acceptedStatus?.appliedDate, 2_104)
        XCTAssertEqual(
            RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .progress).lastPatchWritten,
            resumedTimestamp
        )
    }

    /**
     Verifies cancellation after remote create preserves the durable generation for resume-only recovery.

     The adapter cancels the child upload task only after recording remote success. Shared reconciliation
     observes cancellation before local acceptance, leaving old bookkeeping and the outbox intact. A
     fresh service then verifies the exact remote bytes and accepts without creating another patch.
     */
    func testProgressPatchUploadCancellationAfterRemoteCreatePreservesGeneration() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001451")!
        seedAcceptedMemorizedVerseBaseline(
            settingsStore: settingsStore,
            id: memorizedID,
            kjvOrdinal: 15,
            memorizedAt: 100,
            sourceDevice: "device-cancel",
            lastUpdated: 100
        )
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )

        let recordingAdapter = RemoteSyncMockAdapter()
        await recordingAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-cancel", patchNumber: 1)
        )
        let cancellingAdapter = ProgressMutatingUploadAdapter(delegate: recordingAdapter) {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        let firstService = RemoteSyncProgressPatchUploadService(
            adapter: cancellingAdapter,
            nowProvider: { 1_350 }
        )
        let uploadTask = Task {
            try await firstService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-cancel"),
                settingsStore: settingsStore
            )
        }
        do {
            _ = try await uploadTask.value
            XCTFail("Expected cancellation after remote create")
        } catch is CancellationError {
            // Expected: remote bytes exist, but no local acceptance occurred.
        }

        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .progress,
                sourceDevice: "device-cancel",
                patchNumber: 1
            )
        )
        let firstUploads = await recordingAdapter.uploadedFilesSnapshot()
        let firstUpload = try XCTUnwrap(firstUploads.first)
        let remotePatch = RemoteSyncFile(
            id: "/progress/device-cancel/existing-1",
            name: "1.9.sqlite3.gz",
            size: Int64(firstUpload.data.count),
            timestamp: 2_151,
            parentID: "/progress/device-cancel",
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let resumeAdapter = RemoteSyncMockAdapter()
        await resumeAdapter.setListFilesResult([remotePatch])
        await resumeAdapter.setDownloadData(firstUpload.data, forID: remotePatch.id)
        let resumedReport = try await RemoteSyncProgressPatchUploadService(
            adapter: resumeAdapter,
            nowProvider: { 9_999 }
        ).resumePendingPatchIfPresent(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-cancel"),
            settingsStore: settingsStore
        )
        let resumeUploads = await resumeAdapter.uploadedFilesSnapshot()

        XCTAssertEqual(resumedReport?.patchNumber, 1)
        let resumedTimestamp = try XCTUnwrap(resumedReport?.lastUpdated)
        XCTAssertGreaterThan(resumedTimestamp, 1_350)
        XCTAssertTrue(resumeUploads.isEmpty)
        XCTAssertEqual(
            RemoteSyncStateStore(settingsStore: settingsStore).progressState(for: .progress).lastPatchWritten,
            resumedTimestamp
        )
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .progress,
                sourceDevice: "device-cancel",
                patchNumber: 1
            )?.appliedDate,
            2_151
        )
    }

    /**
     Verifies a stale outbox cannot cross destinations until lifecycle explicitly discards it.

     A failed acceptance leaves one generation bound to the old folder. Upload against a replacement
     folder must fail whether bootstrap is incomplete or ready. After the explicit replacement boundary
     discards only the pending generation, current local rows rebuild as dirty for the new destination.
     */
    func testProgressPatchUploadRequiresExplicitDiscardBeforeDestinationReplacement() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001501")!
        seedAcceptedMemorizedVerseBaseline(
            settingsStore: settingsStore,
            id: memorizedID,
            kjvOrdinal: 15,
            memorizedAt: 100,
            sourceDevice: "device-old",
            lastUpdated: 100
        )
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let oldAdapter = RemoteSyncMockAdapter()
        await oldAdapter.enqueueUploadResult(progressUploadResult(parentID: "/progress/device-old", patchNumber: 1))
        let oldService = RemoteSyncProgressPatchUploadService(adapter: oldAdapter, nowProvider: { 1_400 })
        do {
            _ = try await oldService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-old"),
                settingsStore: settingsStore,
                acceptanceCheckpoint: { throw NSError(domain: "ProgressDestinationReplacement", code: 92) }
            )
            XCTFail("Expected acceptance failure to preserve the old destination outbox")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ProgressDestinationReplacement")
        }

        let replacementAdapter = RemoteSyncMockAdapter()
        let replacementService = RemoteSyncProgressPatchUploadService(
            adapter: replacementAdapter,
            nowProvider: { 1_500 }
        )
        do {
            _ = try await replacementService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(
                    deviceFolderID: "/progress/device-new",
                    phase: .awaitingLocalInitialUpload
                ),
                settingsStore: settingsStore
            )
            XCTFail("Expected an unready replacement destination to retain the stale outbox")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncProgressPatchUploadError,
                .pendingPatchDestinationMismatch
            )
        }
        let uploadsBeforeDiscard = await replacementAdapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadsBeforeDiscard.isEmpty)

        do {
            _ = try await replacementService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(
                    deviceFolderID: "/progress/device-new",
                    phase: .ready
                ),
                settingsStore: settingsStore
            )
            XCTFail("Expected a ready replacement destination to remain fail-closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncProgressPatchUploadError,
                .pendingPatchDestinationMismatch
            )
        }

        try replacementService.discardPendingPatchForDestinationReplacement(
            settingsStore: settingsStore
        )

        await replacementAdapter.enqueueUploadResult(
            progressUploadResult(parentID: "/progress/device-new", patchNumber: 1)
        )
        let rebuiltReport = try await replacementService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(
                deviceFolderID: "/progress/device-new",
                phase: .ready
            ),
            settingsStore: settingsStore
        )
        let uploadsAfterDiscard = await replacementAdapter.uploadedFilesSnapshot()

        XCTAssertEqual(rebuiltReport?.upsertedMemorizedVerseCount, 1)
        XCTAssertEqual(uploadsAfterDiscard.count, 1)
        XCTAssertEqual(uploadsAfterDiscard.first?.parentID, "/progress/device-new")
    }

    func testProgressPatchApplyReplaysNewerRowsAndDeletesByAndroidLogEntry() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let deletedID = UUID(uuidString: "15000000-0000-0000-0000-000000002001")!
        let insertedID = UUID(uuidString: "15000000-0000-0000-0000-000000002002")!
        let historyID = UUID(uuidString: "15000000-0000-0000-0000-000000002003")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(id: deletedID, kjvOrdinal: 15, memorizedAt: 100),
            ],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [
                .init(id: insertedID, kjvOrdinal: 16, memorizedAt: 300),
            ],
            chapterHistory: [
                .init(
                    id: historyID,
                    kjvBookOrdinal: 2,
                    chapter: 2,
                    cycle: 1,
                    readAt: 400,
                    bookInitials: "",
                    source: .autoTts
                ),
            ],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 4),
            logEntries: [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(deletedID)),
                    entityID2: .text(""),
                    type: .delete,
                    lastUpdated: 500,
                    sourceDevice: "android"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(insertedID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 501,
                    sourceDevice: "android"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.chapterReadHistoryTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(historyID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 502,
                    sourceDevice: "android"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.globalSettingsTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(RemoteSyncProgressSnapshotService.globalSettingsID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 503,
                    sourceDevice: "android"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try RemoteSyncProgressPatchApplyService().applyPatchArchives(
            [stagedArchive],
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 4)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(report.readingCount, 1)
        XCTAssertEqual(report.memorizedVerseCount, 1)
        XCTAssertEqual(report.targetCount, 0)
        let memorizationSnapshot = MemorizationProgressStore(settingsStore: settingsStore).snapshot()
        XCTAssertEqual(memorizationSnapshot.memorizedVerses.map(\.id), [insertedID])
        XCTAssertEqual(memorizationSnapshot.memorizedVerses.map(\.kjvOrdinal), [16])
        let readingSnapshot = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        XCTAssertEqual(readingSnapshot.history.map(\.id), [historyID])
        XCTAssertEqual(readingSnapshot.history.first?.source, .autoTts)
        XCTAssertTrue(readingSnapshot.settings.autoTrackReading)
        XCTAssertEqual(readingSnapshot.settings.activeCycle, 4)
        XCTAssertEqual(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .progress).map(\.patchNumber), [1])
        XCTAssertEqual(RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .progress).count, 4)
    }

    /**
     Verifies a Progress patch cannot replace Android's fixed global-settings singleton identity.

     Row and log identifiers are corrupted independently so both pre-metadata checks are exercised.
     Neither shape may change local progress, conflict logs, or applied-patch bookkeeping.
     */
    func testProgressPatchApplyRejectsForeignGlobalSettingsIdentifiersWithoutMutation() throws {
        let foreignID = UUID(uuidString: "15000000-0000-0000-0000-000000002049")!
        let scenarios: [(settingsRowID: UUID?, logEntryID: UUID?)] = [
            (foreignID, nil),
            (nil, foreignID),
        ]

        for scenario in scenarios {
            let settingsStore = try makeInMemorySettingsStore()
            seedProgress(
                settingsStore: settingsStore,
                memorizedVerses: [],
                chapterHistory: [],
                targets: [],
                settings: ReadingProgressSettingsSnapshot(
                    autoTrackReading: false,
                    activeCycle: 7
                )
            )
            let retainedReading = try XCTUnwrap(
                settingsStore.getString(ReadingProgressStore.settingsKey)
            )
            let patchDatabaseURL = try makeProgressPatchDatabase(
                memorizedVerses: [],
                chapterHistory: [],
                targets: [],
                settings: ReadingProgressSettingsSnapshot(
                    autoTrackReading: true,
                    activeCycle: 8
                ),
                logEntries: [
                    .init(
                        tableName: RemoteSyncProgressSnapshotService.globalSettingsTable,
                        entityID1: .blob(
                            RemoteSyncProgressSnapshotService.uuidBlob(
                                RemoteSyncProgressSnapshotService.globalSettingsID
                            )
                        ),
                        entityID2: .text(""),
                        type: .upsert,
                        lastUpdated: 500,
                        sourceDevice: "android-foreign-singleton"
                    ),
                ]
            )
            defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
            try rewriteProgressSingletonIdentifiers(
                in: patchDatabaseURL,
                settingsRowID: scenario.settingsRowID,
                logEntryID: scenario.logEntryID
            )
            let archive = try makeProgressPatchArchive(
                patchDatabaseURL: patchDatabaseURL,
                sourceDevice: "android-foreign-singleton",
                patchNumber: 1,
                fileTimestamp: 900
            )
            defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

            XCTAssertThrowsError(
                try RemoteSyncProgressPatchApplyService().applyPatchArchives(
                    [archive],
                    settingsStore: settingsStore
                )
            )
            XCTAssertEqual(
                settingsStore.getString(ReadingProgressStore.settingsKey),
                retainedReading
            )
            XCTAssertTrue(
                RemoteSyncLogEntryStore(settingsStore: settingsStore)
                    .entries(for: .progress)
                    .isEmpty
            )
            XCTAssertTrue(
                RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                    .statuses(for: .progress)
                    .isEmpty
            )
        }
    }

    /**
     Verifies malformed local Progress JSON aborts inbound replay without changing any namespace.

     The staged archive is otherwise valid and newer. Replay must fail during the strict local
     snapshot before replacing content, conflict logs, patch status, or the malformed source value.
     */
    func testProgressPatchApplyRejectsMalformedLocalSnapshotWithoutMutation() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let retainedID = UUID(uuidString: "15000000-0000-0000-0000-000000002051")!
        let incomingID = UUID(uuidString: "15000000-0000-0000-0000-000000002052")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: retainedID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let retainedMemorization = try XCTUnwrap(
            settingsStore.getString(MemorizationProgressStore.settingsKey)
        )
        let malformedReading = "{malformed-reading-progress"
        settingsStore.setString(ReadingProgressStore.settingsKey, value: malformedReading)

        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [.init(id: incomingID, kjvOrdinal: 16, memorizedAt: 300)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(activeCycle: 2),
            logEntries: [
                progressMemorizedVerseLogEntry(
                    id: incomingID,
                    lastUpdated: 500,
                    sourceDevice: "android-malformed-local"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let archive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-malformed-local",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        XCTAssertThrowsError(
            try RemoteSyncProgressPatchApplyService().applyPatchArchives(
                [archive],
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncProgressSnapshotError,
                .invalidReadingProgressSnapshot
            )
        }
        XCTAssertEqual(
            settingsStore.getString(ReadingProgressStore.settingsKey),
            malformedReading
        )
        XCTAssertEqual(
            settingsStore.getString(MemorizationProgressStore.settingsKey),
            retainedMemorization
        )
        XCTAssertTrue(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .progress).isEmpty
        )
        XCTAssertTrue(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .progress).isEmpty
        )
    }

    /**
     Verifies malformed local memorization JSON aborts replay without mutating valid reading state.

     Reading state is valid and the incoming archive would replace it. Strict snapshot decoding must
     reject the malformed memorization namespace before content, logs, or patch status can publish.
     */
    func testProgressPatchApplyRejectsMalformedLocalMemorizationWithoutMutation() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let retainedHistoryID = UUID(uuidString: "15000000-0000-0000-0000-000000002053")!
        let incomingHistoryID = UUID(uuidString: "15000000-0000-0000-0000-000000002054")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [],
            chapterHistory: [
                .init(
                    id: retainedHistoryID,
                    kjvBookOrdinal: 2,
                    chapter: 1,
                    cycle: 1,
                    readAt: 100,
                    bookInitials: "",
                    source: .manual
                )
            ],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let retainedReading = try XCTUnwrap(
            settingsStore.getString(ReadingProgressStore.settingsKey)
        )
        let malformedMemorization = "{malformed-memorization-progress"
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: malformedMemorization
        )

        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [],
            chapterHistory: [
                .init(
                    id: incomingHistoryID,
                    kjvBookOrdinal: 2,
                    chapter: 2,
                    cycle: 1,
                    readAt: 300,
                    bookInitials: "",
                    source: .autoTts
                )
            ],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(activeCycle: 2),
            logEntries: [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.chapterReadHistoryTable,
                    entityID1: .blob(
                        RemoteSyncProgressSnapshotService.uuidBlob(incomingHistoryID)
                    ),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 500,
                    sourceDevice: "android-malformed-local"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let archive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-malformed-local",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        XCTAssertThrowsError(
            try RemoteSyncProgressPatchApplyService().applyPatchArchives(
                [archive],
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncProgressSnapshotError,
                .invalidMemorizationProgressSnapshot
            )
        }
        XCTAssertEqual(
            settingsStore.getString(ReadingProgressStore.settingsKey),
            retainedReading
        )
        XCTAssertEqual(
            settingsStore.getString(MemorizationProgressStore.settingsKey),
            malformedMemorization
        )
        XCTAssertTrue(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .progress).isEmpty
        )
        XCTAssertTrue(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .progress).isEmpty
        )
    }

    /**
     Verifies Android's strictly-newer conflict rule skips a byte-different equal-time upsert.

     An equal timestamp cannot win by source device, operation type, or payload. The archive itself
     still commits its patch status while the accepted row and conflict log remain unchanged.
     */
    func testProgressPatchApplySkipsEqualTimestampOperation() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let rowID = UUID(uuidString: "15000000-0000-0000-0000-000000002055")!
        seedAcceptedMemorizedVerseBaseline(
            settingsStore: settingsStore,
            id: rowID,
            kjvOrdinal: 15,
            memorizedAt: 100,
            sourceDevice: "local-device",
            lastUpdated: 500
        )
        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [.init(id: rowID, kjvOrdinal: 15, memorizedAt: 999)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                progressMemorizedVerseLogEntry(
                    id: rowID,
                    lastUpdated: 500,
                    sourceDevice: "android-equal-time"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let archive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-equal-time",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: archive.archiveFileURL) }

        let report = try RemoteSyncProgressPatchApplyService().applyPatchArchives(
            [archive],
            settingsStore: settingsStore
        )
        let row = try XCTUnwrap(
            MemorizationProgressStore(settingsStore: settingsStore)
                .snapshot().memorizedVerses.first
        )
        let retainedLog = RemoteSyncLogEntryStore(settingsStore: settingsStore).entry(
            for: .progress,
            tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
            entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(rowID)),
            entityID2: .text("")
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)
        XCTAssertEqual(row.memorizedAt, 100)
        XCTAssertEqual(retainedLog?.lastUpdated, 500)
        XCTAssertEqual(retainedLog?.sourceDevice, "local-device")
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statuses(for: .progress).map(\.patchNumber),
            [1]
        )
    }

    /**
     Verifies a later invalid archive cannot roll back an earlier independently committed archive.

     Both gzip members pass the batch size preflight. The second database then fails the exact Room
     version contract, after the first archive has atomically published content, log, and status.
     */
    func testProgressPatchApplyCommitsEachArchiveBeforeLaterSchemaFailure() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let firstID = UUID(uuidString: "15000000-0000-0000-0000-000000002056")!
        let secondID = UUID(uuidString: "15000000-0000-0000-0000-000000002057")!
        let firstDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [.init(id: firstID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                progressMemorizedVerseLogEntry(
                    id: firstID,
                    lastUpdated: 500,
                    sourceDevice: "android-archive-boundary"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: firstDatabaseURL) }
        let secondDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [.init(id: secondID, kjvOrdinal: 16, memorizedAt: 200)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                progressMemorizedVerseLogEntry(
                    id: secondID,
                    lastUpdated: 600,
                    sourceDevice: "android-archive-boundary"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: secondDatabaseURL) }
        try executeProgressSQL("PRAGMA user_version = 10;", at: secondDatabaseURL)
        let firstArchive = try makeProgressPatchArchive(
            patchDatabaseURL: firstDatabaseURL,
            sourceDevice: "android-archive-boundary",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: firstArchive.archiveFileURL) }
        let secondArchive = try makeProgressPatchArchive(
            patchDatabaseURL: secondDatabaseURL,
            sourceDevice: "android-archive-boundary",
            patchNumber: 2,
            fileTimestamp: 1_000
        )
        defer { try? FileManager.default.removeItem(at: secondArchive.archiveFileURL) }

        XCTAssertThrowsError(
            try RemoteSyncProgressPatchApplyService().applyPatchArchives(
                [firstArchive, secondArchive],
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .invalidUserVersion(expected: 9, actual: 10)
            )
        }
        XCTAssertEqual(
            MemorizationProgressStore(settingsStore: settingsStore)
                .snapshot().memorizedVerses.map(\.id),
            [firstID]
        )
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statuses(for: .progress).map(\.patchNumber),
            [1]
        )
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entries(for: .progress).map(\.entityID1),
            [.blob(RemoteSyncProgressSnapshotService.uuidBlob(firstID))]
        )
    }

    /**
     Verifies same-ordinal upserts retain the existing UUID and later incoming-UUID deletes miss it.

     Android's unique-ordinal conflict update changes the existing row in place. Replaying a later
     tombstone for the discarded incoming primary key must therefore leave that updated row present.
     */
    func testProgressPatchApplyPreservesUUIDAcrossOrdinalConflictAndLaterDelete() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let existingID = UUID(uuidString: "15000000-0000-0000-0000-000000002061")!
        let incomingID = UUID(uuidString: "15000000-0000-0000-0000-000000002062")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: existingID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )

        let upsertDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [.init(id: incomingID, kjvOrdinal: 15, memorizedAt: 300)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                progressMemorizedVerseLogEntry(
                    id: incomingID,
                    lastUpdated: 500,
                    sourceDevice: "android-ordinal-conflict"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: upsertDatabaseURL) }
        let deleteDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(incomingID)),
                    entityID2: .text(""),
                    type: .delete,
                    lastUpdated: 600,
                    sourceDevice: "android-ordinal-conflict"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: deleteDatabaseURL) }
        let upsertArchive = try makeProgressPatchArchive(
            patchDatabaseURL: upsertDatabaseURL,
            sourceDevice: "android-ordinal-conflict",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: upsertArchive.archiveFileURL) }
        let deleteArchive = try makeProgressPatchArchive(
            patchDatabaseURL: deleteDatabaseURL,
            sourceDevice: "android-ordinal-conflict",
            patchNumber: 2,
            fileTimestamp: 1_000
        )
        defer { try? FileManager.default.removeItem(at: deleteArchive.archiveFileURL) }

        let report = try RemoteSyncProgressPatchApplyService().applyPatchArchives(
            [upsertArchive, deleteArchive],
            settingsStore: settingsStore
        )
        let rows = MemorizationProgressStore(settingsStore: settingsStore).snapshot().memorizedVerses

        XCTAssertEqual(report.appliedPatchCount, 2)
        XCTAssertEqual(report.appliedLogEntryCount, 2)
        XCTAssertEqual(rows.map(\.id), [existingID])
        XCTAssertEqual(rows.map(\.kjvOrdinal), [15])
        XCTAssertEqual(rows.map(\.memorizedAt), [300])
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statuses(for: .progress).map(\.patchNumber),
            [1, 2]
        )
    }

    /**
     Verifies Progress patch content and sync bookkeeping roll back as one settings transaction.

     The fixture starts with one memorized verse, its old Android log timestamp, and a sentinel
     fingerprint. A newer patch stages replacement content plus patch status and refreshed
     fingerprints, then the final publish checkpoint throws. Every old namespace must remain and
     the incoming patch must remain unapplied. Failure means retry conflict resolution can diverge.
     */
    func testProgressPatchApplyRollsBackContentAndBookkeepingTogether() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let oldID = UUID(uuidString: "15000000-0000-0000-0000-000000002101")!
        let incomingID = UUID(uuidString: "15000000-0000-0000-0000-000000002102")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [.init(id: oldID, kjvOrdinal: 15, memorizedAt: 100)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )

        let entityID = RemoteSyncSQLiteValue.blob(RemoteSyncProgressSnapshotService.uuidBlob(oldID))
        let entityID2 = RemoteSyncSQLiteValue.text("")
        RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
            [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: entityID,
                    entityID2: entityID2,
                    type: .upsert,
                    lastUpdated: 100,
                    sourceDevice: "seed-device"
                )
            ],
            for: .progress
        )
        RemoteSyncRowFingerprintStore(settingsStore: settingsStore).setFingerprint(
            "old-fingerprint",
            for: .progress,
            tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
            entityID1: entityID,
            entityID2: entityID2
        )

        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [.init(id: incomingID, kjvOrdinal: 16, memorizedAt: 300)],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(oldID)),
                    entityID2: .text(""),
                    type: .delete,
                    lastUpdated: 500,
                    sourceDevice: "android-atomic"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(incomingID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 501,
                    sourceDevice: "android-atomic"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-atomic",
            patchNumber: 4,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }
        var checkpointCount = 0

        XCTAssertThrowsError(
            try RemoteSyncProgressPatchApplyService().applyPatchArchives(
                [stagedArchive],
                settingsStore: settingsStore,
                publishCheckpoint: {
                    checkpointCount += 1
                    if checkpointCount == 2 {
                        throw NSError(domain: "ProgressPatchAtomicity", code: 83)
                    }
                }
            )
        ) { error in
            XCTAssertEqual((error as NSError).domain, "ProgressPatchAtomicity")
            XCTAssertEqual((error as NSError).code, 83)
        }
        XCTAssertEqual(checkpointCount, 2)
        XCTAssertEqual(MemorizationProgressStore(settingsStore: settingsStore).snapshot().memorizedVerses.map(\.id), [oldID])
        XCTAssertNil(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .progress,
                sourceDevice: "android-atomic",
                patchNumber: 4
            )
        )
        XCTAssertEqual(
            RemoteSyncLogEntryStore(settingsStore: settingsStore).entry(
                for: .progress,
                tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                entityID1: entityID,
                entityID2: entityID2
            )?.lastUpdated,
            100
        )
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                for: .progress,
                tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                entityID1: entityID,
                entityID2: entityID2
            ),
            "old-fingerprint"
        )
    }

    /**
     Verifies invalid Android KJVA target ordinals fail exact Room row validation before replay.

     The fixture writes ordinal zero into `MemorizationTarget.kjvOrdinalStart`. The inbound contract
     must identify that field precisely and publish no local progress state. A generic SQLite error or
     successful replay would hide malformed Android data at the synchronization boundary.
     */
    func testProgressPatchApplyRejectsInvalidMemorizationTargetOrdinals() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let targetID = UUID(uuidString: "15000000-0000-0000-0000-000000003001")!
        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [],
            chapterHistory: [],
            targets: [
                .init(id: targetID, kjvOrdinalStart: 0, kjvOrdinalEnd: 2, createdAt: 700),
            ],
            settings: ReadingProgressSettingsSnapshot(),
            logEntries: [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizationTargetTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(targetID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 701,
                    sourceDevice: "android"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        XCTAssertThrowsError(
            try RemoteSyncProgressPatchApplyService().applyPatchArchives(
                [stagedArchive],
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .invalidRowValue(
                    table: "MemorizationTarget",
                    column: "kjvOrdinalStart"
                )
            )
        }
    }
}

/**
 Adapter wrapper that mutates local Progress exactly once before an upload suspension returns.

 The delegate records and serves all remote operations. Only `upload` adds behavior: after the
 delegate has captured the exact outgoing bytes but before the service resumes local acceptance,
 the wrapper runs the supplied local mutation. The lock makes one-shot consumption deterministic.
 */
private final class ProgressMutatingUploadAdapter:
    RemoteSyncAdapting,
    RemoteSyncConditionalFileUploading,
    @unchecked Sendable
{
    private let delegate: RemoteSyncMockAdapter
    private let lock = NSLock()
    private var pendingMutation: (() throws -> Void)?

    /** Creates a wrapper around the recording adapter with one upload-time mutation. */
    init(delegate: RemoteSyncMockAdapter, mutation: @escaping () throws -> Void) {
        self.delegate = delegate
        self.pendingMutation = mutation
    }

    /** Delegates remote file listing without modification. */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        try await delegate.listFiles(
            parentIDs: parentIDs,
            name: name,
            mimeType: mimeType,
            modifiedAtLeast: modifiedAtLeast
        )
    }

    /** Delegates remote folder creation without modification. */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        try await delegate.createNewFolder(name: name, parentID: parentID)
    }

    /** Delegates remote download without modification. */
    func download(id: String) async throws -> Data {
        try await delegate.download(id: id)
    }

    /**
     Records the upload through the delegate, then performs the one pending local mutation.

     - Returns: Remote metadata returned by the delegate.
     - Side effects: Reads the archive through the delegate and invokes the mutation once.
     - Throws: Rethrows delegate upload failures and deterministic mutation failures.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        let result = try await delegate.upload(
            name: name,
            fileURL: fileURL,
            parentID: parentID,
            contentType: contentType
        )
        let mutation = lock.withLock {
            defer { pendingMutation = nil }
            return pendingMutation
        }
        try mutation?()
        return result
    }

    /**
     Performs create-only publication through the delegate, then mutates local Progress once.

     This is the production patch path exercised by the shared remote reconciler. Mutation occurs
     only after the remote result exists and before local acceptance resumes.
     */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        let result = try await delegate.uploadIfAbsent(
            name: name,
            fileURL: fileURL,
            maximumByteCount: maximumByteCount,
            parentID: parentID,
            contentType: contentType
        )
        let mutation = lock.withLock {
            defer { pendingMutation = nil }
            return pendingMutation
        }
        try mutation?()
        return result
    }

    /** Delegates remote deletion without modification. */
    func delete(id: String) async throws {
        try await delegate.delete(id: id)
    }

    /** Delegates known-folder validation without modification. */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        try await delegate.isSyncFolderKnown(
            syncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
    }

    /** Delegates known-folder marker creation without modification. */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        try await delegate.makeSyncFolderKnown(
            syncFolderID: syncFolderID,
            deviceIdentifier: deviceIdentifier
        )
    }
}

/**
 Seeds one accepted memorized-verse generation and optional prior patch number for upload tests.

 - Parameters:
   - settingsStore: Store receiving Progress content and synchronization metadata.
   - id: Stable Android memorized-verse UUID.
   - kjvOrdinal: Trusted KJVA global ordinal.
   - memorizedAt: Accepted memorization timestamp.
   - sourceDevice: Device name recorded in the accepted key manifest.
   - lastUpdated: Accepted Android log timestamp.
   - patchNumber: Optional highest accepted patch number for the source device.
 - Side effects: Replaces local Progress content, log entries, fingerprints, and optional status.
 - Failure modes: Test fixture encoding is force-unwrapped by `seedProgress` and is expected valid.
 */
private func seedAcceptedMemorizedVerseBaseline(
    settingsStore: SettingsStore,
    id: UUID,
    kjvOrdinal: Int,
    memorizedAt: Int64,
    sourceDevice: String,
    lastUpdated: Int64,
    patchNumber: Int64? = nil
) {
    seedProgress(
        settingsStore: settingsStore,
        memorizedVerses: [.init(id: id, kjvOrdinal: kjvOrdinal, memorizedAt: memorizedAt)],
        chapterHistory: [],
        targets: [],
        settings: ReadingProgressSettingsSnapshot()
    )
    RemoteSyncLogEntryStore(settingsStore: settingsStore).replaceEntries(
        [progressMemorizedVerseLogEntry(id: id, lastUpdated: lastUpdated, sourceDevice: sourceDevice)],
        for: .progress
    )
    RemoteSyncProgressSnapshotService().refreshBaselineFingerprints(settingsStore: settingsStore)
    if let patchNumber {
        RemoteSyncPatchStatusStore(settingsStore: settingsStore).addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                sizeBytes: 1,
                appliedDate: lastUpdated
            ),
            for: .progress
        )
    }
}

/** Creates one accepted Android upsert manifest row for a memorized-verse fixture. */
private func progressMemorizedVerseLogEntry(
    id: UUID,
    lastUpdated: Int64,
    sourceDevice: String
) -> RemoteSyncLogEntry {
    RemoteSyncLogEntry(
        tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
        entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(id)),
        entityID2: .text(""),
        type: .upsert,
        lastUpdated: lastUpdated,
        sourceDevice: sourceDevice
    )
}

/** Creates deterministic remote metadata for one captured Progress patch upload. */
private func progressUploadResult(
    parentID: String,
    patchNumber: Int64,
    schemaVersion: Int = 9
) -> RemoteSyncFile {
    let name = "\(patchNumber).\(schemaVersion).sqlite3.gz"
    return RemoteSyncFile(
        id: "\(parentID)/\(name)",
        name: name,
        size: 0,
        timestamp: 2_000 + patchNumber,
        parentID: parentID,
        mimeType: NextCloudSyncAdapter.gzipMimeType
    )
}

private struct ProgressMemorizedVerseFixture {
    let id: UUID
    let kjvOrdinal: Int
    let memorizedAt: Int64
}

private struct ProgressChapterReadHistoryFixture {
    let id: UUID
    let kjvBookOrdinal: Int
    let chapter: Int
    let cycle: Int
    let readAt: Int64
    let bookInitials: String
    let source: ReadingProgressSource
}

private struct ProgressTargetFixture {
    let id: UUID
    let kjvOrdinalStart: Int
    let kjvOrdinalEnd: Int
    let createdAt: Int64
}

private func seedProgress(
    settingsStore: SettingsStore,
    memorizedVerses: [ProgressMemorizedVerseFixture],
    chapterHistory: [ProgressChapterReadHistoryFixture],
    targets: [ProgressTargetFixture],
    settings: ReadingProgressSettingsSnapshot
) {
    let readingSnapshot = ReadingProgressSnapshot(
        history: chapterHistory.map {
            ReadingProgressHistoryRow(
                id: $0.id,
                bookInitials: $0.bookInitials,
                startOrdinal: 0,
                kjvBookOrdinal: $0.kjvBookOrdinal,
                chapter: $0.chapter,
                cycle: $0.cycle,
                readAt: $0.readAt,
                source: $0.source
            )
        },
        settings: settings
    )
    let memorizationSnapshot = MemorizationProgressSnapshot(
        memorizedVerses: memorizedVerses.map {
            MemorizedVerseProgress(
                id: $0.id,
                kjvOrdinal: $0.kjvOrdinal,
                memorizedAt: $0.memorizedAt,
                ordinalTrust: verifiedAndroidIdentityMetadata(
                    startOrdinal: $0.kjvOrdinal,
                    endOrdinal: $0.kjvOrdinal
                )
            )
        },
        targetRows: targets.map {
            MemorizationTargetRow(
                id: $0.id,
                startOrdinal: $0.kjvOrdinalStart,
                endOrdinal: $0.kjvOrdinalEnd,
                createdAt: $0.createdAt,
                ordinalTrust: verifiedAndroidIdentityMetadata(
                    startOrdinal: $0.kjvOrdinalStart,
                    endOrdinal: $0.kjvOrdinalEnd
                )
            )
        }
    )
    let encoder = JSONEncoder()
    settingsStore.setString(
        ReadingProgressStore.settingsKey,
        value: String(data: try! encoder.encode(readingSnapshot), encoding: .utf8)!
    )
    settingsStore.setString(
        MemorizationProgressStore.settingsKey,
        value: String(data: try! encoder.encode(memorizationSnapshot), encoding: .utf8)!
    )
}

/**
 Creates explicit trust for a test fixture representing validated Android KJVA-identity input.

 - Parameters:
   - startOrdinal: Inclusive source and KJVA start ordinal.
   - endOrdinal: Inclusive source and KJVA end ordinal.
 - Returns: Android-import metadata accepted only when the range is in bounds and ordered.
 - Side effects: Reads bundled canon bounds only.
 - Failure modes: Invalid fixture ranges become unresolved and are suppressed by production code.
 */
private func verifiedAndroidIdentityMetadata(
    startOrdinal: Int,
    endOrdinal: Int
) -> PersistedOrdinalTrustMetadata {
    PersistedOrdinalTrustPolicy.androidImportMetadata(
        sourceVersification: "KJVA",
        sourceOrdinalStart: startOrdinal,
        sourceOrdinalEnd: endOrdinal,
        kjvaOrdinalStart: startOrdinal,
        kjvaOrdinalEnd: endOrdinal
    )
}

private func makeProgressPatchDatabase(
    memorizedVerses: [ProgressMemorizedVerseFixture],
    chapterHistory: [ProgressChapterReadHistoryFixture],
    targets: [ProgressTargetFixture],
    settings: ReadingProgressSettingsSnapshot,
    logEntries: [RemoteSyncLogEntry]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-progress-test-\(UUID().uuidString).sqlite3")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(
        sqlite3_exec(
            db,
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .progress),
            nil,
            nil,
            nil
        ),
        SQLITE_OK
    )
    for row in memorizedVerses {
        let statement = try progressPrepare(
            "INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);",
            db
        )
        bindProgressUUID(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinal))
        sqlite3_bind_int64(statement, 3, row.memorizedAt)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    for row in chapterHistory {
        let statement = try progressPrepare(
            """
            INSERT INTO ChapterReadHistory (id, kjvBookOrdinal, chapter, cycle, readAt, bookInitials, source)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            db
        )
        bindProgressUUID(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvBookOrdinal))
        sqlite3_bind_int(statement, 3, Int32(row.chapter))
        sqlite3_bind_int(statement, 4, Int32(row.cycle))
        sqlite3_bind_int64(statement, 5, row.readAt)
        sqlite3_bind_text(statement, 6, row.bookInitials, -1, progressSyncTestSQLiteTransient)
        sqlite3_bind_text(statement, 7, row.source.rawValue, -1, progressSyncTestSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    for row in targets {
        let statement = try progressPrepare(
            "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
            db
        )
        bindProgressUUID(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinalStart))
        sqlite3_bind_int(statement, 3, Int32(row.kjvOrdinalEnd))
        sqlite3_bind_int64(statement, 4, row.createdAt)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    let settingsRow = RemoteSyncCurrentProgressSettingsRow(
        id: RemoteSyncProgressSnapshotService.globalSettingsID,
        settings: settings
    )
    let settingsStatement = try progressPrepare(
        """
        INSERT INTO GlobalReadingProgressSettings (
            id, autoTrackReading, autoMarkMemorized, memorizeTypeFullWords, memorizeWordVisibility,
            memorizeErrorHeatmap, memorizeScrambleHideUsed, memorizeIncludeReference, activeCycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """,
        db
    )
    bindProgressUUID(settingsRow.id, to: settingsStatement, index: 1)
    sqlite3_bind_int(settingsStatement, 2, settingsRow.autoTrackReading ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 3, settingsRow.autoMarkMemorized ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 4, settingsRow.memorizeTypeFullWords ? 1 : 0)
    sqlite3_bind_text(settingsStatement, 5, settingsRow.memorizeWordVisibility, -1, progressSyncTestSQLiteTransient)
    sqlite3_bind_int(settingsStatement, 6, settingsRow.memorizeErrorHeatmap ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 7, settingsRow.memorizeScrambleHideUsed ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 8, settingsRow.memorizeIncludeReference ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 9, Int32(settingsRow.activeCycle))
    XCTAssertEqual(sqlite3_step(settingsStatement), SQLITE_DONE)
    sqlite3_finalize(settingsStatement)

    for entry in logEntries {
        let statement = try progressPrepare(
            "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?);",
            db
        )
        sqlite3_bind_text(statement, 1, entry.tableName, -1, progressSyncTestSQLiteTransient)
        bindProgressSQLiteValue(entry.entityID1, to: statement, index: 2)
        bindProgressSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, progressSyncTestSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, progressSyncTestSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    return url
}

private func makeProgressPatchArchive(
    patchDatabaseURL: URL,
    sourceDevice: String,
    patchNumber: Int64,
    fileTimestamp: Int64
) throws -> RemoteSyncStagedPatchArchive {
    let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-progress-test-\(UUID().uuidString).sqlite3.gz")
    try archiveData.write(to: archiveURL, options: .atomic)
    return RemoteSyncStagedPatchArchive(
        patch: RemoteSyncDiscoveredPatch(
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: 9,
            file: RemoteSyncFile(
                id: "/progress/\(sourceDevice)/\(patchNumber).9.sqlite3.gz",
                name: "\(patchNumber).9.sqlite3.gz",
                size: Int64(archiveData.count),
                timestamp: fileTimestamp,
                parentID: "/progress/\(sourceDevice)",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        ),
        archiveFileURL: archiveURL
    )
}

/**
 Rewrites singleton identifiers to build otherwise-valid hostile Progress fixtures.

 - Parameters:
   - databaseURL: Writable SQLite fixture created by `makeProgressPatchDatabase`.
   - settingsRowID: Optional replacement for the singleton table row identifier.
   - logEntryID: Optional replacement for matching `LogEntry.entityId1` values.
 - Side Effects: Mutates only the supplied fixture database.
 - Throws: `invalidSQLiteDatabase` when opening, preparing, or updating the fixture fails.
 */
private func rewriteProgressSingletonIdentifiers(
    in databaseURL: URL,
    settingsRowID: UUID?,
    logEntryID: UUID?
) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(database) }

    if let settingsRowID {
        let statement = try progressPrepare(
            "UPDATE GlobalReadingProgressSettings SET id = ?;",
            database
        )
        defer { sqlite3_finalize(statement) }
        bindProgressUUID(settingsRowID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
    }
    if let logEntryID {
        let statement = try progressPrepare(
            "UPDATE LogEntry SET entityId1 = ? WHERE tableName = 'GlobalReadingProgressSettings';",
            database
        )
        defer { sqlite3_finalize(statement) }
        bindProgressUUID(logEntryID, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
    }
}

/** Executes one SQLite fixture mutation and fails visibly if SQLite rejects it. */
private func executeProgressSQL(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
}

private func materializeProgressArchive(_ data: Data) throws -> URL {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-progress-upload-\(UUID().uuidString).sqlite3")
    try gunzipTestData(data).write(to: databaseURL, options: .atomic)
    return databaseURL
}

private func progressSQLiteInteger(_ sql: String, at url: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }
    let statement = try progressPrepare(sql, db)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    return Int(sqlite3_column_int(statement, 0))
}

private func progressPrepare(_ sql: String, _ database: OpaquePointer) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    return statement
}

private func bindProgressUUID(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
    let data = RemoteSyncProgressSnapshotService.uuidBlob(uuid)
    _ = data.withUnsafeBytes {
        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), progressSyncTestSQLiteTransient)
    }
}

private func bindProgressSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
    switch value.kind {
    case .null:
        sqlite3_bind_null(statement, index)
    case .integer:
        sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
    case .real:
        sqlite3_bind_double(statement, index, value.realValue ?? 0)
    case .text:
        sqlite3_bind_text(statement, index, value.textValue ?? "", -1, progressSyncTestSQLiteTransient)
    case .blob:
        let data = value.blobData ?? Data()
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), progressSyncTestSQLiteTransient)
        }
    }
}

private func hex(_ uuid: UUID) -> String {
    RemoteSyncProgressSnapshotService.uuidBlob(uuid).map { String(format: "%02x", $0) }.joined()
}
