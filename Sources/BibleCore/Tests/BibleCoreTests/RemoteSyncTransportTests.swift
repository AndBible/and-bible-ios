import Darwin
import SwordKit
import XCTest
@testable import BibleCore

/**
 BibleCore WebDAV and Nextcloud transport tests migrated out of the app-host bundle.

 The suite verifies remote-sync request construction, WebDAV multistatus parsing, configured
 Nextcloud folder bootstrapping, incremental SEARCH listing, and Android-compatible sync-folder
 marker handling. It intentionally owns only BibleCore transport behavior; UI, SWORD, SwiftData,
 and WebView imports from the old `AndBibleTests` support class are not needed here.
 */
final class RemoteSyncTransportTests: XCTestCase {
    /**
     Clears the URL protocol handler so each async transport test owns its mocked request path.

     - Side effects: Resets the process-global `MockURLProtocol.requestHandler` fixture.
     - Failure modes: none.
     */
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testWebDAVPropfindBuildsAuthenticatedRequestAndParsesMultiStatus() async throws {
        let expectedAuth = "Basic \(Data("alice:secret".utf8).base64EncodedString())"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuth)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/remote.php/dav/files/alice/sync")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )
        let files = try await client.propfind(path: "sync", depth: 1)

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "/remote.php/dav/files/alice/sync/")
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[0].displayName, "sync")
        XCTAssertEqual(files[1].path, "/remote.php/dav/files/alice/sync/1.1.sqlite3.gz")
        XCTAssertFalse(files[1].isDirectory)
        XCTAssertEqual(files[1].contentLength, 12345)
        XCTAssertEqual(files[1].contentType, "application/gzip")
    }

    func testWebDAVSearchBuildsSearchRequestBody() async throws {
        let modifiedAfter = Date(timeIntervalSince1970: 1_730_000_000)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "SEARCH")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/remote.php/dav")

            let body = try XCTUnwrap(requestBodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("<d:searchrequest"))
            XCTAssertTrue(bodyString.contains("<d:href>/files/alice/sync/bookmarks</d:href>"))
            XCTAssertTrue(bodyString.contains("2024-10-27T03:33:20Z"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )
        let files = try await client.search(path: "sync/bookmarks", modifiedAfter: modifiedAfter)

        XCTAssertEqual(files.count, 2)
    }

    /**
     Verifies bounded WebDAV download writes exact response bytes directly to a local file.

     The result count and file bytes prove the archive path uses the streaming API rather than the
     legacy in-memory `get(path:)` return value.
     */
    func testWebDAVBoundedDownloadStreamsExactBytesToFile() async throws {
        let payload = Data("bounded-download".utf8)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(payload.count)"]
            )!
            return (response, payload)
        }
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-bounded-download-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        let count = try await client.get(
            path: "sync/archive.sqlite3.gz",
            to: destinationURL,
            maximumByteCount: payload.count
        )

        XCTAssertEqual(count, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: destinationURL), payload)
    }

    /**
     Verifies declared and observed WebDAV byte limits reject downloads and remove partial files.

     One response declares an oversized body before output creation. Another declares an allowed
     length but emits an extra byte, proving the streaming loop independently enforces its ceiling.
     */
    func testWebDAVBoundedDownloadRejectsDeclaredAndObservedOverflow() async throws {
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-bounded-overflow-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "5"]
            )!
            return (response, Data("12345".utf8))
        }
        do {
            _ = try await client.get(
                path: "sync/declared.sqlite3.gz",
                to: destinationURL,
                maximumByteCount: 4
            )
            XCTFail("Expected the declared response length to exceed the bound")
        } catch {
            XCTAssertEqual(error as? RemoteSyncBoundedDownloadError, .payloadTooLarge(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4"]
            )!
            return (response, Data("12345".utf8))
        }
        do {
            _ = try await client.get(
                path: "sync/observed.sqlite3.gz",
                to: destinationURL,
                maximumByteCount: 4
            )
            XCTFail("Expected streamed bytes to exceed the bound")
        } catch {
            XCTAssertEqual(error as? RemoteSyncBoundedDownloadError, .payloadTooLarge(5))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testWebDAVMultiStatusParserDecodesPercentEncodedHrefs() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote.php/dav/files/alice/Study%20Pad/entry%201.txt</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>entry 1.txt</d:displayname>
                <d:getcontentlength>42</d:getcontentlength>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let files = try WebDAVMultiStatusParser.parse(data: Data(xml.utf8))

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].href, "/remote.php/dav/files/alice/Study Pad/entry 1.txt")
        XCTAssertEqual(files[0].path, "/remote.php/dav/files/alice/Study Pad/entry 1.txt")
        XCTAssertEqual(files[0].displayName, "entry 1.txt")
        XCTAssertEqual(files[0].contentLength, 42)
    }

    /**
     Verifies a small DAV response cannot allocate amplified text through XML entity expansion.

     Custom internal entities are outside the multistatus contract and fail before their repeated
     references can become an attacker-controlled href.
     */
    func testWebDAVMultiStatusParserRejectsInternalEntityExpansion() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE multistatus [
          <!ENTITY repeated "012345678901234567890123456789">
        ]>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote.php/dav/files/alice/&repeated;&repeated;</d:href>
          </d:response>
        </d:multistatus>
        """

        XCTAssertThrowsError(
            try WebDAVMultiStatusParser.parse(data: Data(xml.utf8))
        ) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidMultiStatusXML)
        }
    }

    /**
     Verifies namespace and propstat status determine which DAV metadata becomes authoritative.

     A failed DAV property set contains a conflicting size, while a successful ownCloud namespaced
     `size` supplies the accepted value. A lookalike non-DAV root must fail closed.
     */
    func testWebDAVMultiStatusParserHonorsNamespacesHierarchyAndSuccessfulPropstats() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
          <d:response>
            <d:href>/remote.php/dav/files/alice/sync/1.sqlite3.gz</d:href>
            <d:propstat>
              <d:prop><d:getcontentlength>999</d:getcontentlength></d:prop>
              <d:status>HTTP/1.1 404 Not Found</d:status>
            </d:propstat>
            <d:propstat>
              <d:prop><oc:size>17</oc:size><d:getcontenttype>application/gzip</d:getcontenttype></d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let files = try WebDAVMultiStatusParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(files.map(\.contentLength), [17])
        XCTAssertEqual(files.map(\.contentType), ["application/gzip"])

        let spoofed = """
        <x:multistatus xmlns:x="urn:not-dav"><x:response /></x:multistatus>
        """
        XCTAssertThrowsError(try WebDAVMultiStatusParser.parse(data: Data(spoofed.utf8))) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidMultiStatusXML)
        }
    }

    /**
     Verifies decoded traversal, separators, empty components, controls, and oversized names fail
     before transport.

     Every value is supplied as a caller-controlled remote identifier. The mock handler fails the test
     if URL construction admits any of them far enough to create a request.
     */
    func testWebDAVRejectsUnsafeCallerPathsBeforeNetworkDispatch() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTFail("Unsafe path reached transport: \(request.url?.absoluteString ?? "nil")")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )
        let unsafePaths = [
            "../outside",
            "sync/./entry",
            "sync//entry",
            "sync\\entry",
            "sync/control\u{7f}",
        ] + [String(repeating: "a", count: 256)]

        for path in unsafePaths {
            do {
                _ = try await client.get(path: path)
                XCTFail("Expected unsafe path rejection for \(path)")
            } catch {
                XCTAssertEqual(error as? WebDAVClientError, .invalidPath, "Unexpected error for \(path)")
            }
        }
    }

    /**
     Verifies reserved characters are treated as decoded filename data and encoded exactly once.

     Literal percent, query, fragment, and space characters must not become URL syntax or be decoded
     into traversal; Foundation emits them as one safe DAV path component.
     */
    func testWebDAVEncodesReservedLogicalFilenameCharactersExactlyOnce() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://example.com/remote.php/dav/files/alice/sync/100%25%3F%23%20complete"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        _ = try await client.get(path: "sync/100%?# complete")
    }

    /**
     Verifies unsafe server roots and username path components fail during adapter construction.

     Encoded traversal, query syntax, embedded URL credentials, and literal username separators must
     not survive configuration normalization or reach the injected URL loading protocol.
     */
    func testNextCloudRejectsUnsafeServerRootAndUsernameBeforeNetworkDispatch() throws {
        let configurations = [
            WebDAVSyncConfiguration(
                serverURL: "https://example.com/base/%2e%2e/private",
                username: "alice",
                folderPath: nil
            ),
            WebDAVSyncConfiguration(
                serverURL: "https://example.com/root?path=/outside",
                username: "alice",
                folderPath: nil
            ),
            WebDAVSyncConfiguration(
                serverURL: "https://attacker@example.com",
                username: "alice",
                folderPath: nil
            ),
        ]

        for configuration in configurations {
            XCTAssertThrowsError(
                try NextCloudSyncAdapter(
                    configuration: configuration,
                    password: "secret",
                    session: makeMockedURLSession()
                )
            ) { error in
                XCTAssertEqual(error as? WebDAVClientError, .invalidURL)
            }
        }

        XCTAssertThrowsError(
            try NextCloudSyncAdapter(
                configuration: WebDAVSyncConfiguration(
                    serverURL: "https://example.com",
                    username: "alice/outside",
                    folderPath: nil
                ),
                password: "secret",
                session: makeMockedURLSession()
            )
        ) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidPath)
        }
    }

    /**
     Verifies adapter-controlled folder, device, and filename fields cannot become DAV path syntax.

     Configuration validation and operation validation both return the public invalid-path error before
     a malicious device identifier or archive name can escape its intended segment.
     */
    func testNextCloudRejectsUnsafeFolderDeviceAndArchiveIdentifiers() async throws {
        XCTAssertThrowsError(
            try NextCloudSyncAdapter(
                configuration: WebDAVSyncConfiguration(
                    serverURL: "https://example.com",
                    username: "alice",
                    folderPath: "AndBible/../private"
                ),
                password: "secret",
                session: makeMockedURLSession()
            )
        ) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidPath)
        }

        MockURLProtocol.requestHandler = { request in
            XCTFail("Unsafe identifier reached transport: \(request.url?.absoluteString ?? "nil")")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )
        let payload = Data("patch".utf8)
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "unsafe-archive-name-\(UUID().uuidString).sqlite3.gz"
        )
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        try payload.write(to: payloadURL, options: .atomic)

        do {
            _ = try await adapter.makeSyncFolderKnown(
                syncFolderID: "/bookmarks",
                deviceIdentifier: "ios/device"
            )
            XCTFail("Expected unsafe device identifier rejection")
        } catch {
            XCTAssertEqual(error as? WebDAVClientError, .invalidPath)
        }
        do {
            _ = try await adapter.uploadIfAbsent(
                name: "../1.1.sqlite3.gz",
                fileURL: payloadURL,
                maximumByteCount: payload.count,
                parentID: "/bookmarks/device",
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
            XCTFail("Expected unsafe archive name rejection")
        } catch {
            XCTAssertEqual(error as? WebDAVClientError, .invalidPath)
        }
    }

    /**
     Verifies every malicious DAV href aborts the complete listing instead of becoming an identifier.

     Cases cover decoded traversal, encoded separators, literal query syntax, root escape, and a
     foreign absolute origin. Percent-encoded reserved characters that remain one logical filename
     segment are valid and covered separately by exact-once encoding tests.
     */
    func testWebDAVRejectsMaliciousServerHrefsOutsideConfiguredRoot() async throws {
        let hrefs = [
            "/remote.php/dav/files/alice/sync/%2e%2e/private.sqlite3.gz",
            "/remote.php/dav/files/alice/sync/device%2Fprivate.sqlite3.gz",
            "/remote.php/dav/files/alice/sync/private.sqlite3.gz?download=1",
            "/remote.php/dav/files/mallory/private.sqlite3.gz",
            "https://evil.example/remote.php/dav/files/alice/sync/private.sqlite3.gz",
        ]
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        for href in hrefs {
            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 207,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(webDAVResponseXML(href: href).utf8))
            }
            do {
                _ = try await client.propfind(path: "sync")
                XCTFail("Expected untrusted href rejection for \(href)")
            } catch {
                XCTAssertEqual(
                    error as? WebDAVClientError,
                    .untrustedServerPath,
                    "Unexpected error for \(href)"
                )
            }
        }
    }

    /**
     Verifies chunked or underreported DAV XML cannot exceed the actual in-memory response ceiling.

     Both listing methods share the bounded byte loop. Invalid XML is intentionally larger than the
     configured ceiling so size rejection must occur before parser allocation or parser diagnostics.
     */
    func testWebDAVListingAndSearchRejectObservedBodyOverflowWithoutContentLength() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(repeating: 0x41, count: 128))
        }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession(),
            maximumInMemoryResponseByteCount: 32
        )

        do {
            _ = try await client.propfind(path: "sync")
            XCTFail("Expected bounded PROPFIND rejection")
        } catch RemoteSyncBoundedDownloadError.payloadTooLarge(let byteCount) {
            XCTAssertGreaterThan(byteCount, 32)
        }
        do {
            _ = try await client.search(path: "sync", modifiedAfter: .distantPast)
            XCTFail("Expected bounded SEARCH rejection")
        } catch RemoteSyncBoundedDownloadError.payloadTooLarge(let byteCount) {
            XCTAssertGreaterThan(byteCount, 32)
        }
    }

    /**
     Verifies conditional success is accepted only after exact same-root destination readback.

     The two-request sequence proves a server's 2xx response is treated as ambiguous rather than as
     ownership evidence when `If-None-Match` may have been ignored.
     */
    func testWebDAVConditionalUploadVerifiesExactDestinationBytesAfterSuccess() async throws {
        let payload = Data("conditional-payload".utf8)
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-conditional-success-\(UUID().uuidString)"
        )
        try payload.write(to: payloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        let requestLog = RequestLog()
        MockURLProtocol.requestHandler = { request in
            requestLog.append(method: request.httpMethod ?? "", path: request.url?.path ?? "")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: request.httpMethod == "PUT" ? 201 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "PUT" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
                return (response, Data())
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return (response, payload)
        }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        let result = try await client.putIfAbsent(
            path: "sync/1.1.sqlite3.gz",
            fileURL: payloadURL,
            maximumByteCount: payload.count
        )

        XCTAssertEqual(result, .created)
        XCTAssertEqual(requestLog.snapshot().map(\.method), ["PUT", "GET"])
    }

    /**
     Verifies a server that ignores the create precondition cannot claim a mismatched object as ours.

     A nominally successful PUT is followed by different remote bytes. The transport must fail visibly
     so higher-level retry and convergence logic can re-list instead of accepting another writer's file.
     */
    func testWebDAVConditionalUploadRejectsNoncompliantSuccessWithMismatchedReadback() async throws {
        let payload = Data("our-writer".utf8)
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-conditional-mismatch-\(UUID().uuidString)"
        )
        try payload.write(to: payloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: request.httpMethod == "PUT" ? 201 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, request.httpMethod == "PUT" ? Data() : Data("bad-writer".utf8))
        }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        do {
            _ = try await client.putIfAbsent(
                path: "sync/1.1.sqlite3.gz",
                fileURL: payloadURL,
                maximumByteCount: payload.count
            )
            XCTFail("Expected mismatched conditional success rejection")
        } catch {
            XCTAssertEqual(error as? WebDAVClientError, .conditionalUploadVerificationFailed)
        }
    }

    /**
     Verifies only HTTP 201 proves a conditional create occurred.

     HTTP 200 and 204 can mean a noncompliant server ignored `If-None-Match`; both must return the
     occupied result without a verification GET so reconciliation performs an authoritative re-list.
     */
    func testWebDAVConditionalUploadTreatsHTTP200And204AsOccupied() async throws {
        let payload = Data("ambiguous-create".utf8)
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-conditional-ambiguous-\(UUID().uuidString)"
        )
        try payload.write(to: payloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        for statusCode in [200, 204] {
            let requestLog = RequestLog()
            MockURLProtocol.requestHandler = { request in
                requestLog.append(method: request.httpMethod ?? "", path: request.url?.path ?? "")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }

            let result = try await client.putIfAbsent(
                path: "sync/1.1.sqlite3.gz",
                fileURL: payloadURL,
                maximumByteCount: payload.count
            )
            XCTAssertEqual(result, .alreadyExists)
            XCTAssertEqual(requestLog.snapshot().map(\.method), ["PUT"])
        }
    }

    /**
     Verifies a conditional redirect is surfaced and never retried as a stripped-precondition request.

     The redirect target is foreign-origin. A second intercepted request would prove URL loading
     followed it despite the rejecting task delegate.
     */
    func testWebDAVConditionalUploadRejectsRedirectBeforePreconditionCanBeStripped() async throws {
        let payload = Data("payload".utf8)
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-conditional-redirect-\(UUID().uuidString)"
        )
        try payload.write(to: payloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        let requestLog = RequestLog()
        MockURLProtocol.requestHandler = { request in
            requestLog.append(method: request.httpMethod ?? "", path: request.url?.absoluteString ?? "")
            if request.url?.host == "evil.example" {
                XCTFail("Conditional request followed a foreign redirect")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 307,
                    httpVersion: nil,
                    headerFields: ["Location": "https://evil.example/replace"]
                )!,
                Data()
            )
        }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        do {
            _ = try await client.putIfAbsent(
                path: "sync/1.1.sqlite3.gz",
                fileURL: payloadURL,
                maximumByteCount: payload.count
            )
            XCTFail("Expected redirect rejection")
        } catch {
            XCTAssertEqual(error as? WebDAVClientError, .redirectRejected(307))
        }
        XCTAssertEqual(requestLog.snapshot().count, 1)
    }

    /**
     Verifies every authenticated DAV method rejects redirects before URL loading can resend it.

     The matrix covers same-origin root escape, cross-origin targets, HTTPS downgrade, ordinary and
     conditional PUT bodies, and DAV methods whose semantics URL loading might otherwise rewrite.
     */
    func testWebDAVRejectsRedirectsForEveryMethodBeforeFollow() async throws {
        let payload = Data("redirect-body".utf8)
        let payloadURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "webdav-all-method-redirect-\(UUID().uuidString)"
        )
        try payload.write(to: payloadURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: payloadURL) }
        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )
        let cases: [(method: String, location: String)] = [
            ("GET", "https://example.com/outside"),
            ("PROPFIND", "https://evil.example/remote.php/dav/files/alice/sync"),
            ("SEARCH", "http://example.com/remote.php/dav"),
            ("PUT", "https://example.com/remote.php/dav/files/alice/other"),
            ("MKCOL", "https://example.com/outside"),
            ("DELETE", "https://evil.example/delete"),
            ("CONDITIONAL", "http://example.com/remote.php/dav/files/alice/sync/file"),
        ]

        for testCase in cases {
            let requestLog = RequestLog()
            MockURLProtocol.requestHandler = { request in
                requestLog.append(method: request.httpMethod ?? "", path: request.url?.absoluteString ?? "")
                if testCase.method == "PUT" || testCase.method == "CONDITIONAL" {
                    XCTAssertEqual(requestBodyData(for: request), payload)
                } else if testCase.method == "PROPFIND" || testCase.method == "SEARCH" {
                    XCTAssertFalse(requestBodyData(for: request)?.isEmpty ?? true)
                }
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 307,
                        httpVersion: nil,
                        headerFields: ["Location": testCase.location]
                    )!,
                    Data()
                )
            }

            do {
                switch testCase.method {
                case "GET": _ = try await client.get(path: "sync/file")
                case "PROPFIND": _ = try await client.propfind(path: "sync")
                case "SEARCH": _ = try await client.search(path: "sync", modifiedAfter: .distantPast)
                case "PUT": try await client.put(path: "sync/file", data: payload)
                case "MKCOL": try await client.mkcol(path: "sync/folder")
                case "DELETE": try await client.delete(path: "sync/file")
                case "CONDITIONAL":
                    _ = try await client.putIfAbsent(
                        path: "sync/file",
                        fileURL: payloadURL,
                        maximumByteCount: payload.count
                    )
                default: XCTFail("Unhandled redirect test method")
                }
                XCTFail("Expected redirect rejection for \(testCase.method)")
            } catch {
                XCTAssertEqual(error as? WebDAVClientError, .redirectRejected(307))
            }
            XCTAssertEqual(requestLog.snapshot().count, 1)
        }
    }

    /** Verifies HTTP DAV roots are rejected before Basic credentials reach URL loading. */
    func testWebDAVRejectsPlainHTTPBeforeNetworkDispatch() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTFail("HTTP request reached transport with credentials")
            throw URLError(.badServerResponse)
        }
        let client = WebDAVClient(
            baseURL: URL(string: "http://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )

        do {
            _ = try await client.get(path: "sync/file")
            XCTFail("Expected HTTP DAV root rejection")
        } catch {
            XCTAssertEqual(error as? WebDAVClientError, .invalidURL)
        }
    }

    func testNextCloudSyncAdapterCreatesConfiguredBaseFolderBeforeListing() async throws {
        let requestLog = RequestLog()
        let listingXML = webDAVMultiStatusXML(
            folderPath: "/remote.php/dav/files/alice/AndBible/Sync/",
            fileName: "1.1.sqlite3.gz"
        )

        MockURLProtocol.requestHandler = { request in
            requestLog.append(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? ""
            )

            let path = try XCTUnwrap(request.url?.path)
            let statusCode: Int
            let payload: Data
            switch (request.httpMethod ?? "", path) {
            case ("MKCOL", "/remote.php/dav/files/alice/AndBible"),
                 ("MKCOL", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 201
                payload = Data()
            case ("PROPFIND", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 207
                payload = Data(listingXML.utf8)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                statusCode = 500
                payload = Data()
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: "AndBible/Sync"
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles()

        XCTAssertEqual(
            requestLog.snapshot(),
            [
                .init(method: "MKCOL", path: "/remote.php/dav/files/alice/AndBible"),
                .init(method: "MKCOL", path: "/remote.php/dav/files/alice/AndBible/Sync"),
                .init(method: "PROPFIND", path: "/remote.php/dav/files/alice/AndBible/Sync"),
            ]
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].id, "/AndBible/Sync/1.1.sqlite3.gz")
        XCTAssertEqual(files[0].parentID, "/AndBible/Sync")
        XCTAssertEqual(files[0].mimeType, "application/gzip")
    }

    func testNextCloudSyncAdapterTreatsExistingBaseFolderAsReady() async throws {
        let requestLog = RequestLog()

        MockURLProtocol.requestHandler = { request in
            requestLog.append(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? ""
            )

            let path = try XCTUnwrap(request.url?.path)
            let statusCode: Int
            let payload: Data
            switch (request.httpMethod ?? "", path) {
            case ("MKCOL", "/remote.php/dav/files/alice/AndBible"),
                 ("MKCOL", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 405
                payload = Data()
            case ("PROPFIND", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 207
                payload = Data(webDAVMultiStatusXML(
                    folderPath: "/remote.php/dav/files/alice/AndBible/Sync/",
                    fileName: "2.1.sqlite3.gz"
                ).utf8)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                statusCode = 500
                payload = Data()
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: "AndBible/Sync"
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles()

        XCTAssertEqual(files.map(\.id), ["/AndBible/Sync/2.1.sqlite3.gz"])
        XCTAssertEqual(
            requestLog.snapshot().prefix(2).map(\.path),
            [
                "/remote.php/dav/files/alice/AndBible",
                "/remote.php/dav/files/alice/AndBible/Sync",
            ]
        )
    }

    /**
     Verifies incremental listing uses Android's authoritative DAV-root SEARCH request.

     The request scopes `/files/user/folder`, emits an ISO UTC cursor without iOS-only overlap, and
     returns SEARCH metadata directly without a second PROPFIND replay.
     */
    func testNextCloudIncrementalListingReplaysCursorBoundaryAndCollapsesDuplicateRows() async throws {
        let requestLog = RequestLog()
        MockURLProtocol.requestHandler = { request in
            requestLog.append(method: request.httpMethod ?? "", path: request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "SEARCH")
            XCTAssertEqual(request.url?.path, "/remote.php/dav")
            let body = try XCTUnwrap(requestBodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("<d:href>/files/alice/sync</d:href>"))
            XCTAssertTrue(bodyString.contains("2024-10-27T03:33:20Z"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            let listing = webDAVMultiStatusXML(
                folderPath: "/remote.php/dav/files/alice/sync/",
                fileName: "3.1.sqlite3.gz"
            ).replacingOccurrences(of: "application/gzip", with: "application/x-alpha-gzip")
            return (
                response,
                Data(listing.utf8)
            )
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles(
            parentIDs: ["/sync"],
            modifiedAtLeast: Date(timeIntervalSince1970: 1_730_000_000)
        )

        XCTAssertEqual(files.map(\.id), ["/sync/3.1.sqlite3.gz"])
        XCTAssertEqual(files.map(\.mimeType), ["application/x-alpha-gzip"])
        XCTAssertEqual(
            requestLog.snapshot().map(\.method),
            ["SEARCH"]
        )
    }

    /**
     Verifies Android-compatible incremental discovery treats SEARCH results as authoritative.

     An empty SEARCH response returns no rows and must not trigger an iOS-only PROPFIND replay.
     */
    func testNextCloudIncrementalListingReturnsRowsMissedBySearchAfterClockRegression() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "SEARCH")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(emptyWebDAVMultiStatusXML.utf8))
        }
        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles(
            parentIDs: ["/sync"],
            modifiedAtLeast: Date(timeIntervalSince1970: 1_900_000_000)
        )

        XCTAssertTrue(files.isEmpty)
    }

    func testNextCloudSyncAdapterMakeSyncFolderKnownUploadsAndroidStyleMarker() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(
                try XCTUnwrap(request.url?.path)
                    .hasPrefix("/remote.php/dav/files/alice/bookmarks/device-known-ios-device-")
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), NextCloudSyncAdapter.gzipMimeType)
            XCTAssertTrue(
                requestBodyData(for: request)?.isEmpty ?? true,
                "Expected the secret marker upload to use an empty request body"
            )

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let secret = try await adapter.makeSyncFolderKnown(
            syncFolderID: "/bookmarks",
            deviceIdentifier: "ios-device"
        )

        XCTAssertTrue(secret.hasPrefix("device-known-ios-device-"))
    }

    func testNextCloudSyncAdapterReportsUnknownFolderWhenMarkerIsMissing() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.url?.path, "/remote.php/dav/files/alice/bookmarks/device-known-ios-device-secret")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let known = try await adapter.isSyncFolderKnown(
            syncFolderID: "/bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )

        XCTAssertFalse(known)
    }

    /**
     Verifies optional gzip FHCRC is checked before a descriptor-backed member is returned.

     A valid header checksum round-trips through bounded inflation. Flipping one checksum bit must
     reject the otherwise identical archive without creating output.
     */
    func testGzipFHCRCValidationAcceptsExactHeaderAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-gzip-fhcrc-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data("fhcrc-payload".utf8)
        var archive = [UInt8](try RemoteSyncArchiveStagingService.gzip(payload))
        archive[3] |= 0x02
        let headerChecksum = ArchiveCRC32.checksum(of: Data(archive.prefix(10)))
        archive.insert(
            contentsOf: [
                UInt8(truncatingIfNeeded: headerChecksum),
                UInt8(truncatingIfNeeded: headerChecksum >> 8),
            ],
            at: 10
        )
        let validURL = directory.appendingPathComponent("valid.sqlite3.gz")
        let outputURL = directory.appendingPathComponent("valid.sqlite3")
        try Data(archive).write(to: validURL)

        let member = try RemoteSyncBoundedFileIO.inspectGzip(
            at: validURL,
            maximumCompressedByteCount: archive.count,
            maximumExpandedByteCount: payload.count
        )
        try RemoteSyncBoundedFileIO.inflateGzip(
            member,
            from: validURL,
            to: outputURL,
            maximumExpandedByteCount: payload.count
        )
        XCTAssertEqual(
            try RemoteSyncBoundedFileIO.readRegularFile(
                at: outputURL,
                maximumByteCount: payload.count
            ),
            payload
        )

        archive[10] ^= 0x01
        let corruptURL = directory.appendingPathComponent("corrupt.sqlite3.gz")
        try Data(archive).write(to: corruptURL)
        XCTAssertThrowsError(
            try RemoteSyncBoundedFileIO.inspectGzip(
                at: corruptURL,
                maximumCompressedByteCount: archive.count,
                maximumExpandedByteCount: payload.count
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncBoundedFileError, .malformedGzip)
        }
    }

    /**
     Verifies replacing an inspected gzip path with a symlink cannot change inflation input.

     Inspection retains the original descriptor, but path substitution is still rejected before any
     output is created so callers cannot unknowingly accept a path whose identity changed mid-operation.
     */
    func testGzipInflationRejectsSymlinkSubstitutionAfterInspection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-gzip-source-swap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.sqlite3.gz")
        let replacementURL = directory.appendingPathComponent("replacement.sqlite3.gz")
        let outputURL = directory.appendingPathComponent("output.sqlite3")
        let sourceData = try RemoteSyncArchiveStagingService.gzip(Data("trusted".utf8))
        try sourceData.write(to: sourceURL)
        try RemoteSyncArchiveStagingService.gzip(Data("replacement".utf8)).write(to: replacementURL)
        let member = try RemoteSyncBoundedFileIO.inspectGzip(
            at: sourceURL,
            maximumCompressedByteCount: sourceData.count,
            maximumExpandedByteCount: 64
        )

        try FileManager.default.removeItem(at: sourceURL)
        XCTAssertEqual(Darwin.symlink(replacementURL.path, sourceURL.path), 0)
        XCTAssertThrowsError(
            try RemoteSyncBoundedFileIO.inflateGzip(
                member,
                from: sourceURL,
                to: outputURL,
                maximumExpandedByteCount: 64
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncBoundedFileError, .unsafeInput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    /**
     Verifies bounded inflation never follows or replaces an existing destination symlink.

     The symlink target begins with sentinel bytes and must remain unchanged after exclusive no-follow
     destination creation fails visibly.
     */
    func testGzipInflationRejectsOutputSymlinkWithoutTouchingTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-gzip-output-link-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.sqlite3.gz")
        let outputURL = directory.appendingPathComponent("output.sqlite3")
        let targetURL = directory.appendingPathComponent("target.sqlite3")
        let sentinel = Data("do-not-overwrite".utf8)
        let archive = try RemoteSyncArchiveStagingService.gzip(Data("payload".utf8))
        try archive.write(to: sourceURL)
        try sentinel.write(to: targetURL)
        XCTAssertEqual(Darwin.symlink(targetURL.path, outputURL.path), 0)
        let member = try RemoteSyncBoundedFileIO.inspectGzip(
            at: sourceURL,
            maximumCompressedByteCount: archive.count,
            maximumExpandedByteCount: 64
        )

        XCTAssertThrowsError(
            try RemoteSyncBoundedFileIO.inflateGzip(
                member,
                from: sourceURL,
                to: outputURL,
                maximumExpandedByteCount: 64
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncBoundedFileError, .unsafeOutput)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), sentinel)
    }

    /**
     Verifies compressed input size is enforced from descriptor metadata before header processing.

     The exact archive exceeds the supplied ceiling by one byte, making the associated count useful
     evidence that the implementation did not trust a remote or caller-provided size hint.
     */
    func testGzipInspectionRejectsActualCompressedBytesPastCeiling() throws {
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-gzip-compressed-limit-\(UUID().uuidString).gz"
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let archive = try RemoteSyncArchiveStagingService.gzip(Data("compressed-limit".utf8))
        try archive.write(to: sourceURL)

        XCTAssertThrowsError(
            try RemoteSyncBoundedFileIO.inspectGzip(
                at: sourceURL,
                maximumCompressedByteCount: archive.count - 1,
                maximumExpandedByteCount: 1_024
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncBoundedFileError,
                .compressedSizeExceeded(Int64(archive.count))
            )
        }
    }

    /**
     Verifies observed expanded bytes remain bounded when the gzip trailer understates output size.

     The forged ISIZE passes inspection with a one-byte declaration, while the deflate stream expands
     to several kilobytes. Inflation must stop before the first over-budget write and remove its output.
     */
    func testGzipInflationRejectsObservedExpansionWhenTrailerLies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-sync-gzip-expanded-limit-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var archive = [UInt8](try RemoteSyncArchiveStagingService.gzip(
            Data(repeating: 0x41, count: 4_096)
        ))
        archive[archive.count - 4] = 1
        archive[archive.count - 3] = 0
        archive[archive.count - 2] = 0
        archive[archive.count - 1] = 0
        let sourceURL = directory.appendingPathComponent("lying.sqlite3.gz")
        let outputURL = directory.appendingPathComponent("output.sqlite3")
        try Data(archive).write(to: sourceURL)
        let member = try RemoteSyncBoundedFileIO.inspectGzip(
            at: sourceURL,
            maximumCompressedByteCount: archive.count,
            maximumExpandedByteCount: 64
        )

        XCTAssertThrowsError(
            try RemoteSyncBoundedFileIO.inflateGzip(
                member,
                from: sourceURL,
                to: outputURL,
                maximumExpandedByteCount: 64
            )
        ) { error in
            guard case .expandedSizeExceeded(let observed)? = error as? RemoteSyncBoundedFileError else {
                return XCTFail("Expected observed expansion failure, got \(error)")
            }
            XCTAssertGreaterThan(observed, 64)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

}

/// Empty valid DAV multistatus used to model an incremental query that misses a cursor-boundary row.
private let emptyWebDAVMultiStatusXML = """
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:"></d:multistatus>
"""

/** Builds one minimal DAV response around an adversarial server-provided href. */
private func webDAVResponseXML(href: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>\(href)</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>private.sqlite3.gz</d:displayname>
            <d:getcontentlength>12</d:getcontentlength>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """
}
