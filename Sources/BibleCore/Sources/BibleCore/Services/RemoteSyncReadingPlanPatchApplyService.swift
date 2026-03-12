// RemoteSyncReadingPlanPatchApplyService.swift — Incremental Android patch replay for reading plans

import CLibSword
import Foundation
import SQLite3
import SwiftData

private let remoteSyncReadingPlanPatchSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while replaying Android reading-plan patch archives against local SwiftData state.

 The service intentionally distinguishes transport/archive failures from malformed patch content so
 callers can surface actionable sync diagnostics instead of collapsing every failure into a generic
 “restore failed” state.
 */
public enum RemoteSyncReadingPlanPatchApplyError: Error, Equatable {
    /// One Android `LogEntry` identifier could not be converted into a UUID row key.
    case invalidLogEntryIdentifier(table: String)

    /// One `UPSERT` log entry referenced a row that was not present in the staged patch database.
    case missingPatchRow(table: String, id: UUID)
}

/**
 Summary of one successful reading-plan patch replay batch.

 Android records patch application per archive, but higher layers also need a compact summary of
 how many row-level mutations were actually applied or skipped once local `LogEntry` precedence
 rules were evaluated.
 */
public struct RemoteSyncReadingPlanPatchApplyReport: Sendable, Equatable {
    /// Number of patch archives applied successfully.
    public let appliedPatchCount: Int

    /// Number of remote `LogEntry` rows that won the timestamp comparison and were replayed.
    public let appliedLogEntryCount: Int

    /// Number of remote `LogEntry` rows skipped because the local row was newer or equal.
    public let skippedLogEntryCount: Int

    /// Supported reading-plan codes present after replay completed.
    public let restoredPlanCodes: [String]

    /// Number of raw Android `ReadingPlanStatus` payloads preserved locally after replay.
    public let preservedStatusCount: Int

    /**
     Creates one reading-plan patch replay summary.

     - Parameters:
       - appliedPatchCount: Number of patch archives applied successfully.
       - appliedLogEntryCount: Number of remote `LogEntry` rows replayed locally.
       - skippedLogEntryCount: Number of remote `LogEntry` rows skipped due to local precedence.
       - restoredPlanCodes: Supported reading-plan codes present after replay.
       - preservedStatusCount: Number of raw Android `ReadingPlanStatus` payloads preserved locally.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        appliedPatchCount: Int,
        appliedLogEntryCount: Int,
        skippedLogEntryCount: Int,
        restoredPlanCodes: [String],
        preservedStatusCount: Int
    ) {
        self.appliedPatchCount = appliedPatchCount
        self.appliedLogEntryCount = appliedLogEntryCount
        self.skippedLogEntryCount = skippedLogEntryCount
        self.restoredPlanCodes = restoredPlanCodes
        self.preservedStatusCount = preservedStatusCount
    }
}

/**
 Replays Android reading-plan patch archives into the local SwiftData reading-plan graph.

 Android patch files for the reading-plan category contain only sparse `ReadingPlan`,
 `ReadingPlanStatus`, and `LogEntry` rows. This service mirrors Android's conflict rule exactly:
 a patch row is applied only when the incoming `LogEntry.lastUpdated` is newer than the locally
 preserved `LogEntry` for the same `(tableName, entityId1, entityId2)` key.

 The implementation stages every archive into an in-memory working set first:
 - current local plans and preserved Android status payloads are read into temporary value types
 - each staged patch archive is decompressed and its newer rows are replayed into that working set
 - only after every archive validates successfully does the service rewrite SwiftData and the
   local-only fidelity stores

 This preserves Android's precedence semantics while avoiding partially mutated local state when a
 later archive row is malformed.

 Data dependencies:
 - `RemoteSyncInitialBackupMetadataRestoreService` reads Android `LogEntry` rows from patch files
 - `RemoteSyncLogEntryStore` provides the local Android conflict baseline for timestamp comparison
 - `RemoteSyncPatchStatusStore` records successfully applied patch archives per source device
 - `RemoteSyncReadingPlanStatusStore` preserves raw Android `ReadingPlanStatus` payloads locally
 - `ReadingPlanService.availablePlans` provides the supported plan templates needed to rebuild
   `ReadingPlanDay` rows after replay

 Side effects:
 - creates and removes temporary decompressed SQLite files beneath the configured temporary directory
 - rewrites local `ReadingPlan` and `ReadingPlanDay` SwiftData rows after successful replay
 - replaces local Android `LogEntry` metadata for the reading-plan category
 - appends applied-patch bookkeeping rows to `RemoteSyncPatchStatusStore`
 - rewrites preserved Android `ReadingPlanStatus` payloads in `RemoteSyncReadingPlanStatusStore`

 Failure modes:
 - throws `RemoteSyncArchiveStagingError.decompressionFailed` when a staged gzip archive cannot be extracted
 - rethrows `RemoteSyncInitialBackupMetadataRestoreError` when staged `LogEntry` rows are malformed
 - throws `RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier` when a patch log row does not use a UUID key
 - throws `RemoteSyncReadingPlanPatchApplyError.missingPatchRow` when an `UPSERT` log row has no matching row in the patch database
 - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when replay would leave the local store with a plan code iOS cannot rebuild from bundled templates
 - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when one preserved Android status payload is not valid for completion reconstruction
 - rethrows `ModelContext.save()` failures after the final rewrite

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied `ModelContext`
   and `SettingsStore`
 */
public final class RemoteSyncReadingPlanPatchApplyService {
    private struct WorkingPlan {
        let id: UUID
        var planCode: String
        var startDate: Date
        var currentDay: Int
    }

