import XCTest
@testable import BibleCore
import SwiftData

/// Deterministic failure injected after replacement graph and status rows have been staged.
private enum SimulatedReadingPlanRestoreError: Error, Equatable {
    /// Represents a non-cancellation restore failure before the single atomic save.
    case interruptedBeforeCommit
}

/// Deterministic graph-read failures injected at destructive patch synchronization boundaries.
private enum SimulatedReadingPlanPatchReadError: Error, Equatable {
    /// Current local plans could not be loaded before archive replay began.
    case preflightProjectionFailed

    /// The accepted post-replay graph could not be projected into fingerprint rows.
    case fingerprintProjectionFailed
}

/// File-backed SwiftData store whose final transaction commit is rejected by a regression test.
private enum ReadingPlanRestoreFailingStore {
    /// Configuration containing `ReadingPlan` and `ReadingPlanDay` rows.
    case graph

    /// Configuration containing preserved Android status `Setting` rows.
    case settings
}

/**
 Shared multi-plan fixture used to prove restore success and rollback against the same durable state.

 The fixture owns one clean context containing two legacy plans, days, and preserved statuses plus a
 replacement snapshot containing two bundled Android plans and statuses. Tests reopen the container
 with a new context so assertions observe only committed state, not in-memory mutation artifacts.
 */
