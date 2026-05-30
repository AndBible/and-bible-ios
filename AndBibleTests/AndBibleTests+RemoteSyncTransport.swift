import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testWebDAVSearchBuildsSearchRequestBody() async throws {
        let modifiedAfter = Date(timeIntervalSince1970: 1_730_000_000)

        MockURLProtocol.requestHandler = { [self] request in
            XCTAssertEqual(request.httpMethod, "SEARCH")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/remote.php/dav/files/alice/sync/bookmarks")

            let body = try XCTUnwrap(requestBodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("<d:searchrequest"))
            XCTAssertTrue(bodyString.contains("<d:href>/remote.php/dav/files/alice/sync/bookmarks</d:href>"))
            XCTAssertTrue(bodyString.contains("Sun, 27 Oct 2024 03:33:20 GMT"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
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

    func testNextCloudSyncAdapterCreatesConfiguredBaseFolderBeforeListing() async throws {
        let requestLog = RequestLog()
        let listingXML = Self.webDAVMultiStatusXML(
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
                payload = Data(Self.webDAVMultiStatusXML(
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

    func testNextCloudSyncAdapterUsesSearchForIncrementalListing() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "SEARCH")
            XCTAssertEqual(request.url?.path, "/remote.php/dav/files/alice/sync")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(Self.webDAVMultiStatusXML(
                    folderPath: "/remote.php/dav/files/alice/sync/",
                    fileName: "3.1.sqlite3.gz"
                ).utf8)
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
    }

    func testNextCloudSyncAdapterMakeSyncFolderKnownUploadsAndroidStyleMarker() async throws {
        MockURLProtocol.requestHandler = { [self] request in
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

}
