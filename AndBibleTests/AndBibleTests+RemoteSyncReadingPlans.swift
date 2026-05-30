import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testRemoteSyncReadingPlanStatusStorePersistsAndClearsStatuses() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)

        statusStore.setStatus(#"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#, planCode: "y1ot1nt1_OTthenNT", dayNumber: 1)
        statusStore.setStatus(#"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#, planCode: "plan.with.dots", dayNumber: 2)

        XCTAssertEqual(
            statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
        )
        XCTAssertEqual(
            statusStore.status(planCode: "plan.with.dots", dayNumber: 2),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )

        XCTAssertEqual(
            statusStore.allStatuses(),
            [
                .init(planCode: "plan.with.dots", dayNumber: 2, readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#),
                .init(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1, readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#),
            ]
        )

        statusStore.clearAll()
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncReadingPlanStatusStorePreservesRemoteStatusIdentifiers() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let remoteStatusID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!

        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: "y1ot1nt1_OTthenNT",
            dayNumber: 1,
            remoteStatusID: remoteStatusID
        )

        XCTAssertEqual(
            statusStore.storedStatus(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1),
            .init(
                planCode: "y1ot1nt1_OTthenNT",
                dayNumber: 1,
                readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                remoteStatusID: remoteStatusID
            )
        )
        XCTAssertEqual(
            statusStore.status(remoteStatusID: remoteStatusID),
            .init(
                planCode: "y1ot1nt1_OTthenNT",
                dayNumber: 1,
                readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                remoteStatusID: remoteStatusID
            )
        )
    }

    func testReadingPlanCustomPropertiesImportPreservesAndroidSyntax() throws {
        let propertiesText = """
        # Android-style custom plan
        Versification=KJV
        1 = Gen.1-Gen.2
        2=Matt.1, Mark.1
        day3=Ignored
        3 = 1Cor.13, 2Tim.1-2Tim.2
        6 = Rev.21-Rev.22
        """

        let parsedReadings = ReadingPlanService.parseProperties(propertiesText)

        XCTAssertEqual(
            parsedReadings,
            [
                1: "Gen.1-Gen.2",
                2: "Matt.1, Mark.1",
                3: "1Cor.13, 2Tim.1-2Tim.2",
                6: "Rev.21-Rev.22",
            ]
        )
        XCTAssertNil(parsedReadings[0])

        let template = try XCTUnwrap(
            ReadingPlanService.importCustomPlan(
                name: "Custom Android Plan",
                propertiesText: propertiesText
            )
        )

        XCTAssertTrue(template.code.hasPrefix("custom_"))
        XCTAssertEqual(template.name, "Custom Android Plan")
        XCTAssertEqual(template.description, "Custom imported reading plan (6 days).")
        XCTAssertEqual(template.totalDays, 6)
        XCTAssertEqual(template.readingsForDay(1), "Gen.1-Gen.2")
        XCTAssertEqual(template.readingsForDay(2), "Matt.1, Mark.1")
        XCTAssertEqual(template.readingsForDay(3), "1Cor.13, 2Tim.1-2Tim.2")
        XCTAssertEqual(template.readingsForDay(4), "")
        XCTAssertEqual(template.readingsForDay(6), "Rev.21-Rev.22")
    }

    func testReadingPlanAlgorithmicPlanLifecycleRemainsAdditive() throws {
        let androidTemplate = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let algorithmicTemplate = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "nt_90" })
        )

        XCTAssertEqual(androidTemplate.readingsForDay(1), "Gen.1-Gen.4")
        XCTAssertEqual(algorithmicTemplate.name, "New Testament in 90 Days")
        XCTAssertEqual(algorithmicTemplate.totalDays, 90)
        XCTAssertEqual(algorithmicTemplate.readingsForDay(1), "Matt.1,Matt.2,Matt.3")

        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(
            template: algorithmicTemplate,
            modelContext: modelContext
        )

        XCTAssertEqual(plan.planCode, "nt_90")
        XCTAssertEqual(plan.planName, "New Testament in 90 Days")
        XCTAssertEqual(plan.currentDay, 0)
        XCTAssertEqual(plan.totalDays, 90)
        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(ReadingPlanService.expectedDay(for: plan), 1)

        let days = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertEqual(days.count, 90)
        XCTAssertEqual(Array(days.prefix(3).map(\.dayNumber)), [1, 2, 3])
        XCTAssertEqual(days.first?.readings, "Matt.1,Matt.2,Matt.3")
        XCTAssertEqual(days.last?.dayNumber, 90)
        XCTAssertFalse(days[0].isCompleted)

        days[0].isCompleted = true
        try modelContext.save()

        XCTAssertEqual(
            ReadingPlanService.completionPercentage(for: plan),
            1.0 / 90.0,
            accuracy: 0.0001
        )
    }

    func testRemoteSyncReadingPlanRestoreReadsAndroidSnapshot() throws {
        let service = RemoteSyncReadingPlanRestoreService()
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 3
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 3,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(snapshot.orphanStatuses, [])
        XCTAssertEqual(snapshot.plans.count, 1)
        XCTAssertEqual(snapshot.plans[0].id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(snapshot.plans[0].planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(snapshot.plans[0].currentDay, 3)
        XCTAssertEqual(snapshot.plans[0].statuses.count, 1)
        XCTAssertEqual(snapshot.plans[0].statuses[0].dayNumber, 3)
    }

    func testRemoteSyncReadingPlanRestoreReplacesLocalPlansAndPreservesAndroidStatuses() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let existingPlan = ReadingPlan(
            planCode: "legacy_plan",
            planName: "Legacy",
            startDate: Date(timeIntervalSince1970: 42),
            currentDay: 1,
            totalDays: 1,
            isActive: true
        )
        modelContext.insert(existingPlan)
        try modelContext.save()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 3
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 3,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        let report = try service.replaceLocalReadingPlans(
            from: snapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        XCTAssertEqual(report.restoredPlanCodes, ["y1ot1nt1_OTthenNT"])
        XCTAssertEqual(report.preservedStatusCount, 1)

        let restoredPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(restoredPlans.count, 1)
        XCTAssertEqual(restoredPlans[0].id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(restoredPlans[0].planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(restoredPlans[0].currentDay, 3)
        XCTAssertTrue(restoredPlans[0].isActive)
        XCTAssertEqual(restoredPlans[0].days?.count, report.restoredDayCount)

        let restoredDays = (restoredPlans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertTrue(restoredDays[0].isCompleted)
        XCTAssertTrue(restoredDays[1].isCompleted)
        XCTAssertFalse(restoredDays[2].isCompleted)

        XCTAssertEqual(
            statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 3),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )
    }

    func testRemoteSyncReadingPlanRestoreRejectsUnknownPlanDefinitionsWithoutMutation() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let existingPlan = ReadingPlan(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            planCode: "existing_plan",
            planName: "Existing",
            startDate: Date(timeIntervalSince1970: 100),
            currentDay: 1,
            totalDays: 1,
            isActive: true
        )
        modelContext.insert(existingPlan)
        try modelContext.save()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    planCode: "custom_missing",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: []
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        XCTAssertThrowsError(
            try service.replaceLocalReadingPlans(
                from: snapshot,
                modelContext: modelContext,
                statusStore: statusStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanRestoreError,
                .unsupportedPlanDefinitions(["custom_missing"])
            )
        }

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.map(\.planCode), ["existing_plan"])
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncReadingPlanRestoreRejectsOrphanStatusesWithoutMutation() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let existingPlan = ReadingPlan(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            planCode: "existing_plan",
            planName: "Existing",
            startDate: Date(timeIntervalSince1970: 100),
            currentDay: 1,
            totalDays: 1,
            isActive: true
        )
        modelContext.insert(existingPlan)
        try modelContext.save()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [],
            statuses: [
                .init(
                    id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                    planCode: "orphan_plan",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        XCTAssertThrowsError(
            try service.replaceLocalReadingPlans(
                from: snapshot,
                modelContext: modelContext,
                statusStore: statusStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanRestoreError,
                .orphanStatuses(["orphan_plan"])
            )
        }

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.map(\.planCode), ["existing_plan"])
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncReadingPlanRestoreRejectsMalformedStatusPayloads() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":"bad"}"#
                )
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        XCTAssertThrowsError(
            try service.replaceLocalReadingPlans(
                from: snapshot,
                modelContext: modelContext,
                statusStore: statusStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanRestoreError,
                .malformedReadingStatus(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1)
            )
        }
    }

    func testRemoteSyncInitialBackupRestoreDispatchesReadingPlanBackups() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncInitialBackupRestoreService()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "a1000000-0000-0000-0000-000000000011")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1_024,
                timestamp: 1_735_689_600_000,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        let report = try service.restoreInitialBackup(
            stagedBackup,
            category: .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .readingPlans(
                RemoteSyncReadingPlanRestoreReport(
                    restoredPlanCodes: ["y1ot1nt1_OTthenNT"],
                    restoredDayCount: ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!.totalDays,
                    preservedStatusCount: 1
                )
            )
        )

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.map(\.planCode), ["y1ot1nt1_OTthenNT"])

        let preservedStatuses = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore).allStatuses()
        XCTAssertEqual(
            preservedStatuses,
            [
                .init(
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                    remoteStatusID: UUID(uuidString: "a1000000-0000-0000-0000-000000000011")!
                )
            ]
        )
    }

    func testRemoteSyncReadingPlanPatchApplyReplaysNewerRowsAndRecordsPatchStatus() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let restoreService = RemoteSyncReadingPlanRestoreService()
        let patchService = RemoteSyncReadingPlanPatchApplyService()

        let planID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "d1000000-0000-0000-0000-000000000011")!
        let patchStatusID = UUID(uuidString: "d1000000-0000-0000-0000-000000000022")!

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
                entityID1: .blob(uuidBlob(planID)),
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
                entityID1: .blob(uuidBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
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
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(patchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 2,
            fileTimestamp: 1_735_689_800_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 2)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(report.restoredPlanCodes, ["y1ot1nt1_OTthenNT"])
        XCTAssertEqual(report.preservedStatusCount, 2)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        let days = (plans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertTrue(days[0].isCompleted)
        XCTAssertTrue(days[1].isCompleted)

        XCTAssertEqual(
            statusStore.storedStatus(planCode: "y1ot1nt1_OTthenNT", dayNumber: 2),
            .init(
                planCode: "y1ot1nt1_OTthenNT",
                dayNumber: 2,
                readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                remoteStatusID: patchStatusID
            )
        )
        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                .init(
                    sourceDevice: "pixel",
                    patchNumber: 2,
                    sizeBytes: Int64((try FileManager.default.attributesOfItem(atPath: stagedArchive.archiveFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0),
                    appliedDate: 1_735_689_800_000
                )
            ]
        )
    }

    func testRemoteSyncReadingPlanPatchApplyDeletesStatusesByRemoteIdentifier() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let restoreService = RemoteSyncReadingPlanRestoreService()
        let patchService = RemoteSyncReadingPlanPatchApplyService()

        let planID = UUID(uuidString: "d2000000-0000-0000-0000-000000000001")!
        let statusID = UUID(uuidString: "d2000000-0000-0000-0000-000000000011")!

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
                    id: statusID,
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
                tableName: "ReadingPlanStatus",
                entityID1: .blob(uuidBlob(statusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "tablet"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [],
            statuses: [],
            logEntries: [
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(statusID)),
                    entityID2: .text(""),
                    type: .delete,
                    lastUpdated: 2_000,
                    sourceDevice: "tablet"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "tablet",
            patchNumber: 3,
            fileTimestamp: 1_735_689_900_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertNil(statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1))

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        let days = (plans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertFalse(days[0].isCompleted)
    }

    func testRemoteSyncReadingPlanPatchApplySkipsOlderRows() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchService = RemoteSyncReadingPlanPatchApplyService()

        let planID = UUID(uuidString: "d3000000-0000-0000-0000-000000000001")!
        let plan = ReadingPlan(
            id: planID,
            planCode: "y1ot1nt1_OTthenNT",
            planName: "Read the Bible in One Year",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            currentDay: 1,
            totalDays: ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!.totalDays,
            isActive: true
        )
        modelContext.insert(plan)
        try modelContext.save()

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 5_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 9
                )
            ],
            statuses: [],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 4_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 4,
            fileTimestamp: 1_735_690_000_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 0)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans[0].currentDay, 1)
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    /**
     Verifies that initial-backup upload writes a full Android reading-plan database and records the
     accepted patch-zero baseline locally.
     */
    func testRemoteSyncInitialBackupUploadWritesReadingPlanDatabaseAndResetsBaseline() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        plan.currentDay = 2
        let firstDay = try XCTUnwrap(plan.days?.first(where: { $0.dayNumber == 1 }))
        firstDay.isCompleted = true
        firstDay.completedDate = Date(timeIntervalSince1970: 1_735_689_700)
        try modelContext.save()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let adapter = MockRemoteSyncAdapter()
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
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "ios-device",
            nowProvider: { 1_900 }
        )

        let report = try await service.uploadInitialBackup(
            for: .readingPlans,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(
            report.patchZeroStatus,
            RemoteSyncPatchStatus(
                sourceDevice: "ios-device",
                patchNumber: 0,
                sizeBytes: report.uploadedFile.size,
                appliedDate: 2_000
            )
        )
        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: report.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 1_900)
        XCTAssertNil(stateStore.progressState(for: .readingPlans).lastSynchronized)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .upload(
                name: "initial.sqlite3.gz",
                parentID: syncFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-readingplan-initial-\(UUID().uuidString).sqlite3.gz")
        let databaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let initialDatabaseData = try gunzipTestData(uploadedArchive.data)
        try initialDatabaseData.write(to: databaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        XCTAssertTrue(metadataSnapshot.logEntries.isEmpty)
        XCTAssertTrue(metadataSnapshot.patchStatuses.isEmpty)

        let snapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(snapshot.orphanStatuses, [])
        XCTAssertEqual(snapshot.plans.count, 1)
        XCTAssertEqual(snapshot.plans[0].planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(snapshot.plans[0].currentDay, 2)
        XCTAssertEqual(snapshot.plans[0].statuses.count, 1)
        XCTAssertEqual(snapshot.plans[0].statuses[0].dayNumber, 1)
    }

}
