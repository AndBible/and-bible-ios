// WebDAVClient.swift — WebDAV transport foundation for cross-platform sync

import Darwin
import Foundation

/**
 Describes one file or collection returned by a WebDAV `PROPFIND` or `SEARCH` response.

 The payload intentionally preserves both the raw `href` reported by the server and a normalized
 `path` derived from that `href`. Sync layers can use the normalized path for follow-up `GET`,
 `PUT`, `MKCOL`, and `DELETE` operations without reparsing XML.
 */
public struct WebDAVFile: Sendable, Equatable {
    /// Raw WebDAV `href` value returned by the server, percent-decoded when possible.
    public let href: String

    /// Normalized URL path derived from `href`.
    public let path: String

    /// Human-readable display name for the resource.
    public let displayName: String

    /// Whether the resource is a directory/collection.
    public let isDirectory: Bool

    /// Optional content length reported by the server.
    public let contentLength: Int64?

    /// Optional MIME type reported by the server.
    public let contentType: String?

    /// Optional last-modified timestamp reported by the server.
    public let lastModified: Date?

    /// Absolute response URL retained for origin validation when the server returned one.
    let sourceURL: URL?

    /**
     Creates one parsed WebDAV resource descriptor.

     - Parameters:
       - href: Raw `href` value from the server response.
       - path: Normalized URL path derived from `href`.
       - displayName: Human-readable file or folder name.
       - isDirectory: Whether the resource represents a collection.
       - contentLength: Optional byte size for file resources.
       - contentType: Optional MIME type.
       - lastModified: Optional last-modified timestamp.
     */
    public init(
        href: String,
        path: String,
        displayName: String,
        isDirectory: Bool,
        contentLength: Int64?,
        contentType: String?,
        lastModified: Date?
    ) {
        self.init(
            href: href,
            path: path,
            displayName: displayName,
            isDirectory: isDirectory,
            contentLength: contentLength,
            contentType: contentType,
            lastModified: lastModified,
            sourceURL: nil
        )
    }

    /** Creates a parsed resource while retaining an absolute server origin for transport validation. */
    init(
        href: String,
        path: String,
        displayName: String,
        isDirectory: Bool,
        contentLength: Int64?,
        contentType: String?,
        lastModified: Date?,
        sourceURL: URL?
    ) {
        self.href = href
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.contentLength = contentLength
        self.contentType = contentType
        self.lastModified = lastModified
        self.sourceURL = sourceURL
    }
}

/**
 Errors emitted by the WebDAV transport layer.
 */
public enum WebDAVClientError: Error, Equatable {
    /// The response was not an `HTTPURLResponse`.
    case invalidResponse

    /// The server returned an unexpected HTTP status code.
    case unexpectedStatus(Int)

    /// XML multistatus payload parsing failed.
    case invalidMultiStatusXML

    /// The WebDAV server URL could not be normalized into a valid request URL.
    case invalidURL

    /// A caller-supplied identifier contains traversal, separator, query, or malformed encoding data.
    case invalidPath

    /// A server-provided DAV `href` is malformed, outside the configured root, or on another origin.
    case untrustedServerPath

    /// A DAV request attempted an HTTP redirect, which is never followed with Basic credentials.
    case redirectRejected(Int)

    /// A successful conditional response could not be confirmed by exact destination readback.
    case conditionalUploadVerificationFailed
}

/**
 Canonicalizes DAV path components without allowing separators or traversal.

 Caller identifiers are already decoded logical paths and are validated without a second percent
 decoding pass. URL and server `href` paths are decoded exactly once through their dedicated entry
 points. Foundation then percent-encodes logical names while constructing requests, preserving valid
 literal `%`, `?`, and `#` filename characters without allowing them to become URL syntax.
 */
enum WebDAVPathValidator {
    /// Conservative filesystem-compatible ceiling for one decoded DAV path component.
    private static let maximumSegmentByteCount = 255

    /// Maximum encoded DAV path accepted before URL or XML construction.
    private static let maximumPathByteCount = 4_096

    /** Parsed and validated server `href` fields used by transport-level root checks. */
    struct ParsedHref {
        /// Percent-decoded representation exposed through `WebDAVFile.href`.
        let href: String

        /// Canonical decoded absolute path, preserving a meaningful trailing collection slash.
        let path: String

        /// Absolute URL when the server supplied an absolute `href`; otherwise `nil`.
        let sourceURL: URL?
    }

    /**
     Canonicalizes a caller-supplied relative DAV request path.

     - Parameter value: Empty/root or slash-separated relative path.
     - Returns: Decoded relative path without leading or trailing separators.
     - Side effects: none.
     - Throws: `WebDAVClientError.invalidPath` for malformed or unsafe components.
     */
    static func canonicalRelativePath(_ value: String) throws -> String {
        guard value.utf8.count <= maximumPathByteCount else {
            throw WebDAVClientError.invalidPath
        }
        if value.isEmpty || value == "/" { return "" }
        guard !value.hasPrefix("//") else { throw WebDAVClientError.invalidPath }
        var candidate = value
        if candidate.hasPrefix("/") { candidate.removeFirst() }
        if candidate.hasSuffix("/") { candidate.removeLast() }
        guard !candidate.isEmpty else { return "" }
        return try validatedDecodedSegments(in: candidate, error: .invalidPath).joined(separator: "/")
    }

