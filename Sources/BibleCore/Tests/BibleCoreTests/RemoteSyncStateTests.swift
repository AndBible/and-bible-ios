import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Localized startup error used to verify CloudKit container recovery messaging.

 The error is intentionally small and deterministic so tests can assert that recovery reports the
 original CloudKit failure while still falling back to the local SwiftData container.
 */
private enum TestStartupContainerError: LocalizedError {
    case cloudKitModelRejected

    var errorDescription: String? {
        "CloudKit model validation failed"
    }
}

/**
 BibleCore remote-sync state and bootstrap tests migrated out of the app-host bundle.

 This suite protects sync settings persistence, iCloud startup recovery, WebDAV configuration,
 Android-compatible folder bootstrap state, patch discovery, and archive staging. It intentionally
 owns only BibleCore behavior; UIKit, BibleUI, BibleView, SWORD, and WebView imports from the old
 shared `AndBibleTests` class are not required for these contracts.
 */
final class RemoteSyncStateTests: XCTestCase {
    private static let testCloudKitContainerIdentifier = try! ProductCloudKitContainerIdentifier(
        "iCloud.org.andbible.tests"
    )

    /**
     Clears the shared URL protocol handler after WebDAV configuration tests.

     - Side effects: Resets the process-global `MockURLProtocol.requestHandler` fixture.
     - Failure modes: none.
     */
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /**
     Verifies the synced SwiftData schema itself satisfies CloudKit startup validation.

     The crash fallback prevents a bad CloudKit schema from taking the whole app down, but the
     feature contract is stronger: when the user enables iCloud sync, the CloudKit-backed
     `AndBible` store should load instead of immediately falling back to local storage. This test
     constructs the same split cloud/local model set as app startup with isolated store names.
     Failure means the model still contains CloudKit-forbidden constraints, missing relationship
     inverses, or required attributes without declaration-level defaults.
     */
    func testICloudSwiftDataSchemaLoadsWithCloudKitConfiguration() throws {
        let cloudModels: [any PersistentModel.Type] = [
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            ReadingPlan.self,
            ReadingPlanDay.self,
            ReadingPlanDefinitionPublicationState.self,
        ]
        let localModels: [any PersistentModel.Type] = [
            Repository.self,
            Setting.self,
        ]
        let schema = Schema(cloudModels + localModels)
        let storeSuffix = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndBibleCloudCompatibility-\(storeSuffix)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let cloudConfig = ModelConfiguration(
            "AndBibleCloudCompatibility-\(storeSuffix)",
            schema: Schema(cloudModels),
            url: temporaryDirectory.appendingPathComponent("AndBibleCloud.store"),
            cloudKitDatabase: .private(Self.testCloudKitContainerIdentifier.value)
        )
        let localConfig = ModelConfiguration(
            "LocalCompatibility-\(storeSuffix)",
            schema: Schema(localModels),
            url: temporaryDirectory.appendingPathComponent("AndBibleLocal.store"),
            cloudKitDatabase: .none
        )

        _ = try ModelContainer(for: schema, configurations: [cloudConfig, localConfig])
        XCTAssertEqual(ReadingPlanDay().dayNumber, 1)
    }

    /**
     Protects startup recovery when the persisted iCloud toggle points app launch at a
     CloudKit-backed SwiftData container that cannot load.

     The issue-196 crash happened before any view rendered because `AndBibleApp` treated the
     CloudKit container failure as fatal. The recovery contract is that startup retries the same
     store locally, clears the persisted iCloud toggle so the next launch does not repeat the
     crash loop, and reports that the effective runtime mode is local-only.
     */
    func testICloudStartupRecoveryFallsBackToLocalContainerAndDisablesCrashLoopPreference() throws {
        let defaultsName = "org.andbible.tests.icloud-startup-recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        defaults.set(true, forKey: syncEnabledKey)
        var loadAttempts: [String] = []

        let result: ICloudModelContainerStartupRecovery.Result<String> = try ICloudModelContainerStartupRecovery.loadContainer(
            iCloudEnabled: true,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey,
            loadCloudKitContainer: {
                loadAttempts.append("cloud")
                throw TestStartupContainerError.cloudKitModelRejected
            },
            loadLocalContainer: {
                loadAttempts.append("local")
                return "local-container"
            }
        )

        XCTAssertEqual(result.container, "local-container")
        XCTAssertEqual(loadAttempts, ["cloud", "local"])
        XCTAssertFalse(result.effectiveICloudEnabled)
        XCTAssertTrue(result.didRecoverFromCloudKitFailure)
        XCTAssertEqual(result.cloudKitLoadErrorDescription, "CloudKit model validation failed")
        XCTAssertFalse(defaults.bool(forKey: syncEnabledKey))
    }