private struct AtomicReadingPlanRestoreFixture {
    let container: ModelContainer
    let modelContext: ModelContext
    let statusStore: RemoteSyncReadingPlanStatusStore
    let replacementSnapshot: RemoteSyncAndroidReadingPlanSnapshot
}

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

    /**
     Verifies Java-properties parsing and compatibility imports keep deterministic Android identity.

     Android identifies a custom reading plan by its `.properties` filename stem. The compatibility
     overload has no filename, so it deterministically derives the same kind of stable code from the
     supplied behavior name; parsing the same definition twice must not create random identities.
     A failure means custom progress cannot resolve the same definition after reconstruction.
     */
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
        let reconstructedTemplate = try XCTUnwrap(
            ReadingPlanService.importCustomPlan(
                name: "Custom Android Plan",
                propertiesText: propertiesText
            )
        )

        XCTAssertEqual(template.code, "Custom_Android_Plan")
        XCTAssertEqual(reconstructedTemplate.code, template.code)
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
        let plan = try ReadingPlanService.startPlan(
            template: androidTemplate,
            modelContext: modelContext
        )

        XCTAssertEqual(plan.planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(plan.planName, "1-Year through Bible")
        XCTAssertEqual(plan.currentDay, 1)
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
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let calendar = Calendar.current

        XCTAssertEqual(plan.startDate, calendar.startOfDay(for: plan.startDate))
    }

    /**
     Verifies a date-based plan selects its day at the next calendar boundary.

     Android derives ordinary-plan position from persisted `planCurrentDay`; only date-prefixed plans
     search their assignments using today's local calendar date. A fixed Gregorian UTC calendar
     proves the lookup crosses midnight without depending on the process locale or time zone.
     */
    func testReadingPlanExpectedDayUsesCalendarDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
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
            currentDay: 9,
            totalDays: 2,
            isActive: true
        )
        let firstDay = ReadingPlanDay(dayNumber: 1, readings: "Feb-3;Gen.1")
        let secondDay = ReadingPlanDay(dayNumber: 2, readings: "Feb-4;Gen.2")
        firstDay.plan = plan
        secondDay.plan = plan

        XCTAssertEqual(
            ReadingPlanService.expectedDay(for: plan, asOf: nextMorning, calendar: calendar),
            2
        )
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
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let expectedStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -4, to: today))

        try ReadingPlanService.setCurrentDay(5, for: plan, modelContext: modelContext, now: now)

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
     Verifies Android's start-date action preserves the persisted day pointer and statuses.

     `ReadingPlanRepository.startPlan` updates `planStartDate` on an existing Room row without
     changing `planCurrentDay`. The setup gives the pointer a value unrelated to the date offset and
     marks one row complete, proving neither pointer nor status is recomputed during the mutation.
     A failure means iOS date editing is rewriting Android-owned progress state.
     */
    func testReadingPlanSetStartDatePreservesCurrentDayAndStatuses() throws {
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 2, day: 6, hour: 12))
        )
        let today = calendar.startOfDay(for: now)
        let newStartDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let days = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        plan.currentDay = 4
        days[0].isCompleted = true
        days[0].completedDate = today
        try modelContext.save()

        try ReadingPlanService.setStartDate(
            newStartDate,
            for: plan,
            modelContext: modelContext,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(plan.startDate, newStartDate)
        XCTAssertEqual(plan.currentDay, 4)
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
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let futureStartDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: today))

        try ReadingPlanService.setStartDate(futureStartDate, for: plan, modelContext: modelContext, now: now)

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
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)

        try ReadingPlanService.resetPlan(plan, modelContext: modelContext)

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

    /**
     Verifies exact Android timestamps and raw current-day pointers survive restore and projection.

     Failure means signed 64-bit milliseconds pass through `Double`, or current-day reads clamp a
     valid large Android value to the local definition's final materialized day.
     */
    func testReadingPlanRestorePreservesExactTimestampsAndCurrentDaySemantics() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let templates = ReadingPlanService.availablePlans
        let lowerTemplate = try XCTUnwrap(templates.first)
        let upperTemplate = try XCTUnwrap(templates.dropFirst().first)
        let lowerID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
        let upperID = UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
        let lowerMilliseconds = Int64.min + 17
        let upperMilliseconds = Int64.max - 17

        _ = try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
            from: RemoteSyncAndroidReadingPlanSnapshot(
                plans: [
                    .init(
                        id: lowerID,
                        planCode: lowerTemplate.code,
                        startDateMilliseconds: lowerMilliseconds,
                        currentDay: Int(Int32.min),
                        statuses: []
                    ),
                    .init(
                        id: upperID,
                        planCode: upperTemplate.code,
                        startDateMilliseconds: upperMilliseconds,
                        currentDay: Int(Int32.max),
                        statuses: []
                    ),
                ]
            ),
            modelContext: context,
            statusStore: RemoteSyncReadingPlanStatusStore(settingsStore: settings)
        )

        let plans = try context.fetch(FetchDescriptor<ReadingPlan>())
        let lowerPlan = try XCTUnwrap(plans.first { $0.id == lowerID })
        let upperPlan = try XCTUnwrap(plans.first { $0.id == upperID })
        XCTAssertEqual(ReadingPlanService.expectedDay(for: lowerPlan), 1)
        XCTAssertEqual(ReadingPlanService.expectedDay(for: upperPlan), Int(Int32.max))

        let current = try RemoteSyncReadingPlanSnapshotService()
            .snapshotCurrentStateStrict(modelContext: context, settingsStore: settings)
        let rowsByID = Dictionary(uniqueKeysWithValues: current.planRowsByKey.values.map {
            ($0.id, $0)
        })
        XCTAssertEqual(rowsByID[lowerID]?.planStartDateMillis, lowerMilliseconds)
        XCTAssertEqual(rowsByID[upperID]?.planStartDateMillis, upperMilliseconds)
        XCTAssertEqual(rowsByID[lowerID]?.planCurrentDay, Int(Int32.min))
        XCTAssertEqual(rowsByID[upperID]?.planCurrentDay, Int(Int32.max))
    }

    func testRemoteSyncReadingPlanRestoreReplacesLocalPlansAndPreservesAndroidStatuses() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let selectionStore = ReadingPlanSelectionStore(settingsStore: settingsStore)
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
        XCTAssertNil(selectionStore.selectedPlanCode)
        XCTAssertFalse(restoredPlans[0].isActive)
        XCTAssertEqual(restoredPlans[0].days?.count, report.restoredDayCount)

        let restoredDays = (restoredPlans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertTrue(restoredDays[0].isCompleted)
        XCTAssertTrue(restoredDays[1].isCompleted)
        XCTAssertFalse(restoredDays[2].isCompleted)

        XCTAssertEqual(
            statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 3),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )

        try selectionStore.select(restoredPlans[0], among: restoredPlans, modelContext: modelContext)
        XCTAssertEqual(selectionStore.selectedPlanCode, restoredPlans[0].planCode)
        XCTAssertTrue(restoredPlans[0].isActive)
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
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
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

    /**
     Verifies non-destructive snapshot compatibility remains fail-soft while strict projection fails.

     The same injected graph-read error must produce an empty snapshot through the legacy public API
     and propagate through the strict API used by destructive synchronization. A failure means the
     integrity fix either breaks established upload callers or again hides a destructive read error.
     */
    func testReadingPlanSnapshotSeparatesCompatibilityAndStrictFetchBehavior() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService(planFetcher: { _ in
            throw SimulatedReadingPlanPatchReadError.preflightProjectionFailed
        })

        let compatibilitySnapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertTrue(compatibilitySnapshot.planRowsByKey.isEmpty)
        XCTAssertTrue(compatibilitySnapshot.statusRowsByKey.isEmpty)
        XCTAssertTrue(compatibilitySnapshot.fingerprintsByKey.isEmpty)
        XCTAssertThrowsError(
            try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? SimulatedReadingPlanPatchReadError,
                .preflightProjectionFailed
            )
        }
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

    /**
     Verifies successful patch replay publishes graph, statuses, and bookkeeping in one primary save.

     The fixture applies newer plan and status rows, then asserts the final graph, raw status,
     applied-patch record, and exactly one `ModelContext.willSave` notification. A second save means
     replay bookkeeping escaped the outer atomic batch and can drift from the accepted graph.
     */
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

        let publishSaveExpectation = expectation(description: "Patch replay performs one primary save")
        publishSaveExpectation.expectedFulfillmentCount = 1
        publishSaveExpectation.assertForOverFulfill = true
        let saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.willSave,
            object: modelContext,
            queue: nil
        ) { _ in
            publishSaveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(saveObserver) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        wait(for: [publishSaveExpectation], timeout: 1)

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

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore).status(
                for: .readingPlans,
                sourceDevice: "pixel",
                patchNumber: 4
            )?.appliedDate,
            1_735_690_000_000
        )

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
        let plan = try ReadingPlanService.startPlan(template: template, modelContext: modelContext)
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
        XCTAssertGreaterThan(
            try XCTUnwrap(stateStore.progressState(for: .readingPlans).lastPatchWritten),
            1_900
        )
        XCTAssertNil(stateStore.progressState(for: .readingPlans).lastSynchronized)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
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

    /**
     Verifies the generic settings batch defers nested settings writes and commits them once.

     The old key is saved through the ordinary immediate-save path, then two nested upserts and one
     removal run inside `performAtomicBatch`. A separately created context must see only the old state
     while the closure is executing and the complete new state after it returns. A failure means an
     inner settings helper can still publish a partial restore before the graph-level commit.
     */
    func testSettingsStoreAtomicBatchDefersNestedWritesUntilCommit() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        settingsStore.setString("atomic.old", value: "persisted")

        try settingsStore.performAtomicBatch(in: modelContext) {
            settingsStore.remove("atomic.old")
            settingsStore.setString("atomic.first", value: "one")
            try settingsStore.performAtomicBatch(in: modelContext) {
                settingsStore.setString("atomic.second", value: "two")
            }

            let observingStore = SettingsStore(modelContext: ModelContext(container))
            XCTAssertEqual(observingStore.getString("atomic.old"), "persisted")
            XCTAssertNil(observingStore.getString("atomic.first"))
            XCTAssertNil(observingStore.getString("atomic.second"))
        }

        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopenedStore.getString("atomic.old"))
        XCTAssertEqual(reopenedStore.getString("atomic.first"), "one")
        XCTAssertEqual(reopenedStore.getString("atomic.second"), "two")
    }

    /**
     Verifies the atomic settings API rejects mismatched and already-dirty model contexts.

     Both constraints prevent a restore rollback from affecting unrelated pending state or a second
     persistence store. A failure means callers can believe settings joined a graph commit when they
     actually used a different context, or can lose pre-existing unsaved changes during rollback.
     */
    func testSettingsStoreAtomicBatchRequiresExactCleanContext() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let differentContext = ModelContext(container)

        XCTAssertThrowsError(
            try settingsStore.performAtomicBatch(in: differentContext) {
                settingsStore.setString("atomic.mismatch", value: "unsafe")
            }
        ) { error in
            XCTAssertEqual(error as? SettingsStoreAtomicBatchError, .modelContextMismatch)
        }
        XCTAssertNil(SettingsStore(modelContext: ModelContext(container)).getString("atomic.mismatch"))

        modelContext.insert(Setting(key: "atomic.pending", value: "unsaved"))
        XCTAssertThrowsError(
            try settingsStore.performAtomicBatch(in: modelContext) {
                settingsStore.setString("atomic.new", value: "unsafe")
            }
        ) { error in
            XCTAssertEqual(error as? SettingsStoreAtomicBatchError, .pendingModelChanges)
        }
        modelContext.rollback()
        let reopenedStore = SettingsStore(modelContext: ModelContext(container))
        XCTAssertNil(reopenedStore.getString("atomic.pending"))
        XCTAssertNil(reopenedStore.getString("atomic.new"))
    }

    /**
     Verifies nested durable recoveries unwind from the newest snapshot back to the oldest.

     A physical settings-store failure reaches the primary save after outer and inner graph recovery
     callbacks register. The callbacks must both run in reverse registration order so sequential or
     nested graph snapshots finish at the true pre-batch generation. The failed setting must remain
     absent after reopening the file-backed stores.
     */
    func testSettingsStoreAtomicBatchUnwindsNestedDurableRecoveriesInReverseOrder() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsAtomicRecoveryOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let persistentStore = try makePersistentReadingPlanRestoreStore(in: temporaryDirectory)
        let modelContext = ModelContext(persistentStore.container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        var recoveryOrder: [String] = []
        let writeFailure = try ReadingPlanSQLiteStoreWriteFailure(
            databaseURL: persistentStore.settingsStoreURL
        )
        try writeFailure.install()

        XCTAssertThrowsError(
            try settingsStore.performAtomicBatch(
                in: modelContext,
                durableRecovery: { _ in recoveryOrder.append("outer") }
            ) {
                try settingsStore.performAtomicBatch(
                    in: modelContext,
                    durableRecovery: { _ in recoveryOrder.append("inner") }
                ) {
                    settingsStore.setString("atomic.uncommitted", value: "new")
                }
            }
        )

        XCTAssertEqual(recoveryOrder, ["inner", "outer"])
        XCTAssertFalse(modelContext.hasChanges)
        writeFailure.remove()

        let reopenedStore = try makePersistentReadingPlanRestoreStore(in: temporaryDirectory)
        XCTAssertNil(
            SettingsStore(modelContext: ModelContext(reopenedStore.container))
                .getString("atomic.uncommitted")
        )
    }

    /**
     Verifies a successful multi-plan restore publishes the complete replacement snapshot.

     The fixture begins with two durable legacy plan/day/status graphs and restores two different
     bundled Android plans. Assertions use a new context after restore and require both replacement
     plans, every generated day, and both preserved statuses while rejecting every legacy row. A
     failure means the single-save path can report success with only part of the replacement durable.
     */
    func testReadingPlanRestoreAtomicallyCommitsCompleteMultiPlanSnapshot() throws {
        let fixture = try makeAtomicReadingPlanRestoreFixture()

        let report = try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
            from: fixture.replacementSnapshot,
            modelContext: fixture.modelContext,
            statusStore: fixture.statusStore
        )

        let reopenedContext = ModelContext(fixture.container)
        let restoredPlans = try reopenedContext.fetch(FetchDescriptor<ReadingPlan>())
        let restoredDays = try reopenedContext.fetch(FetchDescriptor<ReadingPlanDay>())
        let restoredStatuses = RemoteSyncReadingPlanStatusStore(
            settingsStore: SettingsStore(modelContext: reopenedContext)
        ).allStatuses()

        XCTAssertEqual(restoredPlans.map(\.planCode).sorted(), ["y1ot1nt1_OTthenNT", "y1ot1nt2_mcheyne"])
        XCTAssertEqual(restoredDays.count, report.restoredDayCount)
        XCTAssertEqual(restoredStatuses.count, report.preservedStatusCount)
        XCTAssertEqual(restoredStatuses.map(\.planCode).sorted(), ["y1ot1nt1_OTthenNT", "y1ot1nt2_mcheyne"])
        XCTAssertFalse(restoredPlans.contains { $0.planCode.hasPrefix("legacy_") })
        XCTAssertFalse(restoredStatuses.contains { $0.planCode.hasPrefix("legacy_") })
    }

    /**
     Verifies a non-cancellation failure after two replacement statuses are staged restores all old rows.

     A deterministic checkpoint throws only after both replacement plans, their generated days, and
     two status payloads have entered the shared context. Reopening with a fresh context must reveal
     both complete legacy graphs and no replacement data. A failure identifies a partial commit or a
     rollback that covers settings but not plans/days (or vice versa).
     */
    func testReadingPlanRestoreFailureRollsBackCompleteMultiPlanAndStatusReplacement() throws {
        let fixture = try makeAtomicReadingPlanRestoreFixture()
        var stagedReplacementStatusCount = 0

        XCTAssertThrowsError(
            try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
                from: fixture.replacementSnapshot,
                modelContext: fixture.modelContext,
                statusStore: fixture.statusStore,
                mutationCheckpoint: {
                    stagedReplacementStatusCount = fixture.statusStore.allStatuses().filter {
                        !$0.planCode.hasPrefix("legacy_")
                    }.count
                    if stagedReplacementStatusCount == 2 {
                        throw SimulatedReadingPlanRestoreError.interruptedBeforeCommit
                    }
                }
            )
        ) { error in
            XCTAssertEqual(error as? SimulatedReadingPlanRestoreError, .interruptedBeforeCommit)
        }

        XCTAssertEqual(stagedReplacementStatusCount, 2)
        try assertLegacyReadingPlanStateRemainsDurable(in: fixture.container)
    }

    /**
     Verifies cancellation after multiple replacement statuses are staged restores all old rows.

     The injected checkpoint throws the same `CancellationError` used by production task checks only
     after two replacement plans/statuses are visible in the unsaved context. A newly opened context
     must still expose the complete old snapshot. A failure means cancellation can durably publish a
     mixed old/new state despite the restore reporting cancellation.
     */
    func testReadingPlanRestoreCancellationRollsBackCompleteMultiPlanAndStatusReplacement() throws {
        let fixture = try makeAtomicReadingPlanRestoreFixture()
        var stagedReplacementStatusCount = 0

        XCTAssertThrowsError(
            try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
                from: fixture.replacementSnapshot,
                modelContext: fixture.modelContext,
                statusStore: fixture.statusStore,
                mutationCheckpoint: {
                    stagedReplacementStatusCount = fixture.statusStore.allStatuses().filter {
                        !$0.planCode.hasPrefix("legacy_")
                    }.count
                    if stagedReplacementStatusCount == 2 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(stagedReplacementStatusCount, 2)
        try assertLegacyReadingPlanStateRemainsDurable(in: fixture.container)
    }

    /**
     Verifies a graph-store commit failure preserves the complete old two-store snapshot.

     The test uses production-shaped file-backed graph and settings configurations, stages two new
     plans and statuses, and makes the graph store reject writes at the sole final commit. Reopening
     both stores must reveal only the two old plan/day/status generations. A failure
     means the cross-store transaction can publish local settings while losing or partially replacing
     the CloudStore-shaped reading-plan graph.
     */
    func testReadingPlanRestoreGraphStoreFailurePreservesCompleteOldCrossStoreSnapshot() throws {
        try assertFinalSaveFailurePreservesLegacyReadingPlans(failingStore: .graph)
    }

    /**
     Verifies a settings-store commit failure preserves the complete old two-store snapshot.

     The test makes the local settings configuration reject writes after seeding old plans and statuses. This is the
     dangerous commit direction because the graph store may be visited before the failing settings
     store. Reopening both stores must still reveal only the complete old generation. A failure means
     a final local-store error can leave newly committed plans paired with old or missing statuses.
     */
    func testReadingPlanRestoreSettingsStoreFailurePreservesCompleteOldCrossStoreSnapshot() throws {
        try assertFinalSaveFailurePreservesLegacyReadingPlans(failingStore: .settings)
    }

    /**
     Verifies a graph-store failure rolls back the complete patch publication generation.

     The attempted replay changes the plan graph, raw statuses, conflict log, applied-patch status,
     and fingerprint baselines. Rejecting graph writes at final save must preserve the complete old
     graph and byte-identical settings rows after both file-backed stores are reopened.
     */
    func testReadingPlanPatchPublishGraphStoreFailurePreservesReplayState() throws {
        try assertPatchPublishFailurePreservesReplayState(failingStore: .graph)
    }

    /**
     Verifies a settings-store failure rolls back the complete patch publication generation.

     This direction protects against the graph committing before local replay bookkeeping fails.
     Reopening both physical stores must reveal the old plan generation and byte-identical settings,
     including raw statuses, conflict logs, patch statuses, and fingerprint baselines.
     */
    func testReadingPlanPatchPublishSettingsStoreFailurePreservesReplayState() throws {
        try assertPatchPublishFailurePreservesReplayState(failingStore: .settings)
    }

    /**
     Verifies a strict current-plan fetch failure aborts before patch replay can erase local state.

     The behavior seam throws from the same current-plan fetch used by production preflight. The
     complete old graph and settings generation must remain durable, including status payloads,
     conflict logs, applied-patch rows, and fingerprints. A failure means an unreadable local graph
     can still be interpreted as authoritative empty state.
     */
    func testReadingPlanPatchPreflightFetchFailurePreservesReplayState() throws {
        let patchService = RemoteSyncReadingPlanPatchApplyService(planFetcher: { _ in
            throw SimulatedReadingPlanPatchReadError.preflightProjectionFailed
        })
        try assertPatchPublishFailurePreservesReplayState(
            patchService: patchService,
            expectedInjectedError: .preflightProjectionFailed
        )
    }

    /**
     Verifies final fingerprint projection failure rolls back the complete patch generation.

     The snapshot service throws only after replay has staged the replacement graph, raw statuses,
     conflict logs, and patch bookkeeping inside the final atomic batch. Reopening both stores must
     reveal the byte-identical baseline settings and original graph. A failure means fingerprint
     publication can diverge from the accepted reading-plan generation.
     */
    func testReadingPlanPatchFingerprintProjectionFailurePreservesReplayState() throws {
        let snapshotService = RemoteSyncReadingPlanSnapshotService(planFetcher: { _ in
            throw SimulatedReadingPlanPatchReadError.fingerprintProjectionFailed
        })
        try assertPatchPublishFailurePreservesReplayState(
            patchService: RemoteSyncReadingPlanPatchApplyService(snapshotService: snapshotService),
            expectedInjectedError: .fingerprintProjectionFailed
        )
    }

}

private extension RemoteSyncReadingPlanTests {
    /**
     Creates two durable legacy reading-plan graphs plus a two-plan Android replacement snapshot.

     - Returns: Clean shared context/status store and replacement snapshot used by atomicity tests.
     - Side Effects: Saves two legacy plans, two days, and two statuses into an in-memory container.
     - Failure modes: Rethrows container or SwiftData save failures.
     */
    func makeAtomicReadingPlanRestoreFixture(
        container suppliedContainer: ModelContainer? = nil
    ) throws -> AtomicReadingPlanRestoreFixture {
        let container: ModelContainer
        if let suppliedContainer {
            container = suppliedContainer
        } else {
            container = try makeReadingPlanRestoreModelContainer()
        }
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)

        for (index, planCode) in ["legacy_alpha", "legacy_beta"].enumerated() {
            let plan = ReadingPlan(
                id: UUID(),
                planCode: planCode,
                planName: "Legacy \(index + 1)",
                startDate: Date(timeIntervalSince1970: TimeInterval(100 + index)),
                currentDay: 1,
                totalDays: 1,
                isActive: index == 0
            )
            let day = ReadingPlanDay(
                dayNumber: 1,
                isCompleted: index == 0,
                readings: index == 0 ? "Gen.1" : "Matt.1"
            )
            day.plan = plan
            modelContext.insert(plan)
            modelContext.insert(day)
        }
        try modelContext.save()

        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: "legacy_alpha",
            dayNumber: 1,
            remoteStatusID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#,
            planCode: "legacy_beta",
            dayNumber: 1,
            remoteStatusID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        )

        let firstStatus = RemoteSyncAndroidReadingPlanStatus(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            planCode: "y1ot1nt1_OTthenNT",
            dayNumber: 2,
            readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )
        let secondStatus = RemoteSyncAndroidReadingPlanStatus(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            planCode: "y1ot1nt2_mcheyne",
            dayNumber: 3,
            readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )
        let replacementSnapshot = RemoteSyncAndroidReadingPlanSnapshot(
            plans: [
                .init(
                    id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2,
                    statuses: [firstStatus]
                ),
                .init(
                    id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
                    planCode: "y1ot1nt2_mcheyne",
                    startDate: Date(timeIntervalSince1970: 1_700_086_400),
                    currentDay: 3,
                    statuses: [secondStatus]
                ),
            ]
        )

        XCTAssertFalse(modelContext.hasChanges)
        return AtomicReadingPlanRestoreFixture(
            container: container,
            modelContext: modelContext,
            statusStore: statusStore,
            replacementSnapshot: replacementSnapshot
        )
    }

    /**
     Asserts a failed or cancelled restore left the complete legacy graph durably unchanged.

     - Parameter container: Container reopened with a fresh context for committed-state inspection.
     - Side Effects: Creates a new context and performs read-only SwiftData fetches.
     - Failure modes: Rethrows fetch failures; XCTest assertions describe graph/status drift.
     */
    func assertLegacyReadingPlanStateRemainsDurable(in container: ModelContainer) throws {
        let reopenedContext = ModelContext(container)
        let plans = try reopenedContext.fetch(FetchDescriptor<ReadingPlan>())
        let days = try reopenedContext.fetch(FetchDescriptor<ReadingPlanDay>())
        let statuses = RemoteSyncReadingPlanStatusStore(
            settingsStore: SettingsStore(modelContext: reopenedContext)
        ).allStatuses()

        XCTAssertEqual(plans.map(\.planCode).sorted(), ["legacy_alpha", "legacy_beta"])
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.compactMap { $0.plan?.planCode }.sorted(), ["legacy_alpha", "legacy_beta"])
        XCTAssertEqual(statuses.map(\.planCode), ["legacy_alpha", "legacy_beta"])
        XCTAssertFalse(plans.contains { $0.planCode.hasPrefix("y1") })
        XCTAssertFalse(statuses.contains { $0.planCode.hasPrefix("y1") })
    }

    /**
     Forces one configured store's final write to fail and verifies both stores retain old data.

     - Parameter failingStore: Graph or settings store whose SQLite write fails at final commit.
     - Side Effects: Creates two temporary SQLite stores, observes one final save attempt, installs
       an operational failure in one store, reopens both configurations, and removes the temporary directory.
     - Failure modes: Rethrows file-system, container, SQLite-fixture, or fetch failures; XCTest assertions
       distinguish missing final-save execution from cross-store atomicity drift.
     - Determinism: Failure triggers are installed after all old rows are durable and the `willSave`
       expectation proves failure occurs at commit rather than snapshot preparation or fetch.
     */
    func assertFinalSaveFailurePreservesLegacyReadingPlans(
        failingStore: ReadingPlanRestoreFailingStore
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingPlanAtomicRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let persistentStore = try makePersistentReadingPlanRestoreStore(in: temporaryDirectory)
        let fixture = try makeAtomicReadingPlanRestoreFixture(container: persistentStore.container)
        let failingStoreURL: URL
        switch failingStore {
        case .graph:
            failingStoreURL = persistentStore.graphStoreURL
        case .settings:
            failingStoreURL = persistentStore.settingsStoreURL
        }

        let finalSaveExpectation = expectation(description: "Reading-plan replacement reaches final save")
        finalSaveExpectation.expectedFulfillmentCount = 1
        finalSaveExpectation.assertForOverFulfill = true
        let saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.willSave,
            object: fixture.modelContext,
            queue: nil
        ) { _ in
            finalSaveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(saveObserver) }

        let writeFailure = try ReadingPlanSQLiteStoreWriteFailure(databaseURL: failingStoreURL)
        try writeFailure.install()
        XCTAssertThrowsError(
            try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
                from: fixture.replacementSnapshot,
                modelContext: fixture.modelContext,
                statusStore: fixture.statusStore
            )
        )
        wait(for: [finalSaveExpectation], timeout: 1)
        XCTAssertFalse(fixture.modelContext.hasChanges)
        writeFailure.remove()

        let reopenedStore = try makePersistentReadingPlanRestoreStore(in: temporaryDirectory)
        try assertLegacyReadingPlanStateRemainsDurable(in: reopenedStore.container)
    }

    /**
     Forces one physical store to reject patch publication and verifies every old row survives.

     The baseline includes one supported plan, one raw status, Android conflict log entries, one
     applied-patch status, and reading-plan fingerprint rows. The attempted patch changes every one
     of those categories. Comparing all reopened `Setting` key/value pairs protects against replay
     bookkeeping drifting independently of the graph.

     - Parameters:
       - failingStore: Optional graph or settings configuration that rejects the final transaction.
       - patchService: Patch service whose production fetch path or test-injected read behavior runs.
       - expectedInjectedError: Expected behavior-seam error when no physical store is selected.
     - Side Effects: Creates two temporary file-backed stores and one temporary Android patch archive.
     - Failure modes: Rethrows fixture, archive, SQLite-fixture, or fetch failures; XCTest assertions
       report any partial graph or settings publication.
     - Determinism: SQLite raises an operational error at the real final save without timing or lock
       waits; injected read failures run synchronously at their production behavior boundary.
     */
    func assertPatchPublishFailurePreservesReplayState(
        failingStore: ReadingPlanRestoreFailingStore? = nil,
        patchService: RemoteSyncReadingPlanPatchApplyService = RemoteSyncReadingPlanPatchApplyService(),
        expectedInjectedError: SimulatedReadingPlanPatchReadError? = nil
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadingPlanPatchAtomicPublish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let persistentStore = try makePersistentReadingPlanRestoreStore(in: temporaryDirectory)
        let modelContext = ModelContext(persistentStore.container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()

        let planID = UUID(uuidString: "41000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "41000000-0000-0000-0000-000000000011")!
        let patchPlanID = UUID(uuidString: "41000000-0000-0000-0000-000000000002")!
        let patchStatusID = UUID(uuidString: "41000000-0000-0000-0000-000000000022")!
        let planCode = "y1ot1nt1_OTthenNT"
        let patchPlanCode = "y1ot1nt2_mcheyne"
        let baselineSnapshot = RemoteSyncAndroidReadingPlanSnapshot(
            plans: [
                .init(
                    id: planID,
                    planCode: planCode,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1,
                    statuses: [
                        .init(
                            id: baselineStatusID,
                            planCode: planCode,
                            dayNumber: 1,
                            readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                        )
                    ]
                )
            ]
        )
        _ = try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
            from: baselineSnapshot,
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
        patchStatusStore.addStatus(
            .init(
                sourceDevice: "pixel",
                patchNumber: 1,
                sizeBytes: 512,
                appliedDate: 1_735_689_700_000
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let baselineSettings = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Setting>()).map {
                ($0.key, $0.value)
            }
        )
        XCTAssertFalse(modelContext.hasChanges)

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: patchPlanID,
                    planCode: patchPlanCode,
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: patchStatusID,
                    planCode: patchPlanCode,
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(readingPlanUUIDBlob(patchPlanID)),
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

        if let failingStore {
            let failingStoreURL = switch failingStore {
            case .graph: persistentStore.graphStoreURL
            case .settings: persistentStore.settingsStoreURL
            }
            let finalSaveExpectation = expectation(description: "Reading-plan patch reaches final save")
            finalSaveExpectation.expectedFulfillmentCount = 1
            finalSaveExpectation.assertForOverFulfill = true
            let saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.willSave,
                object: modelContext,
                queue: nil
            ) { _ in
                finalSaveExpectation.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(saveObserver) }

            let writeFailure = try ReadingPlanSQLiteStoreWriteFailure(databaseURL: failingStoreURL)
            try writeFailure.install()
            XCTAssertThrowsError(
                try patchService.applyPatchArchives(
                    [stagedArchive],
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            )
            wait(for: [finalSaveExpectation], timeout: 1)
            writeFailure.remove()
        } else {
            let expectedInjectedError = try XCTUnwrap(expectedInjectedError)
            XCTAssertThrowsError(
                try patchService.applyPatchArchives(
                    [stagedArchive],
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            ) { error in
                XCTAssertEqual(error as? SimulatedReadingPlanPatchReadError, expectedInjectedError)
            }
        }
        XCTAssertFalse(modelContext.hasChanges)

        let reopenedStore = try makePersistentReadingPlanRestoreStore(in: temporaryDirectory)
        let reopenedContext = ModelContext(reopenedStore.container)
        let reopenedPlans = try reopenedContext.fetch(FetchDescriptor<ReadingPlan>())
        let reopenedSettings = Dictionary(
            uniqueKeysWithValues: try reopenedContext.fetch(FetchDescriptor<Setting>()).map {
                ($0.key, $0.value)
            }
        )
        XCTAssertEqual(reopenedPlans.count, 1)
        XCTAssertEqual(reopenedPlans.first?.id, planID)
        XCTAssertEqual(reopenedPlans.first?.currentDay, 1)
        XCTAssertEqual(reopenedSettings, baselineSettings)
    }
}
