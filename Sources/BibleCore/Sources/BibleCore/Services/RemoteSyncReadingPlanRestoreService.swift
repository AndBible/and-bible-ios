// RemoteSyncReadingPlanRestoreService.swift — Reading-plan initial-backup restore from Android sync databases

import Foundation
import SQLite3
import SwiftData

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while reading or restoring Android reading-plan sync databases.
 */
public enum RemoteSyncReadingPlanRestoreError: Error, Equatable {
    /// The staged file could not be opened as a readable SQLite database.
    case invalidSQLiteDatabase

    /// The staged database does not contain one of the required Android reading-plan tables.
    case missingTable(String)

    /// The staged database references reading-plan definitions that this iOS build cannot recreate.
    case unsupportedPlanDefinitions([String])

    /// The staged database contains preserved status rows whose `planCode` has no matching plan row.
    case orphanStatuses([String])

    /// One Android `readingStatus` payload was not valid JSON for the expected schema.
    case malformedReadingStatus(planCode: String, dayNumber: Int)

    /// More than one status row targets Android's unique `(planCode, planDay)` identity.
    case duplicateReadingStatus(planCode: String, dayNumber: Int)

    /// One Android UUID-like blob could not be converted into an iOS `UUID`.
    case invalidIdentifierBlob(table: String, column: String)

    /// One staged table exceeds the bounded row count accepted before allocation.
    case tooManyRows(table: String, count: Int64)

    /// One text identity is absent, malformed UTF-8, unsafe as a plan code, or too large.
    case invalidTextValue(table: String, column: String)

    /// One Android day field is outside its signed and allocation-safe domain.
    case invalidDayNumber(table: String, value: Int64)

    /// One staged text payload exceeds the per-field byte ceiling.
    case fieldTooLarge(table: String, column: String, byteCount: Int)
}

/**
 One Android `ReadingPlanStatus` row from a staged sync backup.
 */
public struct RemoteSyncAndroidReadingPlanStatus: Sendable, Equatable {
    /// Android identifier blob converted into iOS UUID form.
    public let id: UUID

    /// Android reading-plan code that owns the status row.
    public let planCode: String

    /// One-based day number within the reading plan definition.
    public let dayNumber: Int

    /// Raw Android JSON payload from `ReadingPlanStatus.readingStatus`.
    public let readingStatusJSON: String

    /**
     Creates one staged Android reading-plan status row.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - planCode: Android reading-plan code that owns the status row.
       - dayNumber: One-based day number within the reading plan definition.
       - readingStatusJSON: Raw Android JSON payload from `ReadingPlanStatus.readingStatus`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(id: UUID, planCode: String, dayNumber: Int, readingStatusJSON: String) {
        self.id = id
        self.planCode = planCode
        self.dayNumber = dayNumber
        self.readingStatusJSON = readingStatusJSON
    }
}

/**
 One Android `ReadingPlan` row plus its associated status rows from a staged sync backup.
 */
public struct RemoteSyncAndroidReadingPlan: Sendable, Equatable {
    /// Android identifier blob converted into iOS UUID form.
    public let id: UUID

    /// Android reading-plan code used to resolve the underlying plan definition.
    public let planCode: String

    /// Exact persisted Android signed-Int64 plan start date.
    public let startDateMilliseconds: Int64

    /// Date-backed presentation retained for compatibility callers.
    public var startDate: Date { AndroidTimestamp.date(from: startDateMilliseconds) }

    /// Persisted Android current-day pointer.
    public let currentDay: Int

    /// All staged status rows that belong to this plan code.
    public let statuses: [RemoteSyncAndroidReadingPlanStatus]

    /**
     Creates one staged Android reading plan.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - planCode: Android reading-plan code used to resolve the underlying plan definition.
       - startDateMilliseconds: Exact persisted Android plan start date.
       - currentDay: Persisted Android current-day pointer.
       - statuses: All staged status rows that belong to this plan code.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID,
        planCode: String,
        startDateMilliseconds: Int64,
        currentDay: Int,
        statuses: [RemoteSyncAndroidReadingPlanStatus]
    ) {
        self.id = id
        self.planCode = planCode
        self.startDateMilliseconds = startDateMilliseconds
        self.currentDay = currentDay
        self.statuses = statuses
    }

    /**
     Creates a compatibility snapshot from a Date-backed caller without a trapping integer cast.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - planCode: Android reading-plan code.
       - startDate: Legacy Date-backed start date.
       - currentDay: Persisted Android current-day pointer.
       - statuses: Status rows belonging to the plan.
     - Side Effects: none.
     - Failure modes: Dates outside signed-Int64 milliseconds saturate by sign. Database readers
       use the exact integer initializer and never enter this compatibility path.
     */
    public init(
        id: UUID,
        planCode: String,
        startDate: Date,
        currentDay: Int,
        statuses: [RemoteSyncAndroidReadingPlanStatus]
    ) {
        let fallback: Int64 = startDate.timeIntervalSince1970.sign == .minus ? .min : .max
        self.init(
            id: id,
            planCode: planCode,
            startDateMilliseconds: (try? AndroidTimestamp.milliseconds(from: startDate)) ?? fallback,
            currentDay: currentDay,
            statuses: statuses
        )
    }
}

/**
 Read-only snapshot of one staged Android reading-plan sync database.

 The snapshot preserves both regular plan rows and any orphaned status rows so the restore layer
 can fail explicitly instead of silently discarding inconsistent remote data.
 */
public struct RemoteSyncAndroidReadingPlanSnapshot: Sendable, Equatable {
    /// Staged Android reading plans grouped with their matching status rows.
    public let plans: [RemoteSyncAndroidReadingPlan]