    /**
     Canonicalizes one absolute URL path for root containment comparisons.

     - Parameter percentEncodedPath: Absolute path whose segments may contain percent escapes.
     - Returns: Decoded absolute path without a trailing slash except for `/`.
     - Side effects: none.
     - Throws: The supplied public error when the path is malformed or unsafe.
     */
    static func canonicalAbsolutePath(
        _ percentEncodedPath: String,
        error: WebDAVClientError
    ) throws -> String {
        guard percentEncodedPath.utf8.count <= maximumPathByteCount,
              percentEncodedPath.hasPrefix("/"),
              !percentEncodedPath.hasPrefix("//") else {
            throw error
        }
        let body = String(percentEncodedPath.dropFirst())
        if body.isEmpty { return "/" }
        var candidate = body
        if candidate.hasSuffix("/") { candidate.removeLast() }
        guard !candidate.isEmpty else { return "/" }
        return "/" + (try decodedSegments(in: candidate, error: error)).joined(separator: "/")
    }

    /**
     Validates one already-decoded absolute DAV path without interpreting percent signs again.

     - Parameters:
       - value: Decoded absolute path returned by the parser or adapter.
       - error: Public error to throw for malformed path semantics.
     - Returns: Canonical decoded path without a trailing slash except for `/`.
     - Side Effects: none.
     - Throws: `error` for traversal, empty components, separators, or control characters.
     */
    static func canonicalDecodedAbsolutePath(
        _ value: String,
        error: WebDAVClientError
    ) throws -> String {
        guard value.utf8.count <= maximumPathByteCount,
              value.hasPrefix("/"),
              !value.hasPrefix("//") else {
            throw error
        }
        let body = String(value.dropFirst())
        if body.isEmpty { return "/" }
        var candidate = body
        if candidate.hasSuffix("/") { candidate.removeLast() }
        guard !candidate.isEmpty else { return "/" }
        return "/" + (try validatedDecodedSegments(in: candidate, error: error))
            .joined(separator: "/")
    }

    /**
     Validates one server-provided DAV `href` before it can become a remote identifier.

     - Parameter value: Raw XML text from a DAV `href` element.
     - Returns: Decoded path plus optional absolute origin metadata.
     - Side effects: none.
     - Throws: `WebDAVClientError.untrustedServerPath` for malformed URI or path semantics.
     */
    static func parseServerHref(_ value: String) throws -> ParsedHref {
        guard !value.isEmpty,
              !value.hasPrefix("//"),
              let components = URLComponents(string: value),
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil else {
            throw WebDAVClientError.untrustedServerPath
        }

        let isAbsolute = components.scheme != nil || components.host != nil
        if isAbsolute {
            guard let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false else {
                throw WebDAVClientError.untrustedServerPath
            }
        } else {
            guard value.hasPrefix("/") else {
                throw WebDAVClientError.untrustedServerPath
            }
        }

        let trailingSlash = components.percentEncodedPath.count > 1
            && components.percentEncodedPath.hasSuffix("/")
        var path = try canonicalAbsolutePath(
            components.percentEncodedPath,
            error: .untrustedServerPath
        )
        if trailingSlash, path != "/" { path += "/" }
        guard let decodedHref = value.removingPercentEncoding else {
            throw WebDAVClientError.untrustedServerPath
        }
        return ParsedHref(
            href: decodedHref,
            path: path,
            sourceURL: isAbsolute ? components.url : nil
        )
    }

    /** Decodes each percent-encoded component once, then validates decoded path semantics. */
    private static func decodedSegments(
        in value: String,
        error: WebDAVClientError
    ) throws -> [String] {
        let rawSegments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawSegments.isEmpty, rawSegments.allSatisfy({ !$0.isEmpty }) else { throw error }
        return try rawSegments.map { raw in
            guard let decoded = String(raw).removingPercentEncoding else {
                throw error
            }
            return try validatedDecodedSegment(decoded, error: error)
        }
    }

    /** Validates every component in one already-decoded slash-separated path body. */
    private static func validatedDecodedSegments(
        in value: String,
        error: WebDAVClientError
    ) throws -> [String] {
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else { throw error }
        return try segments.map { try validatedDecodedSegment(String($0), error: error) }
    }

    /** Rejects only characters that can change decoded path hierarchy or filesystem safety. */
    private static func validatedDecodedSegment(
        _ value: String,
        error: WebDAVClientError
    ) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumSegmentByteCount,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw error
        }
        return value
    }
}

/**
 Reports whether a conditional WebDAV `PUT` created its destination or lost a create race.

 The result keeps HTTP 412 separate from transport failures so higher-level reconciliation can
 inspect the winning remote bytes without treating the race as permission to overwrite them.
 */
public enum WebDAVConditionalPutResult: Sendable, Equatable {
    /// The server accepted the request and created the destination from the supplied bytes.
    case created

    /// The server rejected `If-None-Match: *` because a resource already occupies the destination.
    case alreadyExists
}

/**
 Parses WebDAV multistatus XML into strongly typed `WebDAVFile` values.

 The parser accepts both `PROPFIND` and `SEARCH` responses because both use the same DAV
 multistatus envelope. It evaluates namespace URIs and DAV hierarchy rather than trusting local
 names, and applies properties only from successful `propstat` elements.
 */
public enum WebDAVMultiStatusParser {
    /**
     Parses a WebDAV multistatus response body.

     - Parameter data: XML payload returned by a WebDAV `PROPFIND` or `SEARCH` request.
     - Returns: Parsed resources in the order returned by the server.

     Failure modes:
     - throws `WebDAVClientError.invalidMultiStatusXML` when the XML payload cannot be parsed
     */
    public static func parse(data: Data) throws -> [WebDAVFile] {
        let delegate = MultiStatusXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let parsingError = delegate.parsingError {
            throw parsingError
        }
        guard parsed else {
            throw WebDAVClientError.invalidMultiStatusXML
        }
        return delegate.files
    }
}

