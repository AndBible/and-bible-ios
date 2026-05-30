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

    func testWorkspaceStoreCreateRenameCloneAndDeleteRoundTripsWorkspaceGraph() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)

        let source = store.createWorkspace(name: "Original")
        let later = store.createWorkspace(name: "Later")
        XCTAssertEqual(store.workspaces().map(\.name), ["Original", "Later"])

        let sourcePrimaryWindow = try XCTUnwrap((source.windows ?? []).first)
        store.addHistoryItem(to: sourcePrimaryWindow, document: "KJV", key: "Gen.1.1")
        let secondaryWindow = store.addWindow(to: source, document: "KJV", category: "bible")
        store.addHistoryItem(to: secondaryWindow, document: "KJV", key: "Gen.1.2")

        store.renameWorkspace(source, to: "Renamed")
        XCTAssertEqual(source.name, "Renamed")

        let clone = store.cloneWorkspace(source, newName: "Clone")

        XCTAssertEqual(store.workspaces().map(\.name), ["Renamed", "Clone", "Later"])
        XCTAssertEqual(clone.orderNumber, source.orderNumber + 1)
        XCTAssertEqual(later.orderNumber, 2)
        XCTAssertEqual(clone.windows?.count, source.windows?.count)

        let clonedWindows = (clone.windows ?? []).sorted { $0.orderNumber < $1.orderNumber }
        let sourceWindows = (source.windows ?? []).sorted { $0.orderNumber < $1.orderNumber }
        XCTAssertEqual(clonedWindows.count, sourceWindows.count)
        XCTAssertTrue(Set(clonedWindows.map(\.id)).isDisjoint(with: Set(sourceWindows.map(\.id))))
        XCTAssertEqual(clonedWindows.compactMap(\.pageManager).count, sourceWindows.compactMap(\.pageManager).count)
        XCTAssertEqual(clonedWindows.reduce(into: 0) { $0 += $1.historyItems?.count ?? 0 },
                       sourceWindows.reduce(into: 0) { $0 += $1.historyItems?.count ?? 0 })

        store.delete(clone)

        XCTAssertNil(store.workspace(id: clone.id))
        XCTAssertEqual(store.workspaces().map(\.name), ["Renamed", "Later"])
    }

    func testWorkspaceStoreCreateWorkspaceInheritsWorkspaceScopedDefaultsWithoutCloningGraph() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)

        let source = store.createWorkspace(name: "Source")
        var workspaceDisplaySettings = TextDisplaySettings()
        workspaceDisplaySettings.fontSize = 19
        workspaceDisplaySettings.fontFamily = "serif"
        workspaceDisplaySettings.lineSpacing = 18
        workspaceDisplaySettings.strongsMode = 2
        workspaceDisplaySettings.dayTextColor = Int(Int32(bitPattern: 0xFF112233))
        workspaceDisplaySettings.dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        workspaceDisplaySettings.dayNoise = 7
        workspaceDisplaySettings.nightTextColor = Int(Int32(bitPattern: 0xFFF1E7D0))
        workspaceDisplaySettings.nightBackground = Int(Int32(bitPattern: 0xFF101820))
        workspaceDisplaySettings.nightNoise = 5
        source.textDisplaySettings = workspaceDisplaySettings

        let recentLabelID = UUID()
        let autoAssignLabelID = UUID()
        let primaryLabelID = UUID()
        let studyPadLabelID = UUID()
        source.workspaceSettings = WorkspaceSettings(
            enableTiltToScroll: true,
            enableReverseSplitMode: true,
            autoPin: true,
            recentLabels: [RecentLabel(labelId: recentLabelID)],
            autoAssignLabels: [autoAssignLabelID],
            autoAssignPrimaryLabel: primaryLabelID,
            studyPadCursors: [studyPadLabelID: 3],
            hideCompareDocuments: ["KJV"],
            limitAmbiguousModalSize: true
        )
        source.workspaceColor = Int(Int32(bitPattern: 0xFF335577))
        source.unPinnedWeight = 0.75

        let sourcePrimaryWindow = try XCTUnwrap((source.windows ?? []).first)
        var windowDisplaySettings = TextDisplaySettings()
        windowDisplaySettings.fontSize = 24
        sourcePrimaryWindow.pageManager?.textDisplaySettings = windowDisplaySettings
        store.addHistoryItem(to: sourcePrimaryWindow, document: "KJV", key: "Gen.1.1")
        _ = store.addWindow(to: source, document: "KJV", category: "bible")

        let created = store.createWorkspace(name: "Inherited", inheritingDefaultsFrom: source)

        XCTAssertEqual(created.textDisplaySettings, source.textDisplaySettings?.clearingThemeColors())
        XCTAssertNil(created.textDisplaySettings?.dayTextColor)
        XCTAssertNil(created.textDisplaySettings?.dayBackground)
        XCTAssertNil(created.textDisplaySettings?.dayNoise)
        XCTAssertNil(created.textDisplaySettings?.nightTextColor)
        XCTAssertNil(created.textDisplaySettings?.nightBackground)
        XCTAssertNil(created.textDisplaySettings?.nightNoise)
        XCTAssertEqual(created.workspaceColor, source.workspaceColor)
        XCTAssertEqual(created.workspaceSettings?.enableTiltToScroll, true)
        XCTAssertEqual(created.workspaceSettings?.enableReverseSplitMode, true)
        XCTAssertEqual(created.workspaceSettings?.autoPin, true)
        XCTAssertEqual(created.workspaceSettings?.recentLabels.count, 1)
        XCTAssertEqual(created.workspaceSettings?.recentLabels.first?.labelId, recentLabelID)
        XCTAssertEqual(created.workspaceSettings?.autoAssignLabels.count, 1)
        XCTAssertEqual(created.workspaceSettings?.autoAssignLabels.first, autoAssignLabelID)
        XCTAssertEqual(created.workspaceSettings?.autoAssignPrimaryLabel, primaryLabelID)
        XCTAssertEqual(created.workspaceSettings?.studyPadCursors.count, 1)
        XCTAssertEqual(created.workspaceSettings?.studyPadCursors[studyPadLabelID], 3)
        XCTAssertEqual(created.workspaceSettings?.hideCompareDocuments, ["KJV"])
        XCTAssertEqual(created.workspaceSettings?.limitAmbiguousModalSize, true)
        XCTAssertNil(created.unPinnedWeight)

        let createdWindows = created.windows ?? []
        XCTAssertEqual(createdWindows.count, 1)
        let createdWindow = try XCTUnwrap(createdWindows.first)
        XCTAssertTrue(createdWindow.historyItems?.isEmpty ?? true)
        XCTAssertEqual(createdWindow.pageManager?.currentCategoryName, "bible")
        XCTAssertNil(createdWindow.pageManager?.textDisplaySettings)
    }

    func testWindowManagerMarksVisibleWindowPendingUntilControllerRegisters() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Controller Readiness")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)

        windowManager.setActiveWorkspace(workspace)

        XCTAssertEqual(windowManager.controllerPendingWindowIds, Set([firstWindow.id]))
        XCTAssertTrue(windowManager.isControllerRegistrationPending(for: firstWindow.id))
        XCTAssertTrue(windowManager.hasPendingVisibleControllerRegistration)

        windowManager.registerController(NSObject(), for: firstWindow.id)

        XCTAssertFalse(windowManager.isControllerRegistrationPending(for: firstWindow.id))
        XCTAssertFalse(windowManager.hasPendingVisibleControllerRegistration)
    }

    func testWindowManagerMarksNewWindowPendingWithoutReopeningRegisteredPanes() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "New Window Readiness")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        windowManager.registerController(NSObject(), for: firstWindow.id)

        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))

        XCTAssertFalse(windowManager.isControllerRegistrationPending(for: firstWindow.id))
        XCTAssertTrue(windowManager.isControllerRegistrationPending(for: secondWindow.id))
        XCTAssertEqual(windowManager.controllerPendingWindowIds, Set([secondWindow.id]))

        windowManager.registerController(NSObject(), for: secondWindow.id)

        XCTAssertFalse(windowManager.hasPendingVisibleControllerRegistration)
    }

    func testWindowManagerAddWindowExitsMaximizedStateSoNewPaneCanRegister() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Maximized Add")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        windowManager.registerController(NSObject(), for: firstWindow.id)
        windowManager.maximizeWindow(firstWindow)

        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))

        XCTAssertNil(workspace.maximizedWindowId)
        XCTAssertEqual(windowManager.activeWindow?.id, secondWindow.id)
        XCTAssertTrue(windowManager.visibleWindows.contains(where: { $0.id == secondWindow.id }))
        XCTAssertTrue(windowManager.isControllerRegistrationPending(for: secondWindow.id))
        XCTAssertTrue(windowManager.hasPendingVisibleControllerRegistration)
    }

    func testWindowManagerReadinessIgnoresHiddenWindowsUntilRestored() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Hidden Readiness")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        windowManager.registerController(NSObject(), for: firstWindow.id)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        XCTAssertTrue(windowManager.isControllerRegistrationPending(for: secondWindow.id))

        windowManager.minimizeWindow(secondWindow)

        XCTAssertFalse(windowManager.isControllerRegistrationPending(for: secondWindow.id))
        XCTAssertFalse(windowManager.hasPendingVisibleControllerRegistration)

        windowManager.restoreWindow(secondWindow)

        XCTAssertTrue(windowManager.isControllerRegistrationPending(for: secondWindow.id))
        XCTAssertTrue(windowManager.hasPendingVisibleControllerRegistration)
    }

    func testWindowManagerRoutesNormalWindowsThroughPrimaryLinksWindowAtEnd() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Links")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow

        let firstLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: firstWindow))

        XCTAssertTrue(firstLinksWindow.isLinksWindow)
        XCTAssertTrue(firstLinksWindow.isPinMode)
        XCTAssertFalse(firstLinksWindow.isSynchronized)
        XCTAssertEqual(workspace.primaryTargetLinksWindowId, firstLinksWindow.id)
        XCTAssertNil(firstWindow.targetLinksWindowId)
        XCTAssertEqual(
            windowManager.visibleWindows.map(\.id),
            [firstWindow.id, secondWindow.id, firstLinksWindow.id]
        )

        windowManager.activeWindow = secondWindow
        let secondLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: secondWindow))

        XCTAssertEqual(secondLinksWindow.id, firstLinksWindow.id)
        XCTAssertNil(secondWindow.targetLinksWindowId)
        XCTAssertEqual(
            windowManager.visibleWindows.map(\.id),
            [firstWindow.id, secondWindow.id, firstLinksWindow.id]
        )
    }

    func testWindowManagerRepairsStalePrimaryLinksWindowToExistingLinksWindow() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Stale Links")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let originalLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: firstWindow))
        workspace.primaryTargetLinksWindowId = UUID()

        let repairedLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: firstWindow))

        XCTAssertEqual(repairedLinksWindow.id, originalLinksWindow.id)
        XCTAssertTrue(repairedLinksWindow.isLinksWindow)
        XCTAssertEqual(workspace.primaryTargetLinksWindowId, repairedLinksWindow.id)
    }

    func testWindowManagerRestoresMinimizedPrimaryLinksWindowAndFocusesIt() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Restore Links")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let linksWindow = try XCTUnwrap(windowManager.linksWindow(for: firstWindow))
        windowManager.minimizeWindow(linksWindow)
        windowManager.activeWindow = firstWindow

        let restoredLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: firstWindow))

        XCTAssertEqual(restoredLinksWindow.id, linksWindow.id)
        XCTAssertEqual(restoredLinksWindow.layoutState, "split")
        XCTAssertEqual(windowManager.activeWindow?.id, linksWindow.id)
        XCTAssertTrue(windowManager.visibleWindows.contains(where: { $0.id == linksWindow.id }))
    }

    func testWindowManagerDisplaysPinnedWindowsBeforeUnpinnedWindows() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Pinned Order")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        firstWindow.isPinMode = false
        firstWindow.orderNumber = 0
        secondWindow.isPinMode = true
        secondWindow.orderNumber = 1

        windowManager.refreshWindows()

        XCTAssertEqual(windowManager.visibleWindows.map(\.id), [secondWindow.id, firstWindow.id])
    }

    func testWindowManagerGivesLinksWindowsTheirOwnChainedTarget() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Nested Links")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let primaryLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: firstWindow))

        let nestedLinksWindow = try XCTUnwrap(windowManager.linksWindow(for: primaryLinksWindow))

        XCTAssertNotEqual(nestedLinksWindow.id, primaryLinksWindow.id)
        XCTAssertTrue(nestedLinksWindow.isLinksWindow)
        XCTAssertEqual(workspace.primaryTargetLinksWindowId, primaryLinksWindow.id)
        XCTAssertEqual(primaryLinksWindow.targetLinksWindowId, nestedLinksWindow.id)
        XCTAssertEqual(
            windowManager.visibleWindows.map(\.id),
            [firstWindow.id, primaryLinksWindow.id, nestedLinksWindow.id]
        )
    }

    func testWorkspaceSelectionServicePersistsSelectedWorkspace() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let selectionService = WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager
        )

        let first = workspaceStore.createWorkspace(name: "First")
        let second = workspaceStore.createWorkspace(name: "Second")

        selectionService.activate(first)
        XCTAssertEqual(settingsStore.activeWorkspaceId, first.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, first.id)

        selectionService.activate(second)

        XCTAssertEqual(settingsStore.activeWorkspaceId, second.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, second.id)
        XCTAssertEqual(windowManager.visibleWindows.first?.workspace?.id, second.id)
    }

    func testWorkspaceSelectionServiceRepairsActiveWorkspaceBeforeDelete() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let selectionService = WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager
        )

        let first = workspaceStore.createWorkspace(name: "First")
        let second = workspaceStore.createWorkspace(name: "Second")
        selectionService.activate(first)

        XCTAssertTrue(selectionService.deleteWorkspace(first))

        XCTAssertNil(workspaceStore.workspace(id: first.id))
        XCTAssertEqual(settingsStore.activeWorkspaceId, second.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, second.id)
        XCTAssertEqual(windowManager.visibleWindows.first?.workspace?.id, second.id)
    }

    func testWorkspaceSelectionServiceKeepsActiveWorkspaceWhenDeletingInactiveWorkspace() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let selectionService = WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager
        )

        let first = workspaceStore.createWorkspace(name: "First")
        let second = workspaceStore.createWorkspace(name: "Second")
        let third = workspaceStore.createWorkspace(name: "Third")
        selectionService.activate(second)

        XCTAssertTrue(selectionService.deleteWorkspace(first))

        XCTAssertNil(workspaceStore.workspace(id: first.id))
        XCTAssertEqual(Set(workspaceStore.workspaces().map(\.id)), Set([second.id, third.id]))
        XCTAssertEqual(settingsStore.activeWorkspaceId, second.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, second.id)
    }

    func testWorkspaceSelectionServiceBatchDeleteRepairsActiveWorkspaceToSurvivor() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let selectionService = WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager
        )

        let first = workspaceStore.createWorkspace(name: "First")
        let second = workspaceStore.createWorkspace(name: "Second")
        let third = workspaceStore.createWorkspace(name: "Third")
        selectionService.activate(first)

        XCTAssertTrue(selectionService.deleteWorkspaces([first, second]))

        XCTAssertNil(workspaceStore.workspace(id: first.id))
        XCTAssertNil(workspaceStore.workspace(id: second.id))
        XCTAssertEqual(workspaceStore.workspaces().map(\.id), [third.id])
        XCTAssertEqual(settingsStore.activeWorkspaceId, third.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, third.id)
        XCTAssertEqual(windowManager.visibleWindows.first?.workspace?.id, third.id)
    }

    func testWorkspaceSelectionServicePreservesFinalWorkspaceOnDelete() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let selectionService = WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager
        )

        let only = workspaceStore.createWorkspace(name: "Only")
        selectionService.activate(only)

        XCTAssertFalse(selectionService.deleteWorkspace(only))

        XCTAssertNotNil(workspaceStore.workspace(id: only.id))
        XCTAssertEqual(settingsStore.activeWorkspaceId, only.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, only.id)
    }

    func testSettingsStoreGlobalTextDisplayPropagationClearsMatchingWorkspaceAndWindowOverrides() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)

        var previousGlobal = TextDisplaySettings.appDefaults
        previousGlobal.fontSize = 18
        previousGlobal.showVerseNumbers = true
        previousGlobal.lineSpacing = 10
        settingsStore.setGlobalTextDisplaySettings(previousGlobal)

        let workspace = workspaceStore.createWorkspace(name: "Propagation")
        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.fontSize = 20
        workspaceSettings.showVerseNumbers = false
        workspace.textDisplaySettings = workspaceSettings

        let window = try XCTUnwrap((workspace.windows ?? []).first)
        var windowSettings = TextDisplaySettings()
        windowSettings.fontSize = 20
        windowSettings.showVerseNumbers = false
        windowSettings.lineSpacing = 10
        window.pageManager?.textDisplaySettings = windowSettings
        try context.save()

        var currentGlobal = previousGlobal
        currentGlobal.fontSize = 20
        currentGlobal.showVerseNumbers = false
        settingsStore.setGlobalTextDisplaySettings(currentGlobal)

        XCTAssertNil(workspace.textDisplaySettings?.fontSize)
        XCTAssertNil(workspace.textDisplaySettings?.showVerseNumbers)
        XCTAssertNil(window.pageManager?.textDisplaySettings?.fontSize)
        XCTAssertNil(window.pageManager?.textDisplaySettings?.showVerseNumbers)
        XCTAssertEqual(window.pageManager?.textDisplaySettings?.lineSpacing, 10)
    }

    func testRepositorySourceManagerAddsSwordHTTPSManifestSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Example Repo",
          "description": "Example catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "/sword/packages",
          "manifestUrl": "https://example.org/sword/manifest.json"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.org/sword/manifest.json")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://example.org/sword/manifest.json")

        XCTAssertEqual(registration.source.name, "Example Repo")
        XCTAssertEqual(registration.source.type, "HTTP")
        XCTAssertEqual(registration.source.host, "example.org")
        XCTAssertEqual(registration.source.catalogPath, "/sword")
        XCTAssertEqual(registration.packageDirectory, "/sword/packages")

        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("HTTPSource=Example Repo|example.org|/sword"))
        XCTAssertTrue(manager.loadSources().contains { $0.name == "Example Repo" })
    }

    func testRepositorySourceManagerAddsDirectSwordCatalogFallbackSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        MockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let statusCode: Int
            let data: Data
            switch path {
            case "/sword", "/sword/packages", "/sword/mods.d.tar.gz":
                statusCode = 200
                data = Data("readable".utf8)
            case "/sword/manifest.json":
                statusCode = 404
                data = Data()
            default:
                XCTFail("Unexpected repository validation URL: \(request.url?.absoluteString ?? "")")
                statusCode = 404
                data = Data()
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://custom.example:8443/sword")

        XCTAssertTrue(registration.source.name.hasPrefix("custom.example-"))
        XCTAssertEqual(registration.source.host, "custom.example:8443")
        XCTAssertEqual(registration.source.catalogPath, "/sword")
        XCTAssertEqual(registration.packageDirectory, "/sword/packages")
        XCTAssertEqual(registration.sourceURL.absoluteString, "https://custom.example:8443/sword")

        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("HTTPSource=\(registration.source.name)|custom.example:8443|/sword"))
    }

    func testRepositorySourceManagerRejectsDuplicateDefaultRepositoryName() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "AndBible",
          "description": "Duplicate default",
          "type": "sword-https",
          "host": "duplicate.example",
          "catalogDirectory": "/sword"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://duplicate.example/manifest.json")
            XCTFail("Expected duplicate default repository name to be rejected.")
        } catch RepositorySourceManagementError.duplicateSourceName(let name) {
            XCTAssertEqual(name, "AndBible")
        } catch {
            XCTFail("Unexpected duplicate-source error: \(error)")
        }
    }

    func testRepositorySourceManagerRejectsManifestSourceNamesWithPathSeparators() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "../custom",
          "description": "Unsafe name",
          "type": "sword-https",
          "host": "unsafe.example",
          "catalogDirectory": "/sword"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://unsafe.example/manifest.json")
            XCTFail("Expected manifest source names with path separators to be rejected.")
        } catch RepositorySourceManagementError.invalidManifest(let name) {
            XCTAssertEqual(name, "../custom")
        } catch {
            XCTFail("Unexpected path-separator validation error: \(error)")
        }

        let sourcesAfterFailure = manager.loadSources()
        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertFalse(config.contains("../custom"))
        XCTAssertFalse(sourcesAfterFailure.contains { $0.name == "../custom" })
    }

    func testRepositorySourceManagerProtectsDefaultsAndDeletesCustomSources() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Example Repo|example.org|/sword\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = RepositorySourceManager(basePath: tempDir.path)

        XCTAssertThrowsError(try manager.deleteCustomSource(named: "AndBible")) { error in
            XCTAssertEqual(error as? RepositorySourceManagementError, .protectedDefaultSource("AndBible"))
        }

        try manager.deleteCustomSource(named: "Example Repo")

        let remaining = manager.loadSources()
        XCTAssertTrue(remaining.contains { $0.name == "AndBible" })
        XCTAssertFalse(remaining.contains { $0.name == "Example Repo" })
    }

    func testRepositorySourceManagerResetToDefaultsRemovesCustomSourcesAndRestoresDefaults() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Example Repo|example.org|/sword\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        XCTAssertTrue(manager.loadSources().contains { $0.name == "Example Repo" })

        let notificationExpectation = expectation(description: "Repository source reset posts change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: RepositorySourceManager.sourcesDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try manager.resetToDefaults()

        wait(for: [notificationExpectation], timeout: 1)
        let restoredSources = manager.loadSources()
        XCTAssertFalse(restoredSources.isEmpty)
        XCTAssertTrue(restoredSources.contains { $0.name == "AndBible" })
        XCTAssertFalse(restoredSources.contains { $0.name == "Example Repo" })
        XCTAssertTrue(restoredSources.allSatisfy(manager.isDefaultSource))
    }

    func testRepositorySourceManagerResetToDefaultsReportsRecreationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let missingBasePath = tempDir.appendingPathComponent("missing", isDirectory: true)
        let manager = RepositorySourceManager(basePath: missingBasePath.path)

        XCTAssertThrowsError(try manager.resetToDefaults()) { error in
            XCTAssertEqual(
                error as? RepositorySourceManagementError,
                .configWriteFailed("default configuration was not recreated")
            )
        }
    }

    func testRepositorySourceManagerReplacesCustomSourceInPlace() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Old Repo|old.example|/sword\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manifestData = """
        {
          "name": "New Repo",
          "description": "Replacement",
          "type": "sword-https",
          "host": "new.example",
          "catalogDirectory": "/catalog"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: makeMockedURLSession()
        )

        let registration = try await manager.replaceCustomSource(
            named: "Old Repo",
            with: "https://new.example/manifest.json"
        )

        XCTAssertEqual(registration.source.name, "New Repo")

        let sourceNames = manager.loadSources().map(\.name)
        XCTAssertTrue(sourceNames.contains("New Repo"))
        XCTAssertFalse(sourceNames.contains("Old Repo"))
    }

    func testRepositorySourceManagerRejectsReplacingMissingCustomSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        let initialConfig = try String(contentsOf: configURL, encoding: .utf8)

        MockURLProtocol.requestHandler = { request in
            XCTFail("Replacing a missing source should fail before validating the replacement URL.")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: makeMockedURLSession()
        )

        do {
            _ = try await manager.replaceCustomSource(
                named: "Missing Repo",
                with: "https://new.example/manifest.json"
            )
            XCTFail("Expected replacing a missing source to fail.")
        } catch RepositorySourceManagementError.sourceNotFound(let name) {
            XCTAssertEqual(name, "Missing Repo")
        }

        let config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(config, initialConfig)
        XCTAssertFalse(manager.loadSources().contains { $0.name == "New Repo" })
    }

}
