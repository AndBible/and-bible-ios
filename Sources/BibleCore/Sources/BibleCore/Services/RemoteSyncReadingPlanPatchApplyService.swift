// RemoteSyncReadingPlanPatchApplyService.swift — Incremental Android patch replay for reading plans

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

    /// One replay batch contains more patch archives than the bounded service contract permits.
    case tooManyPatchArchives(Int)

    /// A compressed patch exceeds the byte ceiling checked before reading it into memory.
    case compressedArchiveTooLarge(Int64)

    /// A gzip trailer declares an expanded patch larger than the bounded SQLite ceiling.
    case expandedArchiveTooLarge(UInt64)

    /// Aggregate expanded SQLite bytes exceed the bounded replay-request ceiling.
    case cumulativeArchiveTooLarge(UInt64)

    /// A staged patch is malformed, corrupt, or does not contain one strict gzip member.
    case invalidPatchArchive

    /// One patch table exceeds its row ceiling before any rows are materialized.
    case tooManyRows(table: String, count: Int64)
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

 Android patch files for the reading-plan category contain sparse `ReadingPlan`,
 `ReadingPlanStatus`, and `LogEntry` rows. This service mirrors Android's conflict
 rule for every row:
 a patch row is applied only when the incoming `LogEntry.lastUpdated` is newer than the locally
 preserved `LogEntry` for the same `(tableName, entityId1, entityId2)` key.

 Before the first mutation, every archive is preflighted for compressed and cumulative expanded
 bounds. The service then processes archives in caller order. For each archive it reads the current
 strict graph and settings generation, inflates and validates one exact Room database, replays only
 strictly newer rows, and commits graph, status, log, patch-status, and fingerprint state atomically.

 This matches Android's independently committed archive loop: failure in one archive rolls back that
 archive, while complete commits from earlier archives remain durable and later archives are not
 attempted.

 Data dependencies:
 - `RemoteSyncInitialBackupMetadataRestoreService` reads Android `LogEntry` rows from patch files
 - `RemoteSyncLogEntryStore` provides the local Android conflict baseline for timestamp comparison
 - `RemoteSyncPatchStatusStore` records successfully applied patch archives per source device
 - `RemoteSyncReadingPlanStatusStore` preserves raw Android `ReadingPlanStatus` payloads locally
 - `RemoteSyncReadingPlanDefinitionStore` recovers interrupted local definition publication
 - `ReadingPlanService.catalog` provides bundled and installed templates needed to rebuild day rows

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
 - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when replay would leave the local store with a plan code iOS cannot rebuild from the post-installation catalog
 - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when one preserved Android status payload is not valid for completion reconstruction
 - rethrows context-contract, cancellation, fetch, encoding, final-save, and durable-recovery failures

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied `ModelContext`
   and `SettingsStore`
 */
public final class RemoteSyncReadingPlanPatchApplyService {
    /// Maximum archives replayed in one batch.
    private static let maximumPatchArchiveCount = 1_000

    /// Maximum compressed bytes read for one staged patch.
    private static let maximumCompressedPatchByteCount = 16 * 1_024 * 1_024

    /// Maximum expanded SQLite bytes written for one staged patch.
    private static let maximumExpandedPatchByteCount = 64 * 1_024 * 1_024

    /// Maximum aggregate expanded bytes admitted before the first archive publishes.
    private static let maximumCumulativeExpandedPatchByteCount = 256 * 1_024 * 1_024

    /// Maximum native plan, status, and log rows accepted per patch.
    private static let maximumPlanRowCount: Int64 = 10_000
    private static let maximumStatusRowCount: Int64 = 100_000
    private static let maximumLogEntryRowCount: Int64 = 200_000

    /// Maximum bytes accepted for one raw Android status JSON cell.
    private static let maximumStatusByteCount = 1 * 1_024 * 1_024

    private struct WorkingPlan {
        let id: UUID
        var planCode: String
        var startDateMilliseconds: Int64
        var currentDay: Int
    }

    private struct WorkingStatus {
        var remoteStatusID: UUID?
        var planCode: String
        var dayNumber: Int
        var readingStatusJSON: String
    }

    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let snapshotService: RemoteSyncReadingPlanSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let planFetcher: (ModelContext) throws -> [ReadingPlan]
    private let userPlanDirectory: URL
    private let definitionStore: RemoteSyncReadingPlanDefinitionStore
    private let restoreService: RemoteSyncReadingPlanRestoreService

