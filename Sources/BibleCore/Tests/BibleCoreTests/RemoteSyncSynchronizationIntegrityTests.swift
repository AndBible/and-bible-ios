import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

/**
 End-to-end integrity tests for remote-sync bootstrap, initial transfer, and cursor publication.

 These tests exercise persisted restart state and transaction boundaries through the production
 synchronization services. Remote behavior is deterministic and in-memory; no WebDAV or simulator
 dependency participates in the assertions.
 */
final class RemoteSyncSynchronizationIntegrityTests: XCTestCase {
    /**
     Verifies an unknown persisted bootstrap phase fails closed before incremental discovery.

     The stored marker remains valid, but an older build cannot prove what work a future phase still
     requires. Synchronization must surface the unsupported value instead of treating the category
     as ready and must not list remote patch folders.
     */
    func testUnknownBootstrapPhaseFailsClosedBeforePatchDiscovery() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let secretFileName = "device-known-ios-device-secret"

        settingsStore.setString(
            "remote_sync.readingplans.syncId",
            value: syncFolderID
        )
        settingsStore.setString(
            "remote_sync.readingplans.deviceFolderId",
            value: "\(syncFolderID)/ios-device"
        )
        settingsStore.setString(
            "remote_sync.readingplans.nextCloudSecretFile",
            value: secretFileName
        )
        settingsStore.setString(
            "remote_sync.readingplans.bootstrapPhase",
            value: "futureInitialExchange"
        )
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: secretFileName
        )

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )
        do {
            _ = try await service.synchronize(
                .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected an unknown persisted phase to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncBootstrapError,
                .unsupportedPersistedPhase("futureInitialExchange")
            )
        }

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(
            events,
            [
                .isSyncFolderKnown(
                    syncFolderID: syncFolderID,
                    secretFileName: secretFileName
                )
            ]
        )
    }

    /**
     Verifies a missing adopted baseline remains pending and resumes after a process restart.

     The first run creates the marker/device folder but finds no initial backup. A new service then
     reuses those identifiers, restores the newly available backup, publishes patch zero, and becomes
     ready without duplicating either remote setup operation.
     */
    func testPendingAdoptionRetriesInitialRestoreWithoutDuplicatingRemoteSetup() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "\(syncFolderID)/ios-device"
        let secretFileName = "device-known-ios-device-secret"

        await adapter.setMakeKnownResponse(secretFileName)
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let firstService = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_000_000 }
        )

        do {
            _ = try await firstService.adoptRemoteFolderAndSynchronize(
                for: .readingPlans,
                remoteFolderID: syncFolderID,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected the first adoption attempt to require an initial backup")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncSynchronizationError,
                .missingInitialBackup(.readingPlans)
            )
        }

        let pendingState = stateStore.bootstrapState(for: .readingPlans)
        XCTAssertEqual(
            pendingState,
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: secretFileName,
                phase: .awaitingRemoteInitialRestore
            )
        )

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchive = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        let initialFile = RemoteSyncFile(
            id: "\(syncFolderID)/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialArchive.count),
            timestamp: 2_000,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let deviceFolder = RemoteSyncFile(
            id: deviceFolderID,
            name: "ios-device",
            size: 0,
            timestamp: 1_000,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )

        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.enqueueListFilesResult([deviceFolder])
        await adapter.enqueueListFilesResult([])
        await adapter.setDownloadData(initialArchive, forID: initialFile.id)

        let restartedService = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_000_000 }
        )
        let outcome = try await restartedService.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected the restarted adoption to synchronize")
        }

        XCTAssertEqual(report.bootstrapState.phase, .ready)
        XCTAssertNotNil(report.initialRestoreReport)
        XCTAssertEqual(report.lastPatchWritten, 4_000_000)
        XCTAssertEqual(report.lastSynchronized, 4_000_000)
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans).phase, .ready)
        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: initialFile.size,
                    appliedDate: initialFile.timestamp
                )
            ]
        )

        let events = await adapter.eventsSnapshot()
        let markerCreationCount = events.filter {
            if case .makeKnown = $0 { return true }
            return false
        }.count
        let deviceFolderCreationCount = events.filter {
            if case .createFolder(name: "ios-device", parentID: syncFolderID) = $0 { return true }
            return false
        }.count
        XCTAssertEqual(markerCreationCount, 1)
        XCTAssertEqual(deviceFolderCreationCount, 1)
    }

    /**
     Verifies cancellation at adoption publication keeps the new-destination reset boundary.

     The checkpoint fires after restore, metadata/fingerprint refresh, patch zero, progress, and the
     ready phase have all staged. Cancellation must preserve the old graph and accepted bookkeeping,
     keep the adopted folder pending for retry, and must not resurrect cursors from the old destination.
     */
    func testAdoptionPublicationCancellationRetainsPendingStateAndPreviousGeneration() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "\(syncFolderID)/ios-device"

        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let localPlan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        localPlan.currentDay = 1
        try modelContext.save()

        let originalProgress = RemoteSyncProgressState(
            lastPatchWritten: 700,
            lastSynchronized: 800,
            disabledForVersion: 9
        )
        stateStore.setProgressState(originalProgress, for: .readingPlans)
        let originalStatus = RemoteSyncPatchStatus(
            sourceDevice: "existing-device",
            patchNumber: 3,
            sizeBytes: 123,
            appliedDate: 600
        )
        patchStatusStore.addStatus(originalStatus, for: .readingPlans)
        let originalLogEntry = RemoteSyncLogEntry(
            tableName: "ReadingPlan",
            entityID1: .blob(readingPlanUUIDBlob(localPlan.id)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: 500,
            sourceDevice: "existing-device"
        )
        logEntryStore.addEntry(originalLogEntry, for: .readingPlans)
        fingerprintStore.setFingerprint(
            "existing-fingerprint",
            for: .readingPlans,
            tableName: "ReadingPlan",
            entityID1: .blob(readingPlanUUIDBlob(localPlan.id)),
            entityID2: .text("")
        )
        let originalFingerprintRows = Dictionary(
            uniqueKeysWithValues: settingsStore.entries(
                withPrefix: fingerprintStore.prefix(for: .readingPlans)
            ).map { ($0.key, $0.value) }
        )

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "a2000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 8
                )
            ],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchive = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        let initialFile = RemoteSyncFile(
            id: "\(syncFolderID)/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialArchive.count),
            timestamp: 2_000,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )

        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.setDownloadData(initialArchive, forID: initialFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_500_000 }
        )

        do {
            _ = try await service.adoptRemoteFolderAndSynchronize(
                for: .readingPlans,
                remoteFolderID: syncFolderID,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: RemoteSyncCategory.readingPlans.currentSchemaVersion,
                initialPublishCheckpoint: { throw CancellationError() }
            )
            XCTFail("Expected cancellation at the initial publication boundary")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let restoredPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(restoredPlans.count, 1)
        XCTAssertEqual(restoredPlans[0].currentDay, 1)
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans).phase, .awaitingRemoteInitialRestore)
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans),
            RemoteSyncProgressState(
                lastPatchWritten: nil,
                lastSynchronized: nil,
                disabledForVersion: nil
            )
        )
        XCTAssertEqual(patchStatusStore.statuses(for: .readingPlans), [originalStatus])
        XCTAssertEqual(logEntryStore.entries(for: .readingPlans), [originalLogEntry])
        let retainedFingerprintRows = Dictionary(
            uniqueKeysWithValues: settingsStore.entries(
                withPrefix: fingerprintStore.prefix(for: .readingPlans)
            ).map { ($0.key, $0.value) }
        )
        XCTAssertEqual(retainedFingerprintRows, originalFingerprintRows)
    }

    /**
     Verifies local initial-upload acceptance publishes patch zero and readiness together.

     A successful create uploads one full baseline, records its fingerprint and patch-zero state,
     clears the pending-upload phase, and then saves the ready-pass cursor. The expected acceptance
     timestamp is derived from the mutation-time log high-water mark, matching Android's monotonic
     logical sequence even when the injected wall clock is older than retained local mutations.
     */
    func testSuccessfulLocalInitialUploadPublishesReadyBaseline() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "\(syncFolderID)/ios-device"

        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.currentDay = 2
        try modelContext.save()
        let progressBeforeUpload = stateStore.progressState(for: .readingPlans)
        let expectedAcceptedTimestamp = try RemoteSyncLogicalSequence.nextTimestamp(
            now: 5_000_000,
            highWatermarks: logEntryStore.entries(for: .readingPlans).map(\.lastUpdated)
                + patchStatusStore.statuses(for: .readingPlans).map(\.appliedDate)
                + [
                    progressBeforeUpload.lastPatchWritten,
                    progressBeforeUpload.lastSynchronized,
                ].compactMap { $0 }
        )

        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: syncFolderID,
                name: "org.andbible.ios-sync-readingplans",
                size: 0,
                timestamp: 1_000,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
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
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_100,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 5_000_000 }
        )
        let report = try await service.createRemoteFolderAndSynchronize(
            for: .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let readyState = stateStore.bootstrapState(for: .readingPlans)
        XCTAssertEqual(readyState.phase, .ready)
        XCTAssertEqual(report.bootstrapState, readyState)
        XCTAssertEqual(report.lastPatchWritten, expectedAcceptedTimestamp)
        XCTAssertEqual(report.lastSynchronized, 5_000_000)
        XCTAssertEqual(patchStatusStore.statuses(for: .readingPlans).map(\.patchNumber), [0])
        XCTAssertTrue(logEntryStore.entries(for: .readingPlans).isEmpty)
        XCTAssertNotNil(
            try RemoteSyncReadingPlanSnapshotService().acceptedRowsByKey(
                settingsStore: settingsStore
            )
        )
        XCTAssertNotNil(
            fingerprintStore.fingerprint(
                for: .readingPlans,
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(plan.id)),
                entityID2: .text("")
            )
        )
    }

    /**
     Verifies a post-upload local acceptance failure leaves the complete old generation retryable.

     The archive reaches the backend, then the injected mutation rejects acceptance after patch-zero,
     progress, fingerprints, and ready state have staged. The transaction must restore every prior
     value while retaining the exact prepared archive and acceptance metadata. A retry after a newer
     local edit must reuse those bytes, accept only the original generation, and then remove the outbox.
     */
    func testInitialUploadAcceptanceFailureRetainsPendingStateAndPreviousBaseline() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let pendingState = RemoteSyncBootstrapState(
            syncFolderID: syncFolderID,
            deviceFolderID: "\(syncFolderID)/ios-device",
            secretFileName: "device-known-ios-device-secret",
            phase: .awaitingLocalInitialUpload
        )
        stateStore.setBootstrapState(pendingState, for: .readingPlans)

        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.currentDay = 3
        try modelContext.save()
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let uploadedGeneration = snapshotService.acceptedGeneration(
            from: try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        )
        let planKey = try XCTUnwrap(
            uploadedGeneration.rowsByKey.first(where: { _, row in
                row.tableName == "ReadingPlan" && row.entityID1 == .blob(readingPlanUUIDBlob(plan.id))
            })?.key
        )

        let originalProgress = RemoteSyncProgressState(
            lastPatchWritten: 111,
            lastSynchronized: 222,
            disabledForVersion: 7
        )
        stateStore.setProgressState(originalProgress, for: .readingPlans)
        let originalStatus = RemoteSyncPatchStatus(
            sourceDevice: "existing-device",
            patchNumber: 4,
            sizeBytes: 444,
            appliedDate: 333
        )
        patchStatusStore.addStatus(originalStatus, for: .readingPlans)
        let originalLogEntry = RemoteSyncLogEntry(
            tableName: "ReadingPlan",
            entityID1: .blob(readingPlanUUIDBlob(plan.id)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: 222,
            sourceDevice: "existing-device"
        )
        logEntryStore.addEntry(originalLogEntry, for: .readingPlans)
        fingerprintStore.setFingerprint(
            "previous-baseline",
            for: .readingPlans,
            tableName: "ReadingPlan",
            entityID1: .blob(readingPlanUUIDBlob(plan.id)),
            entityID2: .text("")
        )
        let originalFingerprintRows = Dictionary(
            uniqueKeysWithValues: settingsStore.entries(
                withPrefix: fingerprintStore.prefix(for: .readingPlans)
            ).map { ($0.key, $0.value) }
        )

        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 6_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-upload-acceptance-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryDirectory = testDirectory.appendingPathComponent("staging", isDirectory: true)
        let retryDirectory = testDirectory.appendingPathComponent("retry", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: retryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let uploadService = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            temporaryDirectory: temporaryDirectory,
            retryDirectory: retryDirectory,
            nowProvider: { 7_000_000 }
        )
        var readyState = pendingState
        readyState.phase = .ready

        do {
            _ = try await uploadService.uploadInitialBackup(
                for: .readingPlans,
                bootstrapState: pendingState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: RemoteSyncCategory.readingPlans.currentSchemaVersion,
                acceptedBaselineMutations: {
                    stateStore.setBootstrapState(readyState, for: .readingPlans)
                    throw RemoteSyncSynchronizationIntegrityTestFailure.initialUploadAcceptanceRejected
                }
            )
            XCTFail("Expected local initial-upload acceptance to fail")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncSynchronizationIntegrityTestFailure,
                .initialUploadAcceptanceRejected
            )
        }

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFiles.count, 1)
        let publishedArchiveURL = testDirectory.appendingPathComponent("published-initial.sqlite3.gz")
        let publishedDatabaseURL = testDirectory.appendingPathComponent("published-initial.sqlite3")
        try XCTUnwrap(uploadedFiles.first).data.write(to: publishedArchiveURL, options: .atomic)
        try RemoteSyncBoundedFileIO.inflateGzip(
            at: publishedArchiveURL,
            to: publishedDatabaseURL,
            maximumCompressedByteCount: 64 * 1_024 * 1_024,
            maximumExpandedByteCount: 256 * 1_024 * 1_024
        )
        XCTAssertNoThrow(
            try RemoteSyncInitialBackupUploadService.validateBuiltInitialBackupDatabase(
                at: publishedDatabaseURL,
                category: .readingPlans
            )
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans), pendingState)
        XCTAssertEqual(stateStore.progressState(for: .readingPlans), originalProgress)
        XCTAssertEqual(patchStatusStore.statuses(for: .readingPlans), [originalStatus])
        XCTAssertEqual(logEntryStore.entries(for: .readingPlans), [originalLogEntry])
        let retainedFingerprintRows = Dictionary(
            uniqueKeysWithValues: settingsStore.entries(
                withPrefix: fingerprintStore.prefix(for: .readingPlans)
            ).map { ($0.key, $0.value) }
        )
        XCTAssertEqual(retainedFingerprintRows, originalFingerprintRows)
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedFiles.isEmpty)
        let retainedRetryFiles = try FileManager.default.contentsOfDirectory(
            at: retryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(retainedRetryFiles.count, 2)

        var mismatchedState = pendingState
        mismatchedState.syncFolderID = "/replacement-readingplans"
        mismatchedState.deviceFolderID = "/replacement-readingplans/ios-device"
        do {
            _ = try await uploadService.uploadInitialBackup(
                for: .readingPlans,
                bootstrapState: mismatchedState,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected the destination-bound initial generation to fail closed")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncInitialBackupUploadError,
                .pendingUploadDestinationMismatch
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: retryDirectory,
                includingPropertiesForKeys: nil
            ).count,
            2
        )
        let uploadsAfterMismatch = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadsAfterMismatch.count, 1)

        let currentPlan = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<ReadingPlan>()).first(where: { $0.id == plan.id })
        )
        currentPlan.currentDay = 9
        try modelContext.save()
        let newerGeneration = snapshotService.acceptedGeneration(
            from: try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        )
        XCTAssertNotEqual(
            newerGeneration.fingerprintsByKey[planKey],
            uploadedGeneration.fingerprintsByKey[planKey]
        )

        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 6_500,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        _ = try await uploadService.uploadInitialBackup(
            for: .readingPlans,
            bootstrapState: pendingState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: RemoteSyncCategory.readingPlans.currentSchemaVersion,
            acceptedBaselineMutations: {
                stateStore.setBootstrapState(readyState, for: .readingPlans)
            }
        )

        let completedUploads = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(completedUploads.count, 2)
        XCTAssertEqual(completedUploads[0].data, completedUploads[1].data)
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans), readyState)
        XCTAssertEqual(
            try snapshotService.acceptedRowsByKey(settingsStore: settingsStore),
            uploadedGeneration.rowsByKey
        )
        XCTAssertEqual(
            fingerprintStore.fingerprint(
                for: .readingPlans,
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(plan.id)),
                entityID2: .text("")
            ),
            uploadedGeneration.fingerprintsByKey[planKey]
        )
        XCTAssertTrue(logEntryStore.entries(for: .readingPlans).isEmpty)
        let remainingRetryFiles = try FileManager.default.contentsOfDirectory(
            at: retryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingRetryFiles.isEmpty)
    }

    /**
     Verifies initial backup construction rejects dirty contexts for upload and manual export.

     Both entry points share the strict read batch. Pending graph mutations must fail before remote
     upload or temporary database creation, preserving the persisted pending-upload state.
     */
    func testInitialBackupBuildersRejectDirtyContextBeforeProducingArtifacts() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
        let pendingState = RemoteSyncBootstrapState(
            syncFolderID: "/org.andbible.ios-sync-readingplans",
            deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device",
            secretFileName: "device-known-ios-device-secret",
            phase: .awaitingLocalInitialUpload
        )
        stateStore.setBootstrapState(pendingState, for: .readingPlans)

        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-strict-build-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        modelContext.insert(Setting(key: "unsaved-test-setting", value: "pending"))
        let uploadService = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            temporaryDirectory: temporaryDirectory
        )

        do {
            _ = try await uploadService.uploadInitialBackup(
                for: .readingPlans,
                bootstrapState: pendingState,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected upload construction to reject a dirty context")
        } catch {
            XCTAssertEqual(error as? SettingsStoreAtomicBatchError, .pendingModelChanges)
        }

        do {
            _ = try RemoteSyncInitialBackupUploadService.buildAndroidDatabaseBackupDatabase(
                for: .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: RemoteSyncCategory.readingPlans.currentSchemaVersion,
                temporaryDirectory: temporaryDirectory
            )
            XCTFail("Expected manual export construction to reject a dirty context")
        } catch {
            XCTAssertEqual(error as? SettingsStoreAtomicBatchError, .pendingModelChanges)
        }

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadedFiles.isEmpty)
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans), pendingState)
        let stagedFiles = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    /**
     Verifies an outbound database that inbound restore would reject cannot pass publication validation.

     The fixture is valid SQLite but lacks Android Room identity and schema metadata. The shared
     validator must return the typed outbound-contract error before any compression or transport
     operation can be attempted by the caller.
     */
    func testInitialBackupPublicationValidationRejectsInboundIncompatibleDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-invalid-outbound-contract-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("invalid.sqlite3")

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            return XCTFail("Expected SQLite fixture database")
        }
        XCTAssertEqual(
            sqlite3_exec(database, "CREATE TABLE unrelated(id INTEGER PRIMARY KEY);", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)

        XCTAssertThrowsError(
            try RemoteSyncInitialBackupUploadService.validateBuiltInitialBackupDatabase(
                at: databaseURL,
                category: .readingPlans
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncInitialBackupUploadError,
                .invalidBuiltDatabaseContract(.readingPlans)
            )
        }
    }

    /**
     Verifies explicit destination replacement abandons only unaccepted publication state.

     The reset boundary uses category-owned marker and path contracts, removes sparse and initial
     outbox artifacts, and preserves both user rows and the accepted baseline so local rows are
     re-diffed for the replacement destination.
     */
    func testDestinationReplacementAbandonsPendingPublicationsWithoutDeletingAcceptedState() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let plan = ReadingPlan(planCode: "replacement-test", currentDay: 4)
        modelContext.insert(plan)
        try modelContext.save()

        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-replacement-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        let outboxDirectory = testDirectory.appendingPathComponent("reading-outbox", isDirectory: true)
        let retryDirectory = testDirectory.appendingPathComponent("initial-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }
        try Data("pending-patch".utf8).write(
            to: outboxDirectory.appendingPathComponent("patch.sqlite3.gz")
        )
        let initialArchiveURL = RemoteSyncInitialBackupUploadService.pendingArchiveURL(
            for: .readingPlans,
            retryDirectory: retryDirectory
        )
        let initialMetadataURL = RemoteSyncInitialBackupUploadService.pendingMetadataURL(
            for: .readingPlans,
            retryDirectory: retryDirectory
        )
        try Data("initial".utf8).write(to: initialArchiveURL)
        try Data("metadata".utf8).write(to: initialMetadataURL)
        settingsStore.setString(
            RemoteSyncReadingPlanPatchUploadService.pendingUploadKey,
            value: "pending-generation"
        )
        settingsStore.setString(
            RemoteSyncReadingPlanSnapshotService.acceptedBaselineKey,
            value: "accepted-generation"
        )

        let resetService = RemoteSyncResetService(
            settingsStore: settingsStore,
            fileManager: .default,
            outboxDirectories: [.readingPlans: outboxDirectory],
            initialUploadRetryDirectory: retryDirectory
        )
        try resetService.abandonPendingPublications(for: .readingPlans)

        XCTAssertNil(settingsStore.getString(RemoteSyncReadingPlanPatchUploadService.pendingUploadKey))
        XCTAssertEqual(
            settingsStore.getString(RemoteSyncReadingPlanSnapshotService.acceptedBaselineKey),
            "accepted-generation"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outboxDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initialArchiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: initialMetadataURL.path))
        XCTAssertEqual(try modelContext.fetchCount(FetchDescriptor<ReadingPlan>()), 1)
    }

    /**
     Verifies durable outbound acceptance completes before a newer inbound generation is replayed.

     A reading-plan patch is uploaded remotely but rejected at its local acceptance checkpoint. The
     next synchronization must resume that exact generation first, then apply a newer Android patch.
     The inbound fixture advances from the actual mutation-time journal high-water mark rather than
     assuming the later upload clock owns row time. The inbound row, log timestamp, fingerprint, and
     accepted identity must remain authoritative.
     */
    func testPendingOutboundAcceptancePrecedesInboundReplay() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "\(syncFolderID)/ios-device"
        let secretFileName = "device-known-ios-device-secret"
        let bootstrapState = RemoteSyncBootstrapState(
            syncFolderID: syncFolderID,
            deviceFolderID: deviceFolderID,
            secretFileName: secretFileName,
            phase: .ready
        )
        stateStore.setBootstrapState(bootstrapState, for: .readingPlans)
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: secretFileName
        )

        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.currentDay = 1
        try modelContext.save()
        let initialSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        try settingsStore.performAtomicBatch(in: modelContext) {
            try snapshotService.acceptBaselineFingerprints(
                snapshotService.acceptedGeneration(from: initialSnapshot),
                settingsStore: settingsStore
            )
            logEntryStore.clearCategory(.readingPlans)
        }

        plan.currentDay = 2
        try modelContext.save()
        let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-pending-before-inbound-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagingDirectory = testDirectory.appendingPathComponent("staging", isDirectory: true)
        let outboxDirectory = testDirectory.appendingPathComponent("outbox", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        await adapter.enqueueListFilesResult([])
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/pending-reading-plan-patch",
                name: "pending-reading-plan-patch",
                size: 0,
                timestamp: 20_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let rejectingUploader = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            temporaryDirectory: stagingDirectory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 20_000 },
            finalAcceptanceCheckpoint: {
                throw RemoteSyncSynchronizationIntegrityTestFailure.pendingPatchAcceptanceRejected
            }
        )
        do {
            _ = try await rejectingUploader.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected pending patch local acceptance to fail")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncSynchronizationIntegrityTestFailure,
                .pendingPatchAcceptanceRejected
            )
        }

        let uploads = await adapter.uploadedFilesSnapshot()
        let pendingUpload = try XCTUnwrap(uploads.last)
        let pendingMutationTimestamp = try XCTUnwrap(
            logEntryStore.entries(for: .readingPlans).map(\.lastUpdated).max()
        )
        let inboundTimestamp = try RemoteSyncLogicalSequence.nextTimestamp(
            now: 30_000,
            highWatermarks: [pendingMutationTimestamp]
        )
        let synchronizationTimestamp = try RemoteSyncLogicalSequence.nextTimestamp(
            now: 40_000,
            highWatermarks: [inboundTimestamp]
        )
        let pendingRemoteFile = RemoteSyncFile(
            id: "\(deviceFolderID)/\(pendingUpload.name)",
            name: pendingUpload.name,
            size: Int64(pendingUpload.data.count),
            timestamp: 20_000,
            parentID: deviceFolderID,
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        await adapter.setDownloadData(pendingUpload.data, forID: pendingRemoteFile.id)

        let inboundDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                AndroidReadingPlanRow(
                    id: plan.id,
                    planCode: plan.planCode,
                    startDate: plan.startDate,
                    currentDay: 3
                )
            ],
            statuses: [],
            logEntries: [
                AndroidReadingPlanLogEntryRow(
                    tableName: "ReadingPlan",
                    entityID1: .blob(readingPlanUUIDBlob(plan.id)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: inboundTimestamp,
                    sourceDevice: "android-device"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: inboundDatabaseURL) }
        let inboundArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: inboundDatabaseURL,
            sourceDevice: "android-device",
            patchNumber: 1,
            fileTimestamp: inboundTimestamp
        )
        defer { try? FileManager.default.removeItem(at: inboundArchive.archiveFileURL) }
        let inboundArchiveData = try Data(contentsOf: inboundArchive.archiveFileURL)
        await adapter.setDownloadData(inboundArchiveData, forID: inboundArchive.patch.file.id)
        let androidDeviceFolder = RemoteSyncFile(
            id: inboundArchive.patch.file.parentID,
            name: "android-device",
            size: 0,
            timestamp: inboundTimestamp,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )

        await adapter.enqueueListFilesResult([pendingRemoteFile])
        await adapter.enqueueListFilesResult([androidDeviceFolder])
        await adapter.enqueueListFilesResult([inboundArchive.patch.file])
        let eventCountBeforeSynchronization = await adapter.eventsSnapshot().count
        let acceptingUploader = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            temporaryDirectory: stagingDirectory,
            outboxDirectory: outboxDirectory,
            nowProvider: { synchronizationTimestamp }
        )
        let synchronizationService = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            readingPlanPatchUploadService: acceptingUploader,
            nowProvider: { synchronizationTimestamp }
        )
        let outcome = try await synchronizationService.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected ready-state synchronization")
        }

        let restoredPlan = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<ReadingPlan>()).first(where: { $0.id == plan.id })
        )
        XCTAssertEqual(restoredPlan.currentDay, 3)
        let acceptedEntries = logEntryStore.entries(for: .readingPlans)
        XCTAssertEqual(acceptedEntries.count, 1)
        XCTAssertEqual(acceptedEntries.first?.lastUpdated, inboundTimestamp)
        XCTAssertEqual(acceptedEntries.first?.sourceDevice, "android-device")
        let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let acceptedBaseline = try XCTUnwrap(
            snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
        )
        XCTAssertEqual(
            acceptedBaseline.generation.fingerprintsByKey,
            currentSnapshot.fingerprintsByKey
        )
        XCTAssertEqual(report.lastSynchronized, synchronizationTimestamp)

        let synchronizationEvents = Array(
            (await adapter.eventsSnapshot()).dropFirst(eventCountBeforeSynchronization)
        )
        let pendingDownloadIndex = try XCTUnwrap(
            synchronizationEvents.firstIndex(of: .download(id: pendingRemoteFile.id))
        )
        let inboundDiscoveryIndex = try XCTUnwrap(
            synchronizationEvents.firstIndex { event in
                if case .listFiles(let parentIDs, _, let mimeType, _) = event {
                    return parentIDs == [syncFolderID]
                        && mimeType == NextCloudSyncAdapter.folderMimeType
                }
                return false
            }
        )
        XCTAssertLessThan(pendingDownloadIndex, inboundDiscoveryIndex)
    }

    /**
    Verifies cancellation after discovery starts retains Android's persisted attempt-start cursor.

    Discovery is held after the attempt samples and persists its timestamp. Cancelling and releasing
    the request must throw `CancellationError` while retaining that pre-list cursor. The obsolete
    disabled-version gate clears before transport so this build can retry its current Android schema.
     */
    func testCancellationDuringDiscoveryPreservesPreviousSynchronizationCursor() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let secretFileName = "device-known-ios-device-secret"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: "\(syncFolderID)/ios-device",
                secretFileName: secretFileName
            ),
            for: .readingPlans
        )
        let originalProgress = RemoteSyncProgressState(
            lastPatchWritten: 100,
            lastSynchronized: 200,
            disabledForVersion: 3
        )
        stateStore.setProgressState(originalProgress, for: .readingPlans)

        let adapter = BlockingRemoteSyncDiscoveryAdapter(
            syncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
        var sampledTimestamps: [Int64] = []
        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: {
                sampledTimestamps.append(8_000_000)
                return 8_000_000
            }
        )

        let synchronizationTask = Task {
            try await service.synchronize(
                .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilDiscoveryStarts()
        synchronizationTask.cancel()
        await adapter.releaseDiscovery()

        do {
            _ = try await synchronizationTask.value
            XCTFail("Expected cancellation after discovery started")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(sampledTimestamps, [8_000_000])
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans),
            RemoteSyncProgressState(
                lastPatchWritten: 100,
                lastSynchronized: 8_000_000,
                disabledForVersion: nil
            )
        )
    }

    /**
    Verifies a repeated discovery failure retains Android's persisted zero retry cursor.

    Both attempts discover patch two without patch one. The first uses the old incremental lower
    bound, then the service persists zero before retrying without a lower bound. A repeated failure
    must retain zero so the next synchronization performs another complete discovery.
     */
    func testDiscoveryFailureAfterRetryFromZeroPreservesPreviousSynchronizationCursor() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let secretFileName = "device-known-ios-device-secret"
        let oldCursor: Int64 = 900_000
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: "\(syncFolderID)/ios-device",
                secretFileName: secretFileName
            ),
            for: .readingPlans
        )
        let originalProgress = RemoteSyncProgressState(
            lastPatchWritten: 700,
            lastSynchronized: oldCursor,
            disabledForVersion: 4
        )
        stateStore.setProgressState(originalProgress, for: .readingPlans)

        let remoteDeviceFolder = RemoteSyncFile(
            id: "\(syncFolderID)/pixel",
            name: "pixel",
            size: 0,
            timestamp: 1_000,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let skippedPatch = RemoteSyncFile(
            id: "\(remoteDeviceFolder.id)/2.1.sqlite3.gz",
            name: "2.1.sqlite3.gz",
            size: 10,
            timestamp: 2_000,
            parentID: remoteDeviceFolder.id,
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
        await adapter.enqueueListFilesResult([remoteDeviceFolder])
        await adapter.enqueueListFilesResult([skippedPatch])
        await adapter.enqueueListFilesResult([remoteDeviceFolder])
        await adapter.enqueueListFilesResult([skippedPatch])

        var sampledTimestamps: [Int64] = []
        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: {
                let value = Int64(9_000_000 + sampledTimestamps.count)
                sampledTimestamps.append(value)
                return value
            }
        )

        do {
            _ = try await service.synchronize(
                .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected repeated skipped-patch discovery to fail")
        } catch {
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .patchFilesSkipped)
        }

        XCTAssertEqual(sampledTimestamps, [9_000_000])
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans),
            RemoteSyncProgressState(
                lastPatchWritten: 700,
                lastSynchronized: 0,
                disabledForVersion: nil
            )
        )
        let events = await adapter.eventsSnapshot()
        var patchListingLowerBounds: [Date?] = []
        for event in events {
            if case .listFiles(_, _, let mimeType, let modifiedAtLeast) = event, mimeType == nil {
                patchListingLowerBounds.append(modifiedAtLeast)
            }
        }
        XCTAssertEqual(patchListingLowerBounds.count, 2)
        XCTAssertEqual(
            patchListingLowerBounds[0],
            Date(timeIntervalSince1970: TimeInterval(oldCursor) / 1_000.0)
        )
        XCTAssertNil(patchListingLowerBounds[1])
    }

    /**
     Verifies success advances the cursor to the attempt-start timestamp, not a later clock sample.

     No-op outbound preflight avoids backend publication work. Persisting the attempt-start value
     preserves Android's guarantee that patches arriving during the run remain visible next pass.
     */
    func testSuccessfulSynchronizationPersistsAttemptStartTimestamp() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let secretFileName = "device-known-ios-device-secret"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: "\(syncFolderID)/ios-device",
                secretFileName: secretFileName
            ),
            for: .readingPlans
        )
        stateStore.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 123,
                lastSynchronized: 456,
                disabledForVersion: 5
            ),
            for: .readingPlans
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
        await adapter.enqueueListFilesResult([])
        var sampledTimestamps: [Int64] = []
        let suppliedTimestamps: [Int64] = [10_000_000, 10_000_500]
        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: {
                let index = min(sampledTimestamps.count, suppliedTimestamps.count - 1)
                let value = suppliedTimestamps[index]
                sampledTimestamps.append(value)
                return value
            }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected ready-state synchronization")
        }

        XCTAssertEqual(sampledTimestamps, [10_000_000])
        XCTAssertEqual(report.lastSynchronized, 10_000_000)
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans),
            RemoteSyncProgressState(
                lastPatchWritten: 123,
                lastSynchronized: 10_000_000,
                disabledForVersion: nil
            )
        )
    }

    /**
    Verifies a successful retry-from-zero retains Android's persisted full-discovery cursor.

    The first attempt discovers a skipped patch and the second intentionally uses a zero discovery
    baseline. Success retains that durable zero so the next synchronization performs one more complete
    discovery instead of restoring the earlier high-water mark during a regressed wall clock.
     */
    func testSuccessfulSynchronizationRetainsCursorWhenWallClockRegresses() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let secretFileName = "device-known-ios-device-secret"
        let previousCursor: Int64 = 20_000_000
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: "\(syncFolderID)/ios-device",
                secretFileName: secretFileName
            ),
            for: .readingPlans
        )
        stateStore.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 123,
                lastSynchronized: previousCursor
            ),
            for: .readingPlans
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: secretFileName
        )
        let remoteDeviceFolder = RemoteSyncFile(
            id: "\(syncFolderID)/pixel",
            name: "pixel",
            size: 0,
            timestamp: 1_000,
            parentID: syncFolderID,
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let skippedPatch = RemoteSyncFile(
            id: "\(remoteDeviceFolder.id)/2.1.sqlite3.gz",
            name: "2.1.sqlite3.gz",
            size: 10,
            timestamp: 2_000,
            parentID: remoteDeviceFolder.id,
            mimeType: NextCloudSyncAdapter.gzipMimeType
        )
        await adapter.enqueueListFilesResult([remoteDeviceFolder])
        await adapter.enqueueListFilesResult([skippedPatch])
        await adapter.enqueueListFilesResult([])
        var sampledTimestamps: [Int64] = []
        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: {
                sampledTimestamps.append(10_000_000)
                return 10_000_000
            }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected ready-state synchronization")
        }

        XCTAssertEqual(sampledTimestamps, [10_000_000])
        XCTAssertEqual(report.lastSynchronized, 0)
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans).lastSynchronized,
            0
        )
    }

    /**
     Verifies logical mutation timestamps advance under equal clocks, regressions, and rapid writes.

     Each allocation is strictly greater than all accepted and pending high-water marks. Exhaustion is
     fail-visible rather than wrapping into Android's negative signed timestamp domain.
     */
    func testLogicalMutationTimestampAllocationAdvancesPastEveryHighWaterMark() throws {
        let first = try RemoteSyncLogicalSequence.nextTimestamp(
            now: 1_000,
            highWatermarks: [999, 1_000, 1_000]
        )
        let second = try RemoteSyncLogicalSequence.nextTimestamp(
            now: 900,
            highWatermarks: [first, first]
        )
        let third = try RemoteSyncLogicalSequence.nextTimestamp(
            now: second,
            highWatermarks: [first, second]
        )

        XCTAssertEqual([first, second, third], [1_001, 1_002, 1_003])
        XCTAssertThrowsError(
            try RemoteSyncLogicalSequence.nextTimestamp(
                now: 0,
                highWatermarks: [Int64.max]
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncLogicalSequenceError, .timestampExhausted)
        }
    }

    /**
     Verifies either half of an interrupted initial outbox pair is discarded before transport.

     An archive-only pair models process death between archive and metadata writes. A metadata-only
     pair models process death during post-acceptance cleanup. Both cases must rebuild one complete
     generation, upload it successfully, and leave no retry artifact after local acceptance.
     */
    func testInitialUploadRecoversPartialArchiveMetadataPairs() async throws {
        for orphanArchive in [true, false] {
            let container = try makeReadingPlanRestoreModelContainer()
            let modelContext = ModelContext(container)
            let settingsStore = SettingsStore(modelContext: modelContext)
            let adapter = RemoteSyncMockAdapter()
            let syncFolderID = "/org.andbible.ios-sync-readingplans"
            let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "remote-sync-partial-initial-\(UUID().uuidString)",
                isDirectory: true
            )
            let stagingDirectory = testDirectory.appendingPathComponent("staging", isDirectory: true)
            let retryDirectory = testDirectory.appendingPathComponent("retry", isDirectory: true)
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: retryDirectory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: testDirectory) }

            let orphanURL = orphanArchive
                ? RemoteSyncInitialBackupUploadService.pendingArchiveURL(
                    for: .readingPlans,
                    retryDirectory: retryDirectory
                )
                : RemoteSyncInitialBackupUploadService.pendingMetadataURL(
                    for: .readingPlans,
                    retryDirectory: retryDirectory
                )
            try Data("interrupted-generation".utf8).write(to: orphanURL, options: .atomic)
            await adapter.enqueueUploadResult(
                RemoteSyncFile(
                    id: "\(syncFolderID)/initial.sqlite3.gz",
                    name: "initial.sqlite3.gz",
                    size: 0,
                    timestamp: 11_000,
                    parentID: syncFolderID,
                    mimeType: NextCloudSyncAdapter.gzipMimeType
                )
            )

            let service = RemoteSyncInitialBackupUploadService(
                adapter: adapter,
                deviceIdentifier: "ios-device",
                temporaryDirectory: stagingDirectory,
                retryDirectory: retryDirectory,
                nowProvider: { 10_000 }
            )
            let report = try await service.uploadInitialBackup(
                for: .readingPlans,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
                modelContext: modelContext,
                settingsStore: settingsStore
            )

            XCTAssertEqual(report.category, .readingPlans)
            let uploadedFiles = await adapter.uploadedFilesSnapshot()
            XCTAssertEqual(uploadedFiles.count, 1)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: retryDirectory,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
    }

    /**
     Verifies shared publication identity binds acceptance bytes and reports sequence exhaustion.

     The same identity validates unchanged payload and count material, rejects a changed acceptance
     payload before transport, and emits the typed exhaustion error at `Int64.max`.
     */
    func testPublicationIdentityRejectsAcceptanceDriftAndPatchNumberExhaustion() throws {
        let originalPayload = ["acceptedRevision": 7]
        let rowCounts = ["readingPlans": 1, "logEntries": 1]
        let identity = try RemoteSyncPublicationIdentity.patch(
            category: .readingPlans,
            destinationID: "/reading-plans/ios-device",
            sourceDevice: "ios-device",
            patchNumber: 1,
            schemaVersion: 1,
            remoteFileName: "1.1.sqlite3.gz",
            archiveFileName: "reading-plans-generation.sqlite3.gz",
            archiveSHA256: String(repeating: "a", count: 64),
            archiveSize: 42,
            rowCounts: rowCounts,
            acceptancePayload: originalPayload
        )

        XCTAssertNoThrow(
            try identity.validate(
                kind: .patch,
                category: .readingPlans,
                destinationID: "/reading-plans/ios-device",
                sourceDevice: "ios-device",
                patchNumber: 1,
                schemaVersion: 1,
                remoteFileName: "1.1.sqlite3.gz",
                archiveFileName: "reading-plans-generation.sqlite3.gz",
                archiveSHA256: String(repeating: "a", count: 64),
                archiveSize: 42,
                rowCounts: rowCounts,
                acceptancePayload: originalPayload
            )
        )
        XCTAssertThrowsError(
            try identity.validate(
                kind: .patch,
                category: .readingPlans,
                destinationID: "/reading-plans/ios-device",
                sourceDevice: "ios-device",
                patchNumber: 1,
                schemaVersion: 1,
                remoteFileName: "1.1.sqlite3.gz",
                archiveFileName: "reading-plans-generation.sqlite3.gz",
                archiveSHA256: String(repeating: "a", count: 64),
                archiveSize: 42,
                rowCounts: rowCounts,
                acceptancePayload: ["acceptedRevision": 8]
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPublicationIdentityError, .acceptanceMismatch)
        }
        XCTAssertThrowsError(
            try RemoteSyncPublicationIdentity.nextPatchNumber(after: [Int64.max])
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPublicationIdentityError, .patchNumberExhausted)
        }
    }
}

