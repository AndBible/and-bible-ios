// NextCloudSyncAdapter.swift — Android-aligned WebDAV adapter for remote sync

import Foundation

/**
 Represents one remote file or folder exposed by a non-CloudKit sync backend.

 The shape mirrors Android's `CloudFile` contract closely enough for a future patch-sync engine to
 reuse Android's folder, patch, and secret-marker semantics without translating between unrelated
 models.

 `timestamp` intentionally carries a single millisecond value rather than separate creation and
 modification fields. WebDAV responses do not expose a portable creation timestamp, so the
 NextCloud adapter populates this field from DAV `getlastmodified` when available. That preserves a
 stable ordering field for incremental patch discovery even though the source property differs from
 Android's OwnCloud library.
 */
public struct RemoteSyncFile: Sendable, Equatable {
    /// Backend-specific identifier used for later `GET`, `PUT`, `DELETE`, and folder listing calls.
    public let id: String

    /// Human-readable file or folder name.
    public let name: String

    /// File size in bytes. Folders report `0`.
    public let size: Int64

    /// Best-available backend timestamp expressed as milliseconds since 1970.
    public let timestamp: Int64

    /// Parent folder identifier.
    public let parentID: String

    /// Android-compatible MIME type string. Folders use `DIR`.
    public let mimeType: String

