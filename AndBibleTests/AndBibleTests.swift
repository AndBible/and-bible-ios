import XCTest
@testable import BibleCore
import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI

final class AndBibleTests: XCTestCase {
    private var temporarySwordModulePaths: [String] = []

    override func tearDown() {
        let fm = FileManager.default
        for path in temporarySwordModulePaths {
            try? fm.removeItem(atPath: path)
        }
        temporarySwordModulePaths.removeAll()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAppPreferenceRegistryHasDefinitionForAllKeys() {
        let keys = AppPreferenceKey.allCases
        XCTAssertEqual(keys.count, 35)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(AppPreferenceRegistry.definitions.count, keys.count)

        for key in keys {
            XCTAssertEqual(AppPreferenceRegistry.definition(for: key).key, key)
        }
    }

    func testCriticalPreferenceDefaultsMatchParityContract() {
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .nightModePref3), "system")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .toolbarButtonActions), "default")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .bibleViewSwipeMode), "CHAPTER")
        XCTAssertEqual(AppPreferenceRegistry.intDefault(for: .fontSizeMultiplier), 100)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .openLinksInSpecialWindowPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref), true)
    }

    func testActionPreferencesUseActionShape() {
        let actionKeys: [AppPreferenceKey] = [
            .discreteHelp,
            .openLinks,
            .crashApp,
        ]

        for key in actionKeys {
            let definition = AppPreferenceRegistry.definition(for: key)
            if case .action = definition.storage {
                // expected
            } else {
                XCTFail("Expected .action storage for \(key.rawValue)")
            }
            if case .action = definition.valueType {
                // expected
            } else {
                XCTFail("Expected .action valueType for \(key.rawValue)")
            }
            XCTAssertNil(definition.defaultValue)
        }
    }

    func testCSVSetEncodingAndDecodingRoundTrip() {
        let encoded = AppPreferenceRegistry.encodeCSVSet(["  KJV  ", "", "ESV", "KJV", "  "])
        XCTAssertEqual(encoded, "ESV,KJV,KJV")
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(encoded), ["ESV", "KJV", "KJV"])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(nil), [])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(""), [])
    }

    func testStrongsQueryNormalizationHandlesLeadingZeroes() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H02022")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H02022", "Word//Lemma./H2022"]
        )
    }

    func testStrongsQueryNormalizationAcceptsDecoratedInput() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "lemma:strong:g00123")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./G00123", "Word//Lemma./G123"]
        )
    }

    func testParseVerseKeySupportsHumanReadableFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("I Samuel 2:3")
        XCTAssertEqual(parsed?.book, "I Samuel")
        XCTAssertEqual(parsed?.chapter, 2)
        XCTAssertEqual(parsed?.verse, 3)
    }

    func testParseVerseKeySupportsOsisFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testParseVerseKeySupportsOsisFormatWithSuffix() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1!crossReference.a")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testStrongsSearchFindAllOccurrencesReturnsBundledKJVMatches() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let installedModules = manager.installedModules()
        XCTAssertTrue(
            installedModules.contains(where: { $0.name == "KJV" && $0.features.contains(.strongsNumbers) }),
            "Expected bundled KJV module with Strong's support to be installed for regression testing"
        )

        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H02022"),
            "Expected H02022 to normalize into entry-attribute Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions)

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the bundled KJV Strong's search for H02022 to return at least one verse"
        )
        XCTAssertTrue(
            hits.allSatisfy { !$0.reference.isEmpty },
            "Expected Strong's hits to parse into verse references"
        )
    }

    func testBookmarkStoreBibleBookmarksCanFilterByLabel() throws {
        let schema = Schema([
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = BookmarkStore(modelContext: ModelContext(container))

        let matchingLabel = Label(name: "Matching")
        let otherLabel = Label(name: "Other")
        store.insert(matchingLabel)
        store.insert(otherLabel)

        let matchingBookmark = BibleBookmark(kjvOrdinalStart: 1, kjvOrdinalEnd: 1)
        matchingBookmark.book = "Genesis"
        store.insert(matchingBookmark)

        let otherBookmark = BibleBookmark(kjvOrdinalStart: 2, kjvOrdinalEnd: 2)
        otherBookmark.book = "Genesis"
        store.insert(otherBookmark)

        let matchingJunction = BibleBookmarkToLabel()
        matchingJunction.bookmark = matchingBookmark
        matchingJunction.label = matchingLabel
        store.insert(matchingJunction)

        let otherJunction = BibleBookmarkToLabel()
        otherJunction.bookmark = otherBookmark
        otherJunction.label = otherLabel
        store.insert(otherJunction)

        let filtered = store.bibleBookmarks(labelId: matchingLabel.id)

        XCTAssertEqual(filtered.map(\.id), [matchingBookmark.id])
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

    func testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        XCTAssertEqual(store.selectedBackend, .iCloud)
        XCTAssertNil(store.loadWebDAVConfiguration())
        XCTAssertNil(store.webDAVPassword())
    }

    func testRemoteSyncSettingsStorePersistsAndroidCompatibleNextCloudKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        store.selectedBackend = .nextCloud
        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: " https://nextcloud.example/remote.php/dav/files/alice ",
                username: " alice ",
                folderPath: " Sync Folder "
            ),
            password: " secret "
        )

        XCTAssertEqual(settingsStore.getString("sync_adapter"), "NEXT_CLOUD")
        XCTAssertEqual(
            settingsStore.getString("gdrive_server_url"),
            "https://nextcloud.example/remote.php/dav/files/alice"
        )
        XCTAssertEqual(settingsStore.getString("gdrive_username"), "alice")
        XCTAssertEqual(settingsStore.getString("gdrive_folder_path"), "Sync Folder")
        XCTAssertEqual(secretStore.secret(forKey: "gdrive_password"), "secret")
        XCTAssertEqual(
            store.loadWebDAVConfiguration(),
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example/remote.php/dav/files/alice",
                username: "alice",
                folderPath: "Sync Folder"
            )
        )
        XCTAssertEqual(store.webDAVPassword(), "secret")
    }

    func testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString("sync_adapter", value: "DROPBOX")

        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.selectedBackend, .iCloud)
    }

    func testRemoteSyncSettingsStoreClearsStoredValuesAndPassword() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        store.selectedBackend = .nextCloud
        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example",
                username: "alice",
                folderPath: "sync"
            ),
            password: "secret"
        )

        try store.clearWebDAVConfiguration()

        XCTAssertEqual(store.selectedBackend, .nextCloud)
        XCTAssertNil(store.loadWebDAVConfiguration())
        XCTAssertNil(store.webDAVPassword())
        XCTAssertEqual(settingsStore.getString("gdrive_server_url"), "")
        XCTAssertEqual(settingsStore.getString("gdrive_username"), "")
        XCTAssertEqual(settingsStore.getString("gdrive_folder_path"), "")
    }

    func testRemoteSyncSettingsStoreClearsPasswordWhenSaveReceivesWhitespaceOnlySecret() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        XCTAssertEqual(store.webDAVPassword(), "secret")

        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example",
                username: "alice",
                folderPath: nil
            ),
            password: "   "
        )

        XCTAssertNil(store.webDAVPassword())
        XCTAssertNil(store.loadWebDAVConfiguration()?.folderPath)
    }

    func testWebDAVSyncConfigurationExpandsServerRootToNextCloudDAVEndpoint() async throws {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com",
            username: "alice",
            folderPath: nil
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://nextcloud.example.com/remote.php/dav/files/alice"
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = try configuration.makeWebDAVClient(
            password: "secret",
            session: makeMockedURLSession()
        )
        _ = try await client.testConnection()
    }

    func testWebDAVSyncConfigurationPreservesExplicitDAVEndpoint() async throws {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com/custom/remote.php/dav/files/alice",
            username: "alice",
            folderPath: nil
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://nextcloud.example.com/custom/remote.php/dav/files/alice"
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = try configuration.makeWebDAVClient(
            password: "secret",
            session: makeMockedURLSession()
        )
        _ = try await client.testConnection()
    }

    func testRemoteSyncSettingsStoreMakeWebDAVClientReturnsNilWhenPasswordMissing() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: nil
        )

        XCTAssertNil(try store.makeWebDAVClient(session: makeMockedURLSession()))
    }

    func testRemoteSyncCategoryBuildsAndroidStyleFolderNames() {
        XCTAssertEqual(
            RemoteSyncCategory.bookmarks.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-bookmarks"
        )
        XCTAssertEqual(
            RemoteSyncCategory.workspaces.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-workspaces"
        )
        XCTAssertEqual(
            RemoteSyncCategory.readingPlans.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-readingplans"
        )
    }

    func testRemoteSyncStateStorePersistsBootstrapStateUsingAndroidRawKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        XCTAssertEqual(
            settingsStore.getString("remote_sync.bookmarks.syncId"),
            "/org.andbible.ios-sync-bookmarks"
        )
        XCTAssertEqual(
            settingsStore.getString("remote_sync.bookmarks.deviceFolderId"),
            "/org.andbible.ios-sync-bookmarks/ios-device"
        )
        XCTAssertEqual(
            settingsStore.getString("remote_sync.bookmarks.nextCloudSecretFile"),
            "device-known-ios-device-secret"
        )
        XCTAssertEqual(
            store.bootstrapState(for: .bookmarks),
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
    }

    func testRemoteSyncStateStorePersistsProgressStatePerCategory() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 111,
                lastSynchronized: 222,
                disabledForVersion: 7
            ),
            for: .workspaces
        )
        store.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 333,
                lastSynchronized: nil,
                disabledForVersion: nil
            ),
            for: .bookmarks
        )

        XCTAssertEqual(
            store.progressState(for: .workspaces),
            RemoteSyncProgressState(
                lastPatchWritten: 111,
                lastSynchronized: 222,
                disabledForVersion: 7
            )
        )
        XCTAssertEqual(
            store.progressState(for: .bookmarks),
            RemoteSyncProgressState(
                lastPatchWritten: 333,
                lastSynchronized: nil,
                disabledForVersion: nil
            )
        )
    }

    func testRemoteSyncStateStoreClearCategoryDoesNotTouchOtherCategories() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/bookmark-sync",
                deviceFolderID: "/bookmark-sync/ios-device",
                secretFileName: "bookmark-secret"
            ),
            for: .bookmarks
        )
        store.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 444,
                lastSynchronized: 555,
                disabledForVersion: 8
            ),
            for: .bookmarks
        )
        store.setBootstrapState(
            RemoteSyncBootstrapState(syncFolderID: "/workspace-sync"),
            for: .workspaces
        )

        store.clearCategory(.bookmarks)

        XCTAssertEqual(store.bootstrapState(for: .bookmarks), RemoteSyncBootstrapState())
        XCTAssertEqual(store.progressState(for: .bookmarks), RemoteSyncProgressState())
        XCTAssertEqual(
            store.bootstrapState(for: .workspaces),
            RemoteSyncBootstrapState(syncFolderID: "/workspace-sync")
        )
    }

    func testRemoteSyncBootstrapCoordinatorReturnsReadyForKnownStoredFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: "/org.andbible.ios-sync-bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .ready(
                RemoteSyncBootstrapState(
                    syncFolderID: "/org.andbible.ios-sync-bookmarks",
                    deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                    secretFileName: "device-known-ios-device-secret"
                )
            )
        )
        let events = await adapter.eventsSnapshot()

        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                secretFileName: "device-known-ios-device-secret"
            )
        ])
    }

    func testRemoteSyncBootstrapCoordinatorRepairsMissingDeviceFolderForKnownStoredFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: nil,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: "/org.andbible.ios-sync-bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 0,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .ready(
                RemoteSyncBootstrapState(
                    syncFolderID: "/org.andbible.ios-sync-bookmarks",
                    deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                    secretFileName: "device-known-ios-device-secret"
                )
            )
        )
        XCTAssertEqual(
            stateStore.bootstrapState(for: .bookmarks),
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
    }

    func testRemoteSyncBootstrapCoordinatorRequiresRemoteAdoptionWhenNamedFolderExists() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = MockRemoteSyncAdapter()
        await adapter.setListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks",
                name: "org.andbible.ios-sync-bookmarks",
                size: 0,
                timestamp: 123,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .requiresRemoteAdoption(
                RemoteSyncBootstrapCandidate(
                    category: .bookmarks,
                    syncFolderName: "org.andbible.ios-sync-bookmarks",
                    remoteFolderID: "/org.andbible.ios-sync-bookmarks"
                )
            )
        )
    }

    func testRemoteSyncBootstrapCoordinatorClearsStaleBootstrapAndRequestsCreationWhenMarkerMissing() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/stale-bookmarks",
                deviceFolderID: "/stale-bookmarks/ios-device",
                secretFileName: "stale-secret"
            ),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(false, forSyncFolderID: "/stale-bookmarks", secretFileName: "stale-secret")
        await adapter.setListFilesResult([])

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .requiresRemoteCreation(
                RemoteSyncBootstrapCreation(
                    category: .bookmarks,
                    syncFolderName: "org.andbible.ios-sync-bookmarks"
                )
            )
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .bookmarks), RemoteSyncBootstrapState())
    }

    func testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsMarkerAndDeviceFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = MockRemoteSyncAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 0,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let state = try await coordinator.adoptRemoteFolder(
            for: .bookmarks,
            remoteFolderID: "/org.andbible.ios-sync-bookmarks"
        )

        XCTAssertEqual(
            state,
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .bookmarks), state)
    }

    func testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = MockRemoteSyncAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks",
                name: "org.andbible.ios-sync-bookmarks",
                size: 0,
                timestamp: 0,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 0,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let state = try await coordinator.createRemoteFolder(
            for: .bookmarks,
            replacingRemoteFolderID: "/stale-remote-bookmarks"
        )

        XCTAssertEqual(
            state,
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
        let events = await adapter.eventsSnapshot()

        XCTAssertEqual(events, [
            .delete(id: "/stale-remote-bookmarks"),
            .createFolder(name: "org.andbible.ios-sync-bookmarks", parentID: nil),
            .makeKnown(syncFolderID: "/org.andbible.ios-sync-bookmarks", deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: "/org.andbible.ios-sync-bookmarks"),
        ])
    }

    func testRemoteSyncPatchStatusStorePersistsAndQueriesStatuses() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        store.addStatuses([
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 1, sizeBytes: 100, appliedDate: 1_000),
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 2, sizeBytes: 200, appliedDate: 2_000),
            RemoteSyncPatchStatus(sourceDevice: "device-b", patchNumber: 1, sizeBytes: 300, appliedDate: 3_000),
        ], for: .bookmarks)

        XCTAssertEqual(
            store.status(for: .bookmarks, sourceDevice: "device-a", patchNumber: 2),
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 2, sizeBytes: 200, appliedDate: 2_000)
        )
        XCTAssertEqual(store.lastPatchNumber(for: .bookmarks, sourceDevice: "device-a"), 2)
        XCTAssertEqual(store.totalBytesUsed(for: .bookmarks), 600)
        XCTAssertEqual(store.statuses(for: .bookmarks).count, 3)
    }

    func testRemoteSyncPatchStatusStoreClearCategoryDoesNotTouchOtherCategories() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        store.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 1, sizeBytes: 100, appliedDate: 1_000),
            for: .bookmarks
        )
        store.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "device-b", patchNumber: 1, sizeBytes: 200, appliedDate: 2_000),
            for: .workspaces
        )

        store.clearCategory(.bookmarks)

        XCTAssertTrue(store.statuses(for: .bookmarks).isEmpty)
        XCTAssertEqual(store.statuses(for: .workspaces).count, 1)
    }

    func testRemoteSyncPatchDiscoveryParsesAndroidPatchFileNames() {
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName("7.12.sqlite3.gz")?.patchNumber,
            7
        )
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName("7.12.sqlite3.gz")?.schemaVersion,
            12
        )
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName("5.sqlite3.gz")?.schemaVersion,
            1
        )
        XCTAssertNil(RemoteSyncPatchDiscoveryService.parsePatchFileName("initial.sqlite3.gz"))
    }

    func testRemoteSyncPatchDiscoveryFindsInitialBackup() async throws {
        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 123,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            )
        ])
        let service = RemoteSyncPatchDiscoveryService(
            adapter: adapter,
            statusStore: RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        )

        let file = try await service.findInitialBackup(syncFolderID: "/org.andbible.ios-sync-bookmarks")

        XCTAssertEqual(file?.name, "initial.sqlite3.gz")
    }

    func testRemoteSyncPatchDiscoveryReturnsPendingPatchesFilteredByAppliedStatus() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        statusStore.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 1, sizeBytes: 100, appliedDate: 1_000),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a",
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            ),
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-b",
                name: "device-b",
                size: 0,
                timestamp: 1_100,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            ),
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 111,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            ),
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz",
                name: "2.1.sqlite3.gz",
                size: 222,
                timestamp: 2_100,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            ),
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 333,
                timestamp: 2_050,
                parentID: "/org.andbible.ios-sync-bookmarks/device-b",
                mimeType: "application/gzip"
            ),
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)
        let result = try await service.discoverPendingPatches(
            for: .bookmarks,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/org.andbible.ios-sync-bookmarks"),
            progressState: RemoteSyncProgressState(lastSynchronized: 100_000),
            currentSchemaVersion: 1
        )

        XCTAssertEqual(result.deviceFolders.map(\.name), ["device-a", "device-b"])
        XCTAssertEqual(result.pendingPatches.count, 2)
        XCTAssertEqual(result.pendingPatches[0].sourceDevice, "device-b")
        XCTAssertEqual(result.pendingPatches[0].patchNumber, 1)
        XCTAssertEqual(result.pendingPatches[1].sourceDevice, "device-a")
        XCTAssertEqual(result.pendingPatches[1].patchNumber, 2)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-bookmarks"],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [
                    "/org.andbible.ios-sync-bookmarks/device-a",
                    "/org.andbible.ios-sync-bookmarks/device-b",
                ],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: Date(timeIntervalSince1970: 100)
            ),
        ])
    }

    func testRemoteSyncPatchDiscoveryThrowsWhenPatchSequenceHasGap() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a",
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/3.1.sqlite3.gz",
                name: "3.1.sqlite3.gz",
                size: 333,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            )
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)

        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .bookmarks,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/org.andbible.ios-sync-bookmarks"),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 1
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .patchFilesSkipped)
        }
    }

    func testRemoteSyncPatchDiscoveryThrowsWhenRemotePatchNeedsNewerSchema() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a",
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/1.7.sqlite3.gz",
                name: "1.7.sqlite3.gz",
                size: 333,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            )
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)

        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .bookmarks,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/org.andbible.ios-sync-bookmarks"),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 3
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .incompatiblePatchVersion(7))
        }
    }

    func testRemoteSyncArchiveStagingDownloadsInitialBackupAndExtractsSQLiteFile() async throws {
        let adapter = MockRemoteSyncAdapter()
        let initialDatabaseURL = try makeTemporarySQLiteDatabase(userVersion: 3)
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        await adapter.setDownloadData(initialArchiveData, forID: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz")

        let service = RemoteSyncArchiveStagingService(adapter: adapter)
        let stagedBackup = try await service.downloadInitialBackup(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: Int64(initialArchiveData.count),
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            ),
            currentSchemaVersion: 5
        )

        XCTAssertEqual(stagedBackup.schemaVersion, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedBackup.databaseFileURL.path))
        XCTAssertEqual(try readSQLiteUserVersion(at: stagedBackup.databaseFileURL), 3)
        let initialEvents = await adapter.eventsSnapshot()
        XCTAssertEqual(initialEvents, [
            .download(id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz")
        ])

        service.cleanupInitialBackup(stagedBackup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedBackup.databaseFileURL.path))
    }

    func testRemoteSyncArchiveStagingRejectsInitialBackupWithNewerSchemaVersion() async throws {
        let adapter = MockRemoteSyncAdapter()
        let initialDatabaseURL = try makeTemporarySQLiteDatabase(userVersion: 7)
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        await adapter.setDownloadData(initialArchiveData, forID: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz")

        let service = RemoteSyncArchiveStagingService(adapter: adapter)

        await XCTAssertThrowsErrorAsync(
            try await service.downloadInitialBackup(
                RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                    name: "initial.sqlite3.gz",
                    size: Int64(initialArchiveData.count),
                    timestamp: 1_000,
                    parentID: "/org.andbible.ios-sync-bookmarks",
                    mimeType: "application/gzip"
                ),
                currentSchemaVersion: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncArchiveStagingError,
                .incompatibleInitialBackupVersion(7)
            )
        }
    }

    func testRemoteSyncArchiveStagingDownloadsPatchArchivesInSuppliedOrder() async throws {
        let adapter = MockRemoteSyncAdapter()
        let firstArchive = Data("first-archive".utf8)
        let secondArchive = Data("second-archive".utf8)
        await adapter.setDownloadData(firstArchive, forID: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz")
        await adapter.setDownloadData(secondArchive, forID: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz")

        let service = RemoteSyncArchiveStagingService(adapter: adapter)
        let stagedArchives = try await service.downloadPatchArchives([
            RemoteSyncDiscoveredPatch(
                sourceDevice: "device-b",
                patchNumber: 1,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz",
                    name: "1.1.sqlite3.gz",
                    size: Int64(firstArchive.count),
                    timestamp: 1_000,
                    parentID: "/org.andbible.ios-sync-bookmarks/device-b",
                    mimeType: "application/gzip"
                )
            ),
            RemoteSyncDiscoveredPatch(
                sourceDevice: "device-a",
                patchNumber: 2,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz",
                    name: "2.1.sqlite3.gz",
                    size: Int64(secondArchive.count),
                    timestamp: 1_200,
                    parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                    mimeType: "application/gzip"
                )
            ),
        ])

        XCTAssertEqual(stagedArchives.map(\.patch.sourceDevice), ["device-b", "device-a"])
        XCTAssertEqual(try Data(contentsOf: stagedArchives[0].archiveFileURL), firstArchive)
        XCTAssertEqual(try Data(contentsOf: stagedArchives[1].archiveFileURL), secondArchive)
        let patchDownloadEvents = await adapter.eventsSnapshot()
        XCTAssertEqual(patchDownloadEvents, [
            .download(id: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz"),
            .download(id: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz"),
        ])

        service.cleanupPatchArchives(stagedArchives)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedArchives[0].archiveFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedArchives[1].archiveFileURL.path))
    }

    func testWebDAVSyncConfigurationRejectsLoginPageURLs() {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com/login",
            username: "alice",
            folderPath: nil
        )

        XCTAssertThrowsError(try configuration.resolvedDAVBaseURL()) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidURL)
        }
    }

    private func makeTemporaryBundledSwordPath() throws -> String {
        let fm = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledSwordURL = sourceRoot
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        XCTAssertTrue(
            fm.fileExists(atPath: bundledSwordURL.path),
            "Expected repo-bundled sword resources at \(bundledSwordURL.path)"
        )

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(from: bundledSwordURL, to: tempRoot)

        temporarySwordModulePaths.append(tempRoot.path)
        return tempRoot.path
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyDirectoryContents(from: item, to: target)
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    private func makeMockedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeInMemorySettingsStore() throws -> SettingsStore {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SettingsStore(modelContext: ModelContext(container))
    }

    private func requestBodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    private static let sampleWebDAVMultiStatusXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>/remote.php/dav/files/alice/sync/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>sync</d:displayname>
            <d:resourcetype><d:collection /></d:resourcetype>
            <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/sync/1.1.sqlite3.gz</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>1.1.sqlite3.gz</d:displayname>
            <d:getcontentlength>12345</d:getcontentlength>
            <d:getcontenttype>application/gzip</d:getcontenttype>
            <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static func webDAVMultiStatusXML(folderPath: String, fileName: String) -> String {
        let normalizedFolderPath = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>\(normalizedFolderPath)</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>\(normalizedFolderPath.split(separator: "/").last.map(String.init) ?? "")</d:displayname>
                <d:resourcetype><d:collection /></d:resourcetype>
                <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>\(normalizedFolderPath)\(fileName)</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>\(fileName)</d:displayname>
                <d:getcontentlength>12345</d:getcontentlength>
                <d:getcontenttype>application/gzip</d:getcontenttype>
                <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """
    }
}

private final class InMemorySecretStore: SecretStoring {
    private var secrets: [String: String] = [:]

    func secret(forKey key: String) -> String? {
        secrets[key]
    }

    func setSecret(_ value: String, forKey key: String) throws {
        secrets[key] = value
    }

    func removeSecret(forKey key: String) throws {
        secrets.removeValue(forKey: key)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RequestLogEntry] = []

    func append(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(RequestLogEntry(method: method, path: path))
    }

    func snapshot() -> [RequestLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private struct RequestLogEntry: Equatable {
    let method: String
    let path: String
}

private actor MockRemoteSyncAdapter: RemoteSyncAdapting {
    private var fallbackListFilesResult: [RemoteSyncFile] = []
    private var listFilesResultsQueue: [[RemoteSyncFile]] = []
    private var createFolderResults: [RemoteSyncFile] = []
    private var downloadDataByID: [String: Data] = [:]
    private var knownResponses: [String: Bool] = [:]
    private var makeKnownResponse = "device-known-default"
    private var events: [MockRemoteSyncAdapterEvent] = []

    func setListFilesResult(_ result: [RemoteSyncFile]) {
        fallbackListFilesResult = result
    }

    func enqueueListFilesResult(_ result: [RemoteSyncFile]) {
        listFilesResultsQueue.append(result)
    }

    func enqueueCreateFolderResult(_ result: RemoteSyncFile) {
        createFolderResults.append(result)
    }

    func setDownloadData(_ data: Data, forID id: String) {
        downloadDataByID[id] = data
    }

    func setKnownResponse(_ value: Bool, forSyncFolderID syncFolderID: String, secretFileName: String) {
        knownResponses["\(syncFolderID)|\(secretFileName)"] = value
    }

    func setMakeKnownResponse(_ value: String) {
        makeKnownResponse = value
    }

    func eventsSnapshot() -> [MockRemoteSyncAdapterEvent] {
        events
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
        if !listFilesResultsQueue.isEmpty {
            return listFilesResultsQueue.removeFirst()
        }
        return fallbackListFilesResult
    }

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

    func download(id: String) async throws -> Data {
        events.append(.download(id: id))
        return downloadDataByID[id] ?? Data()
    }

    func delete(id: String) async throws {
        events.append(.delete(id: id))
    }

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        events.append(.isSyncFolderKnown(syncFolderID: syncFolderID, secretFileName: secretFileName))
        return knownResponses["\(syncFolderID)|\(secretFileName)"] ?? false
    }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        events.append(.makeKnown(syncFolderID: syncFolderID, deviceIdentifier: deviceIdentifier))
        return makeKnownResponse
    }
}

private enum MockRemoteSyncAdapterEvent: Equatable {
    case listFiles(parentIDs: [String]?, name: String?, mimeType: String?, modifiedAtLeast: Date?)
    case createFolder(name: String, parentID: String?)
    case download(id: String)
    case delete(id: String)
    case isSyncFolderKnown(syncFolderID: String, secretFileName: String)
    case makeKnown(syncFolderID: String, deviceIdentifier: String)
}

private func makeTemporarySQLiteDatabase(userVersion: Int) throws -> URL {
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
        throw NSError(domain: "AndBibleTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "PRAGMA user_version = \(userVersion);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 2)
    }
    guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS sample (id INTEGER PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 3)
    }
    guard sqlite3_exec(database, "INSERT INTO sample (value) VALUES ('fixture');", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 4)
    }

    return url
}

private func readSQLiteUserVersion(at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 5)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        if let statement {
            sqlite3_finalize(statement)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 6)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 7)
    }
    return Int(sqlite3_column_int(statement, 0))
}

private func XCTAssertThrowsErrorAsync<T>(
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
