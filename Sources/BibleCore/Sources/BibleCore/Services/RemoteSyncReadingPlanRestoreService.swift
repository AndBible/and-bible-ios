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

    /// One Android UUID-like blob could not be converted into an iOS `UUID`.
    case invalidIdentifierBlob(table: String, column: String)
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

    /// Persisted Android plan start date.
    public let startDate: Date

    /// Persisted Android current-day pointer.
    public let currentDay: Int

    /// All staged status rows that belong to this plan code.
    public let statuses: [RemoteSyncAndroidReadingPlanStatus]

    /**
     Creates one staged Android reading plan.

     - Parameters:
       - id: Android identifier blob converted into iOS UUID form.
       - planCode: Android reading-plan code used to resolve the underlying plan definition.
       - startDate: Persisted Android plan start date.
       - currentDay: Persisted Android current-day pointer.
       - statuses: All staged status rows that belong to this plan code.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: UUID,
        planCode: String,
        startDate: Date,
        currentDay: Int,
        statuses: [RemoteSyncAndroidReadingPlanStatus]
    ) {
        self.id = id
        self.planCode = planCode
        self.startDate = startDate
        self.currentDay = currentDay
        self.statuses = statuses
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
 Reads staged Android reading-plan databases and restores them into iOS SwiftData.

 The restore contract is intentionally conservative:
 - staged SQLite rows are read exactly from Android's `ReadingPlan` and `ReadingPlanStatus` tables
 - restore is refused when the staged database references plan codes that this iOS build cannot
   recreate from `ReadingPlanService.availablePlans`
 - raw Android per-reading status JSON is preserved locally through
   `RemoteSyncReadingPlanStatusStore` so iOS does not silently discard progress fidelity it cannot
   yet render natively

 Mapping notes:
 - Android's selected/current plan preference is not stored in the sync database, so iOS derives
   `ReadingPlan.isActive` from whether every reconstructed day is complete
 - for non-date-based plans, Android treats all days before `planCurrentDay` as historic and fully
   read even when earlier `ReadingPlanStatus` rows have already been deleted; this restore mirrors
   that behavior

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement of the supplied `ModelContext`
   and `SettingsStore`
 */