    /**
     Creates one remote file descriptor.

     - Parameters:
       - id: Backend-specific identifier used for future operations.
       - name: Human-readable file or folder name.
       - size: File size in bytes.
       - timestamp: Best-available backend timestamp in milliseconds since 1970.
       - parentID: Parent folder identifier.
       - mimeType: Android-compatible MIME type string.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        id: String,
        name: String,
        size: Int64,
        timestamp: Int64,
        parentID: String,
        mimeType: String
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.timestamp = timestamp
        self.parentID = parentID
        self.mimeType = mimeType
    }
}

/**
 Android-aligned NextCloud/WebDAV adapter built on top of `WebDAVClient`.

 This actor is the iOS equivalent of Android's `NextCloudAdapter`. It is intentionally limited to
 transport-facing responsibilities:
 - normalize the optional base sync folder path
 - map DAV resources into Android-shaped `RemoteSyncFile` values
 - create folder paths with Android's `createFullPath` behavior
 - manage the secret marker file used to prove sync-folder ownership

 The actor does not implement patch numbering, database diff generation, or local sync-state
 persistence. Those remain higher-level responsibilities, just as Android keeps them in `CloudSync`
 and the sync DAO layer rather than inside the adapter itself.

 Data dependencies:
 - `WebDAVSyncConfiguration` supplies the resolved DAV root, username, and optional base folder path
 - `WebDAVClient` performs authenticated transport operations

 Side effects:
 - `verifyConnection`, `listFiles`, `get`, `download`, and `isSyncFolderKnown` perform remote DAV requests
 - `createNewFolder` and base-folder initialization issue `MKCOL` requests
 - `upload` and `makeSyncFolderKnown` upload remote file payloads with HTTP `PUT`
 - `uploadIfAbsent` performs create-only WebDAV `PUT` plus exact readback and preserves occupied destinations
 - `delete` removes remote paths with HTTP `DELETE`

 Concurrency:
 - this type is an actor so repeated calls can safely share the lazily initialized base-folder cache
   without external locking
 */
public actor NextCloudSyncAdapter {
    /// Android-compatible MIME type used for folders in `RemoteSyncFile` payloads.
    public static let folderMimeType = "DIR"

    /// MIME type Android uses for uploaded patch archives and marker files.
    public static let gzipMimeType = "application/gzip"

    private let client: WebDAVClient
    private let davBasePath: String
    private let baseFolderPath: String?
    private var cachedBaseFolderID: String?

    /**
     Creates a NextCloud/WebDAV adapter from persisted Android-compatible settings.

     - Parameters:
       - configuration: Persisted WebDAV settings including server root, username, and optional sync folder path.
       - password: Password or app password used for HTTP Basic authentication.
       - session: URL session used for transport. Tests can inject a mocked session.
     - Side effects:
       - resolves the configured server root into a DAV endpoint
       - creates a transport client that will be reused by later actor calls
     - Failure modes:
       - throws `WebDAVClientError.invalidURL` when the configured server root cannot be normalized into a DAV endpoint
     */
    public init(
        configuration: WebDAVSyncConfiguration,
        password: String,
        session: URLSession = .shared
    ) throws {
        let davBaseURL = try configuration.resolvedDAVBaseURL()
        self.client = WebDAVClient(
            baseURL: davBaseURL,
            username: configuration.username,
            password: password,
            session: session
        )
        self.davBasePath = try Self.normalizedIdentifier(davBaseURL.path)
        self.baseFolderPath = try Self.normalizedOptionalIdentifier(configuration.folderPath)
        self.cachedBaseFolderID = nil
    }

    /**
     Verifies connectivity and credentials by issuing a root-level DAV `PROPFIND`.

     - Side effects: performs a remote DAV request.
     - Failure modes:
       - rethrows transport and authentication failures emitted by `WebDAVClient.testConnection()`
     */
    public func verifyConnection() async throws {
        _ = try await client.testConnection()
    }

    /**
     Loads metadata for one remote file or folder.

     - Parameter id: Backend-specific identifier returned by prior adapter calls.
     - Returns: One `RemoteSyncFile` for the requested path.
     - Side effects: performs a depth-0 DAV `PROPFIND`.
     - Failure modes:
       - rethrows DAV transport failures, including 404-style missing-resource responses
       - throws `WebDAVClientError.invalidResponse` when the server returns no matching resource payload
     */
    public func get(id: String) async throws -> RemoteSyncFile {
        let normalizedID = try Self.normalizedIdentifier(id)
        let files = try await client.propfind(path: try requestPath(for: normalizedID), depth: 0)
        let mappedFiles = try files.map(remoteSyncFile(from:))
        guard let file = mappedFiles.first(where: { $0.id == normalizedID }) else {
            throw WebDAVClientError.invalidResponse
        }
        return file
    }

    /**
     Lists files below one or more parent folders.

     When `modifiedAtLeast` is provided, the adapter uses Android's authoritative WebDAV `SEARCH`
     result directly. Full listings continue to use a shallow `PROPFIND`.

     - Parameters:
       - parentIDs: Parent folder identifiers to search under. `nil` defaults to the configured base folder or DAV root.
       - name: Optional exact filename filter.
       - mimeType: Optional Android-compatible MIME type filter. Folders use `DIR`.
       - modifiedAtLeast: Optional lower-bound timestamp for incremental listing.
     - Returns: Remote files that match the requested filters.
     - Side effects:
       - may create the configured base folder path on first use
       - performs one DAV `PROPFIND` or one `SEARCH` per parent
     - Failure modes:
       - rethrows DAV transport failures from folder creation or listing requests
     */
    public func listFiles(
        parentIDs: [String]? = nil,
        name: String? = nil,
        mimeType: String? = nil,
        modifiedAtLeast: Date? = nil
    ) async throws -> [RemoteSyncFile] {
        let parents: [String]
        if let parentIDs {
            parents = try parentIDs.map(Self.normalizedIdentifier)
        } else {
            parents = [try await defaultParentID()]
        }
        var collected: [RemoteSyncFile] = []

        for parentID in parents {
            let files: [WebDAVFile]
            if let modifiedAtLeast {
                files = try await client.search(
                    path: try requestPath(for: parentID),
                    modifiedAfter: modifiedAtLeast
                )
            } else {
                files = try await client.propfind(path: try requestPath(for: parentID), depth: 1)
            }

            let children = try files
                .map(remoteSyncFile(from:))
                .filter { $0.id != parentID }
            collected.append(contentsOf: children)
        }

        return Self.deduplicatedRemoteFiles(collected).filter { file in
            let nameMatches = name.map { file.name == $0 } ?? true
            let mimeMatches = mimeType.map { file.mimeType == $0 } ?? true
            return nameMatches && mimeMatches
        }
    }

    /**
     Lists direct child folders of the requested parent folder.

     - Parameter parentID: Parent folder identifier.
     - Returns: Child folders represented as `RemoteSyncFile` values with `DIR` MIME types.
     - Side effects: performs a DAV listing request.
     - Failure modes:
       - rethrows DAV transport failures from `listFiles(parentIDs:name:mimeType:modifiedAtLeast:)`
     */
    public func getFolders(parentID: String) async throws -> [RemoteSyncFile] {
        try await listFiles(parentIDs: [parentID], mimeType: Self.folderMimeType)
    }

    /**
     Downloads one remote file payload into memory.

     - Parameter id: Backend-specific file identifier.
     - Returns: Raw file payload bytes.
     - Side effects: performs an authenticated HTTP `GET`.
     - Failure modes:
       - rethrows DAV transport failures from `WebDAVClient.get(path:)`
     */
    public func download(id: String) async throws -> Data {
        try await client.get(path: try requestPath(for: id))
    }

    /**
     Streams one remote file to a bounded local destination.

     - Parameters:
       - id: Backend-specific file identifier.
       - destinationURL: Unique local output file.
       - maximumByteCount: Maximum declared and observed body bytes.
     - Returns: Exact bytes written.
     - Side effects: Performs authenticated HTTP GET and creates `destinationURL`.
     - Throws: DAV transport, filesystem, or bounded-download errors.
     */
    public func download(
        id: String,
        to destinationURL: URL,
        maximumByteCount: Int
    ) async throws -> Int64 {
        try await client.get(
            path: try requestPath(for: id),
            to: destinationURL,
            maximumByteCount: maximumByteCount
        )
    }

    /**
     Creates a remote folder, defaulting to the configured base sync folder or DAV root.

     - Parameters:
       - name: Folder name to create.
       - parentID: Optional parent folder identifier. `nil` uses the configured base sync folder or DAV root.
     - Returns: Metadata for the created folder using Android-compatible `DIR` MIME typing.
     - Side effects:
       - may create the configured base folder path on first use
       - issues DAV `MKCOL` requests for the new folder path
    - Failure modes:
       - rethrows DAV transport failures except that HTTP 405 is treated as "already exists" to match Android's `createFullPath` behavior
     */
    public func createNewFolder(name: String, parentID: String? = nil) async throws -> RemoteSyncFile {
        let validatedName = try Self.validatedSegment(name)
        let resolvedParentID: String
        if let parentID {
            resolvedParentID = try Self.normalizedIdentifier(parentID)
        } else {
            resolvedParentID = try await defaultParentID()
        }
        let folderID = try Self.join(parent: resolvedParentID, child: validatedName)
        try await ensureCollectionExists(id: folderID)
        return RemoteSyncFile(
            id: folderID,
            name: validatedName,
            size: 0,
            timestamp: Self.currentTimestampMilliseconds(),
            parentID: resolvedParentID,
            mimeType: Self.folderMimeType
        )
    }

    /**
     Uploads a local file to the remote backend.

     - Parameters:
       - name: Destination file name.
       - fileURL: Local file URL whose contents will be uploaded.
       - parentID: Parent folder identifier.
       - contentType: MIME type sent with the DAV `PUT`. Defaults to Android's gzip patch type.
     - Returns: Metadata for the uploaded remote file.
     - Side effects:
       - validates and streams the local regular file through an authenticated DAV `PUT`
     - Failure modes:
       - rejects non-regular, replaced, or oversized source files
       - rethrows DAV transport failures from `WebDAVClient.put(path:fileURL:maximumByteCount:contentType:)`
     */
    public func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String = NextCloudSyncAdapter.gzipMimeType
    ) async throws -> RemoteSyncFile {
        let validatedName = try Self.validatedSegment(name)
        let resolvedParentID = try Self.normalizedIdentifier(parentID)
        let fingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
            at: fileURL,
            maximumByteCount: RemoteSyncArchiveStagingService.maximumCompressedInitialBackupByteCount
        )
        let fileID = try Self.join(parent: resolvedParentID, child: validatedName)
        try await client.put(
            path: try requestPath(for: fileID),
            fileURL: fileURL,
            maximumByteCount: RemoteSyncArchiveStagingService.maximumCompressedInitialBackupByteCount,
            contentType: contentType
        )
        return RemoteSyncFile(
            id: fileID,
            name: validatedName,
            size: fingerprint.byteCount,
            timestamp: Self.currentTimestampMilliseconds(),
            parentID: resolvedParentID,
            mimeType: contentType
        )
    }

    /**
     Deletes one remote file or folder.

     - Parameter id: Backend-specific identifier returned by prior adapter calls.
     - Side effects: performs an authenticated DAV `DELETE`.
     - Failure modes:
       - rethrows DAV transport failures from `WebDAVClient.delete(path:)`
     */
    public func delete(id: String) async throws {
        try await client.delete(path: try requestPath(for: id))
    }

    /**
     Verifies whether a sync folder is still owned by this device using Android's secret-marker file.

     - Parameters:
       - syncFolderID: Global sync folder identifier.
       - secretFileName: Previously persisted secret marker filename.
     - Returns: `true` when the marker file still exists in the sync folder; otherwise `false`.
     - Side effects: performs a depth-0 DAV `PROPFIND` for the marker file.
     - Failure modes:
       - returns `false` for HTTP 404-style missing marker responses
       - rethrows all other DAV transport failures because they indicate connectivity or permission issues rather than a clean ownership miss
     */
    public func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        let markerID = try Self.join(parent: syncFolderID, child: secretFileName)
        do {
            _ = try await client.propfind(path: try requestPath(for: markerID), depth: 0)
            return true
        } catch WebDAVClientError.unexpectedStatus(let statusCode) where statusCode == 404 {
            return false
        }
    }

    /**
     Uploads Android's secret marker file and returns the generated filename.

     - Parameters:
       - syncFolderID: Global sync folder identifier that should be marked as owned by this device.
       - deviceIdentifier: Stable device identifier used in the marker filename prefix.
     - Returns: Generated marker filename that callers can persist locally.
     - Side effects: performs an authenticated DAV `PUT` of an empty marker payload.
     - Failure modes:
       - rethrows DAV transport failures from `WebDAVClient.put(path:data:contentType:)`
     */
    public func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        let validatedDeviceIdentifier = try Self.validatedSegment(deviceIdentifier)
        let secretFileName = "device-known-\(validatedDeviceIdentifier)-\(UUID().uuidString)"
        let markerID = try Self.join(parent: syncFolderID, child: secretFileName)
        try await client.put(
            path: try requestPath(for: markerID),
            data: Data(),
            contentType: Self.gzipMimeType
        )
        return secretFileName
    }

    private func defaultParentID() async throws -> String {
        if let ensuredBaseFolderID = try await ensuredBaseFolderID() {
            return ensuredBaseFolderID
        }
        return "/"
    }

    private func ensuredBaseFolderID() async throws -> String? {
        guard let baseFolderPath else {
            return nil
        }
        if let cachedBaseFolderID {
            return cachedBaseFolderID
        }
        try await ensureCollectionExists(id: baseFolderPath)
        cachedBaseFolderID = baseFolderPath
        return baseFolderPath
    }

    private func ensureCollectionExists(id: String) async throws {
        let normalizedID = try Self.normalizedIdentifier(id)
        guard normalizedID != "/" else {
            return
        }

        var current = ""
        for component in normalizedID.split(separator: "/") {
            current += "/\(component)"
            do {
                try await client.mkcol(path: try requestPath(for: current))
            } catch WebDAVClientError.unexpectedStatus(let statusCode) where statusCode == 405 {
                continue
            }
        }
    }

    private func remoteSyncFile(from file: WebDAVFile) throws -> RemoteSyncFile {
        let identifier = try identifier(forServerPath: file.path)
        let normalizedID = try Self.normalizedIdentifier(identifier)
        let parentID = Self.parentIdentifier(for: normalizedID)
        let fallbackName = normalizedID == "/" ? "/" : normalizedID.split(separator: "/").last.map(String.init) ?? "/"
        guard file.contentLength.map({ $0 >= 0 }) ?? true else {
            throw WebDAVClientError.invalidResponse
        }
        let timestamp: Int64
        if let lastModified = file.lastModified {
            let milliseconds = lastModified.timeIntervalSince1970 * 1_000
            guard milliseconds.isFinite,
                  milliseconds >= Double(Int64.min),
                  milliseconds <= Double(Int64.max) else {
                throw WebDAVClientError.invalidResponse
            }
            timestamp = Int64(milliseconds.rounded(.towardZero))
        } else {
            timestamp = 0
        }
        return RemoteSyncFile(
            id: normalizedID,
            name: fallbackName,
            size: file.contentLength ?? 0,
            timestamp: timestamp,
            parentID: parentID,
            mimeType: file.isDirectory ? Self.folderMimeType : (file.contentType ?? "application/octet-stream")
        )
    }

    private func requestPath(for identifier: String) throws -> String {
        let normalizedID = try Self.normalizedIdentifier(identifier)
        if normalizedID == "/" {
            return ""
        }
        return String(normalizedID.dropFirst())
    }

    private func identifier(forServerPath serverPath: String) throws -> String {
        let normalizedServerPath = try Self.normalizedIdentifier(serverPath)
        guard davBasePath == "/"
                || normalizedServerPath == davBasePath
                || normalizedServerPath.hasPrefix(davBasePath + "/") else {
            throw WebDAVClientError.untrustedServerPath
        }
        if davBasePath == "/" { return normalizedServerPath }
        let suffix = String(normalizedServerPath.dropFirst(davBasePath.count))
        return suffix.isEmpty ? "/" : try Self.normalizedIdentifier(suffix)
    }

    private static func normalizedOptionalIdentifier(_ value: String?) throws -> String? {
        var normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalized.hasPrefix("/") { normalized.removeFirst() }
        if normalized.hasSuffix("/") { normalized.removeLast() }
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try normalizedIdentifier(normalized)
    }

    private static func normalizedIdentifier(_ value: String) throws -> String {
        let relativePath = try WebDAVPathValidator.canonicalRelativePath(value)
        return relativePath.isEmpty ? "/" : "/\(relativePath)"
    }

    private static func parentIdentifier(for identifier: String) -> String {
        guard identifier != "/" else {
            return "/"
        }
        let components = identifier.split(separator: "/")
        guard components.count > 1 else {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private static func join(parent: String, child: String) throws -> String {
        let normalizedParent = try normalizedIdentifier(parent)
        let validatedChild = try validatedSegment(child)
        return normalizedParent == "/" ? "/\(validatedChild)" : "\(normalizedParent)/\(validatedChild)"
    }

    /** Validates one exact remote object name without accepting path separators. */
    private static func validatedSegment(_ value: String) throws -> String {
        let decoded = try WebDAVPathValidator.canonicalRelativePath(value)
        guard !decoded.isEmpty, !decoded.contains("/") else {
            throw WebDAVClientError.invalidPath
        }
        return decoded
    }

    /** Collapses repeated DAV rows by canonical path using deterministic metadata precedence. */
    private static func deduplicatedWebDAVFiles(_ files: [WebDAVFile]) -> [WebDAVFile] {
        var byPath: [String: WebDAVFile] = [:]
        for file in files {
            if let current = byPath[file.path] {
                byPath[file.path] = preferredWebDAVFile(current, file)
            } else {
                byPath[file.path] = file
            }
        }
        return byPath.values.sorted { $0.path < $1.path }
    }

    /** Collapses overlapping parent/search rows by identifier with stable metadata precedence. */
    private static func deduplicatedRemoteFiles(_ files: [RemoteSyncFile]) -> [RemoteSyncFile] {
        var byIdentifier: [String: RemoteSyncFile] = [:]
        for file in files {
            if let current = byIdentifier[file.id] {
                byIdentifier[file.id] = preferredRemoteFile(current, file)
            } else {
                byIdentifier[file.id] = file
            }
        }
        return byIdentifier.values.sorted(by: remoteFilePrecedes)
    }

    /** Selects a stable DAV metadata row when SEARCH and PROPFIND repeat one path. */
    private static func preferredWebDAVFile(_ lhs: WebDAVFile, _ rhs: WebDAVFile) -> WebDAVFile {
        let lhsTimestamp = lhs.lastModified?.timeIntervalSince1970 ?? 0
        let rhsTimestamp = rhs.lastModified?.timeIntervalSince1970 ?? 0
        if lhsTimestamp != rhsTimestamp { return lhsTimestamp > rhsTimestamp ? lhs : rhs }
        if lhs.contentLength != rhs.contentLength {
            return (lhs.contentLength ?? -1) > (rhs.contentLength ?? -1) ? lhs : rhs
        }
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory ? lhs : rhs }
        if lhs.contentType != rhs.contentType {
            return (lhs.contentType ?? "") > (rhs.contentType ?? "") ? lhs : rhs
        }
        if lhs.displayName != rhs.displayName {
            return lhs.displayName > rhs.displayName ? lhs : rhs
        }
        if lhs.href != rhs.href { return lhs.href > rhs.href ? lhs : rhs }
        let lhsSource = lhs.sourceURL?.absoluteString ?? ""
        let rhsSource = rhs.sourceURL?.absoluteString ?? ""
        return lhsSource >= rhsSource ? lhs : rhs
    }

    /** Selects the deterministic newest metadata row for one canonical remote identifier. */
    private static func preferredRemoteFile(_ lhs: RemoteSyncFile, _ rhs: RemoteSyncFile) -> RemoteSyncFile {
        remoteFilePrecedes(lhs, rhs) ? rhs : lhs
    }

    /** Defines a total ordering for stable duplicate collapse and caller-visible listings. */
    private static func remoteFilePrecedes(_ lhs: RemoteSyncFile, _ rhs: RemoteSyncFile) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.parentID != rhs.parentID { return lhs.parentID < rhs.parentID }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        if lhs.size != rhs.size { return lhs.size < rhs.size }
        return lhs.mimeType < rhs.mimeType
    }

    private static func currentTimestampMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/**
 Adds atomic create-only file publication for remote patch reconciliation.

 Nextcloud receives the exact validated archive file through WebDAV `PUT` with `If-None-Match: *`.
 HTTP 412 remains a distinct occupied-destination result so callers can re-list and verify the winning
 bytes; the adapter never retries that request as an unconditional upload.
 */
