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
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
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

}