    private struct WorkingStatus {
        var remoteStatusID: UUID?
        var planCode: String
        var dayNumber: Int
        var readingStatusJSON: String
    }

    private struct PreparedDay {
        let dayNumber: Int
        let readings: String
        let isCompleted: Bool
    }

    private struct PreparedPlan {
        let id: UUID
        let planCode: String
        let planName: String
        let startDate: Date
        let currentDay: Int
        let totalDays: Int
        let isActive: Bool
        let days: [PreparedDay]
    }

    private struct AndroidReadingStatusPayload: Decodable {
        let chapterReadArray: [AndroidChapterRead]
    }

    private struct AndroidChapterRead: Decodable {
        let readingNumber: Int
    }

    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    /**
     Creates a reading-plan patch replay service.

     - Parameters:
       - metadataRestoreService: Reader used for staged Android `LogEntry` rows.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary decompressed patch databases. Defaults
         to the process temporary directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.metadataRestoreService = metadataRestoreService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    /**
     Applies one ordered batch of staged Android reading-plan patch archives.

     The caller is expected to pass archives in discovery order, matching Android's per-device
     patch-number progression.

     - Parameters:
       - stagedArchives: Previously downloaded staged patch archives in application order.
       - modelContext: SwiftData context whose `ReadingPlan` graph should be rewritten on success.
       - settingsStore: Local-only settings store backing preserved Android fidelity metadata.
     - Returns: Summary describing how many patch archives and `LogEntry` rows were replayed.
     - Side effects:
       - creates and removes temporary decompressed SQLite files
       - rewrites local `ReadingPlan` and `ReadingPlanDay` rows after the full batch succeeds
       - replaces local Android `LogEntry` metadata for `.readingPlans`
       - appends applied-patch rows to `RemoteSyncPatchStatusStore`
       - rewrites preserved Android status payloads in `RemoteSyncReadingPlanStatusStore`
     - Failure modes:
       - rethrows patch-archive decompression failures
       - rethrows malformed staged `LogEntry` metadata failures
       - rethrows malformed reading-status JSON failures
       - throws `RemoteSyncReadingPlanPatchApplyError` for invalid identifiers or missing patch rows
       - rethrows `ModelContext.save()` failures after the final rewrite
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncReadingPlanPatchApplyReport {
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        var workingPlans = try currentPlans(from: modelContext)
        var workingStatuses = statusStore.allStatuses().map {
            WorkingStatus(
                remoteStatusID: $0.remoteStatusID,
                planCode: $0.planCode,
                dayNumber: $0.dayNumber,
                readingStatusJSON: $0.readingStatusJSON
            )
        }
        var logEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .readingPlans).map {
                (logEntryStore.key(for: .readingPlans, entry: $0), $0)
            }
        )

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0

        for stagedArchive in stagedArchives {
            try {
                let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-readingplans-patch-", suffix: ".sqlite3")
                defer { try? fileManager.removeItem(at: patchDatabaseURL) }

                let archiveData = try Data(contentsOf: stagedArchive.archiveFileURL)
                let databaseData = try Self.gunzip(archiveData)
                try databaseData.write(to: patchDatabaseURL, options: .atomic)

                let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
                let patchLogEntries = metadataSnapshot.logEntries.filter {
                    $0.tableName == "ReadingPlan" || $0.tableName == "ReadingPlanStatus"
                }
                let filteredLogEntries = patchLogEntries.filter { entry in
                    let key = logEntryStore.key(for: .readingPlans, entry: entry)
                    guard let localEntry = logEntriesByKey[key] else {
                        return true
                    }
                    return entry.lastUpdated > localEntry.lastUpdated
                }

                skippedLogEntryCount += patchLogEntries.count - filteredLogEntries.count
                if filteredLogEntries.isEmpty {
                    return
                }

                try withSQLiteDatabase(at: patchDatabaseURL) { database in
                    try applyReadingPlanTableOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "ReadingPlan" },
                        database: database,
                        plans: &workingPlans,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                    try applyReadingPlanStatusTableOperations(
                        logEntries: filteredLogEntries.filter { $0.tableName == "ReadingPlanStatus" },
                        database: database,
                        statuses: &workingStatuses,
                        logEntriesByKey: &logEntriesByKey,
                        logEntryStore: logEntryStore
                    )
                }

                appliedLogEntryCount += filteredLogEntries.count
                appliedPatchStatuses.append(
                    RemoteSyncPatchStatus(
                        sourceDevice: stagedArchive.patch.sourceDevice,
                        patchNumber: stagedArchive.patch.patchNumber,
                        sizeBytes: stagedArchive.patch.file.size,
                        appliedDate: stagedArchive.patch.file.timestamp
                    )
                )
            }()
        }

        let supportedPlanCodes = Set(ReadingPlanService.availablePlans.map(\.code))
        let unsupportedPlanCodes = Array(
            Set(workingPlans.values.map(\.planCode).filter { !supportedPlanCodes.contains($0) })
        ).sorted()
        if !unsupportedPlanCodes.isEmpty {
            throw RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions(unsupportedPlanCodes)
        }

        let preparedPlans = try preparePlans(plans: Array(workingPlans.values), statuses: workingStatuses)
        try replaceLocalReadingPlans(
            preparedPlans: preparedPlans,
            preservedStatuses: workingStatuses,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.replaceEntries(
            logEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .readingPlans
        )
        patchStatusStore.addStatuses(appliedPatchStatuses, for: .readingPlans)

        return RemoteSyncReadingPlanPatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            restoredPlanCodes: preparedPlans.map(\.planCode).sorted(),
            preservedStatusCount: workingStatuses.count
        )
    }

    /**
     Loads the current local reading plans into mutable working rows.

     - Parameter modelContext: SwiftData context that owns the local reading-plan graph.
     - Returns: Working reading-plan rows keyed by plan UUID.
     - Side effects:
       - reads local `ReadingPlan` rows from SwiftData
     - Failure modes:
       - fetch failures are swallowed and reported as an empty plan set to match the repo's existing
         store behavior
     */
    private func currentPlans(from modelContext: ModelContext) throws -> [UUID: WorkingPlan] {
        let existingPlans = (try? modelContext.fetch(FetchDescriptor<ReadingPlan>())) ?? []
        return Dictionary(
            uniqueKeysWithValues: existingPlans.map { plan in
                (
                    plan.id,
                    WorkingPlan(
                        id: plan.id,
                        planCode: plan.planCode,
                        startDate: plan.startDate,
                        currentDay: plan.currentDay
                    )
                )
            }
        )
    }

