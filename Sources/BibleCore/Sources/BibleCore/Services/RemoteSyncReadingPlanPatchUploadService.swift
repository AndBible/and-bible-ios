// RemoteSyncReadingPlanPatchUploadService.swift — Android-shaped outbound reading-plan patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncReadingPlanPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android reading-plan patch.
 */
public enum RemoteSyncReadingPlanPatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase
}

/**
 Summary of one successful outbound reading-plan patch upload.

 Android sync tracks patch creation per device folder and relies on `LogEntry` rows for sparse row
 replay. This report preserves the same core counters so higher layers can verify that an upload
 actually contained the expected Android-shaped mutations.
 */
public struct RemoteSyncReadingPlanPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `ReadingPlan` rows written into the patch database.
    public let upsertedPlanCount: Int

    /// Number of `ReadingPlanStatus` rows written into the patch database.
    public let upsertedStatusCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound reading-plan patch-upload summary.

     - Parameters:
       - uploadedFile: Remote file metadata returned by the backend after upload succeeded.
       - patchNumber: Monotonic patch number assigned within the current device folder.
       - upsertedPlanCount: Number of `ReadingPlan` rows written into the patch database.
       - upsertedStatusCount: Number of `ReadingPlanStatus` rows written into the patch database.
       - deletedRowCount: Number of `DELETE` log entries emitted for rows removed locally.
       - logEntryCount: Total number of Android `LogEntry` rows written into the patch database.
       - lastUpdated: Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedPlanCount: Int,
        upsertedStatusCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedPlanCount = upsertedPlanCount
        self.upsertedStatusCount = upsertedStatusCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse reading-plan patch databases and uploads them to the active backend.

 The service mirrors the outbound half of Android's reading-plan sync contract for the one category
 that currently has a full iOS fidelity bridge:
 - project current local SwiftData state into Android `ReadingPlan` and `ReadingPlanStatus` rows
 - compare those rows against the preserved Android `LogEntry` baseline and local row fingerprints
 - emit sparse `UPSERT` and `DELETE` `LogEntry` rows for only the changed Android keys
 - write an Android-compatible SQLite patch database and gzip archive
 - upload `<patchNumber>.<schemaVersion>.sqlite3.gz` into the device folder
 - advance local `LogEntry`, `SyncStatus`, `lastPatchWritten`, and fingerprint baselines only after upload succeeds

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote file upload
 - `RemoteSyncReadingPlanSnapshotService` projects live SwiftData and local-only status metadata into Android-shaped rows
 - `RemoteSyncLogEntryStore` provides the Android conflict baseline and is updated after successful upload
 - `RemoteSyncPatchStatusStore` tracks the highest uploaded patch number for the local device folder
 - `RemoteSyncStateStore` persists Android-aligned `lastPatchWritten` bookkeeping
 - `RemoteSyncArchiveStagingService` provides gzip compression for the generated SQLite patch file

 Side effects:
 - reads live `ReadingPlan` state from SwiftData and preserved status/log metadata from `SettingsStore`
 - creates and removes temporary SQLite and gzip files beneath the configured temporary directory
 - uploads a gzip patch archive into the ready device folder
 - rewrites local Android `LogEntry` and fingerprint baselines for `.readingPlans` after successful upload
 - appends one local patch status row and updates `lastPatchWritten`

 Failure modes:
 - throws `RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID` when the category is not bootstrapped for outbound upload
 - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be created
 - rethrows local filesystem write failures while building the temporary SQLite or gzip files
 - rethrows backend transport or local-file read failures from `RemoteSyncAdapting.upload`
 - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService.gzip(_:)`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncReadingPlanPatchUploadService {
    private struct ChangeSet {
        let planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow]
        let statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        /**
         Returns the total number of delete log entries in the change set.

         - Returns: Number of emitted delete operations.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private let adapter: any RemoteSyncAdapting
    private let snapshotService: RemoteSyncReadingPlanSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Int64

    /**
     Creates a reading-plan patch upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for the final archive upload.
       - snapshotService: Snapshot service used to project current local reading-plan state into Android rows.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary SQLite and gzip files. Defaults to the process temporary directory.
       - nowProvider: Millisecond clock used for Android `LogEntry.lastUpdated` and local `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncReadingPlanSnapshotService = RemoteSyncReadingPlanSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.nowProvider = nowProvider
    }

    /**
     Builds and uploads the next sparse reading-plan patch when local state differs from the baseline.

     The service is intentionally conservative about missing fingerprint baselines. When it finds a
     preserved Android `LogEntry` row with no matching local fingerprint, it assumes the row came
     from a pre-fingerprint restore or replay and refreshes the baseline without uploading a patch.
     That avoids fabricating large false-positive patches the first time outbound diffing is enabled
     on an existing install.

     - Parameters:
       - bootstrapState: Ready bootstrap state for the reading-plan category.
       - modelContext: SwiftData context that owns the live reading-plan graph.
       - settingsStore: Local-only settings store backing preserved Android sync metadata.
       - schemaVersion: Schema version to encode into the generated patch filename and SQLite user version.
     - Returns: Upload summary when a sparse patch was emitted, or `nil` when no local changes need upload.
     - Side effects:
       - may refresh the fingerprint baseline without uploading when the service encounters historical rows with no stored fingerprints
       - creates and removes temporary SQLite and gzip files
       - uploads a gzip patch archive when local changes exist
       - rewrites local `LogEntry`, patch-status, progress, and fingerprint state after successful upload
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID` when `bootstrapState.deviceFolderID` is missing or empty
       - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be opened
       - rethrows filesystem, compression, and backend upload failures
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 1
    ) async throws -> RemoteSyncReadingPlanPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID
        }

        let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
        let timestamp = nowProvider()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let existingEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .readingPlans).map {
                (logEntryStore.key(for: .readingPlans, entry: $0), $0)
            }
        )
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let hadMissingFingerprintBaseline = existingEntriesByKey.keys.contains { key in
            snapshot.planRowsByKey[key] != nil || snapshot.statusRowsByKey[key] != nil
        } && existingEntriesByKey.contains { key, entry in
            if entry.type == .delete {
                return false
            }
            return (snapshot.planRowsByKey[key] != nil || snapshot.statusRowsByKey[key] != nil)
                && fingerprintStore.fingerprint(
                    for: .readingPlans,
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                ) == nil
        }

        let changeSet = buildChangeSet(
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )

        if changeSet.logEntries.isEmpty {
            if hadMissingFingerprintBaseline {
                snapshotService.refreshBaselineFingerprints(
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            }
            return nil
        }

        let patchNumber = (patchStatusStore.lastPatchNumber(
            for: .readingPlans,
            sourceDevice: sourceDevice
        ) ?? 0) + 1
        let patchFileName = "\(patchNumber).\(schemaVersion).sqlite3.gz"

        let databaseURL = temporaryURL(prefix: "remote-sync-readingplans-upload-", suffix: ".sqlite3")
        let archiveURL = temporaryURL(prefix: "remote-sync-readingplans-upload-", suffix: ".sqlite3.gz")
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(at: archiveURL)
        }

        try writePatchDatabase(
            at: databaseURL,
            schemaVersion: schemaVersion,
            changeSet: changeSet
        )
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: databaseURL))
        try archiveData.write(to: archiveURL, options: .atomic)

        let uploadedFile = try await adapter.upload(
            name: patchFileName,
            fileURL: archiveURL,
            parentID: deviceFolderID,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )

        logEntryStore.replaceEntries(
            changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort),
            for: .readingPlans
        )
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                sizeBytes: uploadedFile.size,
                appliedDate: timestamp
            ),
            for: .readingPlans
        )
        var progressState = stateStore.progressState(for: .readingPlans)
        progressState.lastPatchWritten = timestamp
        stateStore.setProgressState(progressState, for: .readingPlans)
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        return RemoteSyncReadingPlanPatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: patchNumber,
            upsertedPlanCount: changeSet.planRowsByKey.count,
            upsertedStatusCount: changeSet.statusRowsByKey.count,
            deletedRowCount: changeSet.deletedRowCount,
            logEntryCount: changeSet.logEntries.count,
            lastUpdated: timestamp
        )
    }

    /**
     Computes the sparse Android row diff for the current snapshot.

     - Parameters:
       - snapshot: Current local reading-plan state projected into Android-shaped rows.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to compare current rows against the last uploaded baseline.
       - timestamp: Millisecond timestamp to assign to any emitted outbound `LogEntry` rows.
       - sourceDevice: Local source-device folder name that should own the outbound patch rows.
     - Returns: Sparse change set containing upserted rows, delete entries, and the updated local metadata baseline.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncReadingPlanCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        timestamp: Int64,
        sourceDevice: String
    ) -> ChangeSet {
        var planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow] = [:]
        var statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.planRowsByKey.sorted(by: { $0.key < $1.key }) {
            let shouldUpload = shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            )
            guard shouldUpload else {
                continue
            }

            let entry = RemoteSyncLogEntry(
                tableName: "ReadingPlan",
                entityID1: .blob(RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            planRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.statusRowsByKey.sorted(by: { $0.key < $1.key }) {
            let shouldUpload = shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            )
            guard shouldUpload else {
                continue
            }

            let entry = RemoteSyncLogEntry(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            statusRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, entry) in existingEntriesByKey.sorted(by: { $0.key < $1.key }) {
            guard entry.type != .delete else {
                continue
            }
            guard snapshot.planRowsByKey[key] == nil, snapshot.statusRowsByKey[key] == nil else {
                continue
            }
            let deleteEntry = RemoteSyncLogEntry(
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: entry.entityID2,
                type: .delete,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            logEntries.append(deleteEntry)
            updatedEntriesByKey[key] = deleteEntry
        }

        return ChangeSet(
            planRowsByKey: planRowsByKey,
            statusRowsByKey: statusRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    /**
     Returns whether one current snapshot row should be emitted as an outbound `UPSERT`.

     Missing fingerprints are intentionally treated as unchanged when the row already has a
     preserved non-delete Android `LogEntry` baseline. That conservative branch prevents a one-time
     fingerprint migration from generating false-positive uploads for historical restores.

     - Parameters:
       - key: Android composite key for the row.
       - currentFingerprint: Current stable row fingerprint, if one was computed.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to read the prior baseline for the row.
     - Returns: `true` when the row should be emitted as an outbound upsert.
     - Side effects: reads preserved local fingerprint rows from `SettingsStore`.
     - Failure modes: This helper cannot fail.
     */
    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String?,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        guard let currentFingerprint else {
            return false
        }

        guard let existingEntry = existingEntriesByKey[key] else {
            return true
        }

        if existingEntry.type == .delete {
            return true
        }

        let existingFingerprint = fingerprintStore.fingerprint(
            for: .readingPlans,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        guard let existingFingerprint else {
            return false
        }
        return existingFingerprint != currentFingerprint
    }

    /**
     Writes one sparse Android reading-plan patch database to the supplied SQLite URL.

     - Parameters:
       - url: Temporary SQLite file URL to create.
       - schemaVersion: SQLite user version that should be written to the patch database.
       - changeSet: Sparse current-row diff that should be serialized.
     - Side effects:
       - creates and writes a temporary SQLite database file
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when the file cannot be opened for writing
       - rethrows SQLite execution failures from schema creation or row inserts
     */
    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        changeSet: ChangeSet
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            PRAGMA user_version = \(schemaVersion);
            CREATE TABLE ReadingPlan (
                planCode TEXT NOT NULL,
                planStartDate INTEGER NOT NULL,
                planCurrentDay INTEGER NOT NULL DEFAULT 1,
                id BLOB NOT NULL PRIMARY KEY
            );
            CREATE TABLE ReadingPlanStatus (
                planCode TEXT NOT NULL,
                planDay INTEGER NOT NULL,
                readingStatus TEXT NOT NULL,
                id BLOB NOT NULL PRIMARY KEY
            );
            CREATE TABLE LogEntry (
                tableName TEXT NOT NULL,
                entityId1 BLOB,
                entityId2 BLOB,
                type TEXT NOT NULL,
                lastUpdated INTEGER NOT NULL,
                sourceDevice TEXT NOT NULL
            );
            """,
            in: database
        )

        for row in changeSet.planRowsByKey.values.sorted(by: { lhs, rhs in
            if lhs.planCode == rhs.planCode {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.planCode < rhs.planCode
        }) {
            try insertReadingPlanRow(row, in: database)
        }

        for row in changeSet.statusRowsByKey.values.sorted(by: { lhs, rhs in
            if lhs.planCode == rhs.planCode {
                if lhs.planDay == rhs.planDay {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.planDay < rhs.planDay
            }
            return lhs.planCode < rhs.planCode
        }) {
            try insertReadingPlanStatusRow(row, in: database)
        }

        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    /**
     Inserts one Android `ReadingPlan` row into the open patch database.

     - Parameters:
       - row: Android-shaped reading-plan row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `ReadingPlan` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertReadingPlanRow(
        _ row: RemoteSyncCurrentReadingPlanRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, row.planCode, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 2, row.planStartDateMillis)
        sqlite3_bind_int(statement, 3, Int32(row.planCurrentDay))
        let blob = RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), remoteSyncReadingPlanPatchUploadSQLiteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `ReadingPlanStatus` row into the open patch database.

     - Parameters:
       - row: Android-shaped reading-plan-status row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `ReadingPlanStatus` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertReadingPlanStatusRow(
        _ row: RemoteSyncCurrentReadingPlanStatusRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO ReadingPlanStatus (planCode, planDay, readingStatus, id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, row.planCode, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        sqlite3_bind_int(statement, 2, Int32(row.planDay))
        sqlite3_bind_text(statement, 3, row.readingStatusJSON, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        let blob = RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), remoteSyncReadingPlanPatchUploadSQLiteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `LogEntry` row into the open patch database.

     - Parameters:
       - entry: Android log entry to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `LogEntry` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertLogEntry(
        _ entry: RemoteSyncLogEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.tableName, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Executes one schema or pragma SQL batch against the open patch database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when SQLite rejects the statement batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Creates a new unique temporary URL beneath the configured temporary directory.

     - Parameters:
       - prefix: File-name prefix for the temporary file.
       - suffix: File-name suffix for the temporary file.
     - Returns: Temporary file URL that does not currently exist.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Derives the Android source-device name from the ready device-folder identifier.

     - Parameter deviceFolderID: Remote device-folder identifier stored in the bootstrap state.
     - Returns: Final path component used as the Android source-device name.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    /**
     Binds one typed SQLite scalar value into a prepared statement parameter.

     - Parameters:
       - value: Typed SQLite value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(
                statement,
                index,
                value.textValue ?? "",
                -1,
                remoteSyncReadingPlanPatchUploadSQLiteTransient
            )
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(data.count),
                    remoteSyncReadingPlanPatchUploadSQLiteTransient
                )
            }
        }
    }

    /**
     Sorts Android log entries into a deterministic patch-write order.

     - Parameters:
       - lhs: First log entry to compare.
       - rhs: Second log entry to compare.
     - Returns: `true` when `lhs` should appear before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.type != rhs.type {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        if lhs.sourceDevice != rhs.sourceDevice {
            return lhs.sourceDevice < rhs.sourceDevice
        }
        if lhs.entityID1 != rhs.entityID1 {
            return sortKey(for: lhs.entityID1) < sortKey(for: rhs.entityID1)
        }
        return sortKey(for: lhs.entityID2) < sortKey(for: rhs.entityID2)
    }

    /**
     Builds a deterministic string key used only for local ordering of SQLite value payloads.

     - Parameter value: Typed SQLite scalar value.
     - Returns: Canonical string preserving storage kind and payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sortKey(for value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "null"
        case .integer:
            return "integer:\(value.integerValue ?? 0)"
        case .real:
            return "real:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            return "text:\(value.textValue ?? "")"
        case .blob:
            return "blob:\(value.blobBase64Value ?? "")"
        }
    }
}
