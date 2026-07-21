import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Package-level remote-sync lifecycle tests.

 The suite keeps synchronization, lifecycle scheduling, and WebDAV configuration coverage in
 `BibleCoreTests` so these contracts run without the app-host XCTest bundle or simulator UI harness.
 */
final class RemoteSyncLifecycleTests: XCTestCase {
    func testRemoteSyncSynchronizationServiceReturnsRemoteAdoptionDecision() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)

        let adapter = RemoteSyncMockAdapter()
        await adapter.setListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans",
                name: "org.andbible.ios-sync-readingplans",
                size: 0,
                timestamp: 1_000,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 2_000_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            outcome,
            .requiresRemoteAdoption(
                RemoteSyncBootstrapCandidate(
                    category: .readingPlans,
                    syncFolderName: "org.andbible.ios-sync-readingplans",
                    remoteFolderID: "/org.andbible.ios-sync-readingplans"
                )
            )
        )
    }

    /// Verifies that a ready reading-plan category downloads and applies the next valid remote patch.
    func testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "/org.andbible.ios-sync-readingplans/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .readingPlans
        )

        let planID = UUID(uuidString: "e1000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "e1000000-0000-0000-0000-000000000011")!
        let patchStatusID = UUID(uuidString: "e1000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(readingPlanUUIDBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        RemoteSyncReadingPlanSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: patchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(readingPlanUUIDBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(readingPlanUUIDBlob(patchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let patchArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let patchFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/1.1.sqlite3.gz",
            name: "1.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_800_000,
            parentID: "/org.andbible.ios-sync-readingplans/pixel",
            mimeType: "application/gzip"
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/pixel",
                name: "pixel",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([patchFile])
        await adapter.setDownloadData(patchArchiveData, forID: patchFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 2_000_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertEqual(report.lastPatchWritten, nil)
        XCTAssertEqual(report.lastSynchronized, 2_000_000)
        XCTAssertNil(report.patchUploadReport)

        guard case .readingPlans(let patchReport)? = report.patchReplayReport else {
            return XCTFail("Expected reading-plan patch replay report")
        }

        XCTAssertEqual(patchReport.appliedPatchCount, 1)
        XCTAssertEqual(patchReport.appliedLogEntryCount, 2)
        XCTAssertEqual(patchReport.skippedLogEntryCount, 0)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        let persistedProgress = stateStore.progressState(for: .readingPlans)
        XCTAssertEqual(persistedProgress.lastSynchronized, 2_000_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/pixel"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: patchFile.id),
        ])
    }

    /// Verifies that a ready reading-plan category uploads one sparse local patch when no newer remote patches exist.
    func testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "/org.andbible.ios-sync-readingplans/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .readingPlans
        )

        let planID = UUID(uuidString: "d5000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "d5000000-0000-0000-0000-000000000011")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(readingPlanUUIDBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let plan = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<ReadingPlan>()).first)
        plan.currentDay = 2
        let dayTwo = try XCTUnwrap((plan.days ?? []).first(where: { $0.dayNumber == 2 }))
        dayTwo.isCompleted = true
        try modelContext.save()

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 0,
                timestamp: 4_000_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_000_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(report.lastPatchWritten), 4_000_000)
        XCTAssertEqual(report.lastSynchronized, 4_000_000)

        guard case .readingPlans(let uploadReport)? = report.patchUploadReport else {
            return XCTFail("Expected reading-plan patch upload report")
        }

        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedPlanCount, 1)
        XCTAssertEqual(uploadReport.upsertedStatusCount, 1)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 2)
        XCTAssertEqual(uploadReport.lastUpdated, report.lastPatchWritten)
        XCTAssertEqual(uploadReport.uploadedFile.name, "1.1.sqlite3.gz")
        XCTAssertEqual(uploadReport.uploadedFile.parentID, deviceFolderID)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: uploadReport.uploadedFile.size,
                    appliedDate: 4_000_000
                )
            ]
        )
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans).lastPatchWritten,
            uploadReport.lastUpdated
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastSynchronized, 4_000_000)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFiles.count, 1)
        XCTAssertEqual(
            uploadedFiles[0],
            RemoteSyncMockUploadedFile(
                name: "1.1.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType,
                data: uploadedFiles[0].data
            )
        )

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: "1.1.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.1.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
        ])
    }

    /**
     Verifies skipped-patch discovery persists a zero cursor before applying the next valid patch.

     The first pass discovers a numbering gap. The retry must use and retain Android's durable zero
     baseline while applying the complete patch sequence, ensuring a later pass repeats full discovery.
     */
    func testRemoteSyncSynchronizationServiceRetriesSkippedPatchDiscoveryOnce() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        let restoreService = RemoteSyncReadingPlanRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "/org.andbible.ios-sync-readingplans/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .readingPlans
        )

        let planID = UUID(uuidString: "f1000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "f1000000-0000-0000-0000-000000000011")!
        let patchStatusID = UUID(uuidString: "f1000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(readingPlanUUIDBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        RemoteSyncReadingPlanSnapshotService().refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: patchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(readingPlanUUIDBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(readingPlanUUIDBlob(patchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let patchArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let skippedPatch = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/2.1.sqlite3.gz",
            name: "2.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_800_000,
            parentID: "/org.andbible.ios-sync-readingplans/pixel",
            mimeType: "application/gzip"
        )
        let retriedPatch = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/1.1.sqlite3.gz",
            name: "1.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_810_000,
            parentID: "/org.andbible.ios-sync-readingplans/pixel",
            mimeType: "application/gzip"
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/pixel",
                name: "pixel",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([skippedPatch])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/pixel",
                name: "pixel",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([retriedPatch])
        await adapter.setDownloadData(patchArchiveData, forID: retriedPatch.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 2_500_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertEqual(report.lastSynchronized, 0)
        XCTAssertNil(report.patchUploadReport)

        guard case .readingPlans(let patchReport)? = report.patchReplayReport else {
            return XCTFail("Expected reading-plan patch replay report")
        }

        XCTAssertEqual(patchReport.appliedPatchCount, 1)
        XCTAssertEqual(patchReport.appliedLogEntryCount, 2)
        XCTAssertEqual(patchReport.skippedLogEntryCount, 0)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        let persistedProgress = stateStore.progressState(for: .readingPlans)
        XCTAssertEqual(persistedProgress.lastSynchronized, 0)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/pixel"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/pixel"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: retriedPatch.id),
        ])
    }

    /**
     Verifies that creating a fresh remote folder uploads the local baseline as `initial.sqlite3.gz`
     and suppresses sparse local upload during the same synchronization pass.
     */
    func testRemoteSyncSynchronizationServiceCreateRemoteFolderUploadsInitialBackupAndSuppressesSparseUpload() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        plan.currentDay = 2
        let firstDay = try XCTUnwrap(plan.days?.first(where: { $0.dayNumber == 1 }))
        firstDay.isCompleted = true
        firstDay.completedDate = Date(timeIntervalSince1970: 1_735_689_700)
        try modelContext.save()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "\(syncFolderID)/ios-device"
        let adapter = RemoteSyncMockAdapter()
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
                timestamp: 4_000_100,
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
            nowProvider: { 4_000_000 }
        )

        let report = try await service.createRemoteFolderAndSynchronize(
            for: .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertNil(report.patchUploadReport)
        XCTAssertGreaterThan(try XCTUnwrap(report.lastPatchWritten), 4_000_000)
        XCTAssertEqual(report.lastSynchronized, 4_000_000)
        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let patchZeroSize = Int64(try XCTUnwrap(uploadedFiles.first?.data.count))
        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: patchZeroSize,
                    appliedDate: 4_000_100
                )
            ]
        )
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans).lastPatchWritten,
            report.lastPatchWritten
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastSynchronized, 4_000_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .createFolder(name: "org.andbible.ios-sync-readingplans", parentID: nil),
            .makeKnown(syncFolderID: syncFolderID, deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: syncFolderID),
            .listFiles(
                parentIDs: [syncFolderID],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "initial.sqlite3.gz",
                parentID: syncFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
        ])

        XCTAssertEqual(uploadedFiles.count, 1)
        XCTAssertEqual(uploadedFiles[0].name, "initial.sqlite3.gz")
    }

    /// Verifies that adopting a remote folder restores its initial backup, records patch zero, and then runs ready-state synchronization.
    func testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "e2000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "e2000000-0000-0000-0000-000000000011")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        let initialFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialArchiveData.count),
            timestamp: 1_735_689_700_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: "application/gzip"
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_650_000,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_650_000,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])
        await adapter.setDownloadData(initialArchiveData, forID: initialFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 3_000_000 }
        )

        let report = try await service.adoptRemoteFolderAndSynchronize(
            for: .readingPlans,
            remoteFolderID: "/org.andbible.ios-sync-readingplans",
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertEqual(report.lastPatchWritten, 3_000_000)
        XCTAssertEqual(report.lastSynchronized, 3_000_000)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertNil(report.patchUploadReport)
        XCTAssertEqual(
            report.initialRestoreReport,
            .readingPlans(
                RemoteSyncReadingPlanRestoreReport(
                    restoredPlanCodes: ["y1ot1nt1_OTthenNT"],
                    restoredDayCount: ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!.totalDays,
                    preservedStatusCount: 1
                )
            )
        )

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
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 3_000_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .makeKnown(syncFolderID: "/org.andbible.ios-sync-readingplans", deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: "/org.andbible.ios-sync-readingplans"),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: initialFile.id),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/ios-device"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
        ])
    }

    /// Verifies that adopting a remote folder can replay newer remote patches without uploading a local patch in the same pass.
    func testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let initialPlanID = UUID(uuidString: "e3000000-0000-0000-0000-000000000001")!
        let initialStatusID = UUID(uuidString: "e3000000-0000-0000-0000-000000000011")!
        let remotePatchStatusID = UUID(uuidString: "e3000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: initialPlanID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: initialStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        let initialFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialArchiveData.count),
            timestamp: 1_735_689_700_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: "application/gzip"
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: initialPlanID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: remotePatchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(readingPlanUUIDBlob(initialPlanID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(readingPlanUUIDBlob(remotePatchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let patchArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let pixelFolder = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel",
            name: "pixel",
            size: 0,
            timestamp: 1_735_689_710_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let localDeviceFolder = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/ios-device",
            name: "ios-device",
            size: 0,
            timestamp: 1_735_689_705_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let patchFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/1.1.sqlite3.gz",
            name: "1.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_800_000,
            parentID: pixelFolder.id,
            mimeType: "application/gzip"
        )

        let adapter = RemoteSyncMockAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(localDeviceFolder)
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.enqueueListFilesResult([pixelFolder, localDeviceFolder])
        await adapter.enqueueListFilesResult([patchFile])
        await adapter.setDownloadData(initialArchiveData, forID: initialFile.id)
        await adapter.setDownloadData(patchArchiveData, forID: patchFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 3_500_000 }
        )

        let report = try await service.adoptRemoteFolderAndSynchronize(
            for: .readingPlans,
            remoteFolderID: "/org.andbible.ios-sync-readingplans",
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertEqual(report.lastPatchWritten, 3_500_000)
        XCTAssertEqual(report.lastSynchronized, 3_500_000)
        XCTAssertNil(report.patchUploadReport)

        guard case .readingPlans(let patchReport)? = report.patchReplayReport else {
            return XCTFail("Expected reading-plan patch replay report")
        }

        XCTAssertEqual(patchReport.appliedPatchCount, 1)
        XCTAssertEqual(patchReport.appliedLogEntryCount, 2)
        XCTAssertEqual(patchReport.skippedLogEntryCount, 0)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: initialFile.size,
                    appliedDate: initialFile.timestamp
                ),
                RemoteSyncPatchStatus(
                    sourceDevice: "pixel",
                    patchNumber: 1,
                    sizeBytes: patchFile.size,
                    appliedDate: patchFile.timestamp
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 3_500_000)
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastSynchronized, 3_500_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .makeKnown(syncFolderID: "/org.andbible.ios-sync-readingplans", deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: "/org.andbible.ios-sync-readingplans"),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: initialFile.id),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [localDeviceFolder.id, pixelFolder.id],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: patchFile.id),
        ])
    }

    /// Verifies that outbound upload stays idle when the current reading-plan snapshot matches the stored baseline exactly.
    func testRemoteSyncReadingPlanPatchUploadReturnsNilWhenStateMatchesBaseline() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)

        let template = ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        plan.currentDay = 1
        try modelContext.save()

        logEntryStore.addEntry(
            RemoteSyncLogEntry(
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(plan.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let currentSnapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let planKey = logEntryStore.key(
            for: .readingPlans,
            tableName: "ReadingPlan",
            entityID1: .blob(readingPlanUUIDBlob(plan.id)),
            entityID2: .text("")
        )
        let persistedFingerprint = fingerprintStore.fingerprint(
            for: .readingPlans,
            tableName: "ReadingPlan",
            entityID1: .blob(readingPlanUUIDBlob(plan.id)),
            entityID2: .text("")
        )
        XCTAssertEqual(persistedFingerprint, currentSnapshot.fingerprintsByKey[planKey])

        let adapter = RemoteSyncMockAdapter()
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertNil(report)
        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadedFiles.isEmpty)
    }

    /// Verifies that outbound upload writes an Android-shaped sparse patch, uploads it, and advances local sync bookkeeping.
    func testRemoteSyncReadingPlanPatchUploadWritesAndUploadsSparsePatch() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let template = ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        plan.currentDay = 1
        try modelContext.save()

        logEntryStore.addEntry(
            RemoteSyncLogEntry(
                tableName: "ReadingPlan",
                entityID1: .blob(readingPlanUUIDBlob(plan.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        settingsStore.setString("remote_sync_device_identifier", value: "ios-device")
        plan.currentDay = 2
        let dayOne = try XCTUnwrap(plan.days?.first(where: { $0.dayNumber == 1 }))
        dayOne.isCompleted = true
        dayOne.completedDate = Date(timeIntervalSince1970: 1_735_689_700)
        try modelContext.save()

        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-readingplans/ios-device",
                mimeType: "application/gzip"
            )
        )
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.patchNumber, 1)
        XCTAssertEqual(unwrappedReport.upsertedPlanCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedStatusCount, 0)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 0)
        XCTAssertEqual(unwrappedReport.logEntryCount, 1)
        XCTAssertGreaterThan(unwrappedReport.lastUpdated, 2_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/ios-device"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/ios-device"],
                name: "1.1.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.1.sqlite3.gz",
                parentID: "/org.andbible.ios-sync-readingplans/ios-device",
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-readingplan-patch-\(UUID().uuidString).sqlite3.gz")
        let databaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try gunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: databaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        let patchSnapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(patchSnapshot.plans.count, 1)
        XCTAssertEqual(patchSnapshot.plans[0].currentDay, 2)
        XCTAssertTrue(patchSnapshot.plans[0].statuses.isEmpty)
        XCTAssertEqual(metadataSnapshot.logEntries.map(\.type), [.upsert])
        XCTAssertEqual(Set(metadataSnapshot.logEntries.map(\.tableName)), ["ReadingPlan"])
        XCTAssertEqual(Set(metadataSnapshot.logEntries.map(\.sourceDevice)), ["ios-device"])

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: unwrappedReport.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        XCTAssertEqual(
            stateStore.progressState(for: .readingPlans).lastPatchWritten,
            unwrappedReport.lastUpdated
        )
        XCTAssertEqual(logEntryStore.entries(for: .readingPlans).count, 1)

        let currentSnapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertTrue(currentSnapshot.statusRowsByKey.isEmpty)

        let secondReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNil(secondReport)
        let finalUploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(finalUploadedFiles.count, 1)
    }

    /// Verifies that reading-plan initial restore refreshes the outbound fingerprint baseline so later local deletes emit delete patches.
    func testRemoteSyncReadingPlanPatchUploadDetectsDeleteAfterInitialRestoreRefresh() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()

        let planID = UUID(uuidString: "d9000000-0000-0000-0000-000000000001")!
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 3
                )
            ],
            statuses: [],
            logEntries: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_500,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertTrue(
            RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entries(for: .readingPlans).isEmpty
        )
        modelContext.delete(plans[0])
        try modelContext.save()

        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 0,
                timestamp: 2_500,
                parentID: "/org.andbible.ios-sync-readingplans/ios-device",
                mimeType: "application/gzip"
            )
        )
        let uploadService = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_500 }
        )

        let report = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.upsertedPlanCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedStatusCount, 0)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 1)
        XCTAssertEqual(unwrappedReport.logEntryCount, 1)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-readingplan-delete-\(UUID().uuidString).sqlite3.gz")
        let databaseURL2 = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL2)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try gunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: databaseURL2, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL2)
        XCTAssertEqual(metadataSnapshot.logEntries.count, 1)
        XCTAssertEqual(metadataSnapshot.logEntries[0].type, .delete)
        XCTAssertEqual(metadataSnapshot.logEntries[0].tableName, "ReadingPlan")
    }

    /**
     Verifies a reading-plan edit made while remote publication is suspended remains pending.

     The first acceptance must retain the immutable uploaded fingerprint rather than re-reading the
     live graph. A second patch containing the newer day proves the concurrent edit was not lost.
     */
    func testReadingPlanUploadKeepsInFlightEditDirtyForNextPatch() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.currentDay = 1
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        plan.currentDay = 2
        try modelContext.save()
        let uploadedSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let planKey = try XCTUnwrap(uploadedSnapshot.planRowsByKey.first?.key)

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [
                .init(timestamp: 8_000),
                .init(timestamp: 9_000),
            ]
        )
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-inflight-edit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 7_000 }
        )

        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        plan.currentDay = 3
        try modelContext.save()
        await adapter.resumeUpload()

        let firstResult = try await uploadTask.value
        let firstReport = try XCTUnwrap(firstResult)
        XCTAssertEqual(firstReport.patchNumber, 1)
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: planKey,
                category: .readingPlans
            ),
            uploadedSnapshot.fingerprintsByKey[planKey]
        )
        let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNotEqual(
            currentSnapshot.fingerprintsByKey[planKey],
            uploadedSnapshot.fingerprintsByKey[planKey]
        )

        let secondResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let secondReport = try XCTUnwrap(secondResult)
        XCTAssertEqual(secondReport.patchNumber, 2)
        let uploads = await adapter.uploads()
        XCTAssertEqual(uploads.map(\.name), ["1.1.sqlite3.gz", "2.1.sqlite3.gz"])
    }

    /**
     Verifies remote success followed by local failure resumes the exact durable reading-plan generation.

     A new service instance reconciles the existing remote bytes instead of allocating or rebuilding a
     patch. Sync status uses remote file metadata, while `lastPatchWritten` retains generation time.
     */
    func testReadingPlanUploadAcceptanceFailureResumesExactOutboxGeneration() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.currentDay = 1
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let acceptedSnapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let planKey = try XCTUnwrap(acceptedSnapshot.planRowsByKey.first?.key)
        plan.currentDay = 2
        try modelContext.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 12_000, size: 54_321)]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-acceptance-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxDirectory = directory.appendingPathComponent("outbox", isDirectory: true)
        let failingService = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 10_000 },
            finalAcceptanceCheckpoint: {
                throw NSError(domain: "ReadingPlanUploadAcceptance", code: 61)
            }
        )

        do {
            _ = try await failingService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected reading-plan acceptance failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ReadingPlanUploadAcceptance")
        }

        XCTAssertNotNil(settingsStore.getString(RemoteSyncReadingPlanPatchUploadService.pendingUploadKey))
        XCTAssertEqual(
            RemoteSyncRowFingerprintStore(settingsStore: settingsStore).fingerprint(
                forLogKey: planKey,
                category: .readingPlans
            ),
            acceptedSnapshot.fingerprintsByKey[planKey]
        )
        XCTAssertTrue(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .readingPlans).isEmpty
        )
        XCTAssertNil(
            RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .readingPlans).lastPatchWritten
        )

        let retryService = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 99_000 }
        )
        let retryResult = try await retryService.resumePendingUploadIfPresent(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let report = try XCTUnwrap(retryResult)

        XCTAssertEqual(report.patchNumber, 1)
        let retryUploads = await adapter.uploads()
        XCTAssertEqual(retryUploads.count, 1)
        XCTAssertNil(settingsStore.getString(RemoteSyncReadingPlanPatchUploadService.pendingUploadKey))
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: 54_321,
                    appliedDate: 12_000
                )
            ]
        )
        XCTAssertGreaterThan(report.lastUpdated, 10_000)
        XCTAssertEqual(
            RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .readingPlans).lastPatchWritten,
            report.lastUpdated
        )
    }

    /**
     Verifies cancellation after a reading-plan archive becomes durable retains retryable outbox state.

     The mock suspends conditional creation deterministically. Cancellation must leave local acceptance
     untouched; a resume-only call then reconciles the same remote bytes and accepts patch one.
     */
    func testReadingPlanUploadCancellationRetainsDurableGenerationForResume() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        plan.currentDay += 1
        try modelContext.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 15_000)]
        )
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-cancel-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 14_000 }
        )
        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        uploadTask.cancel()
        await adapter.resumeUpload()

        do {
            _ = try await uploadTask.value
            XCTFail("Expected reading-plan upload cancellation")
        } catch is CancellationError {
            // Expected: the durable generation remains available for reconciliation.
        }
        XCTAssertNotNil(settingsStore.getString(RemoteSyncReadingPlanPatchUploadService.pendingUploadKey))
        XCTAssertTrue(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .readingPlans).isEmpty
        )

        let resumed = try await service.resumePendingUploadIfPresent(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(resumed).patchNumber, 1)
        let resumedUploads = await adapter.uploads()
        XCTAssertEqual(resumedUploads.count, 1)
    }

    /**
     Verifies absent local status allocates after remote reading-plan history and corruption fails closed.

     Remote patch seven must yield patch eight. A subsequent malformed local status must abort before
     any additional conditional create, rather than being treated as an empty accepted sequence.
     */
    func testReadingPlanUploadUsesRemoteNumberingAndRejectsCorruptLocalStatus() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        plan.currentDay += 1
        try modelContext.save()

        let deviceFolderID = "/readingplans/ios-device"
        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [.init(timestamp: 18_000)]
        )
        await adapter.seedRemoteFile(
            name: "7.1.sqlite3.gz",
            parentID: deviceFolderID,
            data: Data("accepted remote history".utf8),
            timestamp: 17_000
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-remote-numbering-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 17_500 }
        )

        let firstResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(firstResult).patchNumber, 8)
        let numberedUploads = await adapter.uploads()
        XCTAssertEqual(numberedUploads.map(\.name), ["8.1.sqlite3.gz"])

        plan.currentDay += 1
        try modelContext.save()
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let corruptKey = patchStatusStore.key(
            for: .readingPlans,
            sourceDevice: "ios-device",
            patchNumber: 9
        )
        settingsStore.setString(corruptKey, value: "{not-json")
        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected corrupt reading-plan patch status to fail closed")
        } catch let error as RemoteSyncPatchStatusStoreError {
            XCTAssertEqual(error, .invalidStoredStatus(corruptKey))
        }
        let uploadsAfterCorruption = await adapter.uploads()
        XCTAssertEqual(uploadsAfterCorruption.count, 1)
    }

    /**
     Verifies generated Android status ids merge without overwriting newer reading-plan progress.

     Two id-less statuses are uploaded while transport is suspended. Acceptance must add the generated
     id to the still-present row while preserving its newer JSON, and must not recreate the deleted row.
     The next patch proves both concurrent changes remain dirty.
     */
    func testReadingPlanUploadMergesGeneratedStatusIDWithoutOverwritingConcurrentChanges() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        try modelContext.save()
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#,
            planCode: plan.planCode,
            dayNumber: 1
        )
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#,
            planCode: plan.planCode,
            dayNumber: 2
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: plan.planCode,
            dayNumber: 1
        )
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: plan.planCode,
            dayNumber: 2
        )

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [
                .init(timestamp: 19_000),
                .init(timestamp: 20_000),
            ]
        )
        await adapter.suspendNextUpload()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-status-id-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: directory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 18_500 }
        )
        let uploadTask = Task {
            try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        await adapter.waitUntilUploadStarts()
        let newerJSON = #"{"chapterReadArray":[{"readingNumber":1,"isRead":true},{"readingNumber":2,"isRead":true}]}"#
        statusStore.setStatus(newerJSON, planCode: plan.planCode, dayNumber: 1)
        statusStore.removeStatus(planCode: plan.planCode, dayNumber: 2)
        await adapter.resumeUpload()

        let firstResult = try await uploadTask.value
        XCTAssertEqual(try XCTUnwrap(firstResult).patchNumber, 1)
        let retainedStatus = try XCTUnwrap(
            statusStore.storedStatus(planCode: plan.planCode, dayNumber: 1)
        )
        XCTAssertEqual(retainedStatus.readingStatusJSON, newerJSON)
        XCTAssertNotNil(retainedStatus.remoteStatusID)
        XCTAssertNil(statusStore.storedStatus(planCode: plan.planCode, dayNumber: 2))

        let secondResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(secondResult).patchNumber, 2)
    }

    /**
     Verifies a reading-plan outbox cannot cross destinations without explicit lifecycle cleanup.

     A failed acceptance leaves an old-folder generation. The new folder must reject it; explicit
     discard preserves the old baseline so the current graph rebuilds as patch one for the replacement.
     */
    func testReadingPlanDestinationReplacementRequiresExplicitPendingCleanup() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        try modelContext.save()
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        plan.currentDay += 1
        try modelContext.save()

        let adapter = RemoteSyncDurableOutboxTestAdapter(
            uploadMetadata: [
                .init(timestamp: 21_000),
                .init(timestamp: 22_000),
            ]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-destination-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outboxDirectory = directory.appendingPathComponent("outbox", isDirectory: true)
        let failingService = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 20_000 },
            finalAcceptanceCheckpoint: {
                throw NSError(domain: "ReadingPlanDestination", code: 71)
            }
        )
        do {
            _ = try await failingService.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/old-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected local acceptance failure")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ReadingPlanDestination")
        }

        let replacementService = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: directory,
            outboxDirectory: outboxDirectory,
            nowProvider: { 20_500 }
        )
        do {
            _ = try await replacementService.resumePendingUploadIfPresent(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/new-device"),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            XCTFail("Expected mismatched reading-plan outbox to fail closed")
        } catch let error as RemoteSyncReadingPlanPatchUploadError {
            XCTAssertEqual(
                error,
                .pendingUploadDestinationMismatch(
                    stored: "/readingplans/old-device",
                    requested: "/readingplans/new-device"
                )
            )
        }

        try replacementService.discardPendingUploadForDestinationReplacement(
            settingsStore: settingsStore
        )
        let replacementResult = try await replacementService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/readingplans/new-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(try XCTUnwrap(replacementResult).patchNumber, 1)
        let destinationUploads = await adapter.uploads()
        XCTAssertEqual(
            destinationUploads.map(\.parentID),
            ["/readingplans/old-device", "/readingplans/new-device"]
        )
    }

    func testWebDAVSyncConfigurationRejectsLoginPageURLs() {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com/login",
            username: "alice",
            folderPath: nil
        )

        XCTAssertThrowsError(try configuration.resolvedDAVBaseURL()) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidURL)
        }
    }

    func testRemoteSyncSettingsStorePersistsGlobalLastSynchronizedAndIntervalFallbacks() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.remoteSyncIntervalSeconds, RemoteSyncSettingsStore.defaultSyncIntervalSeconds)
        XCTAssertNil(store.globalLastSynchronized)

        settingsStore.setString("gdrive_sync_interval", value: "42")
        store.globalLastSynchronized = 12_345

        XCTAssertEqual(store.remoteSyncIntervalSeconds, 42)
        XCTAssertEqual(store.globalLastSynchronized, 12_345)

        settingsStore.setString("gdrive_sync_interval", value: "-1")
        settingsStore.setString("globalLastSynchronized", value: "not-a-number")

        XCTAssertEqual(store.remoteSyncIntervalSeconds, RemoteSyncSettingsStore.defaultSyncIntervalSeconds)
        XCTAssertNil(store.globalLastSynchronized)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceSynchronizesEnabledNextCloudCategoriesAndUpdatesGlobalTimestamp() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)
        remoteSettingsStore.setSyncEnabled(true, for: .workspaces)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        synchronizer.synchronizeResults[.bookmarks] = .synchronized(makeLifecycleSyncReport(for: .bookmarks))
        synchronizer.synchronizeResults[.workspaces] = .synchronized(makeLifecycleSyncReport(for: .workspaces))

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 50_000 }
        )

        var synchronizedCategories: [RemoteSyncCategory] = []
        lifecycleService.onCategorySynchronized = { report in
            synchronizedCategories.append(report.category)
        }

        let didSynchronize = await lifecycleService.synchronizeIfNeeded(force: true)

        XCTAssertTrue(didSynchronize)
        XCTAssertEqual(synchronizer.synchronizeCalls, [.bookmarks, .workspaces])
        XCTAssertEqual(synchronizedCategories, [.bookmarks, .workspaces])
        XCTAssertEqual(remoteSettingsStore.globalLastSynchronized, 50_000)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceRespectsSyncIntervalForNonForcedPasses() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)
        remoteSettingsStore.globalLastSynchronized = 100_000

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        synchronizer.synchronizeResults[.bookmarks] = .synchronized(makeLifecycleSyncReport(for: .bookmarks))

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 100_000 + 60_000 }
        )

        let didSynchronize = await lifecycleService.synchronizeIfNeeded(force: false)

        XCTAssertFalse(didSynchronize)
        XCTAssertTrue(synchronizer.synchronizeCalls.isEmpty)
        XCTAssertEqual(remoteSettingsStore.globalLastSynchronized, 100_000)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceSkipsPassesWhenNetworkIsUnavailable() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            networkAvailableProvider: { false },
            nowProvider: { 75_000 }
        )

        let didSynchronize = await lifecycleService.synchronizeIfNeeded(force: true)

        XCTAssertFalse(didSynchronize)
        XCTAssertTrue(synchronizer.synchronizeCalls.isEmpty)
        XCTAssertNil(remoteSettingsStore.globalLastSynchronized)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceAutomaticallyCreatesMissingRemoteFolders() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        synchronizer.synchronizeResults[.bookmarks] = .requiresRemoteCreation(
            RemoteSyncBootstrapCreation(
                category: .bookmarks,
                syncFolderName: RemoteSyncCategory.bookmarks.syncFolderName(bundleIdentifier: "org.andbible.ios")
            )
        )
        synchronizer.createResults[.bookmarks] = makeLifecycleSyncReport(for: .bookmarks)

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 88_000 }
        )

        let didSynchronize = await lifecycleService.synchronizeIfNeeded(force: true)

        XCTAssertTrue(didSynchronize)
        XCTAssertEqual(synchronizer.synchronizeCalls, [.bookmarks])
        XCTAssertEqual(synchronizer.createCalls, [.bookmarks])
        XCTAssertEqual(remoteSettingsStore.globalLastSynchronized, 88_000)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceReportsInteractionRequiredWithoutUpdatingGlobalTimestamp() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .workspaces)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        let candidate = RemoteSyncBootstrapCandidate(
            category: .workspaces,
            syncFolderName: RemoteSyncCategory.workspaces.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            remoteFolderID: "/existing-workspaces"
        )
        synchronizer.synchronizeResults[.workspaces] = .requiresRemoteAdoption(candidate)

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 99_000 }
        )

        var interactionCategory: RemoteSyncCategory?
        lifecycleService.onInteractionRequired = { category, _ in
            interactionCategory = category
        }

        let didSynchronize = await lifecycleService.synchronizeIfNeeded(force: true)

        XCTAssertFalse(didSynchronize)
        XCTAssertEqual(interactionCategory, .workspaces)
        XCTAssertEqual(synchronizer.synchronizeCalls, [.workspaces])
        XCTAssertNil(remoteSettingsStore.globalLastSynchronized)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceAdoptsRemoteFolderAfterUserDecision() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .workspaces)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        let candidate = RemoteSyncBootstrapCandidate(
            category: .workspaces,
            syncFolderName: RemoteSyncCategory.workspaces.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            remoteFolderID: "/existing-workspaces"
        )
        synchronizer.adoptResults[.workspaces] = makeLifecycleSyncReport(for: .workspaces)

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 123_000 }
        )

        let didSynchronize = await lifecycleService.adoptRemoteFolderAndSynchronize(candidate)

        XCTAssertTrue(didSynchronize)
        XCTAssertEqual(synchronizer.adoptCalls, [.workspaces])
        XCTAssertEqual(remoteSettingsStore.globalLastSynchronized, 123_000)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceReplacesRemoteFolderAfterUserDecision() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        let candidate = RemoteSyncBootstrapCandidate(
            category: .bookmarks,
            syncFolderName: RemoteSyncCategory.bookmarks.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            remoteFolderID: "/existing-bookmarks"
        )
        synchronizer.createResults[.bookmarks] = makeLifecycleSyncReport(for: .bookmarks)

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { _ in synchronizer },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 144_000 }
        )

        let didSynchronize = await lifecycleService.replaceRemoteFolderAndSynchronize(candidate)

        XCTAssertTrue(didSynchronize)
        XCTAssertEqual(synchronizer.createCalls, [.bookmarks])
        XCTAssertEqual(remoteSettingsStore.globalLastSynchronized, 144_000)
    }

    func testRemoteSyncSynchronizationServiceFactoryBuildsNextCloudAdapter() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        try remoteSettingsStore.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )

        let factory = RemoteSyncSynchronizationServiceFactory(bundleIdentifier: "org.andbible.ios")

        let adapter = try factory.makeAdapter(using: remoteSettingsStore)

        XCTAssertTrue(adapter is NextCloudSyncAdapter)
    }

    @MainActor
    func testRemoteSyncLifecycleServiceSynchronizesEnabledNextCloudCategories() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let secretStore = InMemorySecretStore()
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: secretStore
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        remoteSettingsStore.setSyncEnabled(true, for: .readingPlans)

        let synchronizer = MockRemoteSyncLifecycleSynchronizer()
        synchronizer.synchronizeResults[.readingPlans] = .synchronized(
            makeLifecycleSyncReport(for: .readingPlans)
        )

        let lifecycleService = RemoteSyncLifecycleService(
            modelContainer: container,
            bundleIdentifier: "org.andbible.ios",
            synchronizationServiceFactory: { remoteSettingsStore in
                XCTAssertEqual(remoteSettingsStore.selectedBackend, .nextCloud)
                return synchronizer
            },
            remoteSettingsStoreFactory: { RemoteSyncSettingsStore(settingsStore: $0, secretStore: secretStore) },
            nowProvider: { 166_000 }
        )

        let didSynchronize = await lifecycleService.synchronizeIfNeeded(force: true)

        XCTAssertTrue(didSynchronize)
        XCTAssertEqual(synchronizer.synchronizeCalls, [.readingPlans])
        XCTAssertEqual(remoteSettingsStore.globalLastSynchronized, 166_000)
    }

