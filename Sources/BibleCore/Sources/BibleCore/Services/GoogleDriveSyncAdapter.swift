// GoogleDriveSyncAdapter.swift — Android-aligned Google Drive sync adapter

import Foundation

/**
 Errors emitted by the Google Drive REST client and adapter.

 The Google Drive sync path reuses the existing remote-sync bootstrap, restore, patch-replay, and
 patch-upload services. Those higher layers only need Android-shaped file metadata and backend
 operations, so the Drive-specific client collapses transport failures into a small error surface
 that still preserves HTTP status codes when callers need to distinguish not-found behavior from
 other failures.
 */
public enum GoogleDriveClientError: Error, Equatable {
    /// Google Drive returned a non-success HTTP status code.
    case httpStatus(Int)

    /// The server returned malformed or incomplete JSON metadata.
    case invalidResponse
}

/**
 Async access-token provider used by the Google Drive REST client.

 The current transport slice does not yet integrate the Google Sign-In SDK, but the client already
 depends on a provider closure instead of a raw token string so later sign-in work can inject token
 refresh behavior without changing the transport API or patch-sync services.
 */
public typealias GoogleDriveAccessTokenProvider = @Sendable () async throws -> String

/**
 Thin Google Drive REST client that mirrors Android's appDataFolder-backed adapter semantics.

 Data dependencies:
 - `GoogleDriveAccessTokenProvider` supplies OAuth access tokens for Bearer authorization
 - `URLSession` performs HTTPS requests against Google Drive REST endpoints

 Side effects:
 - metadata methods perform Google Drive REST requests against the Drive v3 files endpoint
 - upload reads a local file from disk and submits a multipart upload request
 - delete issues a remote file deletion request

 Failure modes:
 - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
 - throws `GoogleDriveClientError.invalidResponse` when the response body is not valid Drive JSON
 - rethrows token-provider failures and local file-read failures

 Concurrency:
 - this type is immutable after initialization and safe to share across actors as long as the
   injected token provider is itself safe to invoke concurrently
 */
final class GoogleDriveClient: @unchecked Sendable {
    /// Google Drive MIME type used for folders.
    static let folderMimeType = "application/vnd.google-apps.folder"

    /// Hidden Drive container used by Android for app-private sync storage.
    static let appDataFolderID = "appDataFolder"

    private static let fileFields = "id,name,size,createdTime,parents,mimeType"
    private static let listFields = "nextPageToken,files(\(fileFields))"
    private static let filesBaseURL = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let uploadBaseURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso8601WithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let accessTokenProvider: GoogleDriveAccessTokenProvider
    private let session: URLSession

    /**
     Creates a Drive REST client.
     *
     * - Parameters:
     *   - accessTokenProvider: Async provider that yields a valid OAuth access token.
     *   - session: URL session used for HTTPS transport. Tests can inject a mocked session.
     * - Side effects: none.
     * - Failure modes: This initializer cannot fail.
     */
    init(
        accessTokenProvider: @escaping GoogleDriveAccessTokenProvider,
        session: URLSession = .shared
    ) {
        self.accessTokenProvider = accessTokenProvider
        self.session = session
    }

    /**
     Lists Drive files using Android-compatible appDataFolder semantics.
     *
     * - Parameters:
     *   - parentIDs: Optional parent identifiers to search under.
     *   - name: Optional exact filename filter.
     *   - mimeType: Optional exact MIME type filter.
     *   - createdTimeAtLeast: Optional lower-bound creation timestamp.
     * - Returns: Matching remote file descriptors collected across all Drive pages.
     * - Side effects: Performs one or more authenticated Google Drive list requests.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
     *   - throws `GoogleDriveClientError.invalidResponse` when the response body is malformed
     *   - rethrows token-provider failures
     */
    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        createdTimeAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        var collected: [RemoteSyncFile] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(url: Self.filesBaseURL, resolvingAgainstBaseURL: false)
            var queryItems = [
                URLQueryItem(name: "spaces", value: Self.appDataFolderID),
                URLQueryItem(name: "fields", value: Self.listFields),
                URLQueryItem(name: "pageSize", value: "1000"),
            ]

            let query = driveQuery(
                parentIDs: parentIDs,
                name: name,
                mimeType: mimeType,
                createdTimeAtLeast: createdTimeAtLeast
            )
            if !query.isEmpty {
                queryItems.append(URLQueryItem(name: "q", value: query))
            }
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components?.queryItems = queryItems

