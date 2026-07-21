import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

private let readingPlanSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Forces one file-backed SwiftData store to report an operational write failure.

 The helper installs `BEFORE INSERT`, `BEFORE UPDATE`, and `BEFORE DELETE` triggers on every model
 table in the selected configuration.
 Evaluating an oversized `zeroblob` raises SQLite's `SQLITE_TOOBIG` operational error through Core
 Data's normal throwing save path. It avoids lock waits and does not masquerade as an optimistic-lock
 conflict, so SwiftData can roll back normally and the test can reopen both stores.

 - Side effects: Opens one SQLite connection and installs/removes temporary failure triggers.
 - Failure modes: Throws an `NSError` when SQLite cannot open, inspect, or modify the selected store.
 - Important: Tests must remove the triggers before reopening the SwiftData container.
 */
final class ReadingPlanSQLiteStoreWriteFailure {
    /// Open SQLite connection used to manage test-only triggers.
    private var database: OpaquePointer?

    /// Trigger names currently installed in the selected store.
    private var triggerNames: [String] = []

    /**
     Opens the selected file-backed SwiftData store.

     - Parameter databaseURL: Graph or settings SQLite store whose writes should fail.
     - Side effects: Opens a read-write SQLite connection.
     - Failure modes: Throws when SQLite cannot open the selected store.
     */
    init(databaseURL: URL) throws {
        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_READWRITE,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let openedDatabase {
                sqlite3_close(openedDatabase)
            }
            throw NSError(
                domain: "ReadingPlanSQLiteStoreWriteFailure",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        database = openedDatabase
        sqlite3_busy_timeout(openedDatabase, 1_000)
    }

    /**
     Installs operational-error triggers for every write operation on each model table.

     - Side effects: Adds persistent test-only triggers that reject the next entity write.
     - Failure modes: Throws when model tables cannot be enumerated or a trigger cannot be created.
       Repeated installation while active is a no-op.
     */
    func install() throws {
        guard triggerNames.isEmpty, let database else {
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let tableSQL = """
        SELECT name
        FROM sqlite_master
        WHERE type = 'table'
          AND name GLOB 'Z*'
          AND name NOT IN ('Z_METADATA', 'Z_MODELCACHE', 'Z_PRIMARYKEY')
        ORDER BY name
        """
        guard sqlite3_prepare_v2(database, tableSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database)
        }

        var tableNames: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawName = sqlite3_column_text(statement, 0) {
                tableNames.append(String(cString: rawName))
            }
        }
        guard !tableNames.isEmpty else {
            throw NSError(
                domain: "ReadingPlanSQLiteStoreWriteFailure",
                code: Int(SQLITE_NOTFOUND),
                userInfo: [NSLocalizedDescriptionKey: "No SwiftData model tables found"]
            )
        }

        do {
            for (tableIndex, tableName) in tableNames.enumerated() {
                for operation in ["INSERT", "UPDATE", "DELETE"] {
                    let triggerName = "reading_plan_write_failure_\(tableIndex)_\(operation.lowercased())"
                    try execute(
                        """
                        CREATE TRIGGER "\(triggerName)"
                        BEFORE \(operation) ON "\(tableName)"
                        BEGIN
                            SELECT zeroblob(2147483648);
                        END;
                        """,
                        database: database
                    )
                    triggerNames.append(triggerName)
                }
            }
        } catch {
            remove()
            throw error
        }
    }

    /**
     Removes every installed failure trigger.

     - Side effects: Restores ordinary writes to the selected store.
     - Failure modes: Trigger-removal errors are ignored so cleanup does not mask the tested error.
     */
    func remove() {
        guard let database else {
            return
        }
        for triggerName in triggerNames.reversed() {
            try? execute("DROP TRIGGER IF EXISTS \"\(triggerName)\";", database: database)
        }
        triggerNames.removeAll()
    }