extension NextCloudSyncAdapter: RemoteSyncConditionalFileUploading {
    /**
     Creates one remote file only when its exact destination does not already exist.

     - Parameters:
       - name: Exact destination filename.
       - fileURL: Durable validated archive file.
       - maximumByteCount: Maximum accepted archive bytes.
       - parentID: Remote parent folder identifier.
       - contentType: MIME type sent with the DAV `PUT`.
     - Returns: `.created` with synthesized remote metadata after a successful create, or
       `.alreadyExists` when WebDAV reports HTTP 412.
     - Side effects: Performs one authenticated WebDAV `PUT` with `If-None-Match: *`, then reads the
       exact destination after HTTP 201 to verify the published bytes.
     - Throws: Cancellation, URL loading, invalid-response, and unexpected-status failures from
       `WebDAVClient.putIfAbsent(path:fileURL:maximumByteCount:contentType:)`.
     - Important: The method never calls the adapter's unconditional `upload` API.
     */
    public func uploadIfAbsent(
        name: String,
        fileURL: URL,
        maximumByteCount: Int,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncConditionalUploadResult {
        try Task.checkCancellation()
        let validatedName = try Self.validatedSegment(name)
        let resolvedParentID = try Self.normalizedIdentifier(parentID)
        let fileID = try Self.join(parent: resolvedParentID, child: validatedName)
        let fingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        let result = try await client.putIfAbsent(
            path: try requestPath(for: fileID),
            fileURL: fileURL,
            maximumByteCount: maximumByteCount,
            contentType: contentType
        )
        switch result {
        case .created:
            return .created(
                RemoteSyncFile(
                    id: fileID,
                    name: validatedName,
                    size: fingerprint.byteCount,
                    timestamp: Self.currentTimestampMilliseconds(),
                    parentID: resolvedParentID,
                    mimeType: contentType
                )
            )
        case .alreadyExists:
            return .alreadyExists
        }
    }
}