            let request = try await authorizedRequest(
                url: try requestURL(from: components),
                method: "GET"
            )
            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response)

            let payload: FileListResponse
            do {
                payload = try JSONDecoder().decode(FileListResponse.self, from: data)
            } catch {
                throw GoogleDriveClientError.invalidResponse
            }

            collected.append(contentsOf: try payload.files.map(remoteSyncFile(from:)))
            pageToken = payload.nextPageToken
        } while pageToken != nil

        return collected
    }

    /**
     Loads metadata for one Drive file or folder.
     *
     * - Parameter id: Drive file identifier.
     * - Returns: Android-shaped metadata for the requested file or folder.
     * - Side effects: Performs one authenticated Google Drive metadata request.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
     *   - throws `GoogleDriveClientError.invalidResponse` when the response body is malformed
     */
    func get(id: String) async throws -> RemoteSyncFile {
        var components = URLComponents(
            url: Self.filesBaseURL.appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "fields", value: Self.fileFields)]
        let request = try await authorizedRequest(url: try requestURL(from: components), method: "GET")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        let payload: DriveFile
        do {
            payload = try JSONDecoder().decode(DriveFile.self, from: data)
        } catch {
            throw GoogleDriveClientError.invalidResponse
        }
        return try remoteSyncFile(from: payload)
    }

    /**
     Downloads the raw bytes for one Drive file.
     *
     * - Parameter id: Drive file identifier.
     * - Returns: Raw file payload bytes.
     * - Side effects: Performs one authenticated Drive media download request.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
     *   - rethrows token-provider failures
     */
    func download(id: String) async throws -> Data {
        var components = URLComponents(
            url: Self.filesBaseURL.appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "alt", value: "media")]
        let request = try await authorizedRequest(url: try requestURL(from: components), method: "GET")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        return data
    }

    /**
     Creates a Drive folder under the supplied parent or the appDataFolder root.
     *
     * - Parameters:
     *   - name: Folder name to create.
     *   - parentID: Optional parent identifier. `nil` targets the appDataFolder root.
     * - Returns: Metadata for the newly created folder.
     * - Side effects: Performs one authenticated Drive metadata creation request.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
     *   - throws `GoogleDriveClientError.invalidResponse` when the response body is malformed
     *   - rethrows JSON-encoding failures for the metadata payload
     */
    func createFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        var components = URLComponents(url: Self.filesBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "fields", value: Self.fileFields)]
        let payload = CreateFileRequest(
            name: name,
            mimeType: Self.folderMimeType,
            parents: [parentID ?? Self.appDataFolderID]
        )
        let body = try JSONEncoder().encode(payload)
        var request = try await authorizedRequest(url: try requestURL(from: components), method: "POST")
        request.httpBody = body
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        let file: DriveFile
        do {
            file = try JSONDecoder().decode(DriveFile.self, from: data)
        } catch {
            throw GoogleDriveClientError.invalidResponse
        }
        return try remoteSyncFile(from: file)
    }

    /**
     Uploads one local file into Google Drive using a multipart metadata-plus-media request.
     *
     * - Parameters:
     *   - name: Destination filename.
     *   - fileURL: Local file whose contents should be uploaded.
     *   - parentID: Drive parent folder identifier.
     *   - contentType: MIME type recorded for the uploaded file.
     * - Returns: Metadata for the uploaded Drive file.
     * - Side effects:
     *   - reads the local file into memory
     *   - performs one authenticated multipart Drive upload request
     * - Failure modes:
     *   - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
     *   - throws `GoogleDriveClientError.invalidResponse` when the response body is malformed
     *   - rethrows local file-read failures and JSON-encoding failures
     */
    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let boundary = "Boundary-\(UUID().uuidString)"

        var components = URLComponents(url: Self.uploadBaseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "fields", value: Self.fileFields),
        ]

        let metadata = try JSONEncoder().encode(
            CreateFileRequest(name: name, mimeType: contentType, parents: [parentID])
        )
        let body = multipartBody(
            metadataJSON: metadata,
            fileData: fileData,
            contentType: contentType,
            boundary: boundary
        )

        var request = try await authorizedRequest(url: try requestURL(from: components), method: "POST")
        request.httpBody = body
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        let file: DriveFile
        do {
            file = try JSONDecoder().decode(DriveFile.self, from: data)
        } catch {
            throw GoogleDriveClientError.invalidResponse
        }
        return try remoteSyncFile(from: file)
    }

    /**
     Deletes one Drive file or folder.
     *
     * - Parameter id: Drive file identifier.
     * - Side effects: Performs one authenticated Drive deletion request.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.httpStatus(_:)` for non-success HTTP responses
     *   - rethrows token-provider failures
     */
    func delete(id: String) async throws {
        let request = try await authorizedRequest(
            url: Self.filesBaseURL.appendingPathComponent(id),
            method: "DELETE"
        )
        let (_, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
    }

    /**
     Builds Android-compatible Drive query syntax from optional metadata filters.
     *
     * - Parameters:
     *   - parentIDs: Optional parent identifiers.
     *   - name: Optional exact filename filter.
     *   - mimeType: Optional exact MIME type filter.
     *   - createdTimeAtLeast: Optional lower-bound creation timestamp.
     * - Returns: Google Drive `q` syntax string, or an empty string when no filters are supplied.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func driveQuery(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        createdTimeAtLeast: Date?
    ) -> String {
        var clauses: [String] = []

        if let parentIDs, !parentIDs.isEmpty {
            let parentsClause = parentIDs
                .map { "'\(Self.escapedQueryLiteral($0))' in parents" }
                .joined(separator: " or ")
            clauses.append("(\(parentsClause))")
        }

        if let createdTimeAtLeast {
            let createdTime = Self.iso8601WithoutFractionalSeconds.string(from: createdTimeAtLeast)
            clauses.append("createdTime > '\(createdTime)'")
        }

        if let name, !name.isEmpty {
            clauses.append("name = '\(Self.escapedQueryLiteral(name))'")
        }

        if let mimeType, !mimeType.isEmpty {
            clauses.append("mimeType = '\(Self.escapedQueryLiteral(mimeType))'")
        }

        return clauses.joined(separator: " and ")
    }

    /**
     Builds an authenticated request with a Bearer token.
     *
     * - Parameters:
     *   - url: Fully resolved Drive endpoint URL.
     *   - method: HTTP method to send.
     * - Returns: URL request configured with Bearer authorization and JSON accept headers.
     * - Side effects:
     *   - awaits the token provider to resolve an access token
     * - Failure modes:
     *   - rethrows token-provider failures
     */
    private func authorizedRequest(url: URL, method: String) async throws -> URLRequest {
        let accessToken = try await accessTokenProvider()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /**
     Validates that the HTTP response is a success status.
     *
     * - Parameter response: URL loading response to validate.
     * - Side effects: none.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.invalidResponse` when the response is not HTTP
     *   - throws `GoogleDriveClientError.httpStatus(_:)` when the status code is outside 200-299
     */
    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw GoogleDriveClientError.httpStatus(httpResponse.statusCode)
        }
    }

    /**
     Converts one decoded Drive metadata payload into the shared remote-sync file shape.
     *
     * - Parameter file: Decoded Drive metadata payload.
     * - Returns: Shared Android-shaped remote file descriptor.
     * - Side effects: none.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.invalidResponse` when mandatory Drive metadata is missing
     */
    private func remoteSyncFile(from file: DriveFile) throws -> RemoteSyncFile {
        guard !file.id.isEmpty, !file.name.isEmpty else {
            throw GoogleDriveClientError.invalidResponse
        }

        return RemoteSyncFile(
            id: file.id,
            name: file.name,
            size: Int64(file.size ?? "0") ?? 0,
            timestamp: timestampMilliseconds(from: file.createdTime),
            parentID: file.parents?.first ?? Self.appDataFolderID,
            mimeType: file.mimeType ?? "application/octet-stream"
        )
    }

    /**
     Converts an optional Drive RFC 3339 timestamp into milliseconds since 1970.
     *
     * - Parameter value: Optional RFC 3339 timestamp string returned by Google Drive.
     * - Returns: Milliseconds since 1970, or `0` when the timestamp is absent or malformed.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func timestampMilliseconds(from value: String?) -> Int64 {
        guard let value, !value.isEmpty else {
            return 0
        }
        if let date = Self.iso8601WithFractionalSeconds.date(from: value)
            ?? Self.iso8601WithoutFractionalSeconds.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return 0
    }

    /**
     Builds a multipart/related upload body matching Google Drive's metadata-plus-media contract.
     *
     * - Parameters:
     *   - metadataJSON: JSON-encoded file metadata section.
     *   - fileData: Binary media payload to upload.
     *   - contentType: MIME type for the media section.
     *   - boundary: Multipart boundary token.
     * - Returns: Multipart request body ready for `httpBody`.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func multipartBody(
        metadataJSON: Data,
        fileData: Data,
        contentType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataJSON)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /**
     Resolves a fully formed request URL from optional URL components.
     *
     * - Parameter components: URL components that should resolve into a valid request URL.
     * - Returns: Fully resolved request URL.
     * - Side effects: none.
     * - Failure modes:
     *   - throws `GoogleDriveClientError.invalidResponse` when the components cannot form a URL
     */
    private func requestURL(from components: URLComponents?) throws -> URL {
        guard let url = components?.url else {
            throw GoogleDriveClientError.invalidResponse
        }
        return url
    }

    /**
     Escapes single quotes for Google Drive `q` syntax.
     *
     * - Parameter value: Unescaped literal value.
     * - Returns: Literal safe for inclusion inside single-quoted Drive query clauses.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private static func escapedQueryLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "\\'")
    }
}

/**
 Internal Drive JSON response for list-file requests.
 */
