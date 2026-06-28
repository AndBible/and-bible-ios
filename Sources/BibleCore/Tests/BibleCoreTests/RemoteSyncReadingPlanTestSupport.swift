import CLibSword
import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

private let readingPlanSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
        Setting.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
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
            """
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
 bytes so the test can inspect the generated Android-compatible database.
 */
actor ReadingPlanMockRemoteSyncAdapter: RemoteSyncAdapting {
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
 Decompresses gzip bytes produced by remote-sync archive services for fixture inspection.

 - Parameter data: Gzip-compressed archive bytes.
 - Returns: Decompressed archive payload.
 - Side effects: Allocates and frees one CLibSword gzip output buffer.
 - Failure modes: Throws `RemoteSyncArchiveStagingError.decompressionFailed` when decompression
   fails or the input buffer is empty.
 */
func gunzipTestData(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
        guard let baseAddress = ptr.baseAddress else {
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