    /// Status rows whose `planCode` had no matching `ReadingPlan` row.
    public let orphanStatuses: [RemoteSyncAndroidReadingPlanStatus]

    /**
     Creates a staged Android reading-plan snapshot.

     - Parameters:
       - plans: Staged Android reading plans grouped with their matching status rows.
       - orphanStatuses: Status rows whose `planCode` had no matching `ReadingPlan` row.
       - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        plans: [RemoteSyncAndroidReadingPlan],
        orphanStatuses: [RemoteSyncAndroidReadingPlanStatus] = []
    ) {
        self.plans = plans
        self.orphanStatuses = orphanStatuses
    }
}

/**
 Summary of one successful Android reading-plan restore.
 */
public struct RemoteSyncReadingPlanRestoreReport: Sendable, Equatable {
    /// Android plan codes that were restored into SwiftData.
    public let restoredPlanCodes: [String]

    /// Number of `ReadingPlanDay` rows recreated from the matching iOS templates.
    public let restoredDayCount: Int

    /// Number of raw Android `ReadingPlanStatus` payloads preserved locally.
    public let preservedStatusCount: Int

    /**
     Creates a restore summary.

     - Parameters:
       - restoredPlanCodes: Android plan codes restored into SwiftData.
       - restoredDayCount: Number of `ReadingPlanDay` rows recreated from templates.
       - preservedStatusCount: Number of raw Android status payloads preserved locally.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(restoredPlanCodes: [String], restoredDayCount: Int, preservedStatusCount: Int) {
        self.restoredPlanCodes = restoredPlanCodes
        self.restoredDayCount = restoredDayCount
        self.preservedStatusCount = preservedStatusCount
    }
}

/**
 One fully materialized reading-plan day ready for atomic SwiftData replacement.

 This value type lets initial-backup restore and incremental patch replay share the same graph
 publication path after each source has completed its own validation and completion calculation.
 */
struct RemoteSyncPreparedReadingPlanDay: Sendable, Equatable {
    /// One-based position in the plan definition.
    let dayNumber: Int

    /// Canonical reading references from the selected bundled, user, or add-on definition.
    let readings: String

    /// Completion state reconstructed from Android status semantics.
    let isCompleted: Bool
}

/**
 One fully materialized reading plan ready for atomic SwiftData replacement.
 */
struct RemoteSyncPreparedReadingPlan: Sendable, Equatable {
    /// Stable Android reading-plan identifier.
    let id: UUID

    /// Android plan definition code.
    let planCode: String

    /// Display name from the matching catalog definition.
    let planName: String

    /// Exact persisted Android plan start date.
    let startDateMilliseconds: Int64

    /// Date-backed presentation used by the current SwiftData model.
    var startDate: Date { AndroidTimestamp.date(from: startDateMilliseconds) }

    /// Normalized current-day position.
    let currentDay: Int

    /// Number of days in the matching catalog definition.
    let totalDays: Int

    /// Whether the restored plan should become active immediately.
    let isActive: Bool

    /// Complete regenerated day graph.
    let days: [RemoteSyncPreparedReadingPlanDay]
}

/**
 Complete reading-plan graph and fidelity-status generation published by one atomic replacement.

 Callers must finish source-specific validation before constructing this payload. Publication uses
 one shared `ModelContext`, allowing both initial restore and patch replay to join a surrounding
 `SettingsStore` batch without introducing a second commit boundary.
 */
struct RemoteSyncReadingPlanReplacement: Sendable, Equatable {
    /// Complete replacement set of plans and generated days.
    let plans: [RemoteSyncPreparedReadingPlan]