#if os(iOS)
    @MainActor
    func testRemoteSyncBackgroundRefreshCoordinatorSchedulesUsingStoredInterval() throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)
        settingsStore.setString("gdrive_sync_interval", value: "900")

        let scheduler = FakeRemoteSyncBackgroundRefreshScheduler()
        let now = Date(timeIntervalSince1970: 1_000)
        let coordinator = RemoteSyncBackgroundRefreshCoordinator(
            modelContainer: container,
            scheduler: scheduler,
            nowProvider: { now },
            synchronizeIfNeeded: { _ in true }
        )

        coordinator.scheduleNextRefreshIfNeeded()

        XCTAssertEqual(
            scheduler.cancelledIdentifiers,
            [RemoteSyncBackgroundRefreshCoordinator.defaultTaskIdentifier]
        )
        XCTAssertEqual(
            scheduler.submittedRequests,
            [
                RemoteSyncBackgroundRefreshRequest(
                    identifier: RemoteSyncBackgroundRefreshCoordinator.defaultTaskIdentifier,
                    earliestBeginDate: now.addingTimeInterval(900)
                ),
            ]
        )
    }

    /**
     Verifies background-refresh scheduling reads from the replacement data stack after a live
     iCloud mode change.

     Issue #322 rebuilds the SwiftData container in-session. The old container is configured as
     iCloud-only, which should cancel background refresh, while the replacement container enables
     NextCloud bookmark sync with a stored interval. A submitted request proves the coordinator
     no longer reads remote-sync settings from stale startup state.
     */
    @MainActor
    func testRemoteSyncBackgroundRefreshCoordinatorUsesUpdatedContainerForScheduling() throws {
        let oldContainer = try makeInMemorySettingsContainer()
        let oldSettingsStore = RemoteSyncSettingsStore(
            settingsStore: SettingsStore(modelContext: ModelContext(oldContainer)),
            secretStore: InMemorySecretStore()
        )
        oldSettingsStore.selectedBackend = .iCloud

        let replacementContainer = try makeInMemorySettingsContainer()
        let replacementSettingsStore = RemoteSyncSettingsStore(
            settingsStore: SettingsStore(modelContext: ModelContext(replacementContainer)),
            secretStore: InMemorySecretStore()
        )
        replacementSettingsStore.selectedBackend = .nextCloud
        replacementSettingsStore.setSyncEnabled(true, for: .bookmarks)
        SettingsStore(modelContext: ModelContext(replacementContainer))
            .setString("gdrive_sync_interval", value: "1800")

        let scheduler = FakeRemoteSyncBackgroundRefreshScheduler()
        let now = Date(timeIntervalSince1970: 2_000)
        let coordinator = RemoteSyncBackgroundRefreshCoordinator(
            modelContainer: oldContainer,
            scheduler: scheduler,
            nowProvider: { now },
            synchronizeIfNeeded: { _ in true }
        )

        coordinator.updateModelContainer(replacementContainer)
        coordinator.scheduleNextRefreshIfNeeded()

        XCTAssertEqual(
            scheduler.submittedRequests,
            [
                RemoteSyncBackgroundRefreshRequest(
                    identifier: RemoteSyncBackgroundRefreshCoordinator.defaultTaskIdentifier,
                    earliestBeginDate: now.addingTimeInterval(1_800)
                ),
            ]
        )
    }

    @MainActor
    func testRemoteSyncBackgroundRefreshCoordinatorCancelsWhenNoRemoteCategoriesAreEnabled() throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )
        remoteSettingsStore.selectedBackend = .nextCloud

        let scheduler = FakeRemoteSyncBackgroundRefreshScheduler()
        let coordinator = RemoteSyncBackgroundRefreshCoordinator(
            modelContainer: container,
            scheduler: scheduler,
            synchronizeIfNeeded: { _ in true }
        )

        coordinator.scheduleNextRefreshIfNeeded()

        XCTAssertTrue(scheduler.submittedRequests.isEmpty)
        XCTAssertEqual(
            scheduler.cancelledIdentifiers,
            [RemoteSyncBackgroundRefreshCoordinator.defaultTaskIdentifier]
        )
    }

    @MainActor
    func testRemoteSyncBackgroundRefreshCoordinatorLaunchHandlerRunsThrottledSyncAndCompletesTask() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)

        let scheduler = FakeRemoteSyncBackgroundRefreshScheduler()
        let syncExpectation = expectation(description: "background refresh invoked synchronizeIfNeeded")
        let completionExpectation = expectation(description: "background refresh task completed")
        var observedForceFlags: [Bool] = []

        let coordinator = RemoteSyncBackgroundRefreshCoordinator(
            modelContainer: container,
            scheduler: scheduler,
            synchronizeIfNeeded: { force in
                observedForceFlags.append(force)
                syncExpectation.fulfill()
                return true
            }
        )
        coordinator.register()

        let task = FakeRemoteSyncBackgroundRefreshTask()
        task.onCompletion = { success in
            XCTAssertTrue(success)
            completionExpectation.fulfill()
        }

        scheduler.launchHandler?(task)

        await fulfillment(of: [syncExpectation, completionExpectation], timeout: 1.0)

        XCTAssertEqual(observedForceFlags, [false])
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(scheduler.submittedRequests.count, 1)
    }

    @MainActor
    func testRemoteSyncBackgroundRefreshCoordinatorExpirationCompletesTaskAsFailure() async throws {
        let container = try makeInMemorySettingsContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let remoteSettingsStore = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )
        remoteSettingsStore.selectedBackend = .nextCloud
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)

        let scheduler = FakeRemoteSyncBackgroundRefreshScheduler()
        let expirationExpectation = expectation(description: "background refresh task installed expiration handler")
        let completionExpectation = expectation(description: "background refresh task completed after expiration")

        let coordinator = RemoteSyncBackgroundRefreshCoordinator(
            modelContainer: container,
            scheduler: scheduler,
            synchronizeIfNeeded: { _ in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    // Cancellation is expected when the task expires.
                }
                return true
            }
        )
        coordinator.register()

        let task = FakeRemoteSyncBackgroundRefreshTask()
        task.onExpirationHandlerSet = {
            expirationExpectation.fulfill()
        }
        task.onCompletion = { success in
            XCTAssertFalse(success)
            completionExpectation.fulfill()
        }

        scheduler.launchHandler?(task)
        await fulfillment(of: [expirationExpectation], timeout: 1.0)
        task.expirationHandler?()
        await fulfillment(of: [completionExpectation], timeout: 1.0)

        XCTAssertEqual(task.completions, [false])
    }