    /**
     Verifies the normal CloudKit startup path preserves the persisted iCloud toggle.

     The issue-196 recovery must stay limited to failed CloudKit startup. A successful
     CloudKit-backed container load remains the effective runtime mode and must not rewrite the
     bootstrap preference.
     */
    func testICloudStartupRecoveryKeepsICloudEnabledWhenCloudKitContainerLoads() throws {
        let defaultsName = "org.andbible.tests.icloud-startup-success.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        defaults.set(true, forKey: syncEnabledKey)
        var loadAttempts: [String] = []

        let result: ICloudModelContainerStartupRecovery.Result<String> = try ICloudModelContainerStartupRecovery.loadContainer(
            iCloudEnabled: true,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey,
            loadCloudKitContainer: {
                loadAttempts.append("cloud")
                return "cloud-container"
            },
            loadLocalContainer: {
                loadAttempts.append("local")
                return "local-container"
            }
        )

        XCTAssertEqual(result.container, "cloud-container")
        XCTAssertEqual(loadAttempts, ["cloud"])
        XCTAssertTrue(result.effectiveICloudEnabled)
        XCTAssertFalse(result.didRecoverFromCloudKitFailure)
        XCTAssertTrue(defaults.bool(forKey: syncEnabledKey))
    }

    /**
     Verifies local-only startup never probes CloudKit or mutates the iCloud bootstrap toggle.

     This guards Android-parity sync behavior from being coupled to the iOS-only recovery path:
     local startup should remain a plain local container open with the existing preference left
     untouched unless an actual CloudKit failure was recovered.
     */
    func testICloudStartupRecoveryUsesLocalContainerWhenICloudDisabled() throws {
        let defaultsName = "org.andbible.tests.icloud-startup-local.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        defaults.set(false, forKey: syncEnabledKey)
        var loadAttempts: [String] = []

        let result: ICloudModelContainerStartupRecovery.Result<String> = try ICloudModelContainerStartupRecovery.loadContainer(
            iCloudEnabled: false,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey,
            loadCloudKitContainer: {
                loadAttempts.append("cloud")
                return "cloud-container"
            },
            loadLocalContainer: {
                loadAttempts.append("local")
                return "local-container"
            }
        )

        XCTAssertEqual(result.container, "local-container")
        XCTAssertEqual(loadAttempts, ["local"])
        XCTAssertFalse(result.effectiveICloudEnabled)
        XCTAssertFalse(result.didRecoverFromCloudKitFailure)
        XCTAssertFalse(defaults.bool(forKey: syncEnabledKey))
    }

    /**
     Verifies iCloud toggle changes can be applied to the live runtime without entering the
     restart-required state.

     Issue #322 tracks the old behavior where `SyncService` only persisted the requested toggle
     and pinned the UI to `.pendingRestart`. The app now installs a runtime mode-change applier
     that rebuilds the SwiftData stack in-session; the service contract is that a successful
     applier result becomes the active mode immediately and keeps the toggle usable.
     */
    @MainActor
    func testSyncServiceAppliesRuntimeModeChangeWithoutPendingRestart() throws {
        let defaultsName = "org.andbible.tests.sync-toggle-live.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        let service = SyncService(
            cloudKitContainerIdentifier: Self.testCloudKitContainerIdentifier,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey
        )
        service.setInitialState(enabled: false)
        var requestedModes: [Bool] = []
        service.setModeChangeHandler { requestedMode in
            requestedModes.append(requestedMode)
            return SyncModeChangeResult(effectiveEnabled: requestedMode)
        }