    /// Complete replacement set of raw Android status payloads.
    let statuses: [RemoteSyncReadingPlanStatusStore.Status]
}

/**
 Reads staged Android reading-plan databases and restores them into iOS SwiftData.

 The restore contract is intentionally conservative:
 - staged SQLite rows are read exactly from Android's `ReadingPlan` and `ReadingPlanStatus` tables
 - restore is refused when the staged database references plan codes that this device cannot
   recreate from its bundled, add-on, or device-local `ReadingPlanService` catalog
 - raw Android per-reading status JSON is preserved locally through
   `RemoteSyncReadingPlanStatusStore` and rendered through the shared typed reading-plan status contract

 Mapping notes:
 - Android's selected/current plan preference is not stored in the reading-plan sync database;
   restored rows remain inactive until `ReadingPlanSelectionStore` reconciles `reading_plan`
 - for non-date-based plans, Android treats all days before `planCurrentDay` as historic and fully
   read even when earlier `ReadingPlanStatus` rows have already been deleted; this restore mirrors
   that behavior

 Side effects:
 - replaces the local plan/day graph and preserved status rows through one settings-backed batch

 Failure modes:
 - rejects orphan statuses, unavailable local plan definitions, and malformed status payloads
 - rethrows definition recovery, cancellation, context, fetch, encoding, and save errors

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied `ModelContext`
   and `SettingsStore`
 */
public final class RemoteSyncReadingPlanRestoreService {
    /// Maximum plan parents accepted from one untrusted database.
    private static let maximumPlanRowCount: Int64 = 10_000

    /// Maximum status rows accepted from one untrusted database.
    private static let maximumStatusRowCount: Int64 = 100_000

    /// Maximum bytes accepted for one raw Android status JSON payload.
    private static let maximumStatusByteCount = 1 * 1_024 * 1_024

    /// Android-equivalent custom-plan directory used when resolving restored templates.
    private let userPlanDirectory: URL

    /// Recovers interrupted device-local definition publication before catalog resolution.
    private let definitionStore: RemoteSyncReadingPlanDefinitionStore

    /// Durable value snapshot of all reading-plan graph rows before an atomic replacement.
    private struct DurableGraph: Equatable {
        /// Complete parent-plan rows ordered by stable identifier.
        let plans: [DurablePlan]

        /// Complete day rows, including any orphan rows, ordered by stable identifier.
        let days: [DurableDay]

        /// Definition publication markers colocated with the graph store.
        let definitionPublicationStates: [DurableDefinitionPublicationState]
    }

    /// Durable value representation of one graph-colocated definition publication marker.
    private struct DurableDefinitionPublicationState: Equatable {
        let storageKey: String
        let committedGeneration: String?
    }

    /// Durable value representation of one `ReadingPlan` row.
    private struct DurablePlan: Equatable {
        let id: UUID
        let planCode: String
        let planName: String
        let startDate: Date
        let currentDay: Int
        let totalDays: Int
        let isActive: Bool
    }

    /// Durable value representation of one `ReadingPlanDay` row and its parent identity.
    private struct DurableDay: Equatable {
        let id: UUID
        let planID: UUID?
        let dayNumber: Int
        let isCompleted: Bool
        let completedDate: Date?
        let readings: String
    }

    /**
     Captures a fresh-context recovery action for the complete durable reading-plan graph.

     Local definition publication uses this action when a custom import changes files and plan rows in one
     settings-backed batch. Reusing the restore service's value snapshot keeps both mutation paths on
     the same cross-configuration compensation contract.

     - Parameter modelContext: Clean context containing the pre-mutation plan and day generation.
     - Returns: Recovery action suitable for `SettingsStore.performAtomicBatch`.
     - Side Effects: Performs strict read-only plan and day fetches now; the returned closure rewrites
       the graph only if a later partial commit differs from the captured generation.
     - Failure modes: Rethrows snapshot fetch failures now or fresh-context recovery failures later.
     */
    static func durableGraphRecovery(
        from modelContext: ModelContext
    ) throws -> (ModelContainer) throws -> Void {
        let durableGraph = try captureDurableGraph(from: modelContext)
        return { container in
            try restoreDurableGraph(durableGraph, in: container)
        }
    }

    /**
     Creates a reading-plan restore service.

     - Parameters:
       - userPlanDirectory: Destination equivalent to Android's `jsword/readingplan` directory.
       - fileManager: Filesystem implementation used for transactional definition installation.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default
    ) {
        self.userPlanDirectory = userPlanDirectory
        definitionStore = RemoteSyncReadingPlanDefinitionStore(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
    }

    /**
     Reads one staged Android reading-plan SQLite database into a typed snapshot.

     - Parameter databaseURL: Local URL of the extracted Android `readingplans.sqlite3` backup.
     - Returns: Typed snapshot of staged reading-plan and status rows.
     - Side effects:
       - opens the staged SQLite database in read-only mode
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase` when the file cannot be
         opened as SQLite
       - throws `RemoteSyncReadingPlanRestoreError.missingTable` when required Android tables are
         absent
       - throws `RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob` when Android UUID-like
         BLOB columns cannot be converted into `UUID`
       - rejects any schema outside Android's exact reading-plan Room contract
     */
    public func readSnapshot(from databaseURL: URL) throws -> RemoteSyncAndroidReadingPlanSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
            db,
            category: .readingPlans
        )
        try requireTable(named: "ReadingPlan", in: db)
        try requireTable(named: "ReadingPlanStatus", in: db)
        try requireRowCount(
            in: "ReadingPlan",
            database: db,
            maximum: Self.maximumPlanRowCount
        )
        try requireRowCount(
            in: "ReadingPlanStatus",
            database: db,
            maximum: Self.maximumStatusRowCount
        )