#endif

}

/**
 Deterministic remote backend for durable patch outbox behavior tests across sync categories.

 The actor retains exact bytes by destination and filename, supports continuation-driven suspension,
 records conditional-create attempts, and allows remote metadata to differ from local archive metadata.
 It intentionally models only the file semantics needed by category upload tests; folder-known methods
 return stable defaults and never perform external I/O.
 */
actor RemoteSyncDurableOutboxTestAdapter: RemoteSyncAdapting, RemoteSyncConditionalFileUploading {
    /** Remote metadata assigned to one successful conditional create. */
    struct UploadMetadata: Sendable, Equatable {
        /// Server-applied modification timestamp in milliseconds.
        let timestamp: Int64

        /// Optional server-reported size, which may differ from the local archive byte count.
        let size: Int64?

        /** Creates one deterministic remote metadata response. */
        init(timestamp: Int64, size: Int64? = nil) {
            self.timestamp = timestamp
            self.size = size
        }
    }

    /** One completed conditional-create attempt retained for assertions. */
    struct Upload: Sendable, Equatable {
        /// Exact Android patch filename.
        let name: String

        /// Destination device-folder identifier.
        let parentID: String

        /// Immutable archive bytes supplied to conditional create.
        let data: Data
    }

    private var uploadMetadata: [UploadMetadata]
    private var completedUploads: [Upload] = []
    private var remoteFilesByID: [String: (file: RemoteSyncFile, data: Data)] = [:]
    private var shouldSuspendNextUpload = false
    private var uploadDidStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /** Creates a backend with deterministic server metadata assigned in upload order. */
    init(uploadMetadata: [UploadMetadata]) {
        self.uploadMetadata = uploadMetadata
    }

    /** Configures the next conditional create to pause after receiving immutable bytes. */
    func suspendNextUpload() {
        shouldSuspendNextUpload = true
        uploadDidStart = false
    }

    /** Waits without polling until the suspended conditional create has captured its bytes. */
    func waitUntilUploadStarts() async {
        if uploadDidStart {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    /** Releases a suspended conditional create exactly once. */
    func resumeUpload() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    /** Seeds one accepted remote patch for numbering or exact-byte reconciliation. */
    func seedRemoteFile(
        name: String,
        parentID: String,
        data: Data,
        timestamp: Int64
    ) {
        let id = "\(parentID)/\(name)"
        remoteFilesByID[id] = (
            RemoteSyncFile(
                id: id,
                name: name,
                size: Int64(data.count),
                timestamp: timestamp,
                parentID: parentID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            ),
            data
        )
    }

    /** Returns completed conditional-create attempts in call order. */
    func uploads() -> [Upload] {
        completedUploads
    }

    /** Lists in-memory remote objects using the adapter's production filter contract. */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        remoteFilesByID.values.map(\.file).filter { file in
            (parentIDs == nil || parentIDs!.contains(file.parentID))
                && (name == nil || file.name == name)
                && (mimeType == nil || file.mimeType == mimeType)
                && (modifiedAtLeast == nil
                    || Date(timeIntervalSince1970: TimeInterval(file.timestamp) / 1_000)
                        >= modifiedAtLeast!)
        }
    }

    /** Creates an in-memory folder descriptor without storing folder state. */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        RemoteSyncFile(
            id: "\(parentID ?? "/")/\(name)",
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    /** Returns exact bytes for one seeded or uploaded remote object. */
    func download(id: String) async throws -> Data {
        remoteFilesByID[id]?.data ?? Data()
    }

    /**
     Supports non-conditional protocol callers by routing through the same in-memory create path.

     Category outbox tests use `uploadIfAbsent`; this method exists only to satisfy the broader adapter
     protocol and deliberately replaces an existing fixture when called directly.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        let data = try Data(contentsOf: fileURL)
        let id = "\(parentID)/\(name)"
        let metadata = nextUploadMetadata(for: data)
        let file = makeRemoteFile(
            id: id,
            name: name,
            parentID: parentID,
            contentType: contentType,
            data: data,
            metadata: metadata
        )
        completedUploads.append(Upload(name: name, parentID: parentID, data: data))
        remoteFilesByID[id] = (file, data)
        return file
    }

    /** Atomically creates one in-memory remote object without replacing an occupied name. */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        let data = try RemoteSyncBoundedFileIO.readRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        let id = "\(parentID)/\(name)"
        guard remoteFilesByID[id] == nil else {
            return .alreadyExists
        }
        if shouldSuspendNextUpload {
            shouldSuspendNextUpload = false
            uploadDidStart = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            guard remoteFilesByID[id] == nil else {
                return .alreadyExists
            }
        }
        let metadata = nextUploadMetadata(for: data)
        let file = makeRemoteFile(
            id: id,
            name: name,
            parentID: parentID,
            contentType: contentType,
            data: data,
            metadata: metadata
        )
        completedUploads.append(Upload(name: name, parentID: parentID, data: data))
        remoteFilesByID[id] = (file, data)
        return .created(file)
    }

    /** Removes one in-memory remote object. */
    func delete(id: String) async throws {
        remoteFilesByID.removeValue(forKey: id)
    }

    /** Returns a stable known-folder result for protocol completeness. */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        true
    }

    /** Returns a stable marker name for protocol completeness. */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        "device-known-\(deviceIdentifier)-secret"
    }

    /** Consumes the next server metadata fixture or derives metadata from local bytes. */
    private func nextUploadMetadata(for data: Data) -> UploadMetadata {
        guard !uploadMetadata.isEmpty else {
            return UploadMetadata(timestamp: 0, size: Int64(data.count))
        }
        return uploadMetadata.removeFirst()
    }

    /** Builds one remote file descriptor from deterministic server metadata. */
    private func makeRemoteFile(
        id: String,
        name: String,
        parentID: String,
        contentType: String,
        data: Data,
        metadata: UploadMetadata
    ) -> RemoteSyncFile {
        RemoteSyncFile(
            id: id,
            name: name,
            size: metadata.size ?? Int64(data.count),
            timestamp: metadata.timestamp,
            parentID: parentID,
            mimeType: contentType
        )
    }
}
