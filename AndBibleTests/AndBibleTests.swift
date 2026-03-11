import XCTest
@testable import BibleCore
import SwordKit
import SwiftData
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