    /**
     Applies one batch of `ReadingPlan` table log entries in Android table order.

     Android applies all `UPSERT` rows for a table before handling `DELETE` rows from the same
     table. This helper mirrors that ordering.

     - Parameters:
       - logEntries: Newer patch log entries for the `ReadingPlan` table.
       - database: Open staged patch database handle.
       - plans: Mutable working reading-plan rows keyed by plan UUID.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive the Android-compatible key strings.
     - Side effects:
       - mutates the working plan map in memory
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID
       - throws `RemoteSyncReadingPlanPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyReadingPlanTableOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        plans: inout [UUID: WorkingPlan],
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let planID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            guard let plan = try fetchReadingPlan(id: planID, from: database) else {
                throw RemoteSyncReadingPlanPatchApplyError.missingPatchRow(table: entry.tableName, id: planID)
            }
            plans[plan.id] = plan
            logEntriesByKey[logEntryStore.key(for: .readingPlans, entry: entry)] = entry
        }

        for entry in deletes {
            let planID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            plans.removeValue(forKey: planID)
            logEntriesByKey[logEntryStore.key(for: .readingPlans, entry: entry)] = entry
        }
    }

    /**
     Applies one batch of `ReadingPlanStatus` table log entries in Android table order.

     - Parameters:
       - logEntries: Newer patch log entries for the `ReadingPlanStatus` table.
       - database: Open staged patch database handle.
       - statuses: Mutable working Android status payloads.
       - logEntriesByKey: Mutable in-memory Android `LogEntry` map keyed by local settings keys.
       - logEntryStore: Store used to derive the Android-compatible key strings.
     - Side effects:
       - mutates the working preserved-status collection in memory
       - mutates the in-memory Android `LogEntry` map
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier` when a log row does not identify a UUID
       - throws `RemoteSyncReadingPlanPatchApplyError.missingPatchRow` when an `UPSERT` row is absent from the patch database
       - rethrows SQLite read failures when one row cannot be read from the staged database
     */
    private func applyReadingPlanStatusTableOperations(
        logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        statuses: inout [WorkingStatus],
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)

