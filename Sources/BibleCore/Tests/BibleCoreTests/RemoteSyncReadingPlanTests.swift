import XCTest
@testable import BibleCore
import SwiftData

/**
 Package-level reading-plan sync tests migrated from the app-host bundle.

 The suite validates Android-compatible reading-plan status persistence, snapshot restore,
 patch replay, and initial backup upload through BibleCore services only. It intentionally avoids
 BibleUI, BibleView, and app bootstrap dependencies so the migration preserves coverage while moving
 the behavior into the app-host-free package lane.
 */
final class RemoteSyncReadingPlanTests: XCTestCase {
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
        4: Luke.1
        5 Matt.1,\\
          Mark.2
        6 = Rev.\\u0032\\u0031-Rev.\\u0032\\u0032
        ! ignored Android comment
        """

        let parsedReadings = ReadingPlanService.parseProperties(propertiesText)

        XCTAssertEqual(
            parsedReadings,
            [
                1: "Gen.1-Gen.2",
                2: "Matt.1, Mark.1",
                3: "1Cor.13, 2Tim.1-2Tim.2",
                4: "Luke.1",
                5: "Matt.1,Mark.2",
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
        XCTAssertEqual(template.readingsForDay(4), "Luke.1")
        XCTAssertEqual(template.readingsForDay(5), "Matt.1,Mark.2")
        XCTAssertEqual(template.readingsForDay(6), "Rev.21-Rev.22")
    }

    /**
     Protects Android built-in catalog parity for bundled reading plans.

     Android's `ReadingPlanTextFileDao` exposes the bundled `.properties` assets as the default
     catalog, while add-on and user-file discovery is tracked separately in issue #338. The iOS
     catalog must therefore contain exactly the same bundled plan codes and must not retain
     iOS-only algorithmic templates. A failure means the visible picker and remote-sync restore
     support have drifted from Android's built-in definition set.
     */
    func testReadingPlanCatalogMatchesAndroidBundledAssets() throws {
        let planCodes = ReadingPlanService.availablePlans.map(\.code)

        XCTAssertEqual(
            Set(planCodes),
            Set([
                "y1ot1nt1_OTthenNT",
                "y1ot1nt1_OTandNT",
                "y1ot1nt1_chronological",
                "y1ot1nt2_mcheyne",
                "y1ot6nt4_profHorner",
                "y1ntpspr",
                "y2ot1ntps2",
            ])
        )
        XCTAssertEqual(planCodes.count, 7)
        XCTAssertFalse(planCodes.contains("nt_90"))
        XCTAssertFalse(planCodes.contains("psalms_proverbs"))
    }

    /**
     Protects Android `ReadingPlanTextFileDao` discovery parity for user and add-on plan files.

     Android orders built-in plans first, then appends unique files from `jsword/readingplan`, then
     appends unique `AndBibleProvidesReadingPlan` add-on files. User files with built-in names do
     not add duplicate rows, but they do trigger the selector warning and supply the plan content
     when that code is loaded. Add-on files win over same-code user files without adding another
     row. The setup writes one duplicate user file, one unique user file, one user/add-on shared
     code, and one add-on-only file. A failure means iOS is either preserving the old bundled-only
     catalog or has introduced iOS-only duplicate/shadowing behavior.
     */
    func testReadingPlanCatalogDiscoversAndroidUserAndAddonPlans() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userPlanDir = tempDir.appendingPathComponent("jsword/readingplan", isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let addonDir = swordDir
            .appendingPathComponent("modules/genbook/rawgenbook/planaddon", isDirectory: true)
        try FileManager.default.createDirectory(at: userPlanDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        # Duplicate User Plan
        # This description should not replace Android's built-in display metadata.
        1=Exod.1
        2=Exod.2
        """.write(
            to: userPlanDir.appendingPathComponent("y1ot1nt1_OTthenNT.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # User Supplied Plan
        # User plan description.
        1=Mark.1
        """.write(
            to: userPlanDir.appendingPathComponent("user_supplied.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # User Shared Plan
        # This metadata must lose to the add-on provider.
        1=John.1
        """.write(
            to: userPlanDir.appendingPathComponent("shared_code.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # Add-on ignored comments
        1=Luke.1
        """.write(
            to: addonDir.appendingPathComponent("addon_plan.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # Shared add-on ignored comments
        1=Acts.1
        """.write(
            to: addonDir.appendingPathComponent("shared_code.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [PLANADDON]
        Description=Add-on Reading Plans
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./modules/genbook/rawgenbook/planaddon/
        ShortPromo=Plans supplied by an add-on module.
        AndBibleReadingPlanDateBased=True
        AndBibleProvidesReadingPlan=addon_plan.properties
        AndBibleProvidesReadingPlan=shared_code.properties
        """.write(
            to: modsDir.appendingPathComponent("planaddon.conf"),
            atomically: true,
            encoding: .utf8
        )

        let catalog = ReadingPlanService.catalog(
            userPlanDirectory: userPlanDir,
            modulePath: swordDir.path
        )

        let planCodes = catalog.templates.map(\.code)
        let builtInCodes = [
            "y1ot1nt1_OTthenNT",
            "y1ot1nt1_OTandNT",
            "y1ot1nt1_chronological",
            "y1ot1nt2_mcheyne",
            "y1ot6nt4_profHorner",
            "y1ntpspr",
            "y2ot1ntps2",
        ]
        XCTAssertEqual(Array(planCodes.prefix(builtInCodes.count)), builtInCodes)
        XCTAssertEqual(Set(planCodes.dropFirst(builtInCodes.count).prefix(2)), ["user_supplied", "shared_code"])
        XCTAssertEqual(planCodes.last, "addon_plan")
        XCTAssertEqual(catalog.duplicateUserPlanCodes, ["y1ot1nt1_OTthenNT"])

        let duplicateBuiltIn = try XCTUnwrap(
            catalog.templates.first { $0.code == "y1ot1nt1_OTthenNT" }
        )
        XCTAssertEqual(duplicateBuiltIn.name, "1-Year through Bible")
        XCTAssertEqual(duplicateBuiltIn.readingsForDay(1), "Exod.1")
        XCTAssertEqual(duplicateBuiltIn.totalDays, 2)

        let userPlan = try XCTUnwrap(catalog.templates.first { $0.code == "user_supplied" })
        XCTAssertEqual(userPlan.name, "User Supplied Plan")
        XCTAssertEqual(userPlan.description, "User plan description.")
        XCTAssertEqual(userPlan.readingsForDay(1), "Mark.1")

        let sharedPlan = try XCTUnwrap(catalog.templates.first { $0.code == "shared_code" })
        XCTAssertEqual(sharedPlan.name, "Add-on Reading Plans")
        XCTAssertEqual(sharedPlan.description, "Plans supplied by an add-on module.")
        XCTAssertEqual(sharedPlan.readingsForDay(1), "Acts.1")
        XCTAssertTrue(sharedPlan.isDateBased)

        let addonPlan = try XCTUnwrap(catalog.templates.first { $0.code == "addon_plan" })
        XCTAssertEqual(addonPlan.name, "Add-on Reading Plans")
        XCTAssertEqual(addonPlan.description, "Plans supplied by an add-on module.")
        XCTAssertEqual(addonPlan.readingsForDay(1), "Luke.1")
        XCTAssertTrue(addonPlan.isDateBased)
    }

    /**
     Verifies starting an Android-backed built-in template still materializes every day row.

     The setup uses the same bundled plan code Android starts from `ReadingPlanSelectorList`.
     The expected result proves removing iOS-only templates does not regress persisted lifecycle
     behavior for the supported Android plan catalog. A failure means catalog parity was achieved
     by losing the start-plan graph that list, daily-reading, and sync flows depend on.
     */
    func testReadingPlanAndroidTemplateLifecycleUsesBundledProperties() throws {
        let androidTemplate = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )

        XCTAssertEqual(androidTemplate.readingsForDay(1), "Gen.1-Gen.4")

        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(
            template: androidTemplate,
            modelContext: modelContext
        )

        XCTAssertEqual(plan.planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(plan.planName, "1-Year through Bible")
        XCTAssertEqual(plan.currentDay, 0)
        XCTAssertEqual(plan.totalDays, 365)
        XCTAssertTrue(plan.isActive)
        XCTAssertEqual(ReadingPlanService.expectedDay(for: plan), 1)

        let days = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertEqual(days.count, 365)
        XCTAssertEqual(Array(days.prefix(3).map(\.dayNumber)), [1, 2, 3])
        XCTAssertEqual(days.first?.readings, "Gen.1-Gen.4")
        XCTAssertEqual(days.last?.dayNumber, 365)
        XCTAssertFalse(days[0].isCompleted)

        days[0].isCompleted = true
        try modelContext.save()

        XCTAssertEqual(
            ReadingPlanService.completionPercentage(for: plan),
            1.0 / 365.0,
            accuracy: 0.0001
        )
    }

    /**
     Verifies new plans store Android's calendar-day start anchor instead of the current timestamp.

     Android starts a plan with `CommonUtils.truncatedDate`, so day progression advances on the next
     calendar day rather than 24 hours after the user tapped Start. A failure means a plan started
     later in the day can remain on day 1 past midnight, creating iOS-only reading-plan drift.
     */
    func testReadingPlanStartPlanUsesAndroidTruncatedStartDate() throws {
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let calendar = Calendar.current

        XCTAssertEqual(plan.startDate, calendar.startOfDay(for: plan.startDate))
    }

    /**
     Verifies expected-day calculation advances at the next calendar day boundary.

     Existing local plans can already have timestamped start dates from the older iOS-only behavior.
     Matching Android requires deriving elapsed days from normalized calendar dates, not from the
     exact elapsed seconds between two timestamps.
     */
    func testReadingPlanExpectedDayUsesCalendarDayBoundary() throws {
        let calendar = Calendar.current
        let startDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 2, day: 3, hour: 22, minute: 15))
        )
        let nextMorning = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 2, day: 4, hour: 0, minute: 30))
        )
        let plan = ReadingPlan(
            planCode: "y1ot1nt1_OTthenNT",
            planName: "1-Year through Bible",
            startDate: startDate,
            currentDay: 1,
            totalDays: 365,
            isActive: true
        )

        XCTAssertEqual(ReadingPlanService.expectedDay(for: plan, asOf: nextMorning), 2)
    }

    /**
     Verifies Android's current-day action can rebase a plan and mark previous days complete.

     Android's `DailyReading.setCurrentDay` makes the selected day today's plan day and marks prior
     days read. This test fixes the clock so the start-date mutation is deterministic, then checks
     that earlier rows are complete while the selected and future days remain open. A failure means
     iOS exposes the daily-reading control without preserving Android's persisted status contract.
     */
    func testReadingPlanSetCurrentDayMirrorsAndroidStatusAndStartDateMutation() throws {
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let expectedStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))

        ReadingPlanService.setCurrentDay(5, for: plan, modelContext: modelContext, now: now)

        XCTAssertEqual(plan.currentDay, 5)
        XCTAssertEqual(plan.startDate, expectedStart)
        let days = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertTrue(days[0].isCompleted)
        XCTAssertTrue(days[3].isCompleted)
        XCTAssertNotNil(days[0].completedDate)
        XCTAssertFalse(days[4].isCompleted)
        XCTAssertNil(days[4].completedDate)
        XCTAssertFalse(days[5].isCompleted)
    }

    /**
     Verifies Android's start-date action updates the persisted plan anchor without rewriting statuses.

     Android lets the user choose a new plan start date from Daily Reading while preserving existing
     read/unread day statuses. The setup marks one row complete before rebasing the date; the expected
     result proves the start anchor and current-day pointer update while completion state remains
     user-authored. A failure means iOS start-date parity is corrupting progress history.
     */
    func testReadingPlanSetStartDateRebasesCurrentDayWithoutChangingStatuses() throws {
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let newStartDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let days = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        days[0].isCompleted = true
        days[0].completedDate = today
        try modelContext.save()

        ReadingPlanService.setStartDate(newStartDate, for: plan, modelContext: modelContext, now: now)

        XCTAssertEqual(plan.startDate, newStartDate)
        XCTAssertEqual(plan.currentDay, 3)
        XCTAssertTrue(days[0].isCompleted)
        XCTAssertFalse(days[1].isCompleted)
        XCTAssertFalse(days[2].isCompleted)
    }

    /**
     Verifies Android's start-date maximum date is enforced below the UI layer.

     Android's date picker rejects future start dates by setting `maxDate` to today. The iOS service
     helper also clamps future inputs so backup, tests, or future non-picker call sites cannot create
     a current-plan state Android would not allow. A failure means the SwiftUI picker may look correct
     while programmatic plan mutation still preserves an iOS-only future-date behavior.
     */
    func testReadingPlanSetStartDateCapsFutureDateAtToday() throws {
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let futureStartDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))

        ReadingPlanService.setStartDate(futureStartDate, for: plan, modelContext: modelContext, now: now)

        XCTAssertEqual(plan.startDate, today)
        XCTAssertEqual(plan.currentDay, 1)
    }

    /**
     Verifies reset deletes the selected reading plan graph, matching Android's current-plan reset.

     Android clears the current plan's stored plan info and day statuses. In iOS the equivalent
     persisted unit is the `ReadingPlan` plus cascaded `ReadingPlanDay` rows, so the service should
     delete the graph and save. A failure means Daily Reading can appear reset while stale plan/day
     rows remain available to list, sync, or restore flows.
     */
    func testReadingPlanResetDeletesPlanGraph() throws {
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)

        ReadingPlanService.resetPlan(plan, modelContext: modelContext)

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<ReadingPlan>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<ReadingPlanDay>()).isEmpty)
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

    /**
     Verifies Android-historic reading-plan days remain implicit when uploading local snapshots.

     For non-date-based plans, Android derives completed days before `currentDay` from the plan row
     itself and does not need `ReadingPlanStatus` rows for those historic days. iOS still marks those
     local rows complete for UI progress, but snapshot upload must not turn that local projection into
     extra Android status rows.
     */
    func testReadingPlanSnapshotDoesNotSynthesizeHistoricNonDateStatuses() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.currentDay = 3
        let days = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        days[0].isCompleted = true
        days[1].isCompleted = true
        try modelContext.save()

        let snapshot = RemoteSyncReadingPlanSnapshotService().snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertTrue(snapshot.statusRowsByKey.isEmpty)
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
                entityID1: .blob(readingPlanUUIDBlob(statusID)),
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
                    entityID1: .blob(readingPlanUUIDBlob(statusID)),
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
                entityID1: .blob(readingPlanUUIDBlob(planID)),
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
                    entityID1: .blob(readingPlanUUIDBlob(planID)),
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
        let adapter = ReadingPlanMockRemoteSyncAdapter()
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
        XCTAssertTrue(snapshot.plans[0].statuses.isEmpty)
    }

}