/**
 Minimal WebDAV client used by future non-CloudKit sync backends.

 This client focuses on transport and XML parsing only. It does not encode any Android patch-sync
 semantics on top of WebDAV; higher layers remain responsible for folder layout, patch numbering,
 and merge policy.

 Side effects:
 - network methods perform authenticated `URLSession` requests against the configured server
 - `putIfAbsent` adds `If-None-Match: *` and reports HTTP 412 without retrying unconditionally
 - `propfind` and `search` parse DAV multistatus XML into `WebDAVFile` values

 - Important: Credentials are encoded as HTTP Basic auth headers on each request. Requests are
   restricted to HTTPS and redirects are rejected before follow-up transport, so credentials never
   cross origins or downgrade to plaintext HTTP. Secret storage remains outside this type.
 - Important: This type is `@unchecked Sendable` because all stored properties are immutable after
   initialization and `URLSession` is safe to use concurrently from multiple tasks.
 */
public final class WebDAVClient: @unchecked Sendable {
    /// Default ceiling for XML, small-object, and status response bodies retained in memory.
    public static let defaultMaximumInMemoryResponseByteCount = 64 * 1_024 * 1_024

    private let baseURL: URL
    private let authorizationHeader: String
    private let session: URLSession
    private let maximumInMemoryResponseByteCount: Int

    /**
     Creates a WebDAV client for one server root.

     - Parameters:
       - baseURL: Base DAV endpoint, for example `https://host/remote.php/dav/files/user`.
       - username: Username used for HTTP Basic authentication.
       - password: Password or app password used for HTTP Basic authentication.
       - session: URL session used for transport. Tests can inject a custom configuration.
       - maximumInMemoryResponseByteCount: Hard actual-byte ceiling for DAV XML and in-memory objects.
     */
    public init(
        baseURL: URL,
        username: String,
        password: String,
        session: URLSession = .shared,
        maximumInMemoryResponseByteCount: Int = WebDAVClient.defaultMaximumInMemoryResponseByteCount
    ) {
        self.baseURL = baseURL
        self.session = session
        self.maximumInMemoryResponseByteCount = maximumInMemoryResponseByteCount
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        self.authorizationHeader = "Basic \(credentials)"
    }

    /**
     Verifies server connectivity by issuing a root-level `PROPFIND`.

     - Returns: Parsed resources returned by the server for the requested root path.
     */
    public func testConnection() async throws -> [WebDAVFile] {
        try await propfind(path: "", depth: 0)
    }

    /**
     Lists files or folders at a given DAV path using `PROPFIND`.

     - Parameters:
       - path: Relative path under `baseURL`.
       - depth: WebDAV depth header value, typically `0` or `1`.
     - Returns: Parsed WebDAV resources from the server multistatus response.
     */
    public func propfind(path: String, depth: Int = 1) async throws -> [WebDAVFile] {
        let request = try makeRequest(
            path: path,
            method: "PROPFIND",
            headers: [
                "Depth": String(depth),
                "Content-Type": "application/xml; charset=utf-8",
            ],
            body: Data(
                """
                <?xml version="1.0" encoding="utf-8" ?>
                <d:propfind xmlns:d="DAV:">
                  <d:prop>
                    <d:displayname />
                    <d:getcontentlength />
                    <d:getcontenttype />
                    <d:getlastmodified />
                    <d:resourcetype />
                  </d:prop>
                </d:propfind>
                """.utf8
            )
        )
        let data = try await performDataRequest(request, allowedStatusCodes: [207])
        return try validatedServerFiles(WebDAVMultiStatusParser.parse(data: data))
    }