private struct FileListResponse: Decodable {
    /// Current page of matching Drive files.
    let files: [DriveFile]

    /// Continuation token for the next page, if any.
    let nextPageToken: String?
}

/**
 Internal Drive JSON response for one file or folder.
 */
private struct DriveFile: Decodable {
    /// Drive file identifier.
    let id: String

    /// Human-readable filename.
    let name: String

    /// Optional size string returned by the Drive API.
    let size: String?

    /// Optional RFC 3339 creation timestamp.
    let createdTime: String?

    /// Parent folder identifiers.
    let parents: [String]?

    /// Google Drive MIME type string.
    let mimeType: String?
}

/**
 JSON payload used for Drive create-folder and upload-metadata requests.
 */
private struct CreateFileRequest: Encodable {
    /// Remote filename.
    let name: String

    /// MIME type recorded for the remote file.
    let mimeType: String

    /// Parent folder identifiers.
    let parents: [String]
}

/**
 Android-aligned Google Drive adapter built on top of `GoogleDriveClient`.

 This adapter exposes the same `RemoteSyncAdapting` boundary already used by the NextCloud
 implementation so the iOS patch-sync engine can reuse bootstrap, restore, replay, and upload
 logic without Drive-specific branching below the adapter layer.

 Google Drive differs from NextCloud in one important ownership detail: Android treats the sync
 folder's Drive file identifier itself as sufficient proof of ownership, so no secret marker file
 is uploaded. The adapter therefore returns a synthetic non-empty marker token from
 `makeSyncFolderKnown` and ignores that value when validating ownership later.
 */