        for entry in upserts {
            let statusID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            guard let status = try fetchReadingPlanStatus(id: statusID, from: database) else {
                throw RemoteSyncReadingPlanPatchApplyError.missingPatchRow(table: entry.tableName, id: statusID)
            }
            upsertStatus(
                WorkingStatus(
                    remoteStatusID: status.id,
                    planCode: status.planCode,
                    dayNumber: status.dayNumber,
                    readingStatusJSON: status.readingStatusJSON
                ),
                into: &statuses
            )
            logEntriesByKey[logEntryStore.key(for: .readingPlans, entry: entry)] = entry
        }

        for entry in deletes {
            let statusID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            statuses.removeAll { $0.remoteStatusID == statusID }
            logEntriesByKey[logEntryStore.key(for: .readingPlans, entry: entry)] = entry
        }
    }

    /**
     Replaces or appends one working preserved-status payload.

     Android logically stores one `ReadingPlanStatus` row per `(planCode, planDay)`. The helper
     enforces that invariant locally even when replaying multiple archives in one batch.

     - Parameters:
       - status: Working preserved-status payload to insert or replace.
       - statuses: Mutable working preserved-status collection.
     - Side effects:
       - mutates the in-memory working preserved-status collection
     - Failure modes: This helper cannot fail.
     */
    private func upsertStatus(_ status: WorkingStatus, into statuses: inout [WorkingStatus]) {
        statuses.removeAll {
            if let remoteStatusID = status.remoteStatusID,
               $0.remoteStatusID == remoteStatusID {
                return true
            }
            return $0.planCode == status.planCode && $0.dayNumber == status.dayNumber
        }
        statuses.append(status)
    }