    /**
     Executes one SQLite schema statement.

     - Parameters:
       - statement: Complete SQLite statement to execute.
       - database: Open fixture database connection.
     - Side effects: Installs or removes test-only triggers.
     - Failure modes: Throws an `NSError` containing SQLite's latest diagnostic.
     */
    private func execute(_ statement: String, database: OpaquePointer) throws {
        let result = sqlite3_exec(database, statement, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw sqliteError(database, code: result)
        }
    }

    /**
     Builds one NSError from the selected SQLite connection's latest diagnostic.

     - Parameters:
       - database: Open SQLite connection that reported the failure.
       - code: SQLite result code, defaulting to the connection's latest code.
     - Returns: Error carrying SQLite's domain, code, and diagnostic message.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sqliteError(_ database: OpaquePointer, code: Int32? = nil) -> NSError {
        NSError(
            domain: "ReadingPlanSQLiteStoreWriteFailure",
            code: Int(code ?? sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
        )
    }

    /** Removes installed triggers and closes the direct SQLite connection. */
    deinit {
        remove()
        if let database {
            sqlite3_close(database)
        }
    }
}

/**
 Production-shaped file-backed reading-plan restore store set.

 Reading plans and days live in one graph configuration while `Setting` rows live in a second local
 configuration, matching `AndBibleApp` without enabling CloudKit in unit tests.
 */
struct PersistentReadingPlanRestoreStore {
    /// Container spanning the graph and local settings configurations.
    let container: ModelContainer

    /// SQLite URL for the reading-plan and reading-plan-day graph.
    let graphStoreURL: URL

    /// SQLite URL for local preserved-status settings.
    let settingsStoreURL: URL
}

/**
 Android `ReadingPlan` table row fixture for remote-sync snapshot tests.

 The row mirrors the production Android backup schema so restore, patch, and initial-backup tests
 can assert Android-compatible behavior without depending on the app-host test bundle.
 */
struct AndroidReadingPlanRow {
    let id: UUID
    let planCode: String
    let startDate: Date
    let currentDay: Int
}

/**
 Android `ReadingPlanStatus` table row fixture for remote-sync snapshot tests.

 Status payloads remain raw JSON because Android stores the serialized reading status exactly in the
 SQLite row; tests use this to protect round-trip fidelity.
 */
struct AndroidReadingPlanStatusRow {
    let id: UUID
    let planCode: String
    let dayNumber: Int
    let readingStatusJSON: String
}

/**
 Android `LogEntry` row fixture used by reading-plan patch replay tests.

 Each row records one Android-style table mutation with typed SQLite entity identifiers.
 */
struct AndroidReadingPlanLogEntryRow {
    let tableName: String
    let entityID1: RemoteSyncSQLiteValue
    let entityID2: RemoteSyncSQLiteValue
    let type: RemoteSyncLogEntryType
    let lastUpdated: Int64
    let sourceDevice: String
}

/**
 Creates an in-memory SwiftData container containing the reading-plan sync schema.

 - Returns: A transient container with reading plans, reading-plan days, and settings.
 - Side effects: Allocates in-process SwiftData storage.
 - Failure modes: Throws if SwiftData cannot initialize the container.
 */
