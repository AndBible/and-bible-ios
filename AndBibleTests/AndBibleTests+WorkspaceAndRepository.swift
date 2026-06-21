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

    /**
     Verifies local iOS workspace creation uses Android's default workspace color.

     Android stores the durable workspace accent in `WorkspaceSettings.workspaceColor` and falls
     back to `#ff444444` for newly created workspaces and selector rendering. This regression test
     protects the iOS creation path from returning to a nil color that makes the selector indicator
     disappear and diverges from Android's color settings behavior.
     */
    func testWorkspaceStoreCreateWorkspaceUsesAndroidDefaultWorkspaceColor() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)

        let workspace = store.createWorkspace(name: "Default Color")

        XCTAssertEqual(Workspace.defaultWorkspaceColor, Int(Int32(bitPattern: 0xFF444444)))
        XCTAssertEqual(workspace.workspaceColor, Workspace.defaultWorkspaceColor)
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

    /**
     Protects Android's synchronized-window old-key comparison.

     Android updates the inactive window's Bible key before deciding whether to post a secondary
     scroll, then skips the scroll when the target key was already equal to the source key. The setup
     creates two synchronized panes in the same group, first with the target one verse behind and then
     with the target at the source verse. The expected result is that only the stale target is returned
     for secondary scrolling; a failure means iOS can keep injecting redundant scroll commands that
     let synced panes alternate focus and walk back to an older visible position.
     */
    func testWindowManagerSkipsSynchronizedTargetAlreadyAtSourceVerse() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Synchronized Target Freshness")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        sourceWindow.pageManager?.bibleBibleBook = 0
        sourceWindow.pageManager?.bibleChapterNo = 1
        sourceWindow.pageManager?.bibleVerseNo = 5
        targetWindow.pageManager?.bibleBibleBook = 0
        targetWindow.pageManager?.bibleChapterNo = 1
        targetWindow.pageManager?.bibleVerseNo = 4

        XCTAssertEqual(
            windowManager.synchronizedVerseUpdateTargets(for: sourceWindow).map(\.id),
            [targetWindow.id]
        )

        targetWindow.pageManager?.bibleVerseNo = 5

        XCTAssertTrue(windowManager.synchronizedVerseUpdateTargets(for: sourceWindow).isEmpty)
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

    /**
     Protects Android workspace text-display dirty-field propagation.

     Android's `TextDisplaySettings.kt` saves workspace edits to `WindowRepository.textDisplaySettings`
     and then calls `updateWindowTextDisplaySettingsValues`, which clears only child window fields
     that now equal the workspace value for fields changed by the workspace edit. Differing window
     overrides and unchanged matching values remain window-owned.

     Expected result:
     - workspace-scoped persisted settings keep changed values and drop redundant global values
     - window overrides equal to the new workspace values are cleared for changed fields
     - window overrides that intentionally differ from the workspace stay present
     - unchanged window values are not cleared just because they match a parent value

     Failure meaning:
     - iOS can regress from Android's workspace inheritance semantics by pinning stale window values
       or erasing intentional per-window overrides after a workspace text-options edit.
     */
    func testWorkspaceTextDisplayPropagationClearsOnlyDirtyMatchingWindowOverrides() {
        var globalSettings = TextDisplaySettings.appDefaults
        globalSettings.fontSize = 18
        globalSettings.showVerseNumbers = true
        globalSettings.showFootNotes = false
        globalSettings.lineSpacing = 10

        let existingWorkspaceSettings = TextDisplaySettings()
        let previousWorkspaceSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: existingWorkspaceSettings,
            global: globalSettings
        )

        var workspaceEditorSettings = previousWorkspaceSettings
        workspaceEditorSettings.fontSize = 20
        workspaceEditorSettings.showVerseNumbers = false
        workspaceEditorSettings.showFootNotes = true

        let persistedWorkspaceSettings = WorkspaceTextDisplaySettingsPropagation.workspaceScopedSettings(
            editorSettings: workspaceEditorSettings,
            previousResolvedSettings: previousWorkspaceSettings,
            existingWorkspaceSettings: existingWorkspaceSettings,
            globalSettings: globalSettings
        )

        XCTAssertEqual(persistedWorkspaceSettings.fontSize, 20)
        XCTAssertEqual(persistedWorkspaceSettings.showVerseNumbers, false)
        XCTAssertEqual(persistedWorkspaceSettings.showFootNotes, true)
        XCTAssertNil(persistedWorkspaceSettings.lineSpacing)

        let currentWorkspaceParentSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: persistedWorkspaceSettings,
            global: globalSettings
        )
        var windowSettings = TextDisplaySettings()
        windowSettings.fontSize = 20
        windowSettings.showVerseNumbers = false
        windowSettings.showFootNotes = false
        windowSettings.lineSpacing = 10

        let propagatedWindowSettings = WorkspaceTextDisplaySettingsPropagation.windowSettingsAfterWorkspaceChange(
            windowSettings,
            currentWorkspaceParentSettings: currentWorkspaceParentSettings,
            previousWorkspaceSettings: previousWorkspaceSettings,
            currentWorkspaceEditorSettings: workspaceEditorSettings
        )

        XCTAssertNil(propagatedWindowSettings.fontSize)
        XCTAssertNil(propagatedWindowSettings.showVerseNumbers)
        XCTAssertEqual(propagatedWindowSettings.showFootNotes, false)
        XCTAssertEqual(propagatedWindowSettings.lineSpacing, 10)
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

    /**
     Verifies SWORD package directories are normalized before persistence and reload.

     Android package directories are repository paths. iOS accepts Android-style manifests and direct
     sidecar reloads, so relative manifest values must become root-relative paths before Downloads
     later builds package ZIP URLs from the host/path tuple.
     */
    func testRepositorySourceManagerNormalizesRelativeSwordManifestPackageDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Relative Repo",
          "description": "Relative package catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "sword/packages",
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

        XCTAssertEqual(registration.packageDirectory, "/sword/packages")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Relative Repo" })
        XCTAssertEqual(source.packageDirectory, "/sword/packages")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        let record = try XCTUnwrap(repositories.first { ($0["name"] as? String) == "Relative Repo" })
        XCTAssertEqual(record["packageDirectory"] as? String, "/sword/packages")
    }

    /**
     Verifies empty SWORD package directories fall back to the Android default package path.

     A manifest can include a blank package directory. Android/JSword behavior treats missing package
     metadata as a catalog-relative packages path, so iOS must normalize blank values to that fallback
     instead of persisting an empty package URL component.
     */
    func testRepositorySourceManagerFallsBackForBlankSwordManifestPackageDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Blank Package Repo",
          "description": "Blank package catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "   ",
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

        XCTAssertEqual(registration.packageDirectory, "/sword/packages")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Blank Package Repo" })
        XCTAssertEqual(source.packageDirectory, "/sword/packages")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        let record = try XCTUnwrap(repositories.first { ($0["name"] as? String) == "Blank Package Repo" })
        XCTAssertEqual(record["packageDirectory"] as? String, "/sword/packages")
    }

    func testRepositorySourceManagerIgnoresNonHTTPSSwordManifestURLMetadata() async throws {
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
          "manifestUrl": "http://example.org/sword/manifest.json"
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

        XCTAssertEqual(registration.manifestURL.absoluteString, "https://example.org/sword/manifest.json")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Example Repo" })
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://example.org/sword/manifest.json")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(
            repositories.compactMap { $0["manifestURL"] as? String },
            ["https://example.org/sword/manifest.json"]
        )
    }

    func testRepositorySourceManagerBackfillsSourceOnlyCustomSwordMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Legacy Repo|legacy.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Legacy Repo" })

        XCTAssertEqual(source.repositoryType, SourceConfig.swordHTTPSRepositoryType)
        XCTAssertEqual(source.description, "https://legacy.example/catalog")
        XCTAssertEqual(source.packageDirectory, "/catalog/packages")
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://legacy.example/catalog")
        XCTAssertEqual(source.sourceURL?.absoluteString, "https://legacy.example/catalog")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.count, 1)

        let record = try XCTUnwrap(repositories.first)
        XCTAssertEqual(record["name"] as? String, "Legacy Repo")
        XCTAssertEqual(record["description"] as? String, "https://legacy.example/catalog")
        XCTAssertEqual(record["type"] as? String, SourceConfig.swordHTTPSRepositoryType)
        XCTAssertEqual(record["host"] as? String, "legacy.example")
        XCTAssertEqual(record["catalogDirectory"] as? String, "/catalog")
        XCTAssertEqual(record["packageDirectory"] as? String, "/catalog/packages")
        XCTAssertEqual(record["manifestURL"] as? String, "https://legacy.example/catalog")
        XCTAssertEqual(record["sourceURL"] as? String, "https://legacy.example/catalog")
    }

    func testRepositorySourceManagerDoesNotOverwriteUnreadableSidecarDuringBackfill() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Legacy Repo|legacy.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let sidecarURL = tempDir.appendingPathComponent("CustomRepositories.json")
        let unreadableSidecar = Data("{\"version\":1,\"repositories\":[".utf8)
        try unreadableSidecar.write(to: sidecarURL)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Legacy Repo" })

        XCTAssertEqual(source.manifestURL?.absoluteString, "https://legacy.example/catalog")
        XCTAssertEqual(source.packageDirectory, "/catalog/packages")
        XCTAssertEqual(try Data(contentsOf: sidecarURL), unreadableSidecar)
    }

    /**
     Verifies sidecar package directories are normalized when merged onto SWORD config rows.

     Older sidecars can contain Android package-directory values before iOS normalized them at write
     time. Loading must normalize the merged `SourceConfig` so Downloads package fallback receives
     the same root-relative repository path Android passes to JSword.
     */
    func testRepositorySourceManagerNormalizesSidecarPackageDirectoryWhenMergingConfigSource() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Sidecar Repo|sidecar.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let sidecar = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Sidecar Repo",
              "description": "Sidecar catalog",
              "type": "sword-https",
              "host": "sidecar.example",
              "catalogDirectory": "/catalog",
              "packageDirectory": " packages ",
              "manifestURL": "https://sidecar.example/catalog",
              "sourceURL": "https://sidecar.example/catalog"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecar.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Sidecar Repo" })

        XCTAssertEqual(source.packageDirectory, "/packages")
    }

    /**
     Verifies whitespace-only package metadata is treated as absent when loading old sidecars.

     A whitespace string is not an Android package directory. Keeping it as non-nil empty metadata
     can hide the direct-catalog fallback path, so the source model should expose `nil` instead.
     */
    func testRepositorySourceManagerTreatsWhitespaceSidecarPackageDirectoryAsMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Whitespace Repo|whitespace.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let sidecar = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Whitespace Repo",
              "description": "Whitespace catalog",
              "type": "sword-https",
              "host": "whitespace.example",
              "catalogDirectory": "/catalog",
              "packageDirectory": "   ",
              "manifestURL": "https://whitespace.example/catalog",
              "sourceURL": "https://whitespace.example/catalog"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecar.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Whitespace Repo" })

        XCTAssertNil(source.packageDirectory)
    }

    func testRepositorySourceManagerAddsMyBibleManifestSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "url": "https://mybible.example/manifest.json",
          "file_name": "Example MyBible",
          "description": "Example MyBible catalog | Android",
          "modules": [
            {
              "file_name": "finrk.SQLite3.zip",
              "description": "Finnish RK",
              "download_url": "https://mybible.example/finrk.SQLite3.zip",
              "language_code": "fi",
              "update_date": "2026-05-01",
              "update_info": "initial"
            }
          ]
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mybible.example/manifest.json")
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

        let registration = try await manager.addCustomSource(from: "https://mybible.example/manifest.json")

        XCTAssertEqual(registration.source.name, "Example MyBible")
        XCTAssertTrue(registration.source.isMyBibleRepository)
        XCTAssertEqual(registration.source.manifestURL?.absoluteString, "https://mybible.example/manifest.json")
        XCTAssertEqual(registration.type, SourceConfig.myBibleHTTPSRepositoryType)

        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertFalse(
            config.contains("HTTPSource=Example MyBible"),
            "MyBible repositories should not be projected into SWORD InstallMgr.conf."
        )

        let loadedSource = try XCTUnwrap(manager.loadSources().first { $0.name == "Example MyBible" })
        XCTAssertTrue(loadedSource.isMyBibleRepository)
        XCTAssertEqual(loadedSource.description, "Example MyBible catalog | Android")
        XCTAssertEqual(loadedSource.manifestURL?.absoluteString, "https://mybible.example/manifest.json")

        try manager.deleteCustomSource(named: "Example MyBible")
        XCTAssertFalse(manager.loadSources().contains { $0.name == "Example MyBible" })
    }

    func testRepositorySourceManagerLoadsMyBibleSidecarWhenSwordConfigUnreadable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Example MyBible",
              "description": "Example MyBible catalog",
              "type": "mybible-https",
              "host": "mybible.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://mybible.example/manifest.json",
              "sourceURL": "https://mybible.example/manifest.json"
            },
            {
              "name": "Example SWORD",
              "description": "Example SWORD catalog",
              "type": "sword-https",
              "host": "sword.example",
              "catalogDirectory": "/sword",
              "packageDirectory": "/sword/packages",
              "manifestURL": "https://sword.example/manifest.json",
              "sourceURL": "https://sword.example/sword"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let sources = manager.loadSources()

        XCTAssertEqual(sources.map(\.name), ["Example MyBible"])
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.isMyBibleRepository)
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://mybible.example/manifest.json")
    }

    func testRepositorySourceManagerDropsInvalidSidecarRecords() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "../Escape",
              "description": "Unsafe name",
              "type": "mybible-https",
              "host": "unsafe.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://unsafe.example/manifest.json",
              "sourceURL": "https://unsafe.example/manifest.json"
            },
            {
              "name": "HTTP MyBible",
              "description": "Unsafe scheme",
              "type": "mybible-https",
              "host": "http.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "http://http.example/manifest.json",
              "sourceURL": "http://http.example/manifest.json"
            },
            {
              "name": "Example MyBible",
              "description": "Example MyBible catalog",
              "type": "mybible-https",
              "host": "mybible.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://mybible.example/manifest.json",
              "sourceURL": "https://mybible.example/manifest.json"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let sources = manager.loadSources()

        XCTAssertEqual(sources.map(\.name), ["Example MyBible"])
        XCTAssertEqual(sources.first?.manifestURL?.absoluteString, "https://mybible.example/manifest.json")
    }

    func testRepositorySourceManagerRepairsSwordSidecarWithNonHTTPSManifestURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = """
        [General]

        [Sources]
        HTTPSource=Example SWORD|sword.example|/sword
        """
        try config.write(
            to: tempDir.appendingPathComponent("InstallMgr.conf"),
            atomically: true,
            encoding: .utf8
        )

        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Example SWORD",
              "description": "Unsafe manifest metadata",
              "type": "sword-https",
              "host": "sword.example",
              "catalogDirectory": "/sword",
              "packageDirectory": "/sword/packages",
              "manifestURL": "http://sword.example/manifest.json",
              "sourceURL": "https://sword.example/sword"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Example SWORD" })

        XCTAssertEqual(source.host, "sword.example")
        XCTAssertEqual(source.catalogPath, "/sword")
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://sword.example/sword")
        XCTAssertEqual(source.sourceURL?.absoluteString, "https://sword.example/sword")
        XCTAssertEqual(source.description, "https://sword.example/sword")
        XCTAssertEqual(source.packageDirectory, "/sword/packages")

        let repairedSidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let repairedSidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: repairedSidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(repairedSidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.compactMap { $0["manifestURL"] as? String }, ["https://sword.example/sword"])
    }

    func testRepositorySourceManagerAddsAndReplacesMyBibleWhenSwordConfigUnreadable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manifestNamesByHost = [
            "initial.example": "Initial MyBible",
            "updated.example": "Updated MyBible"
        ]
        MockURLProtocol.requestHandler = { request in
            let host = try XCTUnwrap(request.url?.host)
            let fileName = try XCTUnwrap(manifestNamesByHost[host])
            let manifestData = """
            {
              "url": "\(request.url!.absoluteString)",
              "file_name": "\(fileName)",
              "description": "\(fileName) catalog",
              "modules": []
            }
            """.data(using: .utf8)!
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

        let added = try await manager.addCustomSource(from: "https://initial.example/manifest.json")
        XCTAssertEqual(added.source.name, "Initial MyBible")
        XCTAssertEqual(manager.loadSources().map(\.name), ["Initial MyBible"])

        let replacement = try await manager.replaceCustomSource(
            named: "Initial MyBible",
            with: "https://updated.example/manifest.json"
        )

        XCTAssertEqual(replacement.source.name, "Updated MyBible")
        let sources = manager.loadSources()
        XCTAssertEqual(sources.map(\.name), ["Updated MyBible"])
        XCTAssertEqual(sources.first?.manifestURL?.absoluteString, "https://updated.example/manifest.json")
    }

    func testRepositorySourceManagerDeletesMyBibleSidecarWhenSwordConfigUnreadable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sidecarURL = tempDir.appendingPathComponent("CustomRepositories.json")
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Example MyBible",
              "description": "Example MyBible catalog",
              "type": "mybible-https",
              "host": "mybible.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://mybible.example/manifest.json",
              "sourceURL": "https://mybible.example/manifest.json"
            },
            {
              "name": "Example SWORD",
              "description": "Example SWORD catalog",
              "type": "sword-https",
              "host": "sword.example",
              "catalogDirectory": "/sword",
              "packageDirectory": "/sword/packages",
              "manifestURL": "https://sword.example/manifest.json",
              "sourceURL": "https://sword.example/sword"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: sidecarURL)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        XCTAssertEqual(manager.loadSources().map(\.name), ["Example MyBible"])

        try manager.deleteCustomSource(named: "Example MyBible")

        XCTAssertTrue(manager.loadSources().isEmpty)
        let updatedSidecarData = try Data(contentsOf: sidecarURL)
        let updatedSidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updatedSidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(updatedSidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.compactMap { $0["name"] as? String }, ["Example SWORD"])
        XCTAssertThrowsError(try manager.deleteCustomSource(named: "Example SWORD")) { error in
            XCTAssertEqual(error as? RepositorySourceManagementError, .configReadFailed)
        }
    }

    func testRepositorySourceManagerPreservesMyBibleOrderWhenReplacingSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestNamesByHost = [
            "first.example": "First MyBible",
            "middle.example": "Middle MyBible",
            "last.example": "Last MyBible",
            "middle-updated.example": "Middle Updated MyBible"
        ]

        MockURLProtocol.requestHandler = { request in
            let host = try XCTUnwrap(request.url?.host)
            let fileName = try XCTUnwrap(manifestNamesByHost[host])
            let manifestData = """
            {
              "url": "\(request.url!.absoluteString)",
              "file_name": "\(fileName)",
              "description": "\(fileName) catalog",
              "modules": []
            }
            """.data(using: .utf8)!
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

        _ = try await manager.addCustomSource(from: "https://first.example/manifest.json")
        _ = try await manager.addCustomSource(from: "https://middle.example/manifest.json")
        _ = try await manager.addCustomSource(from: "https://last.example/manifest.json")

        _ = try await manager.replaceCustomSource(
            named: "Middle MyBible",
            with: "https://middle-updated.example/manifest.json"
        )

        let customNames = manager.loadSources()
            .map(\.name)
            .filter { manifestNamesByHost.values.contains($0) }
        XCTAssertEqual(customNames, ["First MyBible", "Middle Updated MyBible", "Last MyBible"])

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(
            repositories.compactMap { $0["name"] as? String },
            ["First MyBible", "Middle Updated MyBible", "Last MyBible"]
        )
    }

    func testRepositorySourceManagerRejectsDuplicateMyBibleRepositoryName() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "url": "https://duplicate.example/manifest.json",
          "file_name": "AndBible",
          "description": "Duplicate MyBible catalog",
          "modules": []
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
            XCTFail("Expected duplicate MyBible repository name to be rejected.")
        } catch RepositorySourceManagementError.duplicateSourceName(let name) {
            XCTAssertEqual(name, "AndBible")
        } catch {
            XCTFail("Unexpected duplicate MyBible repository error: \(error)")
        }
    }

    func testRepositorySourceManagerRejectsInvalidMyBibleManifest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "url": "https://invalid.example/manifest.json",
          "file_name": "Invalid MyBible",
          "description": "Missing modules"
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
            _ = try await manager.addCustomSource(from: "https://invalid.example/manifest.json")
            XCTFail("Expected invalid MyBible manifest to be rejected.")
        } catch RepositorySourceManagementError.invalidManifest {
            XCTAssertFalse(manager.loadSources().contains { $0.name == "Invalid MyBible" })
        } catch {
            XCTFail("Unexpected invalid MyBible manifest error: \(error)")
        }
    }

    func testRepositorySourceManagerRejectsUnsupportedManifestType() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "type": "unsupported-https",
          "name": "Unsupported Repo"
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
            _ = try await manager.addCustomSource(from: "https://unsupported.example/manifest.json")
            XCTFail("Expected unsupported custom repository type to be rejected.")
        } catch RepositorySourceManagementError.unsupportedRepositoryType(let type) {
            XCTAssertEqual(type, "unsupported-https")
        } catch {
            XCTFail("Unexpected unsupported manifest error: \(error)")
        }
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

    func testRepositorySourceManagerIgnoresOrphanedSwordSidecarForDuplicateNames() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Hidden Repo",
              "description": "Stale SWORD metadata",
              "type": "sword-https",
              "host": "stale.example",
              "catalogDirectory": "/stale",
              "packageDirectory": "/stale/packages",
              "manifestURL": "https://stale.example/manifest.json",
              "sourceURL": "https://stale.example/stale"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manifestData = """
        {
          "name": "Hidden Repo",
          "description": "Visible replacement",
          "type": "sword-https",
          "host": "visible.example",
          "catalogDirectory": "/sword",
          "packageDirectory": "/sword/packages",
          "manifestUrl": "https://visible.example/manifest.json"
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

        let registration = try await manager.addCustomSource(from: "https://visible.example/manifest.json")

        XCTAssertEqual(registration.source.name, "Hidden Repo")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Hidden Repo" })
        XCTAssertEqual(source.host, "visible.example")

        let sidecarDataAfterAdd = try Data(
            contentsOf: tempDir.appendingPathComponent("CustomRepositories.json")
        )
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarDataAfterAdd) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.compactMap { $0["host"] as? String }, ["visible.example"])
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

    /**
     Verifies built-in Downloads sources retain Android's package and catalog directories separately.

     Android's `repositories.txt` defines both directories for every SWORD repository. iOS uses a
     SWORD-compatible config file as local plumbing, but the source model consumed by Downloads and
     installs must still expose the Android package directory instead of reconstructing it later.
     */
    func testRepositorySourceManagerLoadsAndroidDefaultPackageDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let sources = manager.loadSources()

        let crossWire = try XCTUnwrap(sources.first { $0.name == "CrossWire" })
        XCTAssertEqual(crossWire.host, "crosswire.org")
        XCTAssertEqual(crossWire.catalogPath, "/ftpmirror/pub/sword/raw")
        XCTAssertEqual(crossWire.packageDirectory, "/ftpmirror/pub/sword/packages/rawzip")

        let step = try XCTUnwrap(sources.first { $0.name == "STEP Bible (Tyndale)" })
        XCTAssertEqual(step.host, "public.modules.stepbible.org")
        XCTAssertEqual(step.catalogPath, "/catalog")
        XCTAssertEqual(step.packageDirectory, "/packages")
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