    /**
     Prepares the final supported reading plans for SwiftData rewrite.

     - Parameters:
       - plans: Working reading-plan rows present after all patch archives were replayed.
       - statuses: Working preserved-status payloads present after all patch archives were replayed.
     - Returns: Prepared plan rows containing the rebuilt day list for each supported plan.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when a remaining plan code is unsupported
       - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when a preserved Android status payload is not valid for completion reconstruction
     */
    private func preparePlans(
        plans: [WorkingPlan],
        statuses: [WorkingStatus]
    ) throws -> [PreparedPlan] {
        let templatesByCode = Dictionary(uniqueKeysWithValues: ReadingPlanService.availablePlans.map { ($0.code, $0) })
        let missingPlanCodes = Array(
            Set(plans.map(\.planCode).filter { templatesByCode[$0] == nil })
        ).sorted()
        if !missingPlanCodes.isEmpty {
            throw RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions(missingPlanCodes)
        }

        let statusesByPlanCode = Dictionary(grouping: statuses, by: \.planCode)

        return try plans.sorted(by: Self.planSort).map { plan in
            let template = templatesByCode[plan.planCode]!
            let isDateBased = Self.isDateBasedPlan(template)
            let normalizedCurrentDay = min(max(plan.currentDay, 1), max(template.totalDays, 1))
            let statusesByDay = Dictionary(uniqueKeysWithValues: statusesByPlanCode[plan.planCode, default: []].map {
                (
                    $0.dayNumber,
                    RemoteSyncAndroidReadingPlanStatus(
                        id: $0.remoteStatusID ?? UUID(),
                        planCode: $0.planCode,
                        dayNumber: $0.dayNumber,
                        readingStatusJSON: $0.readingStatusJSON
                    )
                )
            })

            var preparedDays: [PreparedDay] = []
            preparedDays.reserveCapacity(template.totalDays)
            var allDaysCompleted = true

            for dayNumber in 1...template.totalDays {
                let readings = template.readingsForDay(dayNumber)
                let expectedCount = Self.expectedReadingCount(for: readings, isDateBasedPlan: isDateBased)
                let completion = try Self.isDayComplete(
                    status: statusesByDay[dayNumber],
                    dayNumber: dayNumber,
                    currentDay: normalizedCurrentDay,
                    expectedReadingCount: expectedCount,
                    isDateBasedPlan: isDateBased
                )
                if !completion {
                    allDaysCompleted = false
                }
                preparedDays.append(
                    PreparedDay(
                        dayNumber: dayNumber,
                        readings: readings,
                        isCompleted: completion
                    )
                )
            }

            return PreparedPlan(
                id: plan.id,
                planCode: plan.planCode,
                planName: template.name,
                startDate: plan.startDate,
                currentDay: normalizedCurrentDay,
                totalDays: template.totalDays,
                isActive: !allDaysCompleted,
                days: preparedDays
            )
        }
    }

    /**
     Rewrites the local `ReadingPlan` graph and preserved Android status payloads.

     - Parameters:
       - preparedPlans: Supported plan rows prepared for SwiftData insertion.
       - preservedStatuses: Raw Android status payloads to preserve locally after the rewrite.
       - modelContext: SwiftData context whose reading-plan graph should be replaced.
       - statusStore: Local-only store used to preserve Android `ReadingPlanStatus` payloads.
     - Side effects:
       - deletes the existing local `ReadingPlan` graph
       - inserts the prepared plan and day rows
       - clears and rewrites preserved Android status payloads
       - saves the supplied `ModelContext`
     - Failure modes:
       - rethrows `ModelContext.save()` failures after mutating local SwiftData state
     */
    private func replaceLocalReadingPlans(
        preparedPlans: [PreparedPlan],
        preservedStatuses: [WorkingStatus],
        modelContext: ModelContext,
        statusStore: RemoteSyncReadingPlanStatusStore
    ) throws {
        let existingPlans = (try? modelContext.fetch(FetchDescriptor<ReadingPlan>())) ?? []
        for plan in existingPlans {
            modelContext.delete(plan)
        }

        statusStore.clearAll()

        for plan in preparedPlans {
            let restoredPlan = ReadingPlan(
                id: plan.id,
                planCode: plan.planCode,
                planName: plan.planName,
                startDate: plan.startDate,
                currentDay: plan.currentDay,
                totalDays: plan.totalDays,
                isActive: plan.isActive
            )
            modelContext.insert(restoredPlan)

            for day in plan.days {
                let restoredDay = ReadingPlanDay(
                    dayNumber: day.dayNumber,
                    isCompleted: day.isCompleted,
                    readings: day.readings
                )
                restoredDay.plan = restoredPlan
                modelContext.insert(restoredDay)
            }
        }

        for status in preservedStatuses.sorted(by: Self.statusSort) {
            statusStore.setStatus(
                status.readingStatusJSON,
                planCode: status.planCode,
                dayNumber: status.dayNumber,
                remoteStatusID: status.remoteStatusID
            )
        }

        try modelContext.save()
    }