func makeReadingPlanRestoreModelContainer() throws -> ModelContainer {
    let schema = Schema([
        ReadingPlan.self,
        ReadingPlanDay.self,
        ReadingPlanDefinitionPublicationState.self,
        Setting.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

/**
 Creates or reopens production-shaped file-backed stores for reading-plan restore tests.

 - Parameter directoryURL: Existing temporary directory that owns both SQLite store families.
 - Returns: Container plus graph/settings URLs used for independent failure injection.
 - Side effects: Creates or opens `ReadingPlanGraph.store` and `ReadingPlanSettings.store` beneath
   `directoryURL`.
 - Failure modes: Rethrows SwiftData model-container/configuration errors.
 */
func makePersistentReadingPlanRestoreStore(in directoryURL: URL) throws -> PersistentReadingPlanRestoreStore {
    let graphModels: [any PersistentModel.Type] = [
        ReadingPlan.self,
        ReadingPlanDay.self,
        ReadingPlanDefinitionPublicationState.self,
    ]
    let localModels: [any PersistentModel.Type] = [Setting.self]
    let schema = Schema(graphModels + localModels)
    let graphStoreURL = directoryURL.appendingPathComponent("ReadingPlanGraph.store")
    let settingsStoreURL = directoryURL.appendingPathComponent("ReadingPlanSettings.store")
    let graphConfiguration = ModelConfiguration(
        "ReadingPlanRestoreGraph",
        schema: Schema(graphModels),
        url: graphStoreURL,
        cloudKitDatabase: .none
    )
    let settingsConfiguration = ModelConfiguration(
        "ReadingPlanRestoreSettings",
        schema: Schema(localModels),
        url: settingsStoreURL,
        cloudKitDatabase: .none
    )
    let container = try ModelContainer(
        for: schema,
        configurations: [graphConfiguration, settingsConfiguration]
    )
    return PersistentReadingPlanRestoreStore(
        container: container,
        graphStoreURL: graphStoreURL,
        settingsStoreURL: settingsStoreURL
    )
}

/**
 Builds a temporary Android-format reading-plan SQLite database.

 - Parameters:
   - plans: Android reading-plan rows inserted into the `ReadingPlan` table.
   - statuses: Android reading-status rows inserted into the `ReadingPlanStatus` table.
   - logEntries: Android patch log rows inserted into the `LogEntry` table.
 - Returns: File URL for the temporary SQLite database.
 - Side effects: Writes one SQLite database beneath the process temporary directory.
 - Failure modes: Throws `RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase` when SQLite
   cannot open the temporary database; XCTest assertions record statement failures.
 */
func makeAndroidReadingPlansDatabase(
    plans: [AndroidReadingPlanRow],
    statuses: [AndroidReadingPlanStatusRow],
    logEntries: [AndroidReadingPlanLogEntryRow] = []
) throws -> URL {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-readingplans-\(UUID().uuidString).sqlite3")

    var db: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
        XCTFail("Failed to open temporary Android reading plan database")
        throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(
        sqlite3_exec(
            db,
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .readingPlans),
            nil,
            nil,
            nil
        ),
        SQLITE_OK
    )

    for plan in plans {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES (?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )

        sqlite3_bind_text(statement, 1, plan.planCode, -1, readingPlanSQLiteTransient)
        sqlite3_bind_int64(statement, 2, Int64(plan.startDate.timeIntervalSince1970 * 1000))
        sqlite3_bind_int(statement, 3, Int32(plan.currentDay))
        let blob = readingPlanUUIDBlob(plan.id)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), readingPlanSQLiteTransient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for status in statuses {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO ReadingPlanStatus (planCode, planDay, readingStatus, id) VALUES (?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )

        sqlite3_bind_text(statement, 1, status.planCode, -1, readingPlanSQLiteTransient)
        sqlite3_bind_int(statement, 2, Int32(status.dayNumber))
        sqlite3_bind_text(statement, 3, status.readingStatusJSON, -1, readingPlanSQLiteTransient)
        let blob = readingPlanUUIDBlob(status.id)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), readingPlanSQLiteTransient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for entry in logEntries {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )

        sqlite3_bind_text(statement, 1, entry.tableName, -1, readingPlanSQLiteTransient)
        bindReadingPlanSQLiteValue(entry.entityID1, to: statement, index: 2)
        bindReadingPlanSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, readingPlanSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, readingPlanSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    return databaseURL
}

/**
 Builds one staged patch archive fixture for reading-plan replay tests.

 - Parameters:
   - patchDatabaseURL: Local SQLite database containing Android patch rows.
   - sourceDevice: Android source-device name owning the patch stream.
   - patchNumber: Monotonic patch number within the source-device stream.
   - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
 - Returns: Staged patch archive pointing at a temporary gzip file.
 - Side effects:
   - reads the supplied SQLite database
   - writes one temporary gzip archive beneath the process temporary directory
 - Failure modes:
   - rethrows filesystem read and write errors
   - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
 */
func makeReadingPlanPatchArchive(
    patchDatabaseURL: URL,
    sourceDevice: String,
    patchNumber: Int64,
    fileTimestamp: Int64
) throws -> RemoteSyncStagedPatchArchive {
    let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-readingplans-patch-\(UUID().uuidString).sqlite3.gz")
    try archiveData.write(to: archiveURL, options: .atomic)

    return RemoteSyncStagedPatchArchive(
        patch: RemoteSyncDiscoveredPatch(
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: 1,
            file: RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/\(sourceDevice)/\(patchNumber).sqlite3.gz",
                name: "\(patchNumber).sqlite3.gz",
                size: Int64(archiveData.count),
                timestamp: fileTimestamp,
                parentID: "/org.andbible.ios-sync-readingplans/\(sourceDevice)",
                mimeType: "application/gzip"
            )
        ),
        archiveFileURL: archiveURL
    )
}

/**
 Remote-sync adapter test double for reading-plan backup upload tests.

 The actor records calls made by `RemoteSyncInitialBackupUploadService` and captures uploaded archive
 bytes so the test can inspect the generated Android-compatible database. It models create-only
 publication by validating and forwarding the exact bounded source file through the deterministic
 upload queue.
 */
actor ReadingPlanMockRemoteSyncAdapter: RemoteSyncAdapting, RemoteSyncConditionalFileUploading {
    private var uploadResults: [RemoteSyncFile] = []
    private var events: [ReadingPlanMockRemoteSyncAdapterEvent] = []
    private var uploadedFiles: [ReadingPlanMockRemoteSyncUploadedFile] = []

    /**
     Queues one upload result returned by the next `upload` call.

     - Parameter result: Remote file metadata to return after capturing the upload payload.
     - Side effects: Mutates the queued upload responses.
     - Failure modes: none.
     */
    func enqueueUploadResult(_ result: RemoteSyncFile) {
        uploadResults.append(result)
    }

    /**
     Returns recorded remote adapter events in call order.

     - Returns: Ordered event snapshot.
     - Side effects: Reads actor-isolated state.
     - Failure modes: none.
     */
    func eventsSnapshot() -> [ReadingPlanMockRemoteSyncAdapterEvent] {
        events
    }

    /**
     Returns files uploaded through the mock adapter.

     - Returns: Captured upload payloads and metadata.
     - Side effects: Reads actor-isolated state.
     - Failure modes: none.
     */
    func uploadedFilesSnapshot() -> [ReadingPlanMockRemoteSyncUploadedFile] {
        uploadedFiles
    }

    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        events.append(
            .listFiles(
                parentIDs: parentIDs,
                name: name,
                mimeType: mimeType,
                modifiedAtLeast: modifiedAtLeast
            )
        )
        return []
    }

    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        events.append(.createFolder(name: name, parentID: parentID))
        return RemoteSyncFile(
            id: [parentID, name].compactMap { $0 }.joined(separator: "/"),
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    func download(id: String) async throws -> Data {
        events.append(.download(id: id))
        return Data()
    }

    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        events.append(.upload(name: name, parentID: parentID, contentType: contentType))
        let data = try Data(contentsOf: fileURL)
        uploadedFiles.append(
            ReadingPlanMockRemoteSyncUploadedFile(
                name: name,
                parentID: parentID,
                contentType: contentType,
                data: data
            )
        )
        if !uploadResults.isEmpty {
            let result = uploadResults.removeFirst()
            return RemoteSyncFile(
                id: result.id,
                name: result.name,
                size: Int64(data.count),
                timestamp: result.timestamp,
                parentID: result.parentID,
                mimeType: result.mimeType
            )
        }
        return RemoteSyncFile(
            id: [parentID, name].joined(separator: "/"),
            name: name,
            size: Int64(data.count),
            timestamp: 0,
            parentID: parentID,
            mimeType: contentType
        )
    }

    /**
     Records a create-only upload through the mock's deterministic upload path.

     The fixture does not model competing writers; conflict and reconciliation behavior is covered by
     `RemoteSyncRemotePatchReconcilerTests`. The returned metadata comes from the queued upload result.

     - Parameters:
       - name: Exact remote filename being created.
       - fileURL: Durable immutable archive file captured by the initial-backup service.
       - maximumByteCount: Maximum accepted archive size.
       - parentID: Destination sync-folder identifier.
       - contentType: MIME type attached to the remote file.
     - Returns: A successful create result containing queued remote metadata.
     - Side effects: Reads and records the bounded upload file through the mock upload path.
     - Throws: Rethrows bounded-file validation and mock upload failures.
     */
    func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        _ = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        return .created(try await upload(
            name: name,
            fileURL: fileURL,
            parentID: parentID,
            contentType: contentType
        ))
    }

    func delete(id: String) async throws {
        events.append(.delete(id: id))
    }

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        events.append(.isSyncFolderKnown(syncFolderID: syncFolderID, secretFileName: secretFileName))
        return false
    }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        events.append(.makeKnown(syncFolderID: syncFolderID, deviceIdentifier: deviceIdentifier))
        return "device-known-\(deviceIdentifier)-secret"
    }
}