        service.toggleSync()

        XCTAssertEqual(requestedModes, [true])
        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.requiresRestart)
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(defaults.bool(forKey: syncEnabledKey))
    }

    /**
     Verifies failed live iCloud mode changes do not leave persisted preferences or UI state in an
     impossible half-applied state.

     The runtime applier is responsible for rebuilding the SwiftData container. When that rebuild
     throws, the service must restore the previous preference and expose an error instead of
     requiring a restart or claiming the requested CloudKit mode is active.
     */
    @MainActor
    func testSyncServiceRevertsPreferenceWhenRuntimeModeChangeFails() throws {
        enum RuntimeModeChangeError: LocalizedError {
            case rejected

            var errorDescription: String? { "CloudKit runtime rebuild failed" }
        }

        let defaultsName = "org.andbible.tests.sync-toggle-failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        defaults.set(false, forKey: syncEnabledKey)
        let service = SyncService(
            cloudKitContainerIdentifier: Self.testCloudKitContainerIdentifier,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey
        )
        service.setInitialState(enabled: false)
        service.setModeChangeHandler { _ in
            throw RuntimeModeChangeError.rejected
        }

        service.toggleSync()

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.requiresRestart)
        XCTAssertEqual(service.state, .error("CloudKit runtime rebuild failed"))
        XCTAssertFalse(defaults.bool(forKey: syncEnabledKey))
    }

    /**
     Verifies failed live iCloud mode changes preserve metadata for the still-active runtime.

     The live mode-change handler throws before `SyncService` accepts a replacement SwiftData
     container. In that path the existing runtime is still current, so rollback should restore the
     persisted mode and expose an error without clearing timestamps that still describe the active
     container.
     */
    @MainActor
    func testSyncServicePreservesCurrentRuntimeMetadataWhenModeChangeFails() throws {
        enum RuntimeModeChangeError: LocalizedError {
            case rejected

            var errorDescription: String? { "CloudKit runtime rebuild failed" }
        }

        let defaultsName = "org.andbible.tests.sync-toggle-failure-metadata.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        defaults.set(true, forKey: syncEnabledKey)
        let service = SyncService(
            cloudKitContainerIdentifier: Self.testCloudKitContainerIdentifier,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey
        )
        service.setInitialState(enabled: true)
        service.recordAccountDescription("Signed in before failed mode change")
        let expectedLastSyncDate = Date(timeIntervalSince1970: 1_805_000_000)
        service.recordRemoteChange(at: expectedLastSyncDate)
        let lastSyncDateBeforeFailure = try XCTUnwrap(service.lastSyncDate)
        let accountDescriptionBeforeFailure = try XCTUnwrap(service.accountDescription)
        service.setModeChangeHandler { _ in
            throw RuntimeModeChangeError.rejected
        }

        service.toggleSync()

        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.requiresRestart)
        XCTAssertEqual(service.state, .error("CloudKit runtime rebuild failed"))
        XCTAssertTrue(defaults.bool(forKey: syncEnabledKey))
        XCTAssertEqual(service.lastSyncDate, lastSyncDateBeforeFailure)
        XCTAssertEqual(service.accountDescription, accountDescriptionBeforeFailure)
    }

    /**
     Preserves the restart-required fallback for hosts that do not install a live runtime applier.

     Production app startup should install the handler, but previews or other test hosts may still
     use `SyncService` directly. Keeping the fallback makes those callers explicit and avoids a
     silent no-op when no runtime stack can be rebuilt.
     */
    @MainActor
    func testSyncServiceFallsBackToPendingRestartWithoutRuntimeModeHandler() throws {
        let defaultsName = "org.andbible.tests.sync-toggle-fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let syncEnabledKey = "icloud_sync_enabled"
        let service = SyncService(
            cloudKitContainerIdentifier: Self.testCloudKitContainerIdentifier,
            defaults: defaults,
            syncEnabledKey: syncEnabledKey
        )
        service.setInitialState(enabled: false)

        service.toggleSync()

        XCTAssertTrue(service.isEnabled)
        XCTAssertTrue(service.requiresRestart)
        XCTAssertEqual(service.state, .pendingRestart)
        XCTAssertTrue(defaults.bool(forKey: syncEnabledKey))
    }

    func testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        XCTAssertEqual(store.selectedBackend, .iCloud)
        XCTAssertNil(store.loadWebDAVConfiguration())
        XCTAssertNil(store.webDAVPassword())
    }

    /**
     Verifies Android-compatible Nextcloud settings trim address fields but preserve password bytes.

     Android's `SharedPrefsDataStore` writes credential text exactly as entered while the server URL,
     username, and folder fields have independent normalization contracts. A failure means iOS could
     silently change a valid app password containing leading or trailing whitespace.
     */
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
        XCTAssertEqual(secretStore.secret(forKey: "gdrive_password"), " secret ")
        XCTAssertEqual(
            store.loadWebDAVConfiguration(),
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example/remote.php/dav/files/alice",
                username: "alice",
                folderPath: "Sync Folder"
            )
        )
        XCTAssertEqual(store.webDAVPassword(), " secret ")
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

    func testRemoteSyncSettingsStoreFallsBackToICloudForRemovedGoogleDriveValue() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString("sync_adapter", value: "GOOGLE_DRIVE")

        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.selectedBackend, .iCloud)
    }

    func testRemoteSyncSettingsStorePreservesExistingNextCloudBackendValue() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString("sync_adapter", value: "NEXT_CLOUD")

        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.selectedBackend, .nextCloud)
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

    /**
     Verifies a whitespace-only password remains exact credential data instead of becoming deletion.

     Android removes the preference only for a null value and otherwise preserves the supplied string.
     A failure means iOS diverges from Android or makes whitespace-bearing credentials unusable.
     */
    func testRemoteSyncSettingsStorePreservesWhitespaceOnlyPassword() throws {
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

        XCTAssertEqual(store.webDAVPassword(), "   ")
        XCTAssertNil(store.loadWebDAVConfiguration()?.folderPath)
    }

    func testRemoteSyncSettingsStorePersistsAndroidCompatibleCategoryToggleKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertFalse(store.isSyncEnabled(for: .bookmarks))
        XCTAssertFalse(store.isSyncEnabled(for: .workspaces))
        XCTAssertFalse(store.isSyncEnabled(for: .readingPlans))
        XCTAssertFalse(store.isSyncEnabled(for: .myDocuments))

        store.setSyncEnabled(true, for: .bookmarks)
        store.setSyncEnabled(true, for: .readingPlans)
        store.setSyncEnabled(false, for: .workspaces)
        store.setSyncEnabled(true, for: .myDocuments)

        XCTAssertEqual(settingsStore.getString("sync_enable_bookmarks"), "true")
        XCTAssertEqual(settingsStore.getString("sync_enable_workspaces"), "false")
        XCTAssertEqual(settingsStore.getString("sync_enable_readingplans"), "true")
        XCTAssertEqual(settingsStore.getString("sync_enable_mydocuments"), "true")
        XCTAssertTrue(store.isSyncEnabled(for: .bookmarks))
        XCTAssertFalse(store.isSyncEnabled(for: .workspaces))
        XCTAssertTrue(store.isSyncEnabled(for: .readingPlans))
        XCTAssertTrue(store.isSyncEnabled(for: .myDocuments))
    }

    func testRemoteSyncSettingsStoreReadsLegacyCategoryToggleKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString("gdrive_mydocuments", value: "true")
        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertTrue(store.isSyncEnabled(for: .myDocuments))

        store.setSyncEnabled(false, for: .myDocuments)
        XCTAssertEqual(settingsStore.getString("sync_enable_mydocuments"), "false")
        XCTAssertFalse(store.isSyncEnabled(for: .myDocuments))
    }

    func testRemoteSyncSettingsStoreGeneratesStableLowercaseDeviceIdentifier() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        let generated = store.deviceIdentifier()
        let reused = store.deviceIdentifier()

        XCTAssertEqual(generated, reused)
        XCTAssertEqual(settingsStore.getString("remote_sync_device_identifier"), generated)
        XCTAssertEqual(generated, generated.lowercased())
        XCTAssertFalse(generated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            return (response, sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = try configuration.makeWebDAVClient(
            password: "secret",
            session: makeMockedURLSession()
        )
        _ = try await client.testConnection()
    }

    /**
     Verifies an explicit Nextcloud DAV endpoint remains the request root without duplicated segments.

     The mocked multistatus response uses hrefs beneath that same custom root so the test exercises
     endpoint preservation without violating the transport's server-path containment contract.
     */
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
            let body = webDAVMultiStatusXML(
                folderPath: "/custom/remote.php/dav/files/alice",
                fileName: "1.1.sqlite3.gz"
            )
            return (response, body.data(using: .utf8)!)
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
        XCTAssertEqual(
            RemoteSyncCategory.myDocuments.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-mydocuments"
        )
    }

    func testRemoteSyncCategoryActiveSyncCasesExposeMyDocuments() {
        XCTAssertEqual(
            RemoteSyncCategory.activeSyncCases,
            [.bookmarks, .workspaces, .readingPlans, .myDocuments, .progress]
        )
    }

    /**
     Verifies folder identifiers retain Android raw keys while the iOS lifecycle phase is durable.

     A restart must recover pending initial work instead of interpreting a configured folder as
     ready. Failure means interrupted adoption can silently skip its required initial restore.
     */
    func testRemoteSyncStateStorePersistsBootstrapStateUsingAndroidRawKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret",
                phase: .awaitingRemoteInitialRestore
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
            settingsStore.getString("remote_sync.bookmarks.bootstrapPhase"),
            "awaitingRemoteInitialRestore"
        )
        XCTAssertEqual(
            store.bootstrapState(for: .bookmarks),
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret",
                phase: .awaitingRemoteInitialRestore
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

    /**
     Verifies a newly selected destination keeps cleanup pending until publication abandonment succeeds.

     The marker is independent of the initial-transfer phase so restart can retry cleanup without
     deleting a durable initial archive after cleanup has already completed.
     */
    func testRemoteSyncStateStorePersistsDestinationCleanupBoundary() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let pendingState = RemoteSyncBootstrapState(
            syncFolderID: "/readingplans",
            deviceFolderID: "/readingplans/ios-device",
            secretFileName: "device-known-secret",
            phase: .awaitingLocalInitialUpload
        )

        try stateStore.setBootstrapStateForNewDestinationAtomically(
            pendingState,
            for: .readingPlans
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans), pendingState)
        XCTAssertTrue(stateStore.requiresPendingPublicationReset(for: .readingPlans))

        try stateStore.markPendingPublicationResetComplete(for: .readingPlans)
        XCTAssertFalse(stateStore.requiresPendingPublicationReset(for: .readingPlans))
        XCTAssertEqual(stateStore.bootstrapState(for: .readingPlans), pendingState)
    }

    func testRemoteSyncStateStoreClearCategoryDoesNotTouchOtherCategories() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/bookmark-sync",
                deviceFolderID: "/bookmark-sync/ios-device",
                secretFileName: "bookmark-secret",
                phase: .awaitingRemoteInitialRestore
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

        let adapter = RemoteSyncMockAdapter()
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

        let adapter = RemoteSyncMockAdapter()
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
        let adapter = RemoteSyncMockAdapter()
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

        let adapter = RemoteSyncMockAdapter()
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

    /**
     Verifies adoption persists a pending restore phase and inspection never reports it as ready.

     The marker/device folder are valid, but incremental sync must remain blocked until the remote
     initial backup publishes successfully. The mock performs no filesystem or network I/O.
     */
    func testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsPendingInitialRestore() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
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
                secretFileName: "device-known-ios-device-secret",
                phase: .awaitingRemoteInitialRestore
            )
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .bookmarks), state)

        await adapter.setKnownResponse(
            true,
            forSyncFolderID: "/org.andbible.ios-sync-bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )
        let inspectedStatus = try await coordinator.inspect(.bookmarks)
        XCTAssertEqual(inspectedStatus, .requiresInitialRestore(state))
    }

    /**
     Verifies remote creation remains pending until the caller uploads the local initial baseline.

     The remote folder replacement and setup complete, but inspection cannot expose the category as
     ready before upload acceptance. Failure means an interrupted create path can skip its baseline.
     */
    func testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = RemoteSyncMockAdapter()
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
                secretFileName: "device-known-ios-device-secret",
                phase: .awaitingLocalInitialUpload
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

    /**
     Verifies authoritative patch-history reads distinguish corrupt metadata from an empty history.

     The compatibility reader remains soft for existing non-critical callers, while the strict reader
     must identify the exact malformed settings key. A failure means outbound numbering or inbound
     discovery could reuse an already accepted patch number after local metadata corruption.
     */
    func testRemoteSyncPatchStatusStoreStrictReadRejectsMalformedAndMismatchedRows() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let malformedKey = store.key(
            for: .readingPlans,
            sourceDevice: "ios-device",
            patchNumber: 4
        )
        settingsStore.setString(malformedKey, value: "{not-json")

        XCTAssertThrowsError(try store.statusesStrict(for: .readingPlans)) { error in
            XCTAssertEqual(
                error as? RemoteSyncPatchStatusStoreError,
                .invalidStoredStatus(malformedKey)
            )
        }
        XCTAssertTrue(store.statuses(for: .readingPlans).isEmpty)

        settingsStore.remove(malformedKey)
        let mismatchedKey = store.key(
            for: .readingPlans,
            sourceDevice: "ios-device",
            patchNumber: 5
        )
        let mismatchedStatus = RemoteSyncPatchStatus(
            sourceDevice: "ios-device",
            patchNumber: 6,
            sizeBytes: 600,
            appliedDate: 6_000
        )
        let payload = try String(
            decoding: JSONEncoder().encode(mismatchedStatus),
            as: UTF8.self
        )
        settingsStore.setString(mismatchedKey, value: payload)

        XCTAssertThrowsError(try store.lastPatchNumberStrict(
            for: .readingPlans,
            sourceDevice: "ios-device"
        )) { error in
            XCTAssertEqual(
                error as? RemoteSyncPatchStatusStoreError,
                .invalidStoredStatus(mismatchedKey)
            )
        }
    }

    /**
     Verifies discovery fails before remote listing when accepted patch metadata is corrupt.

     Treating the malformed row as absent could replay an already applied patch or misclassify a
     sequence gap. The empty adapter event log proves validation precedes every transport operation.
     */
    func testRemoteSyncPatchDiscoveryRejectsCorruptStatusBeforeRemoteListing() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let corruptKey = statusStore.key(
            for: .workspaces,
            sourceDevice: "pixel",
            patchNumber: 2
        )
        settingsStore.setString(corruptKey, value: "{not-json")
        let adapter = RemoteSyncMockAdapter()
        let service = RemoteSyncPatchDiscoveryService(
            adapter: adapter,
            statusStore: statusStore
        )

        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .workspaces,
                bootstrapState: RemoteSyncBootstrapState(
                    syncFolderID: "/org.andbible.ios-sync-workspaces"
                ),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncPatchStatusStoreError,
                .invalidStoredStatus(corruptKey)
            )
        }
        let events = await adapter.eventsSnapshot()
        XCTAssertTrue(events.isEmpty)
    }

    /** Verifies Android `Regex.find` parsing, including unanchored and first-match behavior. */
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
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName(
                "prefix-8.9.sqlite3.gz-suffix"
            )?.patchNumber,
            8
        )
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName(
                "prefix-8.9.sqlite3.gz-suffix"
            )?.schemaVersion,
            9
        )
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName(
                "first-3.sqlite3.gz-second-4.7.sqlite3.gz"
            )?.patchNumber,
            3
        )
        XCTAssertNil(RemoteSyncPatchDiscoveryService.parsePatchFileName("initial.sqlite3.gz"))
    }

    func testRemoteSyncPatchDiscoveryFindsInitialBackup() async throws {
        let adapter = RemoteSyncMockAdapter()
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

        let adapter = RemoteSyncMockAdapter()
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
        let adapter = RemoteSyncMockAdapter()
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

    /**
     Verifies discovery rejects an internal hole after the first expected patch.

     The first-patch check alone admits `{1, 3}`, allowing patch 3 to replay without patch 2 and
     permanently advancing local status past missing mutations. The complete source stream must be
     contiguous before any archive reaches staging.
     */
    func testRemoteSyncPatchDiscoveryThrowsWhenLaterPatchSequenceHasGap() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = RemoteSyncMockAdapter()
        let folderID = "/org.andbible.ios-sync-bookmarks/device-a"
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: folderID,
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "\(folderID)/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 111,
                timestamp: 2_100,
                parentID: folderID,
                mimeType: "application/gzip"
            ),
            RemoteSyncFile(
                id: "\(folderID)/3.1.sqlite3.gz",
                name: "3.1.sqlite3.gz",
                size: 333,
                timestamp: 2_000,
                parentID: folderID,
                mimeType: "application/gzip"
            ),
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)

        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .bookmarks,
                bootstrapState: RemoteSyncBootstrapState(
                    syncFolderID: "/org.andbible.ios-sync-bookmarks"
                ),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 1
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .patchFilesSkipped)
        }
    }

    func testRemoteSyncPatchDiscoveryThrowsWhenRemotePatchNeedsNewerSchema() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = RemoteSyncMockAdapter()
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

    /** Rejects a workspace patch generation that has a migration edge but no Room export. */
    func testRemoteSyncPatchDiscoveryRejectsWorkspaceGenerationWithoutRoomExport() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = RemoteSyncMockAdapter()
        let syncFolderID = "/org.andbible.ios-sync-workspaces"
        let deviceFolderID = "\(syncFolderID)/device-a"
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: deviceFolderID,
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "\(deviceFolderID)/1.10.sqlite3.gz",
                name: "1.10.sqlite3.gz",
                size: 333,
                timestamp: 2_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)
        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .workspaces,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 24
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .incompatiblePatchVersion(10))
        }
    }

    func testRemoteSyncArchiveStagingDownloadsInitialBackupAndExtractsSQLiteFile() async throws {
        let adapter = RemoteSyncMockAdapter()
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
            category: .bookmarks,
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
        let adapter = RemoteSyncMockAdapter()
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
                category: .bookmarks,
                currentSchemaVersion: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncArchiveStagingError,
                .incompatibleInitialBackupVersion(7)
            )
        }
    }

    /** Rejects an initial workspace generation without an authoritative generated Room schema. */
    func testRemoteSyncArchiveStagingRejectsWorkspaceGenerationWithoutRoomExport() async throws {
        let adapter = RemoteSyncMockAdapter()
        let initialDatabaseURL = try makeTemporarySQLiteDatabase(userVersion: 10)
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(
            Data(contentsOf: initialDatabaseURL)
        )
        let remoteID = "/org.andbible.ios-sync-workspaces/initial.sqlite3.gz"
        await adapter.setDownloadData(initialArchiveData, forID: remoteID)

        let service = RemoteSyncArchiveStagingService(adapter: adapter)
        await XCTAssertThrowsErrorAsync(
            try await service.downloadInitialBackup(
                RemoteSyncFile(
                    id: remoteID,
                    name: "initial.sqlite3.gz",
                    size: Int64(initialArchiveData.count),
                    timestamp: 1_000,
                    parentID: "/org.andbible.ios-sync-workspaces",
                    mimeType: NextCloudSyncAdapter.gzipMimeType
                ),
                category: .workspaces,
                currentSchemaVersion: 24
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncArchiveStagingError,
                .incompatibleInitialBackupVersion(10)
            )
        }
    }

    func testRemoteSyncArchiveStagingDownloadsPatchArchivesInSuppliedOrder() async throws {
        let adapter = RemoteSyncMockAdapter()
        let firstArchive = try RemoteSyncArchiveStagingService.gzip(Data("first-archive".utf8))
        let secondArchive = try RemoteSyncArchiveStagingService.gzip(Data("second-archive".utf8))
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
}