    /**
     Reads one `ReadingPlan` row from a staged patch database by UUID.

     - Parameters:
       - id: Android `ReadingPlan.id` value to fetch.
       - database: Open staged patch database handle.
     - Returns: Working plan row when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - rethrows SQLite open/prepare failures as `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase`
       - rethrows malformed identifier failures from `RemoteSyncReadingPlanRestoreService`
     */
    private func fetchReadingPlan(id: UUID, from database: OpaquePointer) throws -> WorkingPlan? {
        let sql = """
        SELECT id, planCode, planStartDate, planCurrentDay
        FROM ReadingPlan
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return WorkingPlan(
            id: try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlan", name: "id"),
            planCode: stringColumn(statement: statement, index: 1),
            startDate: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)) / 1000.0),
            currentDay: Int(sqlite3_column_int(statement, 3))
        )
    }

    /**
     Reads one `ReadingPlanStatus` row from a staged patch database by UUID.

     - Parameters:
       - id: Android `ReadingPlanStatus.id` value to fetch.
       - database: Open staged patch database handle.
     - Returns: Typed Android status row when present in the staged patch database; otherwise `nil`.
     - Side effects:
       - prepares and steps one SQLite select statement
     - Failure modes:
       - rethrows SQLite open/prepare failures as `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase`
       - rethrows malformed identifier failures from `RemoteSyncReadingPlanRestoreService`
     */
    private func fetchReadingPlanStatus(id: UUID, from database: OpaquePointer) throws -> RemoteSyncAndroidReadingPlanStatus? {
        let sql = """
        SELECT id, planCode, planDay, readingStatus
        FROM ReadingPlanStatus
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return RemoteSyncAndroidReadingPlanStatus(
            id: try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlanStatus", name: "id"),
            planCode: stringColumn(statement: statement, index: 1),
            dayNumber: Int(sqlite3_column_int(statement, 2)),
            readingStatusJSON: stringColumn(statement: statement, index: 3)
        )
    }

    /**
     Converts one Android `LogEntry.entityId1` payload into a UUID row key.

     Reading-plan patches use UUID primary keys for both `ReadingPlan` and `ReadingPlanStatus`.
     The local log-entry store preserves Android's typed SQLite values, so the replay engine must
     validate that the incoming row key is still a UUID-shaped blob or text payload before using it.

     - Parameters:
       - value: Typed SQLite value preserved from Android `LogEntry.entityId1`.
       - tableName: Android table name used for error reporting.
     - Returns: UUID row identifier.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier` when the payload is not a UUID-shaped blob or text value
     */
    private func uuid(from value: RemoteSyncSQLiteValue, tableName: String) throws -> UUID {
        switch value.kind {
        case .blob:
            guard let data = value.blobData, data.count == 16 else {
                throw RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier(table: tableName)
            }
            return try uuidFromData(data, table: tableName, name: "entityId1")
        case .text:
            guard let textValue = value.textValue, let uuid = UUID(uuidString: textValue) else {
                throw RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier(table: tableName)
            }
            return uuid
        default:
            throw RemoteSyncReadingPlanPatchApplyError.invalidLogEntryIdentifier(table: tableName)
        }
    }