        let statuses = try fetchStatuses(from: db)
        let statusesByPlanCode = Dictionary(grouping: statuses, by: \.planCode)
        let planRows = try fetchPlans(from: db)
        let knownPlanCodes = Set(planRows.map(\.planCode))
        let orphanStatuses = statuses.filter { !knownPlanCodes.contains($0.planCode) }
        let plans = planRows.map { planRow in
            RemoteSyncAndroidReadingPlan(
                id: planRow.id,
                planCode: planRow.planCode,
                startDateMilliseconds: planRow.startDateMilliseconds,
                currentDay: planRow.currentDay,
                statuses: statusesByPlanCode[planRow.planCode, default: []].sorted { $0.dayNumber < $1.dayNumber }
            )
        }

        return RemoteSyncAndroidReadingPlanSnapshot(
            plans: plans.sorted { $0.planCode < $1.planCode },
            orphanStatuses: orphanStatuses.sorted {
                if $0.planCode == $1.planCode {
                    return $0.dayNumber < $1.dayNumber
                }
                return $0.planCode < $1.planCode
            }
        )
    }

    /**
     Replaces local iOS reading plans with the supplied staged Android snapshot.

     Restore is durably all-or-nothing. The method first validates that every staged
     plan code is reproducible from the device-local catalog, that there are no orphan status rows,
     and that status JSON needed for completion
     calculation is structurally valid. Only after that preflight succeeds does one explicit
     settings-backed SwiftData batch delete
     existing plans, recreate new `ReadingPlan` and `ReadingPlanDay` rows, and preserve the raw
     Android status payloads. The batch performs one primary throwing save, rolls back pending state
     on failure or cancellation, and durably restores the old graph and settings generations when
     separate SwiftData configurations commit only part of that save.

     - Parameters:
       - snapshot: Staged Android snapshot previously read from `readSnapshot(from:)`.
       - modelContext: SwiftData context whose reading-plan rows should be replaced.
       - statusStore: Local-only store used to preserve raw Android status JSON.
     - Returns: Summary of restored plans, recreated day rows, and preserved raw statuses.
     - Side effects:
       - recovers any interrupted device-local definition publication before catalog resolution
       - deletes existing local `ReadingPlan` graphs
       - inserts replacement `ReadingPlan` and `ReadingPlanDay` rows
       - clears and repopulates preserved Android status payloads in `statusStore`
       - saves the shared `modelContext` exactly once on success after the replacement is staged
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.orphanStatuses` when the staged database contains
         status rows whose `planCode` has no matching plan row
       - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when iOS cannot
         reconstruct one or more staged plan codes from the device-local catalog
       - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when a status payload that
         affects completion calculation is not valid Android JSON
       - throws `SettingsStoreAtomicBatchError` when `statusStore` is not bound to the exact clean
         `modelContext` supplied for the graph replacement
       - throws `CancellationError` when the current task is cancelled before commit
       - rethrows definition recovery, strict status-encoding/fetch, and SwiftData save
         errors
     */
    public func replaceLocalReadingPlans(
        from snapshot: RemoteSyncAndroidReadingPlanSnapshot,
        modelContext: ModelContext,
        statusStore: RemoteSyncReadingPlanStatusStore
    ) throws -> RemoteSyncReadingPlanRestoreReport {
        try replaceLocalReadingPlans(
            from: snapshot,
            modelContext: modelContext,
            statusStore: statusStore,
            mutationCheckpoint: { try Task.checkCancellation() }
        )
    }

