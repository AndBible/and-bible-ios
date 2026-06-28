import Foundation
import SQLite3
import XCTest
@testable import BibleCore

/**
 In-memory secret store for remote-sync settings tests.

 The store mimics the production keychain-facing `SecretStoring` contract without touching the
 keychain, letting package tests assert password persistence and clearing deterministically.
 */
final class InMemorySecretStore: SecretStoring {
    private var secrets: [String: String] = [:]

    /**
     Returns the stored secret for a key.

     - Parameter key: Secret identifier supplied by `RemoteSyncSettingsStore`.
     - Returns: The secret value when present, otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    func secret(forKey key: String) -> String? {
        secrets[key]
    }

    /**
     Stores or replaces a secret.

     - Parameters:
       - value: Secret value to persist in memory.
       - key: Secret identifier supplied by `RemoteSyncSettingsStore`.
     - Side effects: Mutates the in-memory secret dictionary.
     - Failure modes: This fake never throws.
     */
    func setSecret(_ value: String, forKey key: String) throws {
        secrets[key] = value
    }

    /**
     Removes a stored secret.

     - Parameter key: Secret identifier to clear.
     - Side effects: Mutates the in-memory secret dictionary.
     - Failure modes: This fake never throws.
     */
    func removeSecret(forKey key: String) throws {
        secrets.removeValue(forKey: key)
    }
}

/**
 Remote-sync adapter test double for state, bootstrap, discovery, and staging tests.

 The actor records every remote operation in call order and returns queued responses so package
 tests can validate Android-compatible bootstrap and patch behavior without WebDAV transport.
 */