    /**
     Executes a read-only SQLite block against one staged patch database.

     - Parameters:
       - databaseURL: Local URL of the decompressed staged patch database.
       - body: Closure that receives the open SQLite database handle.
     - Returns: Result produced by `body`.
     - Side effects:
       - opens the staged database in read-only mode for the duration of `body`
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase` when the staged database cannot be opened
       - rethrows any error produced by `body`
     */
    private func withSQLiteDatabase<T>(at databaseURL: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    /**
     Creates a unique temporary database URL in the configured scratch directory.

     - Parameters:
       - prefix: Leading file-name prefix for easier debugging.
       - suffix: Trailing file-name suffix including the extension.
     - Returns: Unique temporary-file URL that does not yet exist.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Compresses or decompresses staged patch payloads using the same C helpers as archive staging.

     - Parameter data: Raw gzip-compressed patch bytes.
     - Returns: Decompressed SQLite database bytes.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncArchiveStagingError.decompressionFailed` when the payload is not valid gzip data
     */
    private static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = pointer.baseAddress else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            var outputLength: UInt = 0
            guard let output = gunzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    /**
     Converts one required Android UUID BLOB into a Foundation `UUID`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - column: Zero-based column index containing the UUID BLOB.
       - table: Android table name used for error reporting.
       - name: Android column name used for error reporting.
     - Returns: Converted UUID value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob` when the column is absent,
         malformed, or not exactly 16 bytes long
     */
    private func uuidFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID {
        guard
            let bytes = sqlite3_column_blob(statement, column),
            sqlite3_column_bytes(statement, column) == 16
        else {
            throw RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return try uuidFromData(Data(bytes: bytes, count: 16), table: table, name: name)
    }

    /**
     Converts one 16-byte Android UUID payload into a Foundation `UUID`.

     - Parameters:
       - data: Raw 16-byte Android UUID payload.
       - table: Android table name used for error reporting.
       - name: Android column or field name used for error reporting.
     - Returns: Converted UUID value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob` when the payload does not produce a valid UUID string
     */
    private func uuidFromData(_ data: Data, table: String, name: String) throws -> UUID {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let part1 = String(hex[hex.startIndex..<hex.index(hex.startIndex, offsetBy: 8)])
        let part2Start = hex.index(hex.startIndex, offsetBy: 8)
        let part2End = hex.index(part2Start, offsetBy: 4)
        let part2 = String(hex[part2Start..<part2End])
        let part3End = hex.index(part2End, offsetBy: 4)
        let part3 = String(hex[part2End..<part3End])
        let part4End = hex.index(part3End, offsetBy: 4)
        let part4 = String(hex[part3End..<part4End])
        let part5 = String(hex[part4End..<hex.endIndex])

        guard let uuid = UUID(uuidString: "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)") else {
            throw RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return uuid
    }

    /**
     Binds one UUID as Android-style raw BLOB data to an SQLite statement.

     - Parameters:
       - uuid: UUID value to bind.
       - statement: SQLite statement receiving the bound parameter.
       - index: One-based parameter index.
     - Side effects:
       - mutates the bound SQLite statement parameter state
     - Failure modes: This helper cannot fail.
     */
    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var bytes = Data()
        bytes.reserveCapacity(16)

        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let next = hex.index(cursor, offsetBy: 2)
            let byteString = hex[cursor..<next]
            bytes.append(UInt8(byteString, radix: 16)!)
            cursor = next
        }

        _ = bytes.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(
                statement,
                index,
                rawBuffer.baseAddress,
                Int32(bytes.count),
                remoteSyncReadingPlanPatchSQLiteTransient
            )
        }
    }