/**
 Deterministic failure emitted from the upload acceptance transaction.
 */
private enum RemoteSyncSynchronizationIntegrityTestFailure: Error, Equatable {
    /// Local acceptance was rejected after all baseline mutations had staged.
    case initialUploadAcceptanceRejected

    /// A durable sparse patch reached the backend but local acceptance was rejected.
    case pendingPatchAcceptanceRejected
}

/**
 Remote adapter that blocks one ready-state discovery request until a test releases it.

 The adapter validates an existing bootstrap marker, then pauses the first device-folder listing.
 This provides a deterministic cancellation point after cursor sampling without a real backend.
 */
private actor BlockingRemoteSyncDiscoveryAdapter: RemoteSyncAdapting {
    private let syncFolderID: String
    private let secretFileName: String
    private var discoveryStarted = false
    private var discoveryReleased = false
    private var discoveryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var discoveryReleaseWaiter: CheckedContinuation<Void, Never>?

    /**
     Creates a blocking adapter for one persisted bootstrap state.

     - Parameters:
       - syncFolderID: Remote folder identifier accepted by marker validation.
       - secretFileName: Marker filename accepted by validation.
     - Side Effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(syncFolderID: String, secretFileName: String) {
        self.syncFolderID = syncFolderID
        self.secretFileName = secretFileName
    }

    /**
     Waits until ready-state discovery enters its first remote listing.

     - Side Effects: Suspends the caller until discovery starts.
     - Failure modes: This helper cannot fail.
     */
    func waitUntilDiscoveryStarts() async {
        guard !discoveryStarted else { return }
        await withCheckedContinuation { continuation in
            discoveryStartWaiters.append(continuation)
        }
    }

    /**
     Releases the blocked discovery request.

     - Side Effects: Resumes the pending listing or records an early release.
     - Failure modes: This helper cannot fail.
     */
    func releaseDiscovery() {
        discoveryReleased = true
        discoveryReleaseWaiter?.resume()
        discoveryReleaseWaiter = nil
    }

    /**
     Blocks the first device-folder listing and then returns an empty remote generation.

     - Parameters:
       - parentIDs: Parent folder filter supplied by discovery.
       - name: Exact name filter supplied by discovery.
       - mimeType: MIME filter supplied by discovery.
       - modifiedAtLeast: Incremental lower bound supplied by discovery.
     - Returns: No remote folders or patches.
     - Side Effects: Signals discovery start and may suspend until released.
     - Failure modes: This helper cannot fail.
     */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        if !discoveryStarted,
           parentIDs == [syncFolderID],
           mimeType == NextCloudSyncAdapter.folderMimeType {
            discoveryStarted = true
            let waiters = discoveryStartWaiters
            discoveryStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            if !discoveryReleased {
                await withCheckedContinuation { continuation in
                    discoveryReleaseWaiter = continuation
                }
            }
        }
        return []
    }

    /**
     Rejects folder creation because the fixture starts from ready state.

     - Parameters:
       - name: Requested folder name.
       - parentID: Requested parent folder.
     - Returns: Never returns.
     - Side Effects: none.
     - Throws: Always throws an unexpected-operation test failure.
     */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        throw RemoteSyncSynchronizationIntegrityAdapterFailure.unexpectedOperation("createNewFolder")
    }

    /**
     Rejects downloads because the fixture exposes no patches.

     - Parameter id: Requested remote identifier.
     - Returns: Never returns.
     - Side Effects: none.
     - Throws: Always throws an unexpected-operation test failure.
     */
    func download(id: String) async throws -> Data {
        throw RemoteSyncSynchronizationIntegrityAdapterFailure.unexpectedOperation("download")
    }

    /**
     Rejects uploads because cancellation occurs before outbound publication.

     - Parameters:
       - name: Requested remote filename.
       - fileURL: Requested local source file.
       - parentID: Requested remote parent.
       - contentType: Requested content type.
     - Returns: Never returns.
     - Side Effects: none.
     - Throws: Always throws an unexpected-operation test failure.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        throw RemoteSyncSynchronizationIntegrityAdapterFailure.unexpectedOperation("upload")
    }

    /**
     Rejects deletion because the fixture starts from ready state.

     - Parameter id: Requested remote identifier.
     - Side Effects: none.
     - Throws: Always throws an unexpected-operation test failure.
     */
    func delete(id: String) async throws {
        throw RemoteSyncSynchronizationIntegrityAdapterFailure.unexpectedOperation("delete")
    }

    /**
     Validates only the bootstrap marker configured at initialization.

     - Parameters:
       - syncFolderID: Folder identifier under validation.
       - secretFileName: Marker filename under validation.
     - Returns: `true` only for the configured pair.
     - Side Effects: none.
     - Failure modes: This helper cannot fail.
     */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        syncFolderID == self.syncFolderID && secretFileName == self.secretFileName
    }

    /**
     Rejects marker creation because the fixture starts from ready state.

     - Parameters:
       - syncFolderID: Requested folder identifier.
       - deviceIdentifier: Requested device identifier.
     - Returns: Never returns.
     - Side Effects: none.
     - Throws: Always throws an unexpected-operation test failure.
     */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        throw RemoteSyncSynchronizationIntegrityAdapterFailure.unexpectedOperation("makeSyncFolderKnown")
    }
}

/**
 Deterministic failure emitted when the blocking adapter receives an invalid operation.
 */
private enum RemoteSyncSynchronizationIntegrityAdapterFailure: Error {
    /// Operation name that violated the ready-state cancellation fixture contract.
    case unexpectedOperation(String)
}
