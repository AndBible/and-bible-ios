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

    func testGoogleDriveSyncAdapterListsFilesFromAppDataFolderWithPagination() async throws {
        let createdAfter = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedCreatedTime = ISO8601DateFormatter().string(from: createdAfter)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer drive-token")

            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/drive/v3/files")

            let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(queryItems["spaces"], GoogleDriveClient.appDataFolderID)
            XCTAssertEqual(queryItems["pageSize"], "1000")
            XCTAssertEqual(queryItems["fields"], "nextPageToken,files(id,name,size,createdTime,parents,mimeType)")

            let query = try XCTUnwrap(queryItems["q"])
            XCTAssertTrue(query.contains("'appDataFolder' in parents"))
            XCTAssertTrue(query.contains("name = '1.1.sqlite3.gz'"))
            XCTAssertTrue(query.contains("mimeType = 'application/gzip'"))
            XCTAssertTrue(query.contains("createdTime > '\(expectedCreatedTime)'"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!

            if queryItems["pageToken"] == nil {
                return (
                    response,
                    Self.googleDriveListResponseJSON(
                        files: [
                            Self.googleDriveFileJSON(
                                id: "first",
                                name: "1.1.sqlite3.gz",
                                size: "123",
                                createdTime: "2026-03-12T12:00:00Z",
                                parentID: "appDataFolder",
                                mimeType: "application/gzip"
                            )
                        ],
                        nextPageToken: "page-2"
                    ).data(using: .utf8)!
                )
            }

            XCTAssertEqual(queryItems["pageToken"], "page-2")
            return (
                response,
                Self.googleDriveListResponseJSON(
                    files: [
                        Self.googleDriveFileJSON(
                            id: "second",
                            name: "2.1.sqlite3.gz",
                            size: "456",
                            createdTime: "2026-03-12T12:01:00Z",
                            parentID: "appDataFolder",
                            mimeType: "application/gzip"
                        )
                    ],
                    nextPageToken: nil
                ).data(using: .utf8)!
            )
        }

        let adapter = GoogleDriveSyncAdapter(
            accessTokenProvider: { "drive-token" },
            session: makeMockedURLSession()
        )
        let files = try await adapter.listFiles(
            parentIDs: nil,
            name: "1.1.sqlite3.gz",
            mimeType: "application/gzip",
            modifiedAtLeast: createdAfter
        )

        XCTAssertEqual(files.map(\.id), ["first", "second"])
        XCTAssertEqual(files.map(\.parentID), ["appDataFolder", "appDataFolder"])
        XCTAssertEqual(files.map(\.mimeType), ["application/gzip", "application/gzip"])
    }

    func testGoogleDriveSyncAdapterCreatesFolderUnderAppDataRoot() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer drive-token")

            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/drive/v3/files")
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })["fields"],
                "id,name,size,createdTime,parents,mimeType"
            )

            let body = try XCTUnwrap(requestBodyData(for: request))
            let payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(payload["name"] as? String, "org.andbible-sync-bookmarks")
            XCTAssertEqual(payload["mimeType"] as? String, GoogleDriveSyncAdapter.folderMimeType)
            XCTAssertEqual(payload["parents"] as? [String], [GoogleDriveClient.appDataFolderID])

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Self.googleDriveFileJSON(
                    id: "folder-id",
                    name: "org.andbible-sync-bookmarks",
                    size: nil,
                    createdTime: "2026-03-12T12:02:00Z",
                    parentID: "appDataFolder",
                    mimeType: GoogleDriveSyncAdapter.folderMimeType
                ).data(using: .utf8)!
            )
        }

        let adapter = GoogleDriveSyncAdapter(
            accessTokenProvider: { "drive-token" },
            session: makeMockedURLSession()
        )
        let folder = try await adapter.createNewFolder(name: "org.andbible-sync-bookmarks", parentID: nil)

        XCTAssertEqual(folder.id, "folder-id")
        XCTAssertEqual(folder.parentID, GoogleDriveClient.appDataFolderID)
        XCTAssertEqual(folder.mimeType, GoogleDriveSyncAdapter.folderMimeType)
    }

    func testGoogleDriveSyncAdapterUploadsMultipartPatchArchive() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-drive-upload-\(UUID().uuidString).sqlite3.gz")
        try Data("patch-body".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        MockURLProtocol.requestHandler = { [self] request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer drive-token")

            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(components.path, "/upload/drive/v3/files")

            let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            })
            XCTAssertEqual(queryItems["uploadType"], "multipart")
            XCTAssertEqual(queryItems["fields"], "id,name,size,createdTime,parents,mimeType")

            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertTrue(contentType.hasPrefix("multipart/related; boundary="))

            let body = try XCTUnwrap(requestBodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("\"name\":\"1.1.sqlite3.gz\""))
            XCTAssertTrue(bodyString.contains("\"parents\":[\"device-folder\"]"))
            XCTAssertTrue(bodyString.contains("Content-Type: application/gzip"))
            XCTAssertTrue(bodyString.contains("patch-body"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Self.googleDriveFileJSON(
                    id: "uploaded-file",
                    name: "1.1.sqlite3.gz",
                    size: "10",
                    createdTime: "2026-03-12T12:03:00Z",
                    parentID: "device-folder",
                    mimeType: "application/gzip"
                ).data(using: .utf8)!
            )
        }

        let adapter = GoogleDriveSyncAdapter(
            accessTokenProvider: { "drive-token" },
            session: makeMockedURLSession()
        )
        let file = try await adapter.upload(
            name: "1.1.sqlite3.gz",
            fileURL: fileURL,
            parentID: "device-folder",
            contentType: "application/gzip"
        )

        XCTAssertEqual(file.id, "uploaded-file")
        XCTAssertEqual(file.parentID, "device-folder")
        XCTAssertEqual(file.size, 10)
    }

    func testGoogleDriveSyncAdapterUsesFolderExistenceForOwnershipProof() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer drive-token")
            XCTAssertEqual(request.url?.path, "/drive/v3/files/sync-folder")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Self.googleDriveFileJSON(
                    id: "sync-folder",
                    name: "org.andbible-sync-workspaces",
                    size: nil,
                    createdTime: "2026-03-12T12:04:00Z",
                    parentID: "appDataFolder",
                    mimeType: GoogleDriveSyncAdapter.folderMimeType
                ).data(using: .utf8)!
            )
        }

        let adapter = GoogleDriveSyncAdapter(
            accessTokenProvider: { "drive-token" },
            session: makeMockedURLSession()
        )

        let isKnown = try await adapter.isSyncFolderKnown(
            syncFolderID: "sync-folder",
            secretFileName: "ignored-marker"
        )
        let ownershipSentinel = try await adapter.makeSyncFolderKnown(
            syncFolderID: "sync-folder",
            deviceIdentifier: "ios-device"
        )

        XCTAssertTrue(isKnown)
        XCTAssertEqual(ownershipSentinel, GoogleDriveSyncAdapter.ownershipSentinel)
    }

    func testGoogleDriveSyncAdapterReturnsFalseWhenOwnedFolderIsMissing() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let adapter = GoogleDriveSyncAdapter(
            accessTokenProvider: { "drive-token" },
            session: makeMockedURLSession()
        )

        let isKnown = try await adapter.isSyncFolderKnown(
            syncFolderID: "missing-folder",
            secretFileName: "ignored-marker"
        )

        XCTAssertFalse(isKnown)
    }

}
