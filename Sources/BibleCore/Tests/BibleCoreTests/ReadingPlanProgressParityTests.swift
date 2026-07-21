import Foundation
import SwiftData
import SwordKit
import XCTest
@testable import BibleCore

/**
 Android-derived contract fixtures for reading-plan and chapter-progress parity.

 Fixture strings and expected behavior come from Android `OneDaysReadingsDto`, `ReadingStatus`,
 `ReadingPlanControl`, and `ProgressControl` at sibling revision
 `0f3b85823cebbfafeb5a51675827f5314cac3c56`. Tests use fixed dates and isolated persistence.
 */
final class ReadingPlanProgressParityTests: XCTestCase {
    /**
     Verifies Android's date-prefix and comma delimiter contract using representative plan lines.

     Failure means iOS can assign a different `readingNumber`, expose the date token as scripture,
     or split one reading into several semicolon-delimited rows.
     */
    func testAndroidDayAssignmentFixturesMatchOneDaysReadingsDTO() throws {
        let dated = ReadingPlanDayAssignment(rawValue: "Feb-1;Gen.1-Gen.2, Matt.1")
        XCTAssertEqual(dated.dateToken, "Feb-1")
        XCTAssertEqual(dated.readings, ["Gen.1-Gen.2", "Matt.1"])

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 19)))
        let scheduled = try XCTUnwrap(dated.scheduledDate(inYearContaining: reference, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: scheduled), DateComponents(year: 2026, month: 2, day: 1))

        let ordinary = ReadingPlanDayAssignment(rawValue: "Gen.1, Matt.1, Ezra.1, Acts.1")
        XCTAssertNil(ordinary.dateToken)
        XCTAssertEqual(ordinary.readings, ["Gen.1", "Matt.1", "Ezra.1", "Acts.1"])

        let numberedSlots = ReadingPlanDayAssignment(rawValue: "Gen.1,,Matt.1,,")
        XCTAssertEqual(numberedSlots.readings, ["Gen.1", "", "Matt.1"])

        XCTAssertFalse(ReadingPlanService.hasDateBasedPrefix("Gen.1;Matt.1"))
        XCTAssertTrue(ReadingPlanService.hasDateBasedPrefix("Feb-1;Gen.1,Matt.1"))
    }

    /**
     Verifies Android status decoding retains duplicate order and unusual integer row keys.

     Failure means iOS normalizes persisted status rows differently from Android before a read or
     update, changing which duplicate controls the visible checkbox and outbound JSON.
     */
    func testReadingStatusPreservesDuplicateAndNonpositiveRows() throws {
        let payload = try AndroidReadingPlanStatusPayload(
            androidJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false},{"readingNumber":1,"isRead":true},{"readingNumber":0,"isRead":true},{"readingNumber":2,"isRead":true}]}"#
        )

        XCTAssertFalse(payload.isRead(1))
        XCTAssertTrue(payload.isRead(0))
        XCTAssertTrue(payload.isRead(2))

        let updated = payload.setting(readingNumber: 1, isRead: true)
        XCTAssertEqual(updated.chapterReadArray.map(\.readingNumber), [0, 1, 1, 1, 2])
        XCTAssertEqual(updated.chapterReadArray.map(\.isRead), [true, true, true, true, true])

        let nonpositiveUpdate = payload.setting(readingNumber: 0, isRead: false)
        XCTAssertEqual(nonpositiveUpdate.chapterReadArray.map(\.readingNumber), [0, 0, 1, 1, 2])
        XCTAssertEqual(nonpositiveUpdate.chapterReadArray.prefix(2).map(\.isRead), [false, false])
    }

    /**
     Verifies one reading in a multi-reading day remains partial through Android snapshot/restore.

     The test fails if a partial payload is collapsed into day-complete state, synthesized as all
     read, or lost when a fresh iOS store restores the Android-shaped snapshot.
     */
    func testPartialReadingStatusRoundTripsThroughAndroidSnapshotAndRestore() throws {
        let sourceContainer = try makeReadingPlanRestoreModelContainer()
        let sourceContext = ModelContext(sourceContainer)
        let sourceSettings = SettingsStore(modelContext: sourceContext)
        let template = try XCTUnwrap(
            ReadingPlanService.availablePlans.first { $0.code == "y1ot1nt2_mcheyne" }
        )
        let sourcePlan = try ReadingPlanService.startPlan(template: template, modelContext: sourceContext)
        let day = try XCTUnwrap(sourcePlan.days?.first { $0.dayNumber == 1 })
        let progress = ReadingPlanProgressStore(modelContext: sourceContext, settingsStore: sourceSettings)

        let status = try progress.setReading(1, isRead: true, day: day, plan: sourcePlan)
        XCTAssertTrue(status.isRead(1))
        XCTAssertFalse(status.isRead(2))
        XCTAssertFalse(day.isCompleted)
        XCTAssertEqual(
            try status.androidJSON(),
            #"{"chapterReadArray":[{"isRead":true,"readingNumber":1}]}"#
        )

        let current = RemoteSyncReadingPlanSnapshotService().snapshotCurrentState(
            modelContext: sourceContext,
            settingsStore: sourceSettings
        )
        let statusRow = try XCTUnwrap(current.statusRowsByKey.values.first { $0.planDay == 1 })
        XCTAssertEqual(
            try AndroidReadingPlanStatusPayload(androidJSON: statusRow.readingStatusJSON),
            status
        )

        let restoredContainer = try makeReadingPlanRestoreModelContainer()
        let restoredContext = ModelContext(restoredContainer)
        let restoredSettings = SettingsStore(modelContext: restoredContext)
        let snapshot = RemoteSyncAndroidReadingPlanSnapshot(
            plans: [
                RemoteSyncAndroidReadingPlan(
                    id: sourcePlan.id,
                    planCode: sourcePlan.planCode,
                    startDate: sourcePlan.startDate,
                    currentDay: sourcePlan.currentDay,
                    statuses: [
                        RemoteSyncAndroidReadingPlanStatus(
                            id: statusRow.id,
                            planCode: statusRow.planCode,
                            dayNumber: statusRow.planDay,
                            readingStatusJSON: statusRow.readingStatusJSON
                        )
                    ]
                )
            ]
        )
        _ = try RemoteSyncReadingPlanRestoreService().replaceLocalReadingPlans(
            from: snapshot,
            modelContext: restoredContext,
            statusStore: RemoteSyncReadingPlanStatusStore(settingsStore: restoredSettings)
        )

        let restoredPlan = try XCTUnwrap(restoredContext.fetch(FetchDescriptor<ReadingPlan>()).first)
        let restoredDay = try XCTUnwrap(restoredPlan.days?.first { $0.dayNumber == 1 })
        let restoredStatus = try ReadingPlanProgressStore(
            modelContext: restoredContext,
            settingsStore: restoredSettings
        ).status(for: restoredDay, in: restoredPlan)
        XCTAssertTrue(restoredStatus.isRead(1))
        XCTAssertFalse(restoredStatus.isRead(2))
        XCTAssertFalse(restoredDay.isCompleted)
    }

    /**
     Verifies legacy all-or-nothing iOS rows migrate only to explicit all-read Android payloads.

     Failure means a completed legacy day can become partial/unread or overwrite an existing
     Android partial payload.
     */
    func testLegacyCompletedDayMigrationIsConservative() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let plan = ReadingPlan(planCode: "fixture", planName: "Fixture", currentDay: 1, totalDays: 2)
        let completed = ReadingPlanDay(dayNumber: 1, isCompleted: true, readings: "Gen.1,Matt.1")
        let partial = ReadingPlanDay(dayNumber: 2, isCompleted: true, readings: "Gen.2,Matt.2")
        completed.plan = plan
        partial.plan = plan
        context.insert(plan)
        context.insert(completed)
        context.insert(partial)

        let rawStore = RemoteSyncReadingPlanStatusStore(settingsStore: settings)
        let partialPayload = AndroidReadingPlanStatusPayload(
            chapterReadArray: [.init(readingNumber: 1, isRead: true)]
        )
        rawStore.setStatus(
            try partialPayload.androidJSON(),
            planCode: plan.planCode,
            dayNumber: 2
        )

        let progress = ReadingPlanProgressStore(modelContext: context, settingsStore: settings)
        XCTAssertEqual(try progress.migrateLegacyStatuses(in: plan), 1)
        XCTAssertTrue(try progress.status(for: completed, in: plan).isAllRead(readingCount: 2))
        XCTAssertEqual(try progress.status(for: partial, in: plan), partialPayload)
        XCTAssertFalse(partial.isCompleted)
    }

    /**
     Verifies a reading-toggle getter observes the latest persisted payload after each mutation.

     This is the behavior used by `DailyReadingView`'s binding. Failure means the UI can capture a
     stale payload and display the opposite state after the user toggles one reading.
     */
    func testReadingToggleReloadsLatestPerReadingStatus() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let plan = ReadingPlan(planCode: "toggle", planName: "Toggle", currentDay: 1, totalDays: 1)
        let day = ReadingPlanDay(dayNumber: 1, readings: "Gen.1,Matt.1")
        day.plan = plan
        context.insert(plan)
        context.insert(day)
        let progress = ReadingPlanProgressStore(modelContext: context, settingsStore: settings)

        XCTAssertFalse(try progress.status(for: day, in: plan).isRead(1))
        try progress.setReading(1, isRead: true, day: day, plan: plan)
        XCTAssertTrue(try progress.status(for: day, in: plan).isRead(1))
        try progress.setReading(1, isRead: false, day: day, plan: plan)
        XCTAssertFalse(try progress.status(for: day, in: plan).isRead(1))
        XCTAssertFalse(day.isCompleted)
    }

    /**
     Verifies a malformed stored status aborts a local toggle without replacing the corrupt row.

     Failure means the UI can reinterpret corruption as an unread day, overwrite the evidence with
     a fresh payload, and journal a state Android never accepted.
     */
    func testReadingToggleRejectsMalformedStoredStatusWithoutOverwrite() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let plan = ReadingPlan(
            planCode: "corrupt-status",
            planName: "Corrupt Status",
            currentDay: 1,
            totalDays: 1
        )
        let day = ReadingPlanDay(dayNumber: 1, readings: "Gen.1")
        day.plan = plan
        context.insert(plan)
        context.insert(day)
        try context.save()

        let rawStore = RemoteSyncReadingPlanStatusStore(settingsStore: settings)
        rawStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#,
            planCode: plan.planCode,
            dayNumber: day.dayNumber
        )
        let stored = try XCTUnwrap(
            settings.entries(withPrefix: "remote_sync.readingplans.android_status").first
        )
        settings.setString(stored.key, value: "{")

        let progress = ReadingPlanProgressStore(modelContext: context, settingsStore: settings)
        XCTAssertThrowsError(
            try progress.setReading(1, isRead: true, day: day, plan: plan)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanStatusPersistenceError,
                .malformedStoredStatus(stored.key)
            )
        }
        XCTAssertEqual(settings.getString(stored.key), "{")
        XCTAssertFalse(day.isCompleted)
    }

    /**
     Verifies a day deletion cannot replace a corrupt remote identity with a synthetic journal id.

     Failure means staged deletion can reinterpret malformed status persistence as absence, commit
     the graph deletion, and emit an Android delete operation for the wrong row.
     */
    func testDayDeletionRejectsMalformedStatusBeforeGraphAndJournalSave() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let plan = ReadingPlan(
            planCode: "corrupt-delete-status",
            planName: "Corrupt Delete Status",
            currentDay: 1,
            totalDays: 1
        )
        let day = ReadingPlanDay(dayNumber: 1, readings: "Gen.1")
        day.plan = plan
        context.insert(plan)
        context.insert(day)
        try context.save()

        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settings)
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#,
            planCode: plan.planCode,
            dayNumber: day.dayNumber,
            remoteStatusID: UUID()
        )
        let stored = try XCTUnwrap(
            settings.entries(withPrefix: "remote_sync.readingplans.android_status").first
        )
        settings.setString(stored.key, value: "{")

        context.delete(day)
        XCTAssertThrowsError(
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .readingPlans,
                modelContext: context
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanStatusPersistenceError,
                .malformedStoredStatus(stored.key)
            )
        }

        XCTAssertEqual(settings.getString(stored.key), "{")
        XCTAssertTrue(
            try RemoteSyncLogEntryStore(settingsStore: settings)
                .entriesStrict(for: .readingPlans)
                .isEmpty
        )
        let freshContext = ModelContext(container)
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<ReadingPlanDay>()).count, 1)
    }

    /**
     Verifies date plans select by calendar date and reject offset-plan mutations.

     Failure means date plans drift with start-date offsets or expose Android-forbidden set-day and
     set-start-date behavior.
     */
    func testDatePlanUsesCalendarLookupAndIgnoresUnsupportedMutations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 2)))
        let originalStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 20)))
        let plan = ReadingPlan(
            planCode: "dates",
            planName: "Dates",
            startDate: originalStart,
            currentDay: 9,
            totalDays: 2
        )
        let first = ReadingPlanDay(dayNumber: 1, readings: "Feb-1;Gen.1,Matt.1")
        let second = ReadingPlanDay(dayNumber: 2, readings: "Feb-2;Gen.2,Matt.2")
        first.plan = plan
        second.plan = plan

        XCTAssertEqual(ReadingPlanService.expectedDay(for: plan, asOf: now, calendar: calendar), 2)

        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        context.insert(plan)
        context.insert(first)
        context.insert(second)
        try ReadingPlanService.setCurrentDay(1, for: plan, modelContext: context, now: now, calendar: calendar)
        try ReadingPlanService.setStartDate(now, for: plan, modelContext: context, now: now, calendar: calendar)
        XCTAssertEqual(plan.currentDay, 9)
        XCTAssertEqual(plan.startDate, originalStart)
    }

    /**
     Verifies Android date-plan Done retains explicit status and leaves the persisted pointer alone.

     Android's `ReadingPlanRepository.deleteOldStatuses` intentionally does nothing for date plans.
     Failure means revisiting today's plan after Done incorrectly shows its readings as unread.
     */
    func testDatePlanDoneRetainsExplicitStatusAndCalendarPointer() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 1)))
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let progress = ReadingPlanProgressStore(modelContext: context, settingsStore: settings)
        let selection = ReadingPlanSelectionStore(settingsStore: settings)
        let plan = ReadingPlan(
            planCode: "dates-done",
            planName: "Dates Done",
            startDate: now,
            currentDay: 9,
            totalDays: 2
        )
        let first = ReadingPlanDay(dayNumber: 1, readings: "Feb-1;Gen.1,Matt.1")
        let second = ReadingPlanDay(dayNumber: 2, readings: "Feb-2;Gen.2,Matt.2")
        first.plan = plan
        second.plan = plan
        context.insert(plan)
        context.insert(first)
        context.insert(second)
        try selection.select(plan, among: [plan], modelContext: context)
        try progress.setReading(1, isRead: true, day: first, plan: plan, now: now)
        try progress.setReading(2, isRead: true, day: first, plan: plan, now: now)

        XCTAssertNil(
            try ReadingPlanService.finishDay(
                first,
                in: plan,
                modelContext: context,
                progressStore: progress,
                selectionStore: selection,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertEqual(plan.currentDay, 9)
        XCTAssertTrue(try progress.status(for: first, in: plan).isAllRead(readingCount: 2))
        XCTAssertTrue(first.isCompleted)
        XCTAssertEqual(selection.selectedPlanCode, plan.planCode)
    }

    /**
     Verifies a calendar plan started midyear does not create an artificial historical catch-up queue.

     Android uses elapsed days from `planStartDate` for the post-Done due gate even though date tokens
     select today's row. Failure means completing an older displayed row advances to another old row.
     */
    func testDatePlanDoneUsesStoredStartDateForCatchUpGate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2, day: 2)))
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let progress = ReadingPlanProgressStore(modelContext: context, settingsStore: settings)
        let selection = ReadingPlanSelectionStore(settingsStore: settings)
        let plan = ReadingPlan(
            planCode: "dates-midyear",
            planName: "Dates Midyear",
            startDate: now,
            currentDay: 1,
            totalDays: 2
        )
        let oldDay = ReadingPlanDay(dayNumber: 1, readings: "Feb-1;Gen.1")
        let today = ReadingPlanDay(dayNumber: 2, readings: "Feb-2;Gen.2")
        oldDay.plan = plan
        today.plan = plan
        context.insert(plan)
        context.insert(oldDay)
        context.insert(today)
        try selection.select(plan, among: [plan], modelContext: context)
        try progress.setReading(1, isRead: true, day: oldDay, plan: plan, now: now)

        XCTAssertNil(
            try ReadingPlanService.finishDay(
                oldDay,
                in: plan,
                modelContext: context,
                progressStore: progress,
                selectionStore: selection,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertTrue(try progress.status(for: oldDay, in: plan).isRead(1))
        XCTAssertEqual(ReadingPlanService.expectedDay(for: plan, asOf: now, calendar: calendar), 2)
    }

    /**
     Verifies imported definitions use Android's filename code and survive catalog rediscovery.

     Failure means custom plan state can no longer resolve after restart, sync replay, or restore.
     */
    func testCustomPlanImportPersistsStableAndroidFilenameIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-plan-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "# My plan\n1=Gen.1,Matt.1\n2=Gen.2,Matt.2\n"

        let first = try ReadingPlanService.importCustomPlan(
            fileName: "my_stable_plan.properties",
            propertiesText: text,
            userPlanDirectory: directory
        )
        let second = try ReadingPlanService.importCustomPlan(
            fileName: "my_stable_plan.properties",
            propertiesText: text,
            userPlanDirectory: directory
        )
        XCTAssertEqual(first.code, "my_stable_plan")
        XCTAssertEqual(second.code, first.code)
        XCTAssertEqual(
            ReadingPlanService.catalog(userPlanDirectory: directory, modulePath: "").templates
                .first { $0.code == first.code }?.readingsForDay(1),
            "Gen.1,Matt.1"
        )
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("my_stable_plan.properties")),
            text
        )
    }

    /**
     Verifies two started plans retain data while exactly one owns Android's selected preference.

     Failure means iOS can again expose impossible multi-active state or lose another plan's
     current-day history when the user switches selection.
     */
    func testSelectedPlanPreferenceEnforcesOneCurrentPlanWithoutDeletingOthers() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let selection = ReadingPlanSelectionStore(settingsStore: settings)
        let templates = ReadingPlanService.availablePlans
        let first = try ReadingPlanService.startPlan(
            template: templates[0],
            modelContext: context,
            selectionStore: selection
        )
        let second = try ReadingPlanService.startPlan(
            template: templates[1],
            modelContext: context,
            selectionStore: selection
        )

        XCTAssertEqual(selection.selectedPlanCode, second.planCode)
        XCTAssertFalse(first.isActive)
        XCTAssertTrue(second.isActive)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReadingPlan>()).count, 2)

        try selection.select(first, among: [first, second], modelContext: context)
        XCTAssertEqual(selection.selectedPlanCode, first.planCode)
        XCTAssertTrue(first.isActive)
        XCTAssertFalse(second.isActive)
    }

    /**
     Verifies Android chapter history omits source ordinals and supports cycles, local-day stats,
     empty-initial fallback, and per-row deletion.
     */
    func testReadingProgressMatchesAndroidHistoryAndCycleSemantics() throws {
        let container = try makeInMemorySettingsContainer()
        let context = ModelContext(container)
        let store = ReadingProgressStore(settingsStore: SettingsStore(modelContext: context))
        let genesis = try XCTUnwrap(ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1))
        let januarySecondNoon = Date(timeIntervalSince1970: 1_767_355_200)

        XCTAssertEqual(
            try store.recordChapterRead(
                bookInitials: "",
                identity: genesis,
                source: .manual,
                readAt: 1_767_355_200_000
            ),
            1
        )
        let row = try XCTUnwrap(store.snapshot().history.first)
        // Android ReadHistoryDialog renders rows with KJVA.getShortName, not the long-name title.
        XCTAssertEqual(row.androidDisplayReference, "Gen 1")
        XCTAssertNil(row.androidDisplayVersion)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(row), encoding: .utf8))
        XCTAssertFalse(encoded.contains("startOrdinal"))

        let firstCycle = store.presentation(asOf: januarySecondNoon)
        XCTAssertEqual(firstCycle.cycle, 1)
        XCTAssertEqual(firstCycle.distinctChapterCount, 1)
        XCTAssertEqual(firstCycle.activeDayCount, 1)
        XCTAssertEqual(firstCycle.books.first { $0.book.osisId == "Gen" }?.chapterReadCounts[1], 1)
        XCTAssertEqual(firstCycle.calendar.reduce(0) { $0 + $1.count }, 1)
        XCTAssertEqual(AndroidReadingProgressHeatmap.effectiveBookScaleMaximum(1.33), 1.5)
        XCTAssertEqual(
            AndroidReadingProgressHeatmap.bookScalePercentages(maximumReadPercent: 1.5),
            [25, 50, 75, 100, 125, 150]
        )
        XCTAssertEqual(AndroidReadingProgressHeatmap.chapterARGB(count: 0, maximumCount: 20), 0xFFE8E8E8)
        XCTAssertEqual(AndroidReadingProgressHeatmap.chapterARGB(count: 1, maximumCount: 20), 0xFFFFF9C4)
        XCTAssertEqual(AndroidReadingProgressHeatmap.chapterARGB(count: 5, maximumCount: 20), 0xFFFF6D00)
        XCTAssertEqual(AndroidReadingProgressHeatmap.chapterARGB(count: 20, maximumCount: 20), 0xFFB71C1C)
        XCTAssertEqual(AndroidReadingProgressHeatmap.bookARGB(readPercent: 1, effectiveMaximum: 1.5), 0xFF1565C0)
        XCTAssertEqual(AndroidReadingProgressHeatmap.bookARGB(readPercent: 1.5, effectiveMaximum: 1.5), 0xFFB71C1C)

        let overComplete = ReadingProgressPresentationSnapshot(
            cycle: 1,
            latestCycle: 1,
            distinctChapterCount: 1_190,
            activeDayCount: 1,
            totalBibleChapterCount: 1_189,
            books: firstCycle.books,
            calendar: [],
            recentRows: []
        )
        XCTAssertEqual(overComplete.overallProgress, 1)
        XCTAssertGreaterThan(overComplete.overallPercent, 100)

        XCTAssertEqual(try store.startNewCycle(), 2)
        XCTAssertEqual(store.currentCycle(), 2)
        try store.setActiveCycle(1)
        XCTAssertEqual(store.currentCycle(), 1)
        XCTAssertTrue(try store.deleteHistoryEntry(id: row.id))
        XCTAssertTrue(store.snapshot().history.isEmpty)
    }

    /**
     Verifies sparse signed-Int32 plan keys and mutation-time journals survive a store reopen.

     Failure means plan import allocates dense placeholder days, rejects Android-valid keys, or
     relies on upload-time diffing instead of durably journaling local plan/status mutations.
     */
    func testSparseInt32PlanKeysAndMutationJournalSurviveRestart() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparseReadingPlan-\(UUID().uuidString)", isDirectory: true)
        let userPlanDirectory = rootDirectory
            .appendingPathComponent("jsword/readingplan", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let persistentStore = try makePersistentReadingPlanRestoreStore(in: rootDirectory)
        let context = ModelContext(persistentStore.container)
        let settingsStore = SettingsStore(modelContext: context)
        let plan = try ReadingPlanService.importAndStartCustomPlan(
            fileName: "Sparse Int32.properties",
            propertiesData: Data(
                """
                # Sparse Int32
                -2147483648=Gen.1
                0=Gen.2
                1=Gen.3
                10001=Matt.1
                2147483647=Rev.22
                """.utf8
            ),
            modelContext: context,
            settingsStore: settingsStore,
            userPlanDirectory: userPlanDirectory
        )
        XCTAssertEqual(
            (plan.days ?? []).map(\.dayNumber).sorted(),
            [Int(Int32.min), 0, 1, 10_001, Int(Int32.max)]
        )
        XCTAssertEqual(plan.days?.count, 5)
        XCTAssertEqual(plan.totalDays, Int(Int32.max))

        let sparseDay = try XCTUnwrap(
            plan.days?.first { $0.dayNumber == Int(Int32.max) }
        )
        let progressStore = ReadingPlanProgressStore(
            modelContext: context,
            settingsStore: settingsStore,
            userPlanDirectory: userPlanDirectory
        )
        _ = try progressStore.setReading(
            1,
            isRead: true,
            day: sparseDay,
            plan: plan,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let mutationTables = Set(
            try RemoteSyncLogEntryStore(settingsStore: settingsStore)
                .entriesStrict(for: .readingPlans)
                .map(\.tableName)
        )
        XCTAssertTrue(mutationTables.contains("ReadingPlan"))
        XCTAssertTrue(mutationTables.contains("ReadingPlanStatus"))

        let reopenedStore = try makePersistentReadingPlanRestoreStore(in: rootDirectory)
        let reopenedContext = ModelContext(reopenedStore.container)
        let reopenedSettings = SettingsStore(modelContext: reopenedContext)
        try ReadingPlanService.recoverCustomPlanDefinitionPublication(
            settingsStore: reopenedSettings,
            userPlanDirectory: userPlanDirectory
        )
        let reopenedPlan = try XCTUnwrap(
            reopenedContext.fetch(FetchDescriptor<ReadingPlan>()).first
        )
        XCTAssertEqual(reopenedPlan.days?.count, 5)
        XCTAssertEqual(
            (reopenedPlan.days ?? []).map(\.dayNumber).sorted(),
            [Int(Int32.min), 0, 1, 10_001, Int(Int32.max)]
        )
        XCTAssertNotNil(
            try RemoteSyncReadingPlanStatusStore(settingsStore: reopenedSettings)
                .storedStatusStrict(
                    planCode: reopenedPlan.planCode,
                    dayNumber: Int(Int32.max)
                )
        )
        XCTAssertEqual(
            Set(
                try RemoteSyncLogEntryStore(settingsStore: reopenedSettings)
                    .entriesStrict(for: .readingPlans)
                    .map(\.tableName)
            ),
            mutationTables
        )
    }

    /**
     Verifies non-KJV native writes require strict mapping proof before creating identity.

     The Vulgate Psalm anchor is resolved through the pinned JSword canon and strict KJVA mapping;
     a raw or fallback-only source coordinate cannot enter chapter-history persistence.
     */
    func testNonKJVReadingProgressIdentityUsesVerifiedMappingBoundary() throws {
        let source = SwordVersification.Reference(osisBookId: "Ps", chapter: 1, verse: 1)
        let sourceOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(for: source, versification: "Vulg")
        )
        let verified = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "VULG",
                sourceVersification: "Vulg",
                sourceOrdinalStart: sourceOrdinal,
                sourceOrdinalEnd: sourceOrdinal
            )
        )
        let identity = try XCTUnwrap(
            ReadingProgressKJVAIdentity(verifiedBookAnchor: verified, sourceChapter: 10)
        )
        XCTAssertEqual(identity.osisBookId, "Ps")
        XCTAssertEqual(identity.chapter, 10)
        let retainedSourceChapter = try XCTUnwrap(
            ReadingProgressKJVAIdentity(
                androidKJVBookOrdinal: identity.kjvBookOrdinal,
                chapter: 999
            )
        )
        XCTAssertEqual(retainedSourceChapter.osisBookId, identity.osisBookId)
        XCTAssertEqual(retainedSourceChapter.chapter, 999)
    }
}
