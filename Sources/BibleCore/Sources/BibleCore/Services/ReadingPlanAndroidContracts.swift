// ReadingPlanAndroidContracts.swift -- Android reading-plan parsing and progress semantics

import Foundation
import SwiftData

/**
 One Android reading-plan day decoded from a `.properties` value.

 Android's `OneDaysReadingsDto` treats any semicolon as a date-plan marker: the text before the
 first semicolon is a `MMM-d` date token, the text after the last semicolon is the reading list,
 and readings are comma-delimited. Keeping that behavior in one value prevents UI, restore, and
 outbound sync from disagreeing about reading numbers.
 */
public struct ReadingPlanDayAssignment: Equatable, Sendable {
    /// Original `.properties` value retained for lossless display and export.
    public let rawValue: String

    /// Android date token such as `Feb-1`, or `nil` for ordinal-day plans.
    public let dateToken: String?

    /// Ordered reading strings whose one-based positions are Android `readingNumber` values.
    public let readings: [String]

    /// Whether Android would treat this value as date-based.
    public var isDateBased: Bool { dateToken != nil }

    /**
     Parses one Android reading-plan day value.

     - Parameter rawValue: Raw value loaded from a Java `.properties` entry.
     - Side effects: none.
     - Failure modes: Malformed date tokens remain visible in `dateToken`; `scheduledDate` returns
     `nil` for them. Trailing empty comma segments are omitted, while interior empty segments retain
     their Android reading-number position.
     */
    public init(rawValue: String) {
        self.rawValue = rawValue

        let readingsPortion: Substring
        if let firstSeparator = rawValue.firstIndex(of: ";"),
           let lastSeparator = rawValue.lastIndex(of: ";") {
            let token = rawValue[..<firstSeparator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            dateToken = token.isEmpty ? "" : token
            readingsPortion = rawValue[rawValue.index(after: lastSeparator)...]
        } else {
            dateToken = nil
            readingsPortion = rawValue[...]
        }

        var parsedReadings = readingsPortion
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while parsedReadings.last?.isEmpty == true {
            parsedReadings.removeLast()
        }
        readings = parsedReadings
    }

    /**
     Resolves Android's yearless date token in the calendar year containing a reference date.

     Android first parses `MMM-d/yyyy` with `Locale.US`, then retries with the device locale. This
     method follows the same order and normalizes the result to the supplied calendar's local day.

     - Parameters:
       - referenceDate: Date supplying the current calendar year.
       - calendar: User calendar and timezone used for day comparison.
       - fallbackLocale: Device locale used after the fixed US parser.
     - Returns: Local start-of-day date, or `nil` for non-date plans and malformed date tokens.
     - Side effects: none.
     - Failure modes: Invalid or calendar-incompatible date tokens return `nil`.
     */
    public func scheduledDate(
        inYearContaining referenceDate: Date,
        calendar: Calendar = .current,
        fallbackLocale: Locale = .current
    ) -> Date? {
        guard let dateToken, !dateToken.isEmpty else { return nil }
        let year = calendar.component(.year, from: referenceDate)
        let candidate = "\(dateToken)/\(year)"

        for locale in [Locale(identifier: "en_US_POSIX"), fallbackLocale] {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = locale
            formatter.dateFormat = "MMM-d/yyyy"
            formatter.isLenient = true
            if let date = formatter.date(from: candidate) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }
}

/**
 One entry in Android's serialized `ReadingStatus.chapterReadArray`.
 */
public struct AndroidReadingPlanChapterRead: Codable, Equatable, Sendable {
    /// One-based position in `ReadingPlanDayAssignment.readings`.
    public let readingNumber: Int

    /// Whether that reading has been completed.
    public let isRead: Bool

    /** Creates one Android reading-status entry without side effects or validation. */
    public init(readingNumber: Int, isRead: Bool) {
        self.readingNumber = readingNumber
        self.isRead = isRead
    }
}

/**
 Typed form of Android's exact `ReadingPlanStatus.readingStatus` JSON payload.

 Entries retain Android's decoded order, including duplicate and non-positive reading numbers.
 Reads resolve the first matching row. Updating an existing row mutates that first value, appends
 the same value again, and then stable-sorts by reading number, matching Android `ReadingStatus`.
 */
public struct AndroidReadingPlanStatusPayload: Codable, Equatable, Sendable {
    /// Ordered per-reading completion rows encoded under Android's exact JSON key.
    public let chapterReadArray: [AndroidReadingPlanChapterRead]

    /**
     Creates a status payload without normalizing authored rows.

     - Parameter chapterReadArray: Candidate Android status rows.
     - Side effects: none.
     - Failure modes: none.
     */
    public init(chapterReadArray: [AndroidReadingPlanChapterRead] = []) {
        self.chapterReadArray = chapterReadArray
    }

    /**
     Decodes Android status JSON without changing row order or duplicate entries.

     - Parameter json: Raw `ReadingPlanStatus.readingStatus` value.
     - Side effects: none.
     - Failure modes: Throws standard decoding errors for malformed Android payloads.
     */
    public init(androidJSON json: String) throws {
        let decoded = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        self = decoded
    }

    /**
     Returns whether one one-based reading number is marked read.

     - Parameter readingNumber: One-based reading position.
     - Returns: Stored completion state, defaulting to `false` when absent.
     - Side effects: none.
     - Failure modes: none; Android resolves any persisted integer key, including nonpositive rows.
     */
    public func isRead(_ readingNumber: Int) -> Bool {
        chapterReadArray.first { $0.readingNumber == readingNumber }?.isRead == true
    }

    /**
     Returns a copy with one reading status replaced.

     - Parameters:
       - readingNumber: One-based reading position.
       - isRead: New completion state.
     - Returns: Android-equivalent payload containing the updated and appended row.
     - Side effects: none.
     - Failure modes: none; Android permits any persisted integer key at this payload layer.
     */
    public func setting(readingNumber: Int, isRead: Bool) -> Self {
        var rows = chapterReadArray
        if let index = rows.firstIndex(where: { $0.readingNumber == readingNumber }) {
            let updated = AndroidReadingPlanChapterRead(
                readingNumber: readingNumber,
                isRead: isRead
            )
            rows[index] = updated
            rows.append(updated)
        } else {
            rows.append(
                AndroidReadingPlanChapterRead(readingNumber: readingNumber, isRead: isRead)
            )
        }
        let stableRows = rows.enumerated().sorted { lhs, rhs in
            if lhs.element.readingNumber != rhs.element.readingNumber {
                return lhs.element.readingNumber < rhs.element.readingNumber
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Self(chapterReadArray: stableRows)
    }

    /**
     Creates a payload in which every expected reading is marked read or unread.

     - Parameters:
       - readingCount: Number of one-based readings in the day assignment.
       - isRead: Completion state assigned to every reading.
     - Returns: Normalized Android status payload.
     - Side effects: none.
     - Failure modes: Non-positive counts produce an empty payload.
     */
    public static func settingAll(readingCount: Int, isRead: Bool) -> Self {
        guard readingCount > 0 else { return Self() }
        return Self(
            chapterReadArray: (1...readingCount).map {
                AndroidReadingPlanChapterRead(readingNumber: $0, isRead: isRead)
            }
        )
    }

    /**
     Checks Android's `isAllRead` rule for a known day size.

     - Parameter readingCount: Number of readings parsed from the plan definition.
     - Returns: `true` when every one-based reading is marked read; zero-reading days are complete.
     - Side effects: none.
     - Failure modes: Negative counts are treated as zero.
     */
    public func isAllRead(readingCount: Int) -> Bool {
        guard readingCount > 0 else { return true }
        return (1...readingCount).allSatisfy(isRead)
    }

    /**
     Encodes the exact Android JSON object with deterministic key ordering.

     - Returns: UTF-8 JSON suitable for `ReadingPlanStatus.readingStatus`.
     - Side effects: none.
     - Failure modes: Throws standard JSON encoding errors.
     */
    public func androidJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return value
    }
}

/**
 Owns Android-compatible per-reading status over the existing raw status persistence boundary.

 The raw store remains the sync-compatible source of truth. `ReadingPlanDay.isCompleted` is kept
 as a derived compatibility cache for existing UI and migrations; it never replaces a partial
 Android payload.
 */
public final class ReadingPlanProgressStore {
    private let modelContext: ModelContext
    private let statusStore: RemoteSyncReadingPlanStatusStore
    private let snapshotService: RemoteSyncReadingPlanSnapshotService

    /**
     Creates a typed plan-progress store.

     - Parameters:
       - modelContext: Context owning `ReadingPlan` and `ReadingPlanDay` rows.
       - settingsStore: Local settings store owning raw Android status envelopes.
       - userPlanDirectory: Custom-definition directory used by mutation-time journal snapshots.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory()
    ) {
        self.modelContext = modelContext
        statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        snapshotService = RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: userPlanDirectory
        )
    }

    /**
     Resolves effective status for one day using Android historic-day semantics.

     - Parameters:
       - day: Persisted day row.
       - plan: Parent plan.
     - Returns: Effective per-reading status.
     - Side effects: none.
     - Throws: A present malformed status envelope or Android payload. Only an absent status falls
       back to the derived day-completion cache.
     */
    public func status(
        for day: ReadingPlanDay,
        in plan: ReadingPlan
    ) throws -> AndroidReadingPlanStatusPayload {
        let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
        if !ReadingPlanService.isDateBased(plan), day.dayNumber < max(plan.currentDay, 1) {
            return .settingAll(readingCount: assignment.readings.count, isRead: true)
        }
        if let stored = try statusStore.storedStatusStrict(
            planCode: plan.planCode,
            dayNumber: day.dayNumber
        ) {
            return try AndroidReadingPlanStatusPayload(androidJSON: stored.readingStatusJSON)
        }
        if day.isCompleted {
            return .settingAll(readingCount: assignment.readings.count, isRead: true)
        }
        return AndroidReadingPlanStatusPayload()
    }

    /**
     Migrates legacy iOS day-level completion into Android per-reading payloads conservatively.

     A legacy completed day becomes all-read only when its definition supplies concrete readings.
     Existing Android payloads always win, including partial status. Non-date historic days remain
     implicit in `plan.currentDay`, matching Android's status cleanup.

     - Parameter plan: Plan whose day rows should be reconciled.
     - Returns: Number of raw status rows newly materialized.
     - Side effects: Writes status settings, refreshes derived day completion flags, and saves the
       model context when any day cache changes.
     - Throws: Malformed status persistence, payload encoding, mutation-journal, or model-save
       failures. The prior graph and settings remain unchanged when the transaction fails.
     */
    @discardableResult
    public func migrateLegacyStatuses(in plan: ReadingPlan) throws -> Int {
        try performMutation { _ in
            var insertedCount = 0

            for day in plan.days ?? [] {
                let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
                let stored = try statusStore.storedStatusStrict(
                    planCode: plan.planCode,
                    dayNumber: day.dayNumber
                )
                let isImplicitHistoric = !ReadingPlanService.isDateBased(plan) &&
                    day.dayNumber < max(plan.currentDay, 1)

                if stored == nil, day.isCompleted, !isImplicitHistoric, !assignment.readings.isEmpty {
                    let payload = AndroidReadingPlanStatusPayload.settingAll(
                        readingCount: assignment.readings.count,
                        isRead: true
                    )
                    try statusStore.setStatusThrowing(
                        .init(
                            planCode: plan.planCode,
                            dayNumber: day.dayNumber,
                            readingStatusJSON: try payload.androidJSON()
                        )
                    )
                    insertedCount += 1
                }

                let effectiveComplete = try status(for: day, in: plan).isAllRead(
                    readingCount: assignment.readings.count
                )
                if day.isCompleted != effectiveComplete {
                    day.isCompleted = effectiveComplete
                    if !effectiveComplete {
                        day.completedDate = nil
                    }
                }
            }
            return insertedCount
        }
    }

    /**
     Updates one reading and preserves an existing Android status-row identifier.

     Historic non-date days are immutable on Android and therefore ignored here.

     - Parameters:
       - readingNumber: One-based reading position.
       - isRead: New completion state.
       - day: Day row whose derived completion cache should be refreshed.
       - plan: Parent reading plan.
       - now: Completion timestamp for an all-read transition.
     - Returns: Effective normalized payload after the attempted mutation.
     - Side effects: Writes one raw Android status envelope, updates `ReadingPlanDay`, and saves.
     - Throws: Malformed existing status, payload encoding, mutation-journal, or model-save failure.
       Invalid reading numbers and historic non-date days return current status without writing.
     */
    @discardableResult
    public func setReading(
        _ readingNumber: Int,
        isRead: Bool,
        day: ReadingPlanDay,
        plan: ReadingPlan,
        now: Date = Date()
    ) throws -> AndroidReadingPlanStatusPayload {
        let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
        let current = try status(for: day, in: plan)
        guard readingNumber > 0,
              assignment.readings.indices.contains(readingNumber - 1),
              ReadingPlanService.isDateBased(plan) || day.dayNumber >= max(plan.currentDay, 1) else {
            return current
        }

        return try performMutation { _ in
            let previous = try statusStore.storedStatusStrict(
                planCode: plan.planCode,
                dayNumber: day.dayNumber
            )
            let updated = current.setting(readingNumber: readingNumber, isRead: isRead)
            try statusStore.setStatusThrowing(
                .init(
                    planCode: plan.planCode,
                    dayNumber: day.dayNumber,
                    readingStatusJSON: try updated.androidJSON(),
                    remoteStatusID: previous?.remoteStatusID
                )
            )

            let allRead = updated.isAllRead(readingCount: assignment.readings.count)
            day.isCompleted = allRead
            day.completedDate = allRead ? (day.completedDate ?? now) : nil
            return updated
        }
    }

    /**
     Removes every local Android status row owned by one plan.

     - Parameter planCode: Exact Android plan code.
     - Side effects: Deletes matching settings rows.
     - Throws: Malformed status persistence, mutation-journal failure, or settings-save failure.
     */
    public func removeStatuses(planCode: String) throws {
        try performMutation { _ in
            try removeStatusesStaged(planCode: planCode)
        }
    }

    /**
     Removes one explicit Android day-status row.

     - Parameters:
       - planCode: Exact Android plan code.
       - dayNumber: One-based day number.
     - Side effects: Deletes the matching settings row when present.
     - Throws: Malformed status persistence, mutation-journal failure, or settings-save failure.
     */
    public func removeStatus(planCode: String, dayNumber: Int) throws {
        try performMutation { _ in
            statusStore.removeStatusThrowing(planCode: planCode, dayNumber: dayNumber)
        }
    }

    /**
     Deletes Android status rows older than a non-date current day.

     - Parameters:
       - planCode: Exact Android plan code.
       - dayNumber: One-based cutoff; rows strictly before it are removed.
     - Side effects: Deletes matching settings rows.
     - Throws: Malformed status persistence, mutation-journal failure, or settings-save failure.
     */
    public func removeStatuses(planCode: String, before dayNumber: Int) throws {
        try performMutation { _ in
            try removeStatusesStaged(planCode: planCode, before: dayNumber)
        }
    }

    /** Runs graph/status mutations with one strict status read and mutation-journal commit. */
    func performMutation<Result>(
        _ mutations: (SettingsStore) throws -> Result
    ) throws -> Result {
        _ = try statusStore.allStatusesStrict()
        let settingsStore = statusStore.definitionPublicationSettingsStore
        return try settingsStore.performJournaledSave(in: modelContext) {
            let result = try mutations(settingsStore)
            modelContext.processPendingChanges()
            try RemoteSyncMutationJournalService(
                readingPlanSnapshotService: snapshotService
            ).recordLocalChanges(
                for: .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return result
        }
    }

    /** Stages deletion of every status belonging to one exact plan code. */
    func removeStatusesStaged(planCode: String) throws {
        let statuses = try statusStore.allStatusesStrict().filter { $0.planCode == planCode }
        for status in statuses {
            statusStore.removeStatusThrowing(
                planCode: status.planCode,
                dayNumber: status.dayNumber
            )
        }
    }

    /** Stages deletion of statuses before one Android current-day cutoff. */
    func removeStatusesStaged(planCode: String, before dayNumber: Int) throws {
        let statuses = try statusStore.allStatusesStrict().filter {
            $0.planCode == planCode && $0.dayNumber < dayNumber
        }
        for status in statuses {
            statusStore.removeStatusThrowing(
                planCode: status.planCode,
                dayNumber: status.dayNumber
            )
        }
    }
}

/**
 Persists Android's single selected reading-plan preference and reconciles legacy iOS flags.
 */
public final class ReadingPlanSelectionStore {
    /// Exact Android `ReadingPlanControl.READING_PLAN` preference key.
    public static let settingsKey = "reading_plan"

    private let settingsStore: SettingsStore
    private let snapshotService: RemoteSyncReadingPlanSnapshotService

    /** Creates a selection store without side effects or failure modes. */
    public init(
        settingsStore: SettingsStore,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory()
    ) {
        self.settingsStore = settingsStore
        snapshotService = RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: userPlanDirectory
        )
    }

    /// Selected Android plan code, or `nil` when no plan is selected.
    public var selectedPlanCode: String? {
        guard let code = settingsStore.getString(Self.settingsKey), !code.isEmpty else { return nil }
        return code
    }

    /**
     Selects exactly one persisted plan.

     - Parameters:
       - plan: Plan selected by the user.
       - plans: All local plan rows whose compatibility flags must be reconciled.
       - modelContext: Context used to save compatibility flags.
     - Side effects: Writes `reading_plan`, sets only the selected row's `isActive`, and saves.
     - Throws: Snapshot, mutation-journal, settings, or model-save failure.
     */
    public func select(
        _ plan: ReadingPlan,
        among plans: [ReadingPlan],
        modelContext: ModelContext,
        startDateMilliseconds: Int64? = nil
    ) throws {
        try performMutation(modelContext: modelContext) {
            settingsStore.setString(Self.settingsKey, value: plan.planCode)
            if let startDateMilliseconds {
                RemoteSyncReadingPlanTimestampStore(settingsStore: settingsStore)
                    .setMilliseconds(startDateMilliseconds, for: plan.id)
            }
            for candidate in plans {
                candidate.isActive = candidate.id == plan.id
            }
        }
    }

    /**
     Clears selection only when the supplied plan owns Android's selected code.

     - Parameters:
       - planCode: Plan being reset or completed.
       - plans: Remaining local plan rows.
       - modelContext: Context used to save compatibility flags.
     - Side effects: Removes `reading_plan` when it matches and clears matching active flags.
     - Throws: Snapshot, mutation-journal, settings, or model-save failure.
     */
    public func clearIfSelected(
        planCode: String,
        among plans: [ReadingPlan],
        modelContext: ModelContext,
        planID: UUID? = nil
    ) throws {
        try performMutation(modelContext: modelContext) {
            if selectedPlanCode == planCode {
                settingsStore.remove(Self.settingsKey)
            }
            if let planID {
                RemoteSyncReadingPlanTimestampStore(settingsStore: settingsStore)
                    .removeMilliseconds(for: planID)
            }
            for plan in plans where plan.planCode == planCode {
                plan.isActive = false
            }
        }
    }

    /**
     Reconciles pre-parity multi-active rows into one deterministic Android selection.

     An existing valid `reading_plan` preference wins. Otherwise, exactly one or several legacy
     active rows are migrated by selecting the newest start date, then stable code/id order. A
     restore that deliberately leaves every row inactive does not invent a selected plan.

     - Parameters:
       - plans: All persisted plan rows.
       - modelContext: Context used to save compatibility flags.
     - Returns: Selected plan after reconciliation, or `nil`.
     - Side effects: May migrate the selected preference and normalize `isActive` flags.
     - Throws: Snapshot, mutation-journal, settings, or model-save failure.
     */
    @discardableResult
    public func reconcile(
        _ plans: [ReadingPlan],
        modelContext: ModelContext
    ) throws -> ReadingPlan? {
        try performMutation(modelContext: modelContext) {
            let selected: ReadingPlan?
            if let selectedPlanCode,
               let matching = plans.first(where: { $0.planCode == selectedPlanCode }) {
                selected = matching
            } else {
                selected = plans.filter(\.isActive).sorted {
                    if $0.startDate != $1.startDate { return $0.startDate > $1.startDate }
                    if $0.planCode != $1.planCode { return $0.planCode < $1.planCode }
                    return $0.id.uuidString < $1.id.uuidString
                }.first
                if let selected {
                    settingsStore.setString(Self.settingsKey, value: selected.planCode)
                } else if selectedPlanCode != nil {
                    settingsStore.remove(Self.settingsKey)
                }
            }

            for plan in plans {
                plan.isActive = plan.id == selected?.id
            }
            return selected
        }
    }

    /** Commits one selection/graph mutation with its reading-plan journal projection. */
    private func performMutation<Result>(
        modelContext: ModelContext,
        _ mutations: () throws -> Result
    ) throws -> Result {
        try settingsStore.performJournaledSave(in: modelContext) {
            let result = try mutations()
            modelContext.processPendingChanges()
            try RemoteSyncMutationJournalService(
                readingPlanSnapshotService: snapshotService
            ).recordLocalChanges(
                for: .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return result
        }
    }
}