public final class RemoteSyncReadingPlanRestoreService {
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
        let rawStatuses: [RemoteSyncAndroidReadingPlanStatus]
    }

    private struct AndroidReadingStatusPayload: Decodable {
        let chapterReadArray: [AndroidChapterRead]
    }

    private struct AndroidChapterRead: Decodable {
        let readingNumber: Int
        let isRead: Bool
    }

    /**
     Creates a reading-plan restore service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {}

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
     */
    public func readSnapshot(from databaseURL: URL) throws -> RemoteSyncAndroidReadingPlanSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        try requireTable(named: "ReadingPlan", in: db)
        try requireTable(named: "ReadingPlanStatus", in: db)

        let statuses = try fetchStatuses(from: db)
        let statusesByPlanCode = Dictionary(grouping: statuses, by: \.planCode)
        let planRows = try fetchPlans(from: db)

        let knownPlanCodes = Set(planRows.map(\.planCode))
        let orphanStatuses = statuses.filter { !knownPlanCodes.contains($0.planCode) }
        let plans = planRows.map { planRow in
            RemoteSyncAndroidReadingPlan(
                id: planRow.id,
                planCode: planRow.planCode,
                startDate: planRow.startDate,
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

     Restore is all-or-nothing at the semantic level. The method first validates that every staged
     plan code is reproducible from `ReadingPlanService.availablePlans`, that there are no orphan
     status rows, and that any status JSON needed for completion calculation is structurally valid.
     Only after that preflight succeeds does it delete existing plans, recreate new `ReadingPlan`
     and `ReadingPlanDay` rows, and preserve the raw Android status payloads locally.

     - Parameters:
       - snapshot: Staged Android snapshot previously read from `readSnapshot(from:)`.
       - modelContext: SwiftData context whose reading-plan rows should be replaced.
       - statusStore: Local-only store used to preserve raw Android status JSON.
     - Returns: Summary of restored plans, recreated day rows, and preserved raw statuses.
     - Side effects:
       - deletes existing local `ReadingPlan` graphs
       - inserts replacement `ReadingPlan` and `ReadingPlanDay` rows
       - clears and repopulates preserved Android status payloads in `statusStore`
       - saves `modelContext`
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.orphanStatuses` when the staged database contains
         status rows whose `planCode` has no matching plan row
       - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when iOS cannot
         reconstruct one or more staged plan codes from bundled templates
       - throws `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` when a status payload that
         affects completion calculation is not valid Android JSON
       - rethrows SwiftData save errors from `modelContext.save()`
     */
    public func replaceLocalReadingPlans(
        from snapshot: RemoteSyncAndroidReadingPlanSnapshot,
        modelContext: ModelContext,
        statusStore: RemoteSyncReadingPlanStatusStore
    ) throws -> RemoteSyncReadingPlanRestoreReport {
        let preparedPlans = try preparePlans(from: snapshot)

        let existingPlans = (try? modelContext.fetch(FetchDescriptor<ReadingPlan>())) ?? []
        for plan in existingPlans {
            modelContext.delete(plan)
        }

        statusStore.clearAll()

        var restoredDayCount = 0
        var preservedStatusCount = 0
        for preparedPlan in preparedPlans {
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

            for rawStatus in preparedPlan.rawStatuses {
                statusStore.setStatus(
                    rawStatus.readingStatusJSON,
                    planCode: rawStatus.planCode,
                    dayNumber: rawStatus.dayNumber,
                    remoteStatusID: rawStatus.id
                )
                preservedStatusCount += 1
            }
        }

        try modelContext.save()

        return RemoteSyncReadingPlanRestoreReport(
            restoredPlanCodes: preparedPlans.map(\.planCode).sorted(),
            restoredDayCount: restoredDayCount,
            preservedStatusCount: preservedStatusCount
        )
    }

    /**
     Normalizes one staged Android snapshot into validated iOS-ready reading-plan graphs.

     This preflight step resolves bundled iOS plan templates, rejects orphan status rows and
     unsupported plan codes, computes per-day completion, and preserves the raw Android status rows
     for later fidelity storage. It performs all semantic validation before any caller mutates
     SwiftData.

     - Parameter snapshot: Typed Android reading-plan snapshot previously loaded from SQLite.
     - Returns: Prepared plans ready for insertion into local SwiftData models.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncReadingPlanRestoreError.orphanStatuses` when the snapshot contains status
         rows whose `planCode` has no corresponding plan row
       - throws `RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions` when bundled iOS
         templates do not contain one or more staged plan codes
       - rethrows `RemoteSyncReadingPlanRestoreError.malformedReadingStatus` from completion
         calculation when Android status JSON cannot be decoded
     */
    private func preparePlans(from snapshot: RemoteSyncAndroidReadingPlanSnapshot) throws -> [PreparedPlan] {
        if !snapshot.orphanStatuses.isEmpty {
            throw RemoteSyncReadingPlanRestoreError.orphanStatuses(
                Array(Set(snapshot.orphanStatuses.map(\.planCode))).sorted()
            )
        }

        let templatesByCode = Dictionary(uniqueKeysWithValues: ReadingPlanService.availablePlans.map { ($0.code, $0) })
        let missingPlanCodes = Array(
            Set(snapshot.plans.map(\.planCode).filter { templatesByCode[$0] == nil })
        ).sorted()
        if !missingPlanCodes.isEmpty {
            throw RemoteSyncReadingPlanRestoreError.unsupportedPlanDefinitions(missingPlanCodes)
        }

        return try snapshot.plans.map { plan in
            let template = templatesByCode[plan.planCode]!
            let isDateBasedPlan = Self.isDateBasedPlan(template)
            let normalizedCurrentDay = min(max(plan.currentDay, 1), max(template.totalDays, 1))
            let statusesByDay = Dictionary(uniqueKeysWithValues: plan.statuses.map { ($0.dayNumber, $0) })

            var preparedDays: [PreparedDay] = []
            preparedDays.reserveCapacity(template.totalDays)

            var allDaysCompleted = true
            for dayNumber in 1...template.totalDays {
                let readings = template.readingsForDay(dayNumber)
                let expectedReadingCount = Self.expectedReadingCount(
                    for: readings,
                    isDateBasedPlan: isDateBasedPlan
                )
                let completion = try Self.isDayComplete(
                    status: statusesByDay[dayNumber],
                    dayNumber: dayNumber,
                    currentDay: normalizedCurrentDay,
                    expectedReadingCount: expectedReadingCount,
                    isDateBasedPlan: isDateBasedPlan
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
                days: preparedDays,
                rawStatuses: plan.statuses
            )
        }
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
    private func fetchPlans(from db: OpaquePointer) throws -> [(id: UUID, planCode: String, startDate: Date, currentDay: Int)] {
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

        var rows: [(UUID, String, Date, Int)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = try uuidFromBlob(statement: statement, column: 0, table: "ReadingPlan", name: "id")
            let planCode = stringColumn(statement: statement, index: 1)
            let startDateMillis = sqlite3_column_int64(statement, 2)
            let currentDay = Int(sqlite3_column_int(statement, 3))
            rows.append((id, planCode, Date(timeIntervalSince1970: TimeInterval(startDateMillis) / 1000.0), currentDay))
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
                    planCode: stringColumn(statement: statement, index: 1),
                    dayNumber: Int(sqlite3_column_int(statement, 2)),
                    readingStatusJSON: stringColumn(statement: statement, index: 3)
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

    private func stringColumn(statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: raw)
    }

    /**
     Detects whether one bundled reading-plan template uses Android's date-prefixed reading format.

     Android stores some plans with a leading `Mon-1;`-style prefix before the actual reading list.
     Completion semantics differ for these plans because earlier days are not auto-completed solely
     from `currentDay`.

     - Parameter template: Bundled iOS reading-plan template under evaluation.
     - Returns: `true` when the template's first-day reading string matches Android's date-prefixed format.
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
     Counts how many logical readings one plan-day string represents.

     Date-based Android plans prefix the reading list with a date token separated by `;`. That prefix
     does not represent a reading and must be removed before counting comma-delimited readings.

     - Parameters:
       - readings: Raw reading string from a bundled iOS template.
       - isDateBasedPlan: Whether the template uses Android's date-prefixed plan format.
     - Returns: Number of non-empty readings encoded in the supplied day string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func expectedReadingCount(for readings: String, isDateBasedPlan: Bool) -> Int {
        let readingsPortion: String
        if isDateBasedPlan, let separatorIndex = readings.firstIndex(of: ";") {
            readingsPortion = String(readings[readings.index(after: separatorIndex)...])
        } else {
            readingsPortion = readings
        }

        return readingsPortion
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
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

        if expectedReadingCount == 0 {
            return true
        }

        let readByNumber = Dictionary(uniqueKeysWithValues: payload.chapterReadArray.map { ($0.readingNumber, $0.isRead) })
        for readingNumber in 1...expectedReadingCount {
            if readByNumber[readingNumber] != true {
                return false
            }
        }
        return true
    }
}