    /**
     Reads one SQLite text column and falls back to the empty string when SQLite returns `NULL`.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - index: Zero-based column index.
     - Returns: UTF-8 text payload, or the empty string when the column is `NULL`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func stringColumn(statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: raw)
    }

    /**
     Orders Android log entries deterministically for in-memory replay and persistence.

     - Parameters:
       - lhs: First log entry to compare.
       - rhs: Second log entry to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        let lhsKey = "\(lhs.entityID1)-\(lhs.entityID2)"
        let rhsKey = "\(rhs.entityID1)-\(rhs.entityID2)"
        return lhsKey < rhsKey
    }

    /**
     Orders working reading plans deterministically before rebuild.

     - Parameters:
       - lhs: First working plan row to compare.
       - rhs: Second working plan row to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func planSort(_ lhs: WorkingPlan, _ rhs: WorkingPlan) -> Bool {
        if lhs.planCode != rhs.planCode {
            return lhs.planCode < rhs.planCode
        }
        if lhs.startDate != rhs.startDate {
            return lhs.startDate < rhs.startDate
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /**
     Orders preserved Android status payloads deterministically before persistence.

     - Parameters:
       - lhs: First preserved status payload to compare.
       - rhs: Second preserved status payload to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func statusSort(_ lhs: WorkingStatus, _ rhs: WorkingStatus) -> Bool {
        if lhs.planCode != rhs.planCode {
            return lhs.planCode < rhs.planCode
        }
        if lhs.dayNumber != rhs.dayNumber {
            return lhs.dayNumber < rhs.dayNumber
        }
        return (lhs.remoteStatusID?.uuidString ?? "") < (rhs.remoteStatusID?.uuidString ?? "")
    }

    /**
     Detects whether one bundled reading-plan template uses Android's date-prefixed reading format.

     - Parameter template: Bundled reading-plan template to inspect.
     - Returns: `true` when the template uses Android's date-prefixed reading format.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func isDateBasedPlan(_ template: ReadingPlanTemplate) -> Bool {
        let firstDay = template.readingsForDay(1)
        let regex = try! NSRegularExpression(pattern: #"^[A-Za-z]{3}-\d{1,2};"#)
        let range = NSRange(firstDay.startIndex..<firstDay.endIndex, in: firstDay)
        return regex.firstMatch(in: firstDay, options: [], range: range) != nil
    }

    /**
     Counts the reading segments expected for one plan-day string.

     - Parameters:
       - readings: Raw reading-plan day payload from the bundled template.
       - isDateBasedPlan: Whether the template uses Android's date-prefixed reading format.
     - Returns: Number of reading segments Android expects for completion.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func expectedReadingCount(for readings: String, isDateBasedPlan: Bool) -> Int {
        let payload: String
        if isDateBasedPlan, let separator = readings.firstIndex(of: ";") {
            payload = String(readings[readings.index(after: separator)...])
        } else {
            payload = readings
        }

        let components = payload
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return components.count
    }

    /**
     Computes whether one plan day should be treated as complete.

     - Parameters:
       - status: Preserved Android status payload for the day, when present.
       - dayNumber: One-based day number within the plan definition.
       - currentDay: Persisted Android current-day pointer after normalization.
       - expectedReadingCount: Number of reading segments the template expects for the day.
       - isDateBasedPlan: Whether the template uses Android's date-prefixed reading format.
     - Returns: `true` when the day should be marked complete in SwiftData.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when one preserved Android status payload is not valid for the expected schema
     */
    private static func isDayComplete(
        status: RemoteSyncAndroidReadingPlanStatus?,
        dayNumber: Int,
        currentDay: Int,
        expectedReadingCount: Int,
        isDateBasedPlan: Bool
    ) throws -> Bool {
        if !isDateBasedPlan, dayNumber < currentDay {
            return true
        }
        guard let status else {
            return expectedReadingCount == 0
        }

        let decoder = JSONDecoder()
        let payload: AndroidReadingStatusPayload
        do {
            payload = try decoder.decode(AndroidReadingStatusPayload.self, from: Data(status.readingStatusJSON.utf8))
        } catch {
            throw RemoteSyncReadingPlanRestoreError.malformedReadingStatus(
                planCode: status.planCode,
                dayNumber: status.dayNumber
            )
        }

        let uniqueReadings = Set(payload.chapterReadArray.map(\.readingNumber))
        return uniqueReadings.count >= expectedReadingCount
    }
}