    /**
     Creates a reading-plan patch replay service.

     - Parameters:
       - metadataRestoreService: Reader used for staged Android `LogEntry` rows.
       - snapshotService: Snapshot service used to refresh outbound fingerprint baselines after replay.
       - userPlanDirectory: Destination equivalent to Android's `jsword/readingplan` directory.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary decompressed patch databases. Defaults
         to the process temporary directory.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        snapshotService: RemoteSyncReadingPlanSnapshotService? = nil,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.metadataRestoreService = metadataRestoreService
        self.snapshotService = snapshotService ?? RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.userPlanDirectory = userPlanDirectory
        definitionStore = RemoteSyncReadingPlanDefinitionStore(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        restoreService = RemoteSyncReadingPlanRestoreService(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        planFetcher = { modelContext in
            try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        }
    }

    /**
     Creates a patch replay service with explicit current-plan fetch behavior.

     This initializer supports behavior-level failure tests without weakening production fetches or
     coupling assertions to SwiftData implementation details.

     - Parameters:
       - metadataRestoreService: Reader used for staged Android `LogEntry` rows.
       - snapshotService: Snapshot service used to refresh outbound fingerprint baselines after replay.
       - userPlanDirectory: Destination equivalent to Android's `jsword/readingplan` directory.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary decompressed patch databases.
       - planFetcher: Throwing operation that returns the complete current local plan graph.
     - Side effects: none until patch replay begins.
     - Failure modes: The initializer cannot fail; `planFetcher` errors are rethrown by patch preflight.
     */
    init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        snapshotService: RemoteSyncReadingPlanSnapshotService? = nil,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        planFetcher: @escaping (ModelContext) throws -> [ReadingPlan]
    ) {
        self.metadataRestoreService = metadataRestoreService
        self.snapshotService = snapshotService ?? RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.userPlanDirectory = userPlanDirectory
        definitionStore = RemoteSyncReadingPlanDefinitionStore(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        restoreService = RemoteSyncReadingPlanRestoreService(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        self.planFetcher = planFetcher
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
       - preflights every archive's bounded gzip metadata before the first mutation
       - recovers interrupted local definition publication before each archive projection
       - reads the current plan, preserved-status, and conflict-log generation inside
         that archive's settings-backed transaction
       - creates and removes temporary decompressed SQLite files
       - rewrites local graph, Android metadata, patch status, preserved payloads, and
         outbound fingerprints in one atomic publication per successful archive
     - Failure modes:
       - rethrows patch-archive decompression failures
       - rethrows malformed staged `LogEntry` metadata failures
       - rethrows malformed reading-status JSON failures
       - throws `RemoteSyncReadingPlanPatchApplyError` for invalid identifiers or missing patch rows
       - rethrows definition recovery, validation, installation, and rollback failures
       - rethrows `SettingsStoreAtomicBatchError` when the supplied settings store does not own the
         exact clean `modelContext`
       - rethrows cancellation, strict preflight, strict fingerprint projection, replacement,
         final-save, and durable-recovery failures; a later failure preserves earlier archive commits
     - Note: Archives are committed independently and in caller order, matching Android replay.
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncReadingPlanPatchApplyReport {
        guard stagedArchives.count <= Self.maximumPatchArchiveCount else {
            throw RemoteSyncReadingPlanPatchApplyError.tooManyPatchArchives(
                stagedArchives.count
            )
        }
        try preflightArchiveBounds(stagedArchives)
        if stagedArchives.count > 1 {
            var appliedPatchCount = 0
            var appliedLogEntryCount = 0
            var skippedLogEntryCount = 0
            var restoredPlanCodes: [String] = []
            var preservedStatusCount = 0
            for stagedArchive in stagedArchives {
                let report = try applyPatchArchives(
                    [stagedArchive],
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
                appliedPatchCount += report.appliedPatchCount
                appliedLogEntryCount += report.appliedLogEntryCount
                skippedLogEntryCount += report.skippedLogEntryCount
                restoredPlanCodes = report.restoredPlanCodes
                preservedStatusCount = report.preservedStatusCount
            }
            return RemoteSyncReadingPlanPatchApplyReport(
                appliedPatchCount: appliedPatchCount,
                appliedLogEntryCount: appliedLogEntryCount,
                skippedLogEntryCount: skippedLogEntryCount,
                restoredPlanCodes: restoredPlanCodes,
                preservedStatusCount: preservedStatusCount
            )
        }
        try definitionStore.prepareForSnapshot(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        let initialState = try settingsStore.performAtomicBatch(in: modelContext) {
            let plans = try currentPlans(from: modelContext, settingsStore: settingsStore)
            let statuses = try statusStore.allStatusesStrict().map {
                WorkingStatus(
                    remoteStatusID: $0.remoteStatusID,
                    planCode: $0.planCode,
                    dayNumber: $0.dayNumber,
                    readingStatusJSON: $0.readingStatusJSON
                )
            }
            let logEntriesByKey = Dictionary(
                uniqueKeysWithValues: try logEntryStore.entriesStrict(for: .readingPlans).map {
                    (logEntryStore.key(for: .readingPlans, entry: $0), $0)
                }
            )
            return (plans, statuses, logEntriesByKey)
        }
        var workingPlans = initialState.0
        var workingStatuses = initialState.1
        var logEntriesByKey = initialState.2

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0

        for stagedArchive in stagedArchives {
            try {
                let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-readingplans-patch-", suffix: ".sqlite3")
                defer { try? fileManager.removeItem(at: patchDatabaseURL) }

                try decompressPatchArchive(
                    from: stagedArchive.archiveFileURL,
                    to: patchDatabaseURL
                )
                try withSQLiteDatabase(at: patchDatabaseURL) { database in
                    try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                        database,
                        category: .readingPlans
                    )
                    try validatePatchDatabaseBounds(database)
                }

                let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
                let patchLogEntries = metadataSnapshot.logEntries.filter {
                    $0.tableName == "ReadingPlan"
                        || $0.tableName == "ReadingPlanStatus"
                }
                let filteredLogEntries = patchLogEntries.filter { entry in
                    let key = logEntryStore.key(for: .readingPlans, entry: entry)
                    guard let localEntry = logEntriesByKey[key] else {
                        return true
                    }
                    return RemoteSyncLogEntryConflictOrder.isNewer(entry, than: localEntry)
                }

                skippedLogEntryCount += patchLogEntries.count - filteredLogEntries.count
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

        return try settingsStore.performAtomicBatch(in: modelContext) {
            let supportedPlanCodes = Set(
                ReadingPlanService.catalog(userPlanDirectory: userPlanDirectory).templates.map(\.code)
            )
            let unsupportedPlanCodes = Array(
                Set(workingPlans.values.map(\.planCode).filter { !supportedPlanCodes.contains($0) })
            ).sorted()
            if !unsupportedPlanCodes.isEmpty {
                throw RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions(unsupportedPlanCodes)
            }

            let preparedPlans = try preparePlans(
                plans: Array(workingPlans.values),
                statuses: workingStatuses
            )
            let replacement = RemoteSyncReadingPlanReplacement(
                plans: preparedPlans,
                statuses: workingStatuses.sorted(by: Self.statusSort).map { status in
                    RemoteSyncReadingPlanStatusStore.Status(
                        planCode: status.planCode,
                        dayNumber: status.dayNumber,
                        readingStatusJSON: status.readingStatusJSON,
                        remoteStatusID: status.remoteStatusID
                    )
                }
            )
            let restoreReport = try settingsStore.performAtomicBatch(in: modelContext) {
                let report = try restoreService.replaceLocalReadingPlans(
                    with: replacement,
                    modelContext: modelContext,
                    statusStore: statusStore
                )
                logEntryStore.replaceEntries(
                    logEntriesByKey.values.sorted(by: Self.logEntrySort),
                    for: .readingPlans
                )
                patchStatusStore.addStatuses(appliedPatchStatuses, for: .readingPlans)
                try snapshotService.refreshBaselineFingerprintsStrict(
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
                return report
            }

            return RemoteSyncReadingPlanPatchApplyReport(
                appliedPatchCount: appliedPatchStatuses.count,
                appliedLogEntryCount: appliedLogEntryCount,
                skippedLogEntryCount: skippedLogEntryCount,
                restoredPlanCodes: restoreReport.restoredPlanCodes,
                preservedStatusCount: restoreReport.preservedStatusCount
            )
        }
    }

    /**
     Loads the current local reading plans into mutable working rows.

     - Parameter modelContext: SwiftData context that owns the local reading-plan graph.
     - Returns: Working reading-plan rows keyed by plan UUID.
     - Side effects:
       - reads local `ReadingPlan` rows from SwiftData
     - Failure modes:
       - rethrows SwiftData fetch failures before patch staging or publication begins
     */
    private func currentPlans(
        from modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> [UUID: WorkingPlan] {
        let existingPlans = try planFetcher(modelContext)
        let exactTimestamps = try RemoteSyncReadingPlanTimestampStore(
            settingsStore: settingsStore
        ).allMilliseconds()
        return Dictionary(
            uniqueKeysWithValues: try existingPlans.map { plan in
                let startDateMilliseconds: Int64
                if let preserved = exactTimestamps[plan.id] {
                    startDateMilliseconds = preserved
                } else {
                    startDateMilliseconds = try AndroidTimestamp.milliseconds(from: plan.startDate)
                }
                return (
                    plan.id,
                    WorkingPlan(
                        id: plan.id,
                        planCode: plan.planCode,
                        startDateMilliseconds: startDateMilliseconds,
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
    ) throws -> [RemoteSyncPreparedReadingPlan] {
        let templatesByCode = Dictionary(
            uniqueKeysWithValues: ReadingPlanService.catalog(
                userPlanDirectory: userPlanDirectory
            ).templates.map { ($0.code, $0) }
        )
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
            let effectiveCurrentDay = max(plan.currentDay, 1)
            var statusesByDay: [Int: RemoteSyncAndroidReadingPlanStatus] = [:]
            for status in statusesByPlanCode[plan.planCode, default: []] {
                guard statusesByDay[status.dayNumber] == nil else {
                    throw RemoteSyncReadingPlanRestoreError.duplicateReadingStatus(
                        planCode: status.planCode,
                        dayNumber: status.dayNumber
                    )
                }
                statusesByDay[status.dayNumber] = RemoteSyncAndroidReadingPlanStatus(
                    id: status.remoteStatusID ?? UUID(),
                    planCode: status.planCode,
                    dayNumber: status.dayNumber,
                    readingStatusJSON: status.readingStatusJSON
                )
            }

            var preparedDays: [RemoteSyncPreparedReadingPlanDay] = []
            preparedDays.reserveCapacity(template.dayNumbers.count)
            for dayNumber in template.dayNumbers {
                let readings = template.readingsForDay(dayNumber)
                let expectedCount = Self.expectedReadingCount(for: readings)
                let completion = try Self.isDayComplete(
                    status: statusesByDay[dayNumber],
                    dayNumber: dayNumber,
                    currentDay: effectiveCurrentDay,
                    expectedReadingCount: expectedCount,
                    isDateBasedPlan: isDateBased
                )
                preparedDays.append(
                    RemoteSyncPreparedReadingPlanDay(
                        dayNumber: dayNumber,
                        readings: readings,
                        isCompleted: completion
                    )
                )
            }

            return RemoteSyncPreparedReadingPlan(
                id: plan.id,
                planCode: plan.planCode,
                planName: template.name,
                startDateMilliseconds: plan.startDateMilliseconds,
                currentDay: plan.currentDay,
                totalDays: template.totalDays,
                isActive: false,
                days: preparedDays
            )
        }
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
        try bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER else {
            throw RemoteSyncReadingPlanRestoreError.invalidDayNumber(
                table: "ReadingPlan",
                value: 0
            )
        }
        let currentDayValue = sqlite3_column_int64(statement, 3)
        guard currentDayValue >= Int64(Int32.min),
              currentDayValue <= Int64(Int32.max) else {
            throw RemoteSyncReadingPlanRestoreError.invalidDayNumber(
                table: "ReadingPlan",
                value: currentDayValue
            )
        }
        return WorkingPlan(
            id: try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlan", name: "id"),
            planCode: try planCodeColumn(
                statement: statement,
                index: 1,
                table: "ReadingPlan"
            ),
            startDateMilliseconds: sqlite3_column_int64(statement, 2),
            currentDay: Int(currentDayValue)
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
        try bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return RemoteSyncAndroidReadingPlanStatus(
            id: try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlanStatus", name: "id"),
            planCode: try planCodeColumn(
                statement: statement,
                index: 1,
                table: "ReadingPlanStatus"
            ),
            dayNumber: try dayNumberColumn(
                statement: statement,
                index: 2,
                table: "ReadingPlanStatus"
            ),
            readingStatusJSON: try textColumn(
                statement: statement,
                index: 3,
                table: "ReadingPlanStatus",
                column: "readingStatus",
                maximumByteCount: Self.maximumStatusByteCount,
                permitsEmpty: true
            )
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

    /** Rejects oversized native patch tables before metadata or row materialization. */
    private func validatePatchDatabaseBounds(_ database: OpaquePointer) throws {
        try requirePatchRowCount(
            table: "ReadingPlan",
            database: database,
            maximum: Self.maximumPlanRowCount
        )
        try requirePatchRowCount(
            table: "ReadingPlanStatus",
            database: database,
            maximum: Self.maximumStatusRowCount
        )
        try requirePatchRowCount(
            table: "LogEntry",
            database: database,
            maximum: Self.maximumLogEntryRowCount
        )
    }

    /** Reads one table count through SQLite's aggregate without allocating row payloads. */
    private func requirePatchRowCount(
        table: String,
        database: OpaquePointer,
        maximum: Int64
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM \(table)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        let count = sqlite3_column_int64(statement, 0)
        guard count >= 0, count <= maximum else {
            throw RemoteSyncReadingPlanPatchApplyError.tooManyRows(
                table: table,
                count: count
            )
        }
    }

    /**
     Creates a unique temporary database URL in the configured scratch directory.

     - Parameters:
       - prefix: Leading file-name prefix for easier debugging.
       - suffix: Trailing file-name suffix including the extension.
     - Returns: Unique temporary-file URL that does not yet exist.
     - Side effects: none.
     - Throws: `RemoteSyncWireIntegerError.outOfRange` when the BLOB byte count cannot fit SQLite's
       signed 32-bit count argument.
     */
    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Inflates one strict gzip member into a bounded file and verifies its trailer integrity.

     - Parameters:
       - archiveURL: Readable staged gzip file.
       - databaseURL: Unique output URL for the expanded SQLite database.
     - Side effects: Reads a bounded compressed payload and writes at most 64 MiB to `databaseURL`.
     - Throws: Typed compressed/expanded size errors or `invalidPatchArchive` for malformed data.
     */
    private func decompressPatchArchive(from archiveURL: URL, to databaseURL: URL) throws {
        try Task.checkCancellation()
        do {
            let member = try RemoteSyncBoundedFileIO.inspectGzip(
                at: archiveURL,
                maximumCompressedByteCount: Self.maximumCompressedPatchByteCount,
                maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
            )
            try RemoteSyncBoundedFileIO.inflateGzip(
                member,
                from: archiveURL,
                to: databaseURL,
                maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch RemoteSyncBoundedFileError.compressedSizeExceeded(let size) {
            throw RemoteSyncReadingPlanPatchApplyError.compressedArchiveTooLarge(size)
        } catch RemoteSyncBoundedFileError.expandedSizeExceeded(let size) {
            throw RemoteSyncReadingPlanPatchApplyError.expandedArchiveTooLarge(size)
        } catch {
            throw RemoteSyncReadingPlanPatchApplyError.invalidPatchArchive
        }
    }

    /**
     Verifies all archive headers and cumulative expanded bytes before any graph publication.

     - Parameter stagedArchives: Caller-ordered ReadingList patch files.
     - Side effects: Opens each archive without following symlinks and reads bounded gzip metadata.
     - Throws: Typed compressed, expanded, cumulative, or malformed-archive errors without inflating
     a SQLite file or mutating graph rows or settings.
     */
    private func preflightArchiveBounds(
        _ stagedArchives: [RemoteSyncStagedPatchArchive]
    ) throws {
        var cumulativeExpandedByteCount: UInt64 = 0
        for stagedArchive in stagedArchives {
            try Task.checkCancellation()
            let member: RemoteSyncGzipMember
            do {
                member = try RemoteSyncBoundedFileIO.inspectGzip(
                    at: stagedArchive.archiveFileURL,
                    maximumCompressedByteCount: Self.maximumCompressedPatchByteCount,
                    maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
                )
            } catch RemoteSyncBoundedFileError.compressedSizeExceeded(let size) {
                throw RemoteSyncReadingPlanPatchApplyError.compressedArchiveTooLarge(size)
            } catch RemoteSyncBoundedFileError.expandedSizeExceeded(let size) {
                throw RemoteSyncReadingPlanPatchApplyError.expandedArchiveTooLarge(size)
            } catch {
                throw RemoteSyncReadingPlanPatchApplyError.invalidPatchArchive
            }
            let (next, overflow) = cumulativeExpandedByteCount.addingReportingOverflow(
                member.expandedByteCount
            )
            guard !overflow,
                  next <= UInt64(Self.maximumCumulativeExpandedPatchByteCount) else {
                throw RemoteSyncReadingPlanPatchApplyError.cumulativeArchiveTooLarge(
                    overflow ? UInt64.max : next
                )
            }
            cumulativeExpandedByteCount = next
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
    private func bindUUIDBlob(
        _ uuid: UUID,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        let bytes = RemoteSyncReadingPlanSnapshotService.uuidBlob(uuid)
        let byteCount = try RemoteSyncWireInteger.int32(
            exactly: bytes.count,
            field: "UUID.byteCount"
        )

        _ = bytes.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(
                statement,
                index,
                rawBuffer.baseAddress,
                byteCount,
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
    /** Reads one exact bounded UTF-8 cell without C-string truncation. */
    private func textColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String,
        column: String,
        maximumByteCount: Int,
        permitsEmpty: Bool
    ) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT else {
            throw RemoteSyncReadingPlanRestoreError.invalidTextValue(
                table: table,
                column: column
            )
        }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount <= maximumByteCount else {
            throw RemoteSyncReadingPlanRestoreError.fieldTooLarge(
                table: table,
                column: column,
                byteCount: byteCount
            )
        }
        guard (permitsEmpty || byteCount > 0),
              let bytes = sqlite3_column_text(statement, index),
              let value = String(
                  data: Data(bytes: bytes, count: byteCount),
                  encoding: .utf8
              ) else {
            throw RemoteSyncReadingPlanRestoreError.invalidTextValue(
                table: table,
                column: column
            )
        }
        return value
    }

    /** Reads one bounded non-traversing Android plan code. */
    private func planCodeColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String
    ) throws -> String {
        let value = try textColumn(
            statement: statement,
            index: index,
            table: table,
            column: "planCode",
            maximumByteCount: RemoteSyncReadingPlanDefinitionStore.maximumPlanCodeByteCount,
            permitsEmpty: false
        )
        guard value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            throw RemoteSyncReadingPlanRestoreError.invalidTextValue(
                table: table,
                column: "planCode"
            )
        }
        return value
    }

    /** Reads one positive day value inside Android's and iOS's allocation-safe domains. */
    private func dayNumberColumn(
        statement: OpaquePointer?,
        index: Int32,
        table: String
    ) throws -> Int {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw RemoteSyncReadingPlanRestoreError.invalidDayNumber(table: table, value: 0)
        }
        let value = sqlite3_column_int64(statement, index)
        guard value >= Int64(Int32.min), value <= Int64(Int32.max) else {
            throw RemoteSyncReadingPlanRestoreError.invalidDayNumber(table: table, value: value)
        }
        return Int(value)
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
        if lhs.startDateMilliseconds != rhs.startDateMilliseconds {
            return lhs.startDateMilliseconds < rhs.startDateMilliseconds
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
     Detects whether one reading-plan template uses Android's date-prefixed reading format.

     - Parameter template: Reading-plan template to inspect.
     - Returns: `true` when catalog discovery marked the template as Android date-based.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func isDateBasedPlan(_ template: ReadingPlanTemplate) -> Bool {
        template.isDateBased
    }

    /**
     Counts the reading segments expected for one plan-day string.

     - Parameter readings: Raw reading-plan day payload from the bundled template.
     - Returns: Number of reading segments Android expects for completion.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func expectedReadingCount(for readings: String) -> Int {
        ReadingPlanDayAssignment(rawValue: readings).readings.count
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

        let payload: AndroidReadingPlanStatusPayload
        do {
            payload = try AndroidReadingPlanStatusPayload(androidJSON: status.readingStatusJSON)
        } catch {
            throw RemoteSyncReadingPlanRestoreError.malformedReadingStatus(
                planCode: status.planCode,
                dayNumber: status.dayNumber
            )
        }

        return payload.isAllRead(readingCount: expectedReadingCount)
    }
}