    /**
     Replaces local reading plans atomically while invoking a deterministic interruption checkpoint.

     This internal overload lets concurrency tests interrupt after staged graph/status mutations while
     production delegates every checkpoint to `Task.checkCancellation()`. All semantic preflight still
     occurs before entering the atomic batch.

     - Parameters:
       - snapshot: Validated or untrusted staged Android reading-plan snapshot.
       - modelContext: Exact clean context shared by plans, days, and the status store's settings.
       - statusStore: Preserved Android status store bound to `modelContext`.
       - mutationCheckpoint: Throwing callback invoked before mutation, after each destructive or
         plan/status replacement phase, and immediately before commit.
     - Returns: Summary of the replacement after its primary save succeeds.
     - Side Effects: Replaces all plan/day/status rows through one atomic settings batch.
     - Throws: Rethrows preflight, checkpoint, context-contract, encoding, fetch, save, and durable
       recovery errors; failed publication restores the complete old durable generation.
     */
    func replaceLocalReadingPlans(
        from snapshot: RemoteSyncAndroidReadingPlanSnapshot,
        modelContext: ModelContext,
        statusStore: RemoteSyncReadingPlanStatusStore,
        mutationCheckpoint: @escaping () throws -> Void
    ) throws -> RemoteSyncReadingPlanRestoreReport {
        try definitionStore.prepareForSnapshot(
            settingsStore: statusStore.definitionPublicationSettingsStore
        )
        let preparedPlans = try preparePlans(from: snapshot)
        let statuses = snapshot.plans.flatMap(\.statuses).map { status in
            RemoteSyncReadingPlanStatusStore.Status(
                planCode: status.planCode,
                dayNumber: status.dayNumber,
                readingStatusJSON: status.readingStatusJSON,
                remoteStatusID: status.id
            )
        }

        return try replaceLocalReadingPlans(
            with: RemoteSyncReadingPlanReplacement(
                plans: preparedPlans,
                statuses: statuses
            ),
            modelContext: modelContext,
            statusStore: statusStore,
            mutationCheckpoint: mutationCheckpoint
        )
    }

