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
        XCTAssertEqual(
            RemoteSyncCategory.myDocuments.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-mydocuments"
        )
    }

    func testRemoteSyncCategoryActiveSyncCasesExposeMyDocuments() {
        XCTAssertEqual(
            RemoteSyncCategory.activeSyncCases,
            [.bookmarks, .workspaces, .readingPlans, .myDocuments]
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

    /// Verifies that synchronization stops at the Android adopt-vs-create branch when a same-named remote folder exists.
}