/**
 Ordered remote adapter events emitted by `ReadingPlanMockRemoteSyncAdapter`.
 */
enum ReadingPlanMockRemoteSyncAdapterEvent: Equatable {
    case listFiles(parentIDs: [String]?, name: String?, mimeType: String?, modifiedAtLeast: Date?)
    case createFolder(name: String, parentID: String?)
    case download(id: String)
    case upload(name: String, parentID: String, contentType: String)
    case delete(id: String)
    case isSyncFolderKnown(syncFolderID: String, secretFileName: String)
    case makeKnown(syncFolderID: String, deviceIdentifier: String)
}

/**
 Captured upload payload emitted by `ReadingPlanMockRemoteSyncAdapter`.
 */
struct ReadingPlanMockRemoteSyncUploadedFile: Equatable {
    let name: String
    let parentID: String
    let contentType: String
    let data: Data
}

/**
 Binds one typed Android SQLite scalar into a fixture statement.

 - Parameters:
   - value: Typed scalar payload that should be bound into SQLite.
   - statement: SQLite statement receiving the bound parameter.
   - index: One-based parameter index.
 - Side effects: Mutates the bound SQLite statement parameter state.
 - Failure modes: This helper cannot fail.
 */
private func bindReadingPlanSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
    switch value.kind {
    case .null:
        sqlite3_bind_null(statement, index)
    case .integer:
        sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
    case .real:
        sqlite3_bind_double(statement, index, value.realValue ?? 0)
    case .text:
        sqlite3_bind_text(statement, index, value.textValue ?? "", -1, readingPlanSQLiteTransient)
    case .blob:
        let data = value.blobData ?? Data()
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), readingPlanSQLiteTransient)
        }
    }
}

/**
 Encodes one UUID in the Android database blob representation.

 - Parameter uuid: Identifier to encode.
 - Returns: Sixteen bytes matching Android UUID blob storage.
 - Side effects: none.
 - Failure modes: none for valid `UUID` values.
 */
func readingPlanUUIDBlob(_ uuid: UUID) -> Data {
    let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
    var bytes = Data()
    bytes.reserveCapacity(16)

    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2)
        let byteString = hex[index..<nextIndex]
        bytes.append(UInt8(byteString, radix: 16)!)
        index = nextIndex
    }
    return bytes
}