actor RemoteSyncMockAdapter: RemoteSyncAdapting {
    private var fallbackListFilesResult: [RemoteSyncFile] = []
    private var listFilesResultsQueue: [[RemoteSyncFile]] = []
    private var createFolderResults: [RemoteSyncFile] = []
    private var uploadResults: [RemoteSyncFile] = []
    private var downloadDataByID: [String: Data] = [:]
    private var knownResponses: [String: Bool] = [:]
    private var makeKnownResponse = "device-known-default"
    private var events: [RemoteSyncMockAdapterEvent] = []
    private var uploadedFiles: [RemoteSyncMockUploadedFile] = []

    /**
     Installs a fallback listing used when no queued listing is available.

     - Parameter result: Files returned by `listFiles` after the queue is exhausted.
     - Side effects: Mutates the adapter's fallback response.
     - Failure modes: none.
     */
    func setListFilesResult(_ result: [RemoteSyncFile]) {
        fallbackListFilesResult = result
    }

    /**
     Queues the next listing response.

     - Parameter result: Files returned by the next `listFiles` call.
     - Side effects: Appends to the listing response queue.
     - Failure modes: none.
     */
    func enqueueListFilesResult(_ result: [RemoteSyncFile]) {
        listFilesResultsQueue.append(result)
    }

    /**
     Queues the next folder-creation response.

     - Parameter result: Remote file metadata returned by the next `createNewFolder` call.
     - Side effects: Appends to the folder creation response queue.
     - Failure modes: none.
     */
    func enqueueCreateFolderResult(_ result: RemoteSyncFile) {
        createFolderResults.append(result)
    }

    /**
     Queues the next upload response.

     - Parameter result: Remote file metadata returned by the next `upload` call.
     - Side effects: Appends to the upload response queue.
     - Failure modes: none.
     */
    func enqueueUploadResult(_ result: RemoteSyncFile) {
        uploadResults.append(result)
    }

    /**
     Installs downloaded bytes for a remote file identifier.

     - Parameters:
       - data: Bytes returned by `download`.
       - id: Remote file identifier.
     - Side effects: Mutates the download fixture map.
     - Failure modes: none.
     */
    func setDownloadData(_ data: Data, forID id: String) {
        downloadDataByID[id] = data
    }

    /**
     Installs a known-folder marker lookup result.

     - Parameters:
       - value: Result returned by `isSyncFolderKnown`.
       - syncFolderID: Remote sync folder identifier.
       - secretFileName: Marker file name expected by the bootstrap coordinator.
     - Side effects: Mutates the known-folder response map.
     - Failure modes: none.
     */
    func setKnownResponse(_ value: Bool, forSyncFolderID syncFolderID: String, secretFileName: String) {
        knownResponses["\(syncFolderID)|\(secretFileName)"] = value
    }

    /**
     Installs the marker name returned when a folder is made known.

     - Parameter value: Marker file name returned by `makeSyncFolderKnown`.
     - Side effects: Mutates the marker creation response.
     - Failure modes: none.
     */
    func setMakeKnownResponse(_ value: String) {
        makeKnownResponse = value
    }

    /**
     Returns recorded remote-sync operations.

     - Returns: Ordered event list captured so far.
     - Side effects: none.
     - Failure modes: none.
     */
    func eventsSnapshot() -> [RemoteSyncMockAdapterEvent] {
        events
    }

    /**
     Returns recorded upload payloads.

     - Returns: Uploaded file metadata and bytes captured so far.
     - Side effects: none.
     - Failure modes: none.
     */
    func uploadedFilesSnapshot() -> [RemoteSyncMockUploadedFile] {
        uploadedFiles
    }

    /**
     Records and serves a remote listing request.

     - Parameters:
       - parentIDs: Optional parent folder filter.
       - name: Optional file name filter.
       - mimeType: Optional MIME type filter.
       - modifiedAtLeast: Optional timestamp lower bound.
     - Returns: The next queued listing response, or the fallback listing.
     - Side effects: Appends a `.listFiles` event and consumes one queued response when present.
     - Failure modes: This fake never throws.
     */
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
        if !listFilesResultsQueue.isEmpty {
            return listFilesResultsQueue.removeFirst()
        }
        return fallbackListFilesResult
    }

    /**
     Records and serves a folder-creation request.

     - Parameters:
       - name: Folder name to create.
       - parentID: Optional parent folder identifier.
     - Returns: The next queued folder response, or synthesized folder metadata.
     - Side effects: Appends a `.createFolder` event and consumes one queued response when present.
     - Failure modes: This fake never throws.
     */
    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        events.append(.createFolder(name: name, parentID: parentID))
        if !createFolderResults.isEmpty {
            return createFolderResults.removeFirst()
        }
        return RemoteSyncFile(
            id: [parentID, name].compactMap { $0 }.joined(separator: "/"),
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    /**
     Records and serves a file download.

     - Parameter id: Remote file identifier.
     - Returns: Bytes previously registered for the identifier, or empty data.
     - Side effects: Appends a `.download` event.
     - Failure modes: This fake never throws.
     */
    func download(id: String) async throws -> Data {
        events.append(.download(id: id))
        return downloadDataByID[id] ?? Data()
    }

    /**
     Records and serves a file upload.

     - Parameters:
       - name: Destination file name.
       - fileURL: Local file whose bytes should be captured.
       - parentID: Remote parent folder identifier.
       - contentType: Uploaded content type.
     - Returns: The next queued upload response, or synthesized metadata.
     - Side effects: Reads the local file, appends upload payload metadata, and records a `.upload`
       event.
     - Failure modes: Rethrows file-read errors from `Data(contentsOf:)`.
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        events.append(.upload(name: name, parentID: parentID, contentType: contentType))
        let data = try Data(contentsOf: fileURL)
        uploadedFiles.append(
            RemoteSyncMockUploadedFile(
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
     Records a remote delete request.

     - Parameter id: Remote file or folder identifier to delete.
     - Side effects: Appends a `.delete` event.
     - Failure modes: This fake never throws.
     */
    func delete(id: String) async throws {
        events.append(.delete(id: id))
    }

    /**
     Records and serves a known-folder marker lookup.

     - Parameters:
       - syncFolderID: Remote sync folder identifier.
       - secretFileName: Expected marker file name.
     - Returns: Registered known-folder result, defaulting to `false`.
     - Side effects: Appends an `.isSyncFolderKnown` event.
     - Failure modes: This fake never throws.
     */
    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        events.append(.isSyncFolderKnown(syncFolderID: syncFolderID, secretFileName: secretFileName))
        return knownResponses["\(syncFolderID)|\(secretFileName)"] ?? false
    }

    /**
     Records and serves a known-folder marker creation.

     - Parameters:
       - syncFolderID: Remote sync folder identifier.
       - deviceIdentifier: Device identifier used in the marker file name.
     - Returns: Registered marker file name.
     - Side effects: Appends a `.makeKnown` event.
     - Failure modes: This fake never throws.
     */
    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        events.append(.makeKnown(syncFolderID: syncFolderID, deviceIdentifier: deviceIdentifier))
        return makeKnownResponse
    }
}