    /**
     Downloads a raw file payload using HTTP `GET`.

     - Parameter path: Relative DAV path to download.
     - Returns: Raw response body.
     */
    public func get(path: String) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET")
        return try await performDataRequest(request, allowedStatusCodes: [200])
    }

    /**
     Streams a raw file payload into a bounded local file using HTTP `GET`.

     - Parameters:
       - path: Relative DAV path to download.
       - destinationURL: Unique local output file.
       - maximumByteCount: Maximum declared and observed response bytes.
     - Returns: Exact bytes written.
     - Side effects: Performs authenticated network I/O and creates `destinationURL`.
     - Throws: Transport/status/filesystem errors or `payloadTooLarge`; partial output is removed.
     */
    public func get(
        path: String,
        to destinationURL: URL,
        maximumByteCount: Int
    ) async throws -> Int64 {
        guard maximumByteCount >= 0 else {
            throw RemoteSyncBoundedDownloadError.payloadTooLarge(0)
        }
        let request = try makeRequest(path: path, method: "GET")
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: WebDAVRejectingRedirectDelegate.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        try validateFinalResponseURL(http.url, for: request)
        if (300..<400).contains(http.statusCode) {
            throw WebDAVClientError.redirectRejected(http.statusCode)
        }
        guard http.statusCode == 200 else {
            throw WebDAVClientError.unexpectedStatus(http.statusCode)
        }
        let declaredLength = response.expectedContentLength
        guard declaredLength < 0 || declaredLength <= Int64(maximumByteCount) else {
            throw RemoteSyncBoundedDownloadError.payloadTooLarge(declaredLength)
        }
        let descriptor = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown)
        }
        var createdStatus = stat()
        guard Darwin.fstat(descriptor, &createdStatus) == 0,
              (createdStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw CocoaError(.fileWriteUnknown)
        }
        let createdDevice = UInt64(createdStatus.st_dev)
        let createdInode = UInt64(createdStatus.st_ino)

        do {
            defer { Darwin.close(descriptor) }
            var count: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                guard count < Int64(maximumByteCount) else {
                    throw RemoteSyncBoundedDownloadError.payloadTooLarge(count + 1)
                }
                buffer.append(byte)
                count += 1
                if buffer.count == 64 * 1_024 {
                    try Task.checkCancellation()
                    try Self.writeAll(buffer, to: descriptor)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try Self.writeAll(buffer, to: descriptor)
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            var finalStatus = stat()
            guard Darwin.fstat(descriptor, &finalStatus) == 0,
                  (finalStatus.st_mode & S_IFMT) == S_IFREG,
                  finalStatus.st_size == off_t(count),
                  Self.pathNamesFile(
                      destinationURL,
                      device: createdDevice,
                      inode: createdInode
                  ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return count
        } catch {
            Self.removeFileIfNamed(
                destinationURL,
                device: createdDevice,
                inode: createdInode
            )
            throw error
        }
    }

    /**
     Uploads a file payload using HTTP `PUT`.

     - Parameters:
       - path: Relative DAV destination path.
       - data: Raw payload to upload.
       - contentType: MIME type for the uploaded payload.
     */
    public func put(path: String, data: Data, contentType: String = "application/octet-stream") async throws {
        let request = try makeRequest(
            path: path,
            method: "PUT",
            headers: ["Content-Type": contentType],
            body: data
        )
        _ = try await performDataRequest(request, allowedStatusCodes: [200, 201, 204])
    }

    /**
     Uploads one bounded regular file without materializing archive bytes in memory.

     - Parameters:
       - path: Relative DAV destination path.
       - fileURL: Existing no-follow regular source file.
       - maximumByteCount: Maximum accepted source bytes.
       - contentType: MIME type sent with the upload.
     - Side Effects: Performs authenticated HTTPS upload from `fileURL`.
     - Throws: Cancellation, local-file validation, redirect, transport, or unexpected-status errors.
     */
    public func put(
        path: String,
        fileURL: URL,
        maximumByteCount: Int,
        contentType: String = "application/octet-stream"
    ) async throws {
        let request = try makeRequest(
            path: path,
            method: "PUT",
            headers: ["Content-Type": contentType]
        )
        _ = try await performBoundedFileUploadRequest(
            request,
            fileURL: fileURL,
            maximumByteCount: maximumByteCount,
            allowedStatusCodes: [200, 201, 204]
        )
    }

    /**
     Creates a file only when no resource already exists at the destination path.

     - Parameters:
       - path: Relative DAV destination path.
       - fileURL: Durable local payload to create remotely.
       - maximumByteCount: Maximum accepted source and verification bytes.
       - contentType: MIME type for the uploaded payload.
     - Returns: `.created` for a successful create, or `.alreadyExists` when the server returns
       HTTP 412 for the `If-None-Match: *` precondition.
     - Side effects: Performs one authenticated HTTP `PUT`, followed by an exact-destination `GET`
       after HTTP 201; it never retries without the precondition.
     - Throws:
       - `CancellationError` when the calling task is cancelled before or during transport
       - `WebDAVClientError.invalidResponse` for a non-HTTP response
       - `WebDAVClientError.unexpectedStatus` for statuses other than 200, 201, 204, or 412
       - `WebDAVClientError.redirectRejected` when either request receives a redirect
       - `WebDAVClientError.conditionalUploadVerificationFailed` when readback bytes differ
       - URL loading errors from the configured session
     - Important: HTTP 200/204 are ambiguous because a noncompliant server may have ignored
       `If-None-Match`; they return `.alreadyExists` so higher-level reconciliation must re-list and
       verify the occupied destination. A returned `.alreadyExists` never proves bytes match; callers
       must download and reconcile the occupied destination before accepting it.
     */
    public func putIfAbsent(
        path: String,
        fileURL: URL,
        maximumByteCount: Int,
        contentType: String = "application/octet-stream"
    ) async throws -> WebDAVConditionalPutResult {
        try Task.checkCancellation()
        let request = try makeRequest(
            path: path,
            method: "PUT",
            headers: [
                "Content-Type": contentType,
                "If-None-Match": "*",
            ],
            body: nil
        )
        let http = try await performBoundedFileUploadRequest(
            request,
            fileURL: fileURL,
            maximumByteCount: maximumByteCount,
            allowedStatusCodes: [200, 201, 204, 412],
            validatesSourceAfterUpload: true
        )
        try Task.checkCancellation()
        switch http.statusCode {
        case 201:
            let expectedFingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
                at: fileURL,
                maximumByteCount: maximumByteCount
            )
            let verificationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                "webdav-conditional-verification-\(UUID().uuidString)"
            )
            defer { try? FileManager.default.removeItem(at: verificationURL) }
            _ = try await get(
                path: path,
                to: verificationURL,
                maximumByteCount: maximumByteCount
            )
            let verifiedFingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
                at: verificationURL,
                maximumByteCount: maximumByteCount
            )
            guard verifiedFingerprint == expectedFingerprint else {
                throw WebDAVClientError.conditionalUploadVerificationFailed
            }
            return .created
        case 200, 204, 412:
            return .alreadyExists
        default:
            throw WebDAVClientError.unexpectedStatus(http.statusCode)
        }
    }

    /**
     Creates a remote directory using `MKCOL`.

     - Parameter path: Relative DAV collection path to create.
     */
    public func mkcol(path: String) async throws {
        let request = try makeRequest(path: path, method: "MKCOL")
        _ = try await performDataRequest(request, allowedStatusCodes: [201])
    }

    /**
     Deletes a remote file or directory using HTTP `DELETE`.

     - Parameter path: Relative DAV path to remove.
     */
    public func delete(path: String) async throws {
        let request = try makeRequest(path: path, method: "DELETE")
        _ = try await performDataRequest(request, allowedStatusCodes: [200, 204])
    }

    /**
     Performs a WebDAV `SEARCH` for resources modified after a given timestamp.

     - Parameters:
       - path: Relative DAV collection path to search under.
       - modifiedAfter: Lower bound for `getlastmodified`.
     - Returns: Parsed WebDAV resources from the multistatus response.
     */
    public func search(path: String, modifiedAfter: Date) async throws -> [WebDAVFile] {
        let target = try searchTarget(for: path)
        let body = searchBody(scopeHref: target.scopeHref, modifiedAfter: modifiedAfter)
        let request = try makeRequest(
            url: target.requestURL,
            method: "SEARCH",
            headers: ["Content-Type": "text/xml; charset=utf-8"],
            body: Data(body.utf8)
        )
        let data = try await performDataRequest(request, allowedStatusCodes: [200, 207])
        return try validatedServerFiles(WebDAVMultiStatusParser.parse(data: data))
    }

    private func makeRequest(
        path: String,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        try makeRequest(
            url: resolvedURL(for: path),
            method: method,
            headers: headers,
            body: body
        )
    }

    /** Builds one authenticated request only after validating its exact HTTPS DAV target. */
    private func makeRequest(
        url: URL,
        method: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) throws -> URLRequest {
        guard try isPermittedRequestURL(url) else {
            throw WebDAVClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }

    private func resolvedURL(for path: String) throws -> URL {
        let relativePath = try WebDAVPathValidator.canonicalRelativePath(path)
        var (components, normalizedBasePath) = try validatedBaseComponents()
        let finalPath: String
        if relativePath.isEmpty {
            finalPath = normalizedBasePath
        } else if normalizedBasePath == "/" {
            finalPath = "/\(relativePath)"
        } else {
            finalPath = "\(normalizedBasePath)/\(relativePath)"
        }
        components.path = finalPath
        guard let url = components.url,
              try isWithinConfiguredRoot(url) else {
            throw WebDAVClientError.invalidURL
        }
        return url
    }

    private func performDataRequest(
        _ request: URLRequest,
        allowedStatusCodes: Set<Int>
    ) async throws -> Data {
        try await performBoundedDataRequest(
            request,
            allowedStatusCodes: allowedStatusCodes,
            maximumByteCount: maximumInMemoryResponseByteCount
        ).0
    }

    /** Streams one response into bounded memory and validates status plus final DAV containment. */
    private func performBoundedDataRequest(
        _ request: URLRequest,
        allowedStatusCodes: Set<Int>,
        maximumByteCount: Int
    ) async throws -> (Data, HTTPURLResponse) {
        guard maximumByteCount >= 0 else {
            throw RemoteSyncBoundedDownloadError.payloadTooLarge(0)
        }
        let (bytes, response) = try await session.bytes(
            for: request,
            delegate: WebDAVRejectingRedirectDelegate.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        try validateFinalResponseURL(http.url, for: request)
        if (300..<400).contains(http.statusCode) {
            throw WebDAVClientError.redirectRejected(http.statusCode)
        }
        guard allowedStatusCodes.contains(http.statusCode) else {
            throw WebDAVClientError.unexpectedStatus(http.statusCode)
        }
        let declaredLength = response.expectedContentLength
        guard declaredLength < 0 || declaredLength <= Int64(maximumByteCount) else {
            throw RemoteSyncBoundedDownloadError.payloadTooLarge(declaredLength)
        }

        var data = Data()
        if declaredLength > 0, let capacity = Int(exactly: declaredLength) {
            data.reserveCapacity(capacity)
        }
        for try await byte in bytes {
            guard data.count < maximumByteCount else {
                throw RemoteSyncBoundedDownloadError.payloadTooLarge(Int64(data.count) + 1)
            }
            data.append(byte)
        }
        return (data, http)
    }

    /** Uploads a validated file with redirect rejection and revalidates its exact path identity. */
    private func performBoundedFileUploadRequest(
        _ request: URLRequest,
        fileURL: URL,
        maximumByteCount: Int,
        allowedStatusCodes: Set<Int>,
        validatesSourceAfterUpload: Bool = true
    ) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let initialFingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
        let (responseData, response) = try await session.upload(
            for: request,
            fromFile: fileURL,
            delegate: WebDAVRejectingRedirectDelegate.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw WebDAVClientError.invalidResponse
        }
        try validateFinalResponseURL(http.url, for: request)
        if (300..<400).contains(http.statusCode) {
            throw WebDAVClientError.redirectRejected(http.statusCode)
        }
        guard allowedStatusCodes.contains(http.statusCode) else {
            throw WebDAVClientError.unexpectedStatus(http.statusCode)
        }
        guard responseData.count <= maximumInMemoryResponseByteCount else {
            throw RemoteSyncBoundedDownloadError.payloadTooLarge(Int64(responseData.count))
        }
        if validatesSourceAfterUpload {
            let finalFingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
                at: fileURL,
                maximumByteCount: maximumByteCount
            )
            guard finalFingerprint == initialFingerprint else {
                throw RemoteSyncBoundedFileError.unsafeInput
            }
        }
        try Task.checkCancellation()
        return http
    }

    private func searchBody(scopeHref: String, modifiedAfter: Date) -> String {
        return """
        <?xml version="1.0" encoding="utf-8" ?>
        <d:searchrequest xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:basicsearch>
            <d:select>
              <d:prop>
                <d:displayname />
                <oc:size />
                <d:getcontenttype />
                <d:getlastmodified />
              </d:prop>
            </d:select>
            <d:from>
              <d:scope>
                <d:href>\(Self.xmlEscaped(scopeHref))</d:href>
                <d:depth>infinity</d:depth>
              </d:scope>
            </d:from>
            <d:where>
              <d:gt>
                <d:prop><d:getlastmodified /></d:prop>
                <d:literal>\(Self.iso8601SearchString(from: modifiedAfter))</d:literal>
              </d:gt>
            </d:where>
            <d:orderby>
              <d:order>
                <d:prop><d:getlastmodified /></d:prop>
                <d:ascending />
              </d:order>
            </d:orderby>
          </d:basicsearch>
        </d:searchrequest>
        """
    }

    /** Resolves Android's DAV-root SEARCH target and `/files/user/folder` scope href. */
    private func searchTarget(for path: String) throws -> (requestURL: URL, scopeHref: String) {
        let relativePath = try WebDAVPathValidator.canonicalRelativePath(path)
        var (components, rootPath) = try validatedBaseComponents()
        let rootComponents = rootPath.split(separator: "/").map(String.init)
        if let remoteIndex = rootComponents.indices.first(where: { index in
            index + 2 < rootComponents.count
                && rootComponents[index] == "remote.php"
                && rootComponents[index + 1] == "dav"
                && rootComponents[index + 2] == "files"
        }) {
            let davEndIndex = remoteIndex + 1
            let davRootComponents = Array(rootComponents[...davEndIndex])
            let suffixStart = davEndIndex + 1
            let baseScopeComponents = suffixStart < rootComponents.count
                ? Array(rootComponents[suffixStart...])
                : []
            let requestedScopeComponents = relativePath.isEmpty
                ? []
                : relativePath.split(separator: "/").map(String.init)
            components.path = "/" + davRootComponents.joined(separator: "/")
            guard let requestURL = components.url else {
                throw WebDAVClientError.invalidURL
            }
            return (
                requestURL,
                "/" + (baseScopeComponents + requestedScopeComponents).joined(separator: "/")
            )
        }

        let requestURL = try resolvedURL(for: "")
        let scopePath = relativePath.isEmpty
            ? rootPath
            : (rootPath == "/" ? "/\(relativePath)" : "\(rootPath)/\(relativePath)")
        return (requestURL, scopePath)
    }

    /** Returns validated base URL components and their canonical decoded DAV root path. */
    private func validatedBaseComponents() throws -> (URLComponents, String) {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw WebDAVClientError.invalidURL
        }
        let rootPath = try WebDAVPathValidator.canonicalAbsolutePath(
            components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            error: .invalidURL
        )
        return (components, rootPath)
    }

    /** Allows ordinary descendants plus Android's exact DAV-root SEARCH endpoint. */
    private func isPermittedRequestURL(_ url: URL) throws -> Bool {
        if try isWithinConfiguredRoot(url) { return true }
        let target = try searchTarget(for: "")
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(
                url: target.requestURL,
                resolvingAgainstBaseURL: false
              ),
              candidate.user == nil,
              candidate.password == nil,
              candidate.query == nil,
              candidate.fragment == nil,
              Self.sameOrigin(candidate, expected) else {
            return false
        }
        return try WebDAVPathValidator.canonicalAbsolutePath(
            candidate.percentEncodedPath.isEmpty ? "/" : candidate.percentEncodedPath,
            error: .invalidURL
        ) == WebDAVPathValidator.canonicalAbsolutePath(
            expected.percentEncodedPath.isEmpty ? "/" : expected.percentEncodedPath,
            error: .invalidURL
        )
    }

    /** Reports whether an absolute URL remains on the configured origin and beneath the DAV root. */
    private func isWithinConfiguredRoot(_ url: URL) throws -> Bool {
        let (baseComponents, rootPath) = try validatedBaseComponents()
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              candidate.user == nil,
              candidate.password == nil,
              candidate.query == nil,
              candidate.fragment == nil,
              Self.sameOrigin(baseComponents, candidate) else {
            return false
        }
        let candidatePath = try WebDAVPathValidator.canonicalAbsolutePath(
            candidate.percentEncodedPath.isEmpty ? "/" : candidate.percentEncodedPath,
            error: .untrustedServerPath
        )
        return Self.path(candidatePath, isWithin: rootPath)
    }

    /** Validates the effective URL reported by URL loading after any permitted redirect handling. */
    private func validateFinalResponseURL(_ responseURL: URL?, for request: URLRequest) throws {
        guard let responseURL,
              let requestedURL = request.url,
              try isPermittedRequestURL(requestedURL),
              let responseComponents = URLComponents(
                url: responseURL,
                resolvingAgainstBaseURL: false
              ),
              let requestComponents = URLComponents(
                url: requestedURL,
                resolvingAgainstBaseURL: false
              ),
              Self.sameOrigin(responseComponents, requestComponents),
              responseComponents.query == requestComponents.query,
              responseComponents.fragment == requestComponents.fragment,
              try WebDAVPathValidator.canonicalAbsolutePath(
                responseComponents.percentEncodedPath.isEmpty
                    ? "/"
                    : responseComponents.percentEncodedPath,
                error: .untrustedServerPath
              ) == WebDAVPathValidator.canonicalAbsolutePath(
                requestComponents.percentEncodedPath.isEmpty
                    ? "/"
                    : requestComponents.percentEncodedPath,
                error: .untrustedServerPath
              ) else {
            throw WebDAVClientError.untrustedServerPath
        }
    }

    /** Rejects parsed DAV resources outside the configured origin/root before adapter mapping. */
    private func validatedServerFiles(_ files: [WebDAVFile]) throws -> [WebDAVFile] {
        let (_, rootPath) = try validatedBaseComponents()
        for file in files {
            let candidatePath = try WebDAVPathValidator.canonicalDecodedAbsolutePath(
                file.path,
                error: .untrustedServerPath
            )
            guard Self.path(candidatePath, isWithin: rootPath) else {
                throw WebDAVClientError.untrustedServerPath
            }
            if let sourceURL = file.sourceURL, !(try isWithinConfiguredRoot(sourceURL)) {
                throw WebDAVClientError.untrustedServerPath
            }
        }
        return files
    }

    /** Compares URL origins using normalized default ports and case-insensitive schemes/hosts. */
    private static func sameOrigin(_ lhs: URLComponents, _ rhs: URLComponents) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs) == effectivePort(rhs)
    }

    /** Returns an explicit or scheme-default port for an origin comparison. */
    private static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /** Performs a component-boundary containment check for canonical absolute paths. */
    private static func path(_ candidate: String, isWithin root: String) -> Bool {
        root == "/" || candidate == root || candidate.hasPrefix(root + "/")
    }

    /** Writes a complete buffered response chunk to an already-open no-follow descriptor. */
    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
        }
    }

    /** Reports whether a path still names the regular inode created for a streamed download. */
    private static func pathNamesFile(_ url: URL, device: UInt64, inode: UInt64) -> Bool {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return UInt64(status.st_dev) == device && UInt64(status.st_ino) == inode
    }

    /** Removes a partial download only while its original inode remains at the destination path. */
    private static func removeFileIfNamed(_ url: URL, device: UInt64, inode: UInt64) {
        guard pathNamesFile(url, device: device, inode: inode) else { return }
        _ = Darwin.unlink(url.path)
    }

    private static func iso8601SearchString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private final class MultiStatusXMLDelegate: NSObject, XMLParserDelegate {
    private struct Element: Equatable {
        let namespaceURI: String
        let localName: String
    }

    private struct PropertyAccumulator {
        var displayName: String?
        var contentLength: Int64?
        var contentType: String?
        var lastModified: Date?
        var isDirectory = false

        /** Merges one successful DAV propstat without applying failed property values. */
        mutating func merge(_ other: PropertyAccumulator) {
            if let displayName = other.displayName { self.displayName = displayName }
            if let contentLength = other.contentLength { self.contentLength = contentLength }
            if let contentType = other.contentType { self.contentType = contentType }
            if let lastModified = other.lastModified { self.lastModified = lastModified }
            isDirectory = isDirectory || other.isDirectory
        }
    }

    private struct PropstatAccumulator {
        var properties = PropertyAccumulator()
        var statusCode: Int?
    }

    private struct ResponseAccumulator {
        var href: String?
        var statusCode: Int?
        var properties = PropertyAccumulator()
        var sawPropstat = false
        var sawSuccessfulPropstat = false
    }

    private enum TextTarget {
        case href
        case responseStatus
        case propstatStatus
        case displayName
        case contentLength
        case ownCloudSize
        case contentType
        case lastModified
    }

    private enum Namespace {
        static let dav = "DAV:"
        static let ownCloud = "http://owncloud.org/ns"
    }

    private enum Limit {
        static let capturedTextBytes = 8 * 1_024
        static let responseCount = 100_000
    }

    private static let multistatus = Element(namespaceURI: Namespace.dav, localName: "multistatus")
    private static let response = Element(namespaceURI: Namespace.dav, localName: "response")
    private static let propstat = Element(namespaceURI: Namespace.dav, localName: "propstat")
    private static let prop = Element(namespaceURI: Namespace.dav, localName: "prop")
    private static let resourceType = Element(namespaceURI: Namespace.dav, localName: "resourcetype")

    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    var files: [WebDAVFile] = []

    /// First fail-closed validation or structure error encountered while parsing a response.
    var parsingError: WebDAVClientError?

    private var elementStack: [Element] = []
    private var currentResponse: ResponseAccumulator?
    private var currentPropstat: PropstatAccumulator?
    private var textTarget: TextTarget?
    private var textBuffer = ""
    private var sawMultistatus = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard parsingError == nil else { return }
        let element = Element(namespaceURI: namespaceURI ?? "", localName: elementName)
        let parent = elementStack.last
        elementStack.append(element)

        if elementStack.count == 1 {
            guard element == Self.multistatus else {
                rejectStructure(parser)
                return
            }
            sawMultistatus = true
            return
        }

        if element == Self.response, parent == Self.multistatus {
            guard currentResponse == nil, files.count < Limit.responseCount else {
                rejectStructure(parser)
                return
            }
            currentResponse = ResponseAccumulator()
            return
        }

        if element == Self.propstat, parent == Self.response {
            guard currentResponse != nil, currentPropstat == nil else {
                rejectStructure(parser)
                return
            }
            currentResponse?.sawPropstat = true
            currentPropstat = PropstatAccumulator()
            return
        }

        if element.namespaceURI == Namespace.dav,
           element.localName == "collection",
           parent == Self.resourceType,
           elementStack.dropLast(2).last == Self.prop,
           currentPropstat != nil {
            currentPropstat?.properties.isDirectory = true
            return
        }

        guard textTarget == nil else { return }
        switch (element.namespaceURI, element.localName, parent) {
        case (Namespace.dav, "href", Self.response):
            beginCapture(.href)
        case (Namespace.dav, "status", Self.response):
            beginCapture(.responseStatus)
        case (Namespace.dav, "status", Self.propstat):
            beginCapture(.propstatStatus)
        case (Namespace.dav, "displayname", Self.prop):
            beginCapture(.displayName)
        case (Namespace.dav, "getcontentlength", Self.prop):
            beginCapture(.contentLength)
        case (Namespace.ownCloud, "size", Self.prop):
            beginCapture(.ownCloudSize)
        case (Namespace.dav, "getcontenttype", Self.prop):
            beginCapture(.contentType)
        case (Namespace.dav, "getlastmodified", Self.prop):
            beginCapture(.lastModified)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textTarget != nil else { return }
        guard textBuffer.utf8.count + string.utf8.count <= Limit.capturedTextBytes else {
            rejectStructure(parser)
            return
        }
        textBuffer += string
    }

    /** Rejects internal entities so a bounded wire payload cannot expand into unbounded parser text. */
    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        rejectEntityDeclaration(parser)
    }

    /** Rejects external entities even though Foundation entity resolution is separately disabled. */
    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        rejectEntityDeclaration(parser)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard parsingError == nil else { return }
        let element = Element(namespaceURI: namespaceURI ?? "", localName: elementName)
        guard elementStack.last == element else {
            rejectStructure(parser)
            return
        }

        if let textTarget, Self.element(for: textTarget) == element {
            do {
                try finishCapture(textTarget)
            } catch {
                rejectStructure(parser)
                return
            }
        }

        if element == Self.propstat {
            guard let propstat = currentPropstat,
                  let statusCode = propstat.statusCode else {
                rejectStructure(parser)
                return
            }
            if (200..<300).contains(statusCode) {
                currentResponse?.properties.merge(propstat.properties)
                currentResponse?.sawSuccessfulPropstat = true
            }
            currentPropstat = nil
        } else if element == Self.response {
            guard let response = currentResponse else {
                rejectStructure(parser)
                return
            }
            do {
                try append(response: response)
            } catch let error as WebDAVClientError {
                parsingError = error
                parser.abortParsing()
                return
            } catch {
                rejectStructure(parser)
                return
            }
            currentResponse = nil
        }

        elementStack.removeLast()
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        guard parsingError == nil,
              sawMultistatus,
              elementStack.isEmpty,
              currentResponse == nil,
              currentPropstat == nil,
              textTarget == nil else {
            rejectStructure(parser)
            return
        }
    }

    private func beginCapture(_ target: TextTarget) {
        textTarget = target
        textBuffer = ""
    }

    private func finishCapture(_ target: TextTarget) throws {
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .href:
            guard !value.isEmpty else { throw WebDAVClientError.invalidMultiStatusXML }
            currentResponse?.href = value
        case .responseStatus:
            currentResponse?.statusCode = try Self.statusCode(from: value)
        case .propstatStatus:
            currentPropstat?.statusCode = try Self.statusCode(from: value)
        case .displayName:
            currentPropstat?.properties.displayName = value
        case .contentLength, .ownCloudSize:
            guard let length = Int64(value), length >= 0 else {
                throw WebDAVClientError.invalidMultiStatusXML
            }
            currentPropstat?.properties.contentLength = length
        case .contentType:
            currentPropstat?.properties.contentType = value.isEmpty ? nil : value
        case .lastModified:
            guard let date = Self.rfc1123Formatter.date(from: value) else {
                throw WebDAVClientError.invalidMultiStatusXML
            }
            currentPropstat?.properties.lastModified = date
        }
        textTarget = nil
        textBuffer = ""
    }

    private func append(response: ResponseAccumulator) throws {
        if let statusCode = response.statusCode, !(200..<300).contains(statusCode) {
            return
        }
        if response.sawPropstat, !response.sawSuccessfulPropstat {
            return
        }
        guard let href = response.href else {
            throw WebDAVClientError.invalidMultiStatusXML
        }
        let parsedHref = try WebDAVPathValidator.parseServerHref(href)
        let displayName = response.properties.displayName?.isEmpty == false
            ? response.properties.displayName!
            : URL(fileURLWithPath: parsedHref.path).lastPathComponent
        files.append(
            WebDAVFile(
                href: parsedHref.href,
                path: parsedHref.path,
                displayName: displayName,
                isDirectory: response.properties.isDirectory,
                contentLength: response.properties.contentLength,
                contentType: response.properties.contentType,
                lastModified: response.properties.lastModified,
                sourceURL: parsedHref.sourceURL
            )
        )
    }

    private static func statusCode(from value: String) throws -> Int {
        let fields = value.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2,
              fields[0].uppercased().hasPrefix("HTTP/"),
              let statusCode = Int(fields[1]),
              (100...599).contains(statusCode) else {
            throw WebDAVClientError.invalidMultiStatusXML
        }
        return statusCode
    }

    private static func element(for target: TextTarget) -> Element {
        switch target {
        case .href:
            return Element(namespaceURI: Namespace.dav, localName: "href")
        case .responseStatus, .propstatStatus:
            return Element(namespaceURI: Namespace.dav, localName: "status")
        case .displayName:
            return Element(namespaceURI: Namespace.dav, localName: "displayname")
        case .contentLength:
            return Element(namespaceURI: Namespace.dav, localName: "getcontentlength")
        case .ownCloudSize:
            return Element(namespaceURI: Namespace.ownCloud, localName: "size")
        case .contentType:
            return Element(namespaceURI: Namespace.dav, localName: "getcontenttype")
        case .lastModified:
            return Element(namespaceURI: Namespace.dav, localName: "getlastmodified")
        }
    }

    /** Aborts a multistatus response at its first custom entity declaration. */
    private func rejectEntityDeclaration(_ parser: XMLParser) {
        parsingError = .invalidMultiStatusXML
        parser.abortParsing()
    }

    /** Aborts malformed namespace, hierarchy, text, or status structures. */
    private func rejectStructure(_ parser: XMLParser) {
        parsingError = .invalidMultiStatusXML
        parser.abortParsing()
    }
}

/** Rejects every DAV redirect before URL loading can resend credentials, methods, or bodies. */
private final class WebDAVRejectingRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Shared stateless delegate used by every authenticated DAV request.
    static let shared = WebDAVRejectingRedirectDelegate()

    /** Returns `nil` for every redirect target, leaving the original 3xx response visible to the caller. */
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