    /**
     Publishes one fully prepared reading-plan generation through the shared atomic batch boundary.

     Patch replay calls this method from inside its wider settings batch, so graph replacement joins
     raw statuses, log entries, applied-patch rows, and fingerprint baselines in the outer commit.
     Initial-backup restore calls it without an outer batch and lets the status store own the commit.

     - Parameters:
       - replacement: Complete prevalidated plan/day graph and raw status generation.
       - modelContext: Exact clean context shared by graph models and the status store.
       - statusStore: Status store backed by the same `SettingsStore` and context.
       - mutationCheckpoint: Throwing interruption check invoked throughout destructive mutation.
     - Returns: Summary of the staged replacement after its owning batch commits.
     - Side Effects: Deletes the old plan/day/status generation and stages the complete replacement.
     - Throws: Rethrows context-contract, checkpoint, fetch, encoding, final-save, and durable
       recovery errors. The owning settings batch restores the prior durable generation on failure.
     */
    func replaceLocalReadingPlans(
        with replacement: RemoteSyncReadingPlanReplacement,
        modelContext: ModelContext,
        statusStore: RemoteSyncReadingPlanStatusStore,
        mutationCheckpoint: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> RemoteSyncReadingPlanRestoreReport {
        let durableGraph = try Self.captureDurableGraph(from: modelContext)

        return try statusStore.performAtomicBatch(
            in: modelContext,
            durableRecovery: { container in
                try Self.restoreDurableGraph(durableGraph, in: container)
            }
        ) {
            try mutationCheckpoint()

            let existingDays = try modelContext.fetch(FetchDescriptor<ReadingPlanDay>())
            for day in existingDays {
                modelContext.delete(day)
                try mutationCheckpoint()
            }

            let existingPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
            for plan in existingPlans {
                modelContext.delete(plan)
                try mutationCheckpoint()
            }

            statusStore.clearAll()
            let timestampStore = RemoteSyncReadingPlanTimestampStore(
                settingsStore: statusStore.definitionPublicationSettingsStore
            )
            timestampStore.clearAll()
            try mutationCheckpoint()

            var restoredDayCount = 0
            for preparedPlan in replacement.plans {
                let restoredPlan = ReadingPlan(
                    id: preparedPlan.id,
                    planCode: preparedPlan.planCode,
                    planName: preparedPlan.planName,
                    startDate: preparedPlan.startDate,
                    currentDay: preparedPlan.currentDay,
                    totalDays: preparedPlan.totalDays,
                    isActive: preparedPlan.isActive
                )
                modelContext.insert(restoredPlan)
                timestampStore.setMilliseconds(
                    preparedPlan.startDateMilliseconds,
                    for: preparedPlan.id
                )

                for day in preparedPlan.days {
                    let restoredDay = ReadingPlanDay(
                        dayNumber: day.dayNumber,
                        isCompleted: day.isCompleted,
                        readings: day.readings
                    )
                    restoredDay.plan = restoredPlan
                    modelContext.insert(restoredDay)
                    restoredDayCount += 1
                }
                try mutationCheckpoint()
            }

            for status in replacement.statuses.sorted(by: Self.statusSort) {
                try statusStore.setStatusThrowing(status)
                try mutationCheckpoint()
            }

            try mutationCheckpoint()
            return RemoteSyncReadingPlanRestoreReport(
                restoredPlanCodes: replacement.plans.map(\.planCode).sorted(),
                restoredDayCount: restoredDayCount,
                preservedStatusCount: replacement.statuses.count
            )
        }
    }

    /**
     Captures every persisted reading-plan parent and day row before replacement begins.

     - Parameter modelContext: Clean context that owns the reading-plan graph.
     - Returns: Store-independent value snapshot suitable for fresh-context recovery.
     - Side Effects: Performs strict plan, day, and definition-publication-state fetches.
     - Failure modes: Rethrows SwiftData fetch failures before any mutation begins.
     */
    private static func captureDurableGraph(from modelContext: ModelContext) throws -> DurableGraph {
        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>()).map { plan in
            DurablePlan(
                id: plan.id,
                planCode: plan.planCode,
                planName: plan.planName,
                startDate: plan.startDate,
                currentDay: plan.currentDay,
                totalDays: plan.totalDays,
                isActive: plan.isActive
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let days = try modelContext.fetch(FetchDescriptor<ReadingPlanDay>()).map { day in
            DurableDay(
                id: day.id,
                planID: day.plan?.id,
                dayNumber: day.dayNumber,
                isCompleted: day.isCompleted,
                completedDate: day.completedDate,
                readings: day.readings
            )
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let definitionPublicationStates = try modelContext.fetch(
            FetchDescriptor<ReadingPlanDefinitionPublicationState>()
        ).map { state in
            DurableDefinitionPublicationState(
                storageKey: state.storageKey,
                committedGeneration: state.committedGeneration
            )
        }.sorted { $0.storageKey < $1.storageKey }
        return DurableGraph(
            plans: plans,
            days: days,
            definitionPublicationStates: definitionPublicationStates
        )
    }

    /**
     Restores a pre-commit reading-plan graph through a fresh graph-only save when needed.

     A failed graph-store commit leaves the durable graph equal to `expected`, so no save is issued
     against the still-failing store. A settings-store failure can leave the graph committed; in that
     case this helper replaces all plan/day rows and graph-colocated publication markers, then saves
     only their configuration.

     - Parameters:
       - expected: Exact plan/day generation captured before the failed batch.
       - container: Production-shaped container spanning graph and settings configurations.
     - Side Effects: When durable graph state differs, replaces every plan/day row in a fresh context.
     - Failure modes: Rethrows strict fetch or graph-only save failures.
     */
    private static func restoreDurableGraph(
        _ expected: DurableGraph,
        in container: ModelContainer
    ) throws {
        let recoveryContext = ModelContext(container)
        recoveryContext.autosaveEnabled = false
        let current = try captureDurableGraph(from: recoveryContext)
        guard current != expected else {
            return
        }

        let currentPlans = try recoveryContext.fetch(FetchDescriptor<ReadingPlan>())
        let currentDays = try recoveryContext.fetch(FetchDescriptor<ReadingPlanDay>())
        let currentPublicationStates = try recoveryContext.fetch(
            FetchDescriptor<ReadingPlanDefinitionPublicationState>()
        )
        for plan in currentPlans {
            recoveryContext.delete(plan)
        }
        for day in currentDays where day.plan == nil {
            recoveryContext.delete(day)
        }
        for state in currentPublicationStates {
            recoveryContext.delete(state)
        }

        var plansByID: [UUID: ReadingPlan] = [:]
        for plan in expected.plans {
            let restoredPlan = ReadingPlan(
                id: plan.id,
                planCode: plan.planCode,
                planName: plan.planName,
                startDate: plan.startDate,
                currentDay: plan.currentDay,
                totalDays: plan.totalDays,
                isActive: plan.isActive
            )
            recoveryContext.insert(restoredPlan)
            plansByID[plan.id] = restoredPlan
        }
        for day in expected.days {
            let restoredDay = ReadingPlanDay(
                id: day.id,
                dayNumber: day.dayNumber,
                isCompleted: day.isCompleted,
                readings: day.readings
            )
            restoredDay.completedDate = day.completedDate
            restoredDay.plan = day.planID.flatMap { plansByID[$0] }
            recoveryContext.insert(restoredDay)
        }
        for state in expected.definitionPublicationStates {
            recoveryContext.insert(
                ReadingPlanDefinitionPublicationState(
                    storageKey: state.storageKey,
                    committedGeneration: state.committedGeneration
                )
            )
        }
        try recoveryContext.save()
    }

    /**
     Normalizes one staged Android snapshot into validated iOS-ready reading-plan graphs.

     This preflight step resolves the device's bundled, add-on, and local plan templates, rejects orphan status rows and
     unsupported plan codes, computes per-day completion, and preserves the raw Android status rows
     for later fidelity storage. It performs all semantic validation before any caller mutates
     SwiftData.

     - Parameter snapshot: Typed Android reading-plan snapshot previously loaded from SQLite.
     - Returns: Prepared plans ready for insertion into local SwiftData models.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.orphanStatuses` when the snapshot contains status
         rows whose `planCode` has no corresponding plan row
       - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when the local catalog
         does not contain one or more staged plan codes
       - rethrows `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` from completion
         calculation when Android status JSON cannot be decoded
     */
    private func preparePlans(
        from snapshot: RemoteSyncAndroidReadingPlanSnapshot
    ) throws -> [RemoteSyncPreparedReadingPlan] {
        if !snapshot.orphanStatuses.isEmpty {
            throw RemoteSyncReadingPlanRestoreError.orphanStatuses(
                Array(Set(snapshot.orphanStatuses.map(\.planCode))).sorted()
            )
        }

        let templatesByCode = Dictionary(
            uniqueKeysWithValues: ReadingPlanService.catalog(
                userPlanDirectory: userPlanDirectory
            ).templates.map { ($0.code, $0) }
        )
        let missingPlanCodes = Array(
            Set(snapshot.plans.map(\.planCode).filter { templatesByCode[$0] == nil })
        ).sorted()
        if !missingPlanCodes.isEmpty {
            throw RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions(missingPlanCodes)
        }

        return try snapshot.plans.map { plan in
            let template = templatesByCode[plan.planCode]!
            let isDateBasedPlan = Self.isDateBasedPlan(template)
            let effectiveCurrentDay = max(plan.currentDay, 1)
            var statusesByDay: [Int: RemoteSyncAndroidReadingPlanStatus] = [:]
            for status in plan.statuses {
                guard statusesByDay[status.dayNumber] == nil else {
                    throw RemoteSyncReadingPlanRestoreError.duplicateReadingStatus(
                        planCode: status.planCode,
                        dayNumber: status.dayNumber
                    )
                }
                statusesByDay[status.dayNumber] = status
            }

            var preparedDays: [RemoteSyncPreparedReadingPlanDay] = []
            preparedDays.reserveCapacity(template.dayNumbers.count)

            for dayNumber in template.dayNumbers {
                let readings = template.readingsForDay(dayNumber)
                let expectedReadingCount = Self.expectedReadingCount(for: readings)
                let completion = try Self.isDayComplete(
                    status: statusesByDay[dayNumber],
                    dayNumber: dayNumber,
                    currentDay: effectiveCurrentDay,
                    expectedReadingCount: expectedReadingCount,
                    isDateBasedPlan: isDateBasedPlan
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
     Orders preserved statuses deterministically before replacing their namespaced setting rows.

     - Parameters:
       - lhs: First preserved status.
       - rhs: Second preserved status.
     - Returns: `true` when `lhs` sorts before `rhs` by plan code, day, then remote identifier.
     - Side Effects: none.
     - Failure modes: This comparator cannot fail.
     */
    private static func statusSort(
        _ lhs: RemoteSyncReadingPlanStatusStore.Status,
        _ rhs: RemoteSyncReadingPlanStatusStore.Status
    ) -> Bool {
        if lhs.planCode != rhs.planCode {
            return lhs.planCode < rhs.planCode
        }
        if lhs.dayNumber != rhs.dayNumber {
            return lhs.dayNumber < rhs.dayNumber
        }
        return (lhs.remoteStatusID?.uuidString ?? "") < (rhs.remoteStatusID?.uuidString ?? "")
    }

    /**
     Verifies that one required Android table exists in the staged SQLite database.

     - Parameters:
       - tableName: Exact Android table name expected in the staged backup.
       - db: Open SQLite handle positioned on the staged backup database.
     - Side effects:
       - issues one metadata query against SQLite's `sqlite_master` catalog
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare
         the metadata query
       - throws `RemoteSyncReadingPlanRestoreError.missingTable` when the required table is absent
     */
    private func requireTable(named tableName: String, in db: OpaquePointer) throws {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }

        sqlite3_bind_text(statement, 1, tableName, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw RemoteSyncReadingPlanRestoreError.missingTable(tableName)
        }
    }

    /**
     Reads raw Android `ReadingPlan` rows from the staged SQLite database.

     - Parameter db: Open SQLite handle positioned on the staged backup database.
     - Returns: Ordered tuples containing raw Android identifiers, plan codes, start dates, and
       current-day counters.
     - Side effects:
       - performs one SQLite read query against the staged `ReadingPlan` table
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare
         the select statement
       - rethrows `RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob` when Android identifier
         BLOBs are absent, malformed, or not 16 bytes long
     */
    private func fetchPlans(
        from db: OpaquePointer
    ) throws -> [(id: UUID, planCode: String, startDateMilliseconds: Int64, currentDay: Int)] {
        let sql = """
        SELECT id, planCode, planStartDate, planCurrentDay
        FROM ReadingPlan
        ORDER BY planCode, planStartDate
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }

        var rows: [(UUID, String, Int64, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlan", name: "id")
            let planCode = try planCodeColumn(
                statement: statement,
                index: 1,
                table: "ReadingPlan"
            )
            let startDateMillis = sqlite3_column_int64(statement, 2)
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
            let currentDay = Int(currentDayValue)
            rows.append((id, planCode, startDateMillis, currentDay))
        }
        return rows
    }

    /**
     Reads raw Android `ReadingPlanStatus` rows from the staged SQLite database.

     - Parameter db: Open SQLite handle positioned on the staged backup database.
     - Returns: Ordered raw status rows grouped later by `planCode` and day number.
     - Side effects:
       - performs one SQLite read query against the staged `ReadingPlanStatus` table
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase` when SQLite cannot prepare
         the select statement
       - rethrows `RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob` when Android identifier
         BLOBs are absent, malformed, or not 16 bytes long
     */
    private func fetchStatuses(from db: OpaquePointer) throws -> [RemoteSyncAndroidReadingPlanStatus] {
        let sql = """
        SELECT id, planCode, planDay, readingStatus
        FROM ReadingPlanStatus
        ORDER BY planCode, planDay
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }

        var rows: [RemoteSyncAndroidReadingPlanStatus] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlanStatus", name: "id")
            rows.append(
                RemoteSyncAndroidReadingPlanStatus(
                    id: id,
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
            )
        }
        return rows
    }

    /**
     Converts one required Android 16-byte identifier BLOB into a Foundation `UUID`.

     Android persists raw 128-bit identifiers as SQLite BLOBs without textual UUID formatting. This
     helper reconstructs the canonical UUID string representation so higher layers can work with
     Foundation values consistently.

     - Parameters:
       - statement: Active SQLite statement positioned on a row.
       - column: Zero-based column index containing the required BLOB.
       - table: Android table name used for error reporting.
       - name: Android column name used for error reporting.
     - Returns: Converted `UUID` value.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob` when the BLOB is absent,
         not exactly 16 bytes long, or cannot be rendered as a valid UUID string
     */
    private func uuidFromBlob(statement: OpaquePointer?, column: Int32, table: String, name: String) throws -> UUID {
        guard
            let bytes = sqlite3_column_blob(statement, column),
            sqlite3_column_bytes(statement, column) == 16
        else {
            throw RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob(table: table, column: name)
        }

        let data = Data(bytes: bytes, count: 16)
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
        let uuidString = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"

        guard let uuid = UUID(uuidString: uuidString) else {
            throw RemoteSyncReadingPlanRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return uuid
    }

    /** Reads one exact bounded UTF-8 text cell without C-string truncation. */
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

    /** Reads and validates one bounded Android reading-plan filename identity. */
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

    /** Reads one Android signed-Int32 day number before converting the SQLite value. */
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

    /** Rejects an oversized table before row materialization begins. */
    private func requireRowCount(
        in table: String,
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
            throw RemoteSyncReadingPlanRestoreError.tooManyRows(table: table, count: count)
        }
    }

    /**
     Detects whether one reading-plan template uses Android's date-prefixed reading format.

     Android stores some plans with a leading `Mon-1;`-style prefix before the actual reading list.
     Completion semantics differ for these plans because earlier days are not auto-completed solely
     from `currentDay`.

     - Parameter template: iOS reading-plan template under evaluation.
     - Returns: `true` when catalog discovery marked the template as Android date-based.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func isDateBasedPlan(_ template: ReadingPlanTemplate) -> Bool {
        template.isDateBased
    }

    /**
     Counts how many logical readings one plan-day string represents.

     Date-based Android plans prefix the reading list with a date token separated by `;`. That prefix
     does not represent a reading and must be removed before counting comma-delimited readings.

     - Parameter readings: Raw reading string from a bundled iOS template.
     - Returns: Number of non-empty readings encoded in the supplied day string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func expectedReadingCount(for readings: String) -> Int {
        ReadingPlanDayAssignment(rawValue: readings).readings.count
    }

    /**
     Resolves whether one restored reading-plan day should be marked complete in iOS.

     Non-date-based Android plans implicitly treat days before `currentDay` as completed even when no
     per-day JSON status row exists. Date-based plans require explicit status JSON because `currentDay`
     alone does not imply completion. When a JSON payload is present, completion is derived from the
     Android `chapterReadArray` structure and the expected number of readings for that day.

     - Parameters:
       - status: Optional raw Android status row for the day being evaluated.
       - dayNumber: One-based day number within the plan template.
       - currentDay: Normalized current-day counter restored from Android metadata.
       - expectedReadingCount: Number of logical readings expected for this plan day.
       - isDateBasedPlan: Whether the plan uses Android's date-prefixed format.
     - Returns: `true` when the restored day should be flagged complete in local SwiftData.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when a present Android
         status payload is not valid JSON or cannot be decoded into the expected schema
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