/**
 Ordered remote adapter events captured by `RemoteSyncMockAdapter`.

 Tests compare these events to verify bootstrap, discovery, staging, and cleanup call order without
 depending on WebDAV transport internals.
 */
enum RemoteSyncMockAdapterEvent: Equatable {
    case listFiles(parentIDs: [String]?, name: String?, mimeType: String?, modifiedAtLeast: Date?)
    case createFolder(name: String, parentID: String?)
    case download(id: String)
    case upload(name: String, parentID: String, contentType: String)
    case delete(id: String)
    case isSyncFolderKnown(syncFolderID: String, secretFileName: String)
    case makeKnown(syncFolderID: String, deviceIdentifier: String)
}

/**
 Captured upload payload emitted by `RemoteSyncMockAdapter`.

 The fixture keeps the uploaded bytes with the remote destination metadata so tests can inspect
 generated SQLite archives after sync services call the adapter.
 */
struct RemoteSyncMockUploadedFile: Equatable {
    let name: String
    let parentID: String
    let contentType: String
    let data: Data
}

/**
 Creates a temporary SQLite database with one fixture table and an explicit user-version pragma.

 - Parameter userVersion: Value written to `PRAGMA user_version`.
 - Returns: File URL for the created database.
 - Side effects: Writes a SQLite database beneath the process temporary directory.
 - Failure modes: Throws `NSError` when SQLite open, pragma, table creation, or fixture insert
   operations fail.
 */
func makeTemporarySQLiteDatabase(userVersion: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "remote-sync-test-\(UUID().uuidString).sqlite3"
    )

    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
    ) == SQLITE_OK,
    let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "BibleCoreTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "PRAGMA user_version = \(userVersion);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "BibleCoreTests.SQLite", code: 2)
    }
    guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS sample (id INTEGER PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "BibleCoreTests.SQLite", code: 3)
    }
    guard sqlite3_exec(database, "INSERT INTO sample (value) VALUES ('fixture');", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "BibleCoreTests.SQLite", code: 4)
    }

    return url
}

/**
 Reads the SQLite `user_version` pragma from a database file.

 - Parameter url: Database URL to inspect.
 - Returns: Integer `user_version` value stored in the SQLite header.
 - Side effects: Opens and closes the database read-only.
 - Failure modes: Throws `NSError` when SQLite cannot open, prepare, or step the pragma query.
 */
func readSQLiteUserVersion(at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "BibleCoreTests.SQLite", code: 5)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        if let statement {
            sqlite3_finalize(statement)
        }
        throw NSError(domain: "BibleCoreTests.SQLite", code: 6)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "BibleCoreTests.SQLite", code: 7)
    }
    return Int(sqlite3_column_int(statement, 0))
}

/**
 Asserts that an async expression throws and lets the caller inspect the error.

 Package-level remote-sync tests use this helper for async service errors that XCTest does not
 cover with a built-in async throwing assertion.

 - Parameters:
   - expression: Async throwing expression expected to fail.
   - errorHandler: Assertion closure that validates the thrown error.
   - file: Source file reported to XCTest on failure.
   - line: Source line reported to XCTest on failure.
 - Side effects: Records an XCTest failure when the expression does not throw.
 - Failure modes: The helper catches the expression error and passes it to `errorHandler`.
 */
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