public actor GoogleDriveSyncAdapter: RemoteSyncAdapting {
    /// Google Drive MIME type used for folders.
    public static let folderMimeType = GoogleDriveClient.folderMimeType

    /// Synthetic marker token stored in backend-agnostic bootstrap state for Google Drive folders.
    public static let ownershipSentinel = "__google_drive_folder_id__"

    private let client: GoogleDriveClient

    /**
     Creates a Google Drive adapter from an async access-token provider.
     *
     * - Parameters:
     *   - accessTokenProvider: Async provider that yields a valid Google OAuth access token.
     *   - session: URL session used for HTTPS transport. Tests can inject a mocked session.
     * - Side effects: none.
     * - Failure modes: This initializer cannot fail.
     */
    public init(
        accessTokenProvider: @escaping GoogleDriveAccessTokenProvider,
        session: URLSession = .shared
    ) {
        self.client = GoogleDriveClient(accessTokenProvider: accessTokenProvider, session: session)
    }

    /**
     Verifies Drive access by listing the appDataFolder root.
     *
     * - Side effects: Performs an authenticated Drive list request.
     * - Failure modes:
     *   - rethrows Drive transport or authorization failures from `GoogleDriveClient`
     */
    public func verifyConnection() async throws {
        _ = try await client.listFiles(
            parentIDs: [GoogleDriveClient.appDataFolderID],
            name: nil,
            mimeType: nil,
            createdTimeAtLeast: nil
        )
    }

    /**
     Lists Drive files beneath one or more parent folders.
     *
     * - Parameters:
     *   - parentIDs: Optional parent identifiers. `nil` defaults to `appDataFolder`.
     *   - name: Optional exact filename filter.
     *   - mimeType: Optional exact MIME type filter.
     *   - modifiedAtLeast: Optional lower-bound timestamp. Google Drive uses `createdTime` to
     *     match Android's adapter behavior.
     * - Returns: Matching Android-shaped remote file descriptors.
     * - Side effects: Performs authenticated Drive list requests.
     * - Failure modes:
     *   - rethrows Drive transport or authorization failures from `GoogleDriveClient`
     */
    public func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        try await client.listFiles(
            parentIDs: parentIDs ?? [GoogleDriveClient.appDataFolderID],
            name: name,
            mimeType: mimeType,
            createdTimeAtLeast: modifiedAtLeast
        )
    }

    /**
     Creates a Drive folder under the supplied parent or the appDataFolder root.
     *
     * - Parameters:
     *   - name: Folder name to create.
     *   - parentID: Optional parent identifier. `nil` targets `appDataFolder`.
     * - Returns: Android-shaped metadata for the created folder.
     * - Side effects: Performs an authenticated Drive metadata creation request.
     * - Failure modes:
     *   - rethrows Drive transport or authorization failures from `GoogleDriveClient`
     */
    public func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        try await client.createFolder(name: name, parentID: parentID)
    }

    /**
     Downloads one Drive file payload.
     *
     * - Parameter id: Drive file identifier.
     * - Returns: Raw file payload bytes.
     * - Side effects: Performs an authenticated Drive media download request.
     * - Failure modes:
     *   - rethrows Drive transport or authorization failures from `GoogleDriveClient`
     */
    public func download(id: String) async throws -> Data {
        try await client.download(id: id)
    }

    /**
     Uploads one local file into the requested Drive folder.
     *
     * - Parameters:
     *   - name: Destination filename.
     *   - fileURL: Local file whose contents should be uploaded.
     *   - parentID: Drive parent folder identifier.
     *   - contentType: MIME type recorded for the uploaded file.
     * - Returns: Android-shaped metadata for the uploaded Drive file.
     * - Side effects:
     *   - reads the local file from disk
     *   - performs an authenticated Drive multipart upload request
     * - Failure modes:
     *   - rethrows Drive transport, authorization, file-read, or JSON-encoding failures from
     *     `GoogleDriveClient`
     */
    public func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        try await client.upload(
            name: name,
            fileURL: fileURL,
            parentID: parentID,
            contentType: contentType
        )
    }

    /**
     Deletes one Drive file or folder.
     *
     * - Parameter id: Drive file identifier.
     * - Side effects: Performs an authenticated Drive deletion request.
     * - Failure modes:
     *   - rethrows Drive transport or authorization failures from `GoogleDriveClient`
     */
    public func delete(id: String) async throws {
        try await client.delete(id: id)
    }

    /**
     Checks whether the stored sync-folder identifier still exists in Drive.
     *
     * Google Drive does not require NextCloud-style secret marker files. Android treats the folder
     * identifier itself as the proof of ownership, so this method ignores `secretFileName` and
     * simply checks whether the folder metadata can still be loaded.
     *
     * - Parameters:
     *   - syncFolderID: Stored Drive folder identifier for the sync category.
     *   - secretFileName: Ignored synthetic marker token retained for backend-agnostic state.
     * - Returns: `true` when the Drive folder still exists.
     * - Side effects: Performs an authenticated Drive metadata request.
     * - Failure modes:
     *   - returns `false` for HTTP 404 responses
     *   - rethrows other Drive transport or authorization failures from `GoogleDriveClient`
     */
    public func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        do {
            _ = try await client.get(id: syncFolderID)
            return true
        } catch GoogleDriveClientError.httpStatus(let statusCode) where statusCode == 404 {
            return false
        }
    }

    /**
     Returns the synthetic ownership token used for Google Drive bootstrap state.
     *
     * - Parameters:
     *   - syncFolderID: Stored Drive folder identifier. Unused because Drive does not require
     *     secret marker uploads.
     *   - deviceIdentifier: Stable device identifier. Unused for the same reason.
     * - Returns: Non-empty synthetic token stored in backend-agnostic bootstrap state.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    public func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        Self.ownershipSentinel
    }
}
