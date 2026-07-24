import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 App-host-free package coverage for workspace, window, bookmark-label filtering, and
 text-display inheritance contracts owned by BibleCore.

 These tests were migrated out of `AndBibleTests` so durable workspace/window behavior runs in
 the package lane without booting the app. Failures indicate data-model, selection, synchronized
 window, or settings-inheritance regressions rather than app bootstrap failures.
 */
final class WorkspaceWindowStoreTests: XCTestCase {
    /**
     Verifies new and historical workspace settings use Android's enabled auto-pin default.

     The empty JSON payload models an iOS workspace written before `autoPin` was serialized. Both
     construction paths must resolve to Android's Room default without changing an explicit false.
     */
    func testWorkspaceSettingsUseAndroidAutoPinDefault() throws {
        XCTAssertTrue(WorkspaceSettings().autoPin)

        let decoded = try JSONDecoder().decode(WorkspaceSettings.self, from: Data("{}".utf8))

        XCTAssertTrue(decoded.autoPin)
        XCTAssertFalse(WorkspaceSettings(autoPin: false).autoPin)
    }

    /**
     Verifies workspace settings clear an auto-assign primary label when no auto-assigned labels remain.
     */
    func testWorkspaceSettingsClearsAutoAssignPrimaryLabelWhenAutoAssignLabelsAreEmpty() {
        let orphanPrimaryLabelID = UUID(uuidString: "c2100000-0000-0000-0000-000000000001")!

        let settings = WorkspaceSettings(
            autoAssignLabels: [],
            autoAssignPrimaryLabel: orphanPrimaryLabelID
        )

        XCTAssertTrue(settings.autoAssignLabels.isEmpty)
        XCTAssertNil(settings.autoAssignPrimaryLabel)
    }

    /**
     Verifies workspace settings repair an orphan primary label to the deterministic first assigned label.
     */
    func testWorkspaceSettingsRepairsOrphanAutoAssignPrimaryLabelToFirstAssignedLabel() {
        let firstAssignedLabelID = UUID(uuidString: "c2100000-0000-0000-0000-000000000002")!
        let secondAssignedLabelID = UUID(uuidString: "c2100000-0000-0000-0000-000000000003")!
        let orphanPrimaryLabelID = UUID(uuidString: "c2100000-0000-0000-0000-000000000004")!

        let settings = WorkspaceSettings(
            autoAssignLabels: [secondAssignedLabelID, firstAssignedLabelID],
            autoAssignPrimaryLabel: orphanPrimaryLabelID
        )

        XCTAssertEqual(settings.autoAssignLabels, [firstAssignedLabelID, secondAssignedLabelID])
        XCTAssertEqual(settings.autoAssignPrimaryLabel, firstAssignedLabelID)
    }

    /**
     Verifies workspace settings keep an auto-assign primary label that is still assigned.
     */
    func testWorkspaceSettingsPreservesAssignedAutoAssignPrimaryLabel() {
        let firstAssignedLabelID = UUID(uuidString: "c2100000-0000-0000-0000-000000000005")!
        let primaryLabelID = UUID(uuidString: "c2100000-0000-0000-0000-000000000006")!

        let settings = WorkspaceSettings(
            autoAssignLabels: [firstAssignedLabelID, primaryLabelID],
            autoAssignPrimaryLabel: primaryLabelID
        )

        XCTAssertEqual(settings.autoAssignLabels, [firstAssignedLabelID, primaryLabelID])
        XCTAssertEqual(settings.autoAssignPrimaryLabel, primaryLabelID)
    }

    /**
     Verifies Bible bookmark label filtering uses the SwiftData label junction instead of returning
     every bookmark in the same passage range.

     The setup inserts two Bible bookmarks, two labels, and one junction per bookmark. The expected
     result is that querying by the matching label returns only the bookmark connected through that
     junction. A failure means label-scoped bookmark lists can leak unrelated bookmarks or ignore the
     persisted many-to-many relationship.
     */
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

        let matchingBookmark = BibleBookmark(
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJVA",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJVA",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4,
                kjvaOrdinalStart: 4,
                kjvaOrdinalEnd: 4
            )
        )
        matchingBookmark.book = "Genesis"
        store.insert(matchingBookmark)

        let otherBookmark = BibleBookmark(
            kjvOrdinalStart: 5,
            kjvOrdinalEnd: 5,
            ordinalStart: 5,
            ordinalEnd: 5,
            v11n: "KJVA",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJVA",
                sourceOrdinalStart: 5,
                sourceOrdinalEnd: 5,
                kjvaOrdinalStart: 5,
                kjvaOrdinalEnd: 5
            )
        )
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

    /**
     Protects the core workspace graph lifecycle used by workspace management UI.

     The test creates, renames, clones, and deletes workspaces with windows and history entries in an
     in-memory production schema. The expected result is that clone ordering, cloned window identity,
     page-manager/history cloning, and delete cleanup all round trip together. A failure indicates
     `WorkspaceStore` can corrupt workspace ordering, share mutable child rows between clones, or
     leave stale workspace records behind.
     */
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

    /**
     Validates Android-style workspace default inheritance for newly created workspaces.

     The setup gives a source workspace text-display defaults, workspace metadata, labels, cursors,
     color, window overrides, and history. The expected result is that a new workspace inherits only
     workspace-scoped defaults, clears theme colors back to global inheritance, and starts with a fresh
     single-window graph. A failure means new workspace creation is either missing durable defaults or
     accidentally cloning runtime state such as history, window overrides, and unpinned weights.
     */
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
        let studyPadLabelID = UUID()
        source.workspaceSettings = WorkspaceSettings(
            enableTiltToScroll: true,
            enableReverseSplitMode: true,
            autoPin: true,
            recentLabels: [RecentLabel(labelId: recentLabelID)],
            autoAssignLabels: [autoAssignLabelID],
            autoAssignPrimaryLabel: autoAssignLabelID,
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
        XCTAssertEqual(created.workspaceSettings?.autoAssignPrimaryLabel, autoAssignLabelID)
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
        XCTAssertEqual(workspace.workspaceSettings?.autoPin, true)
    }

    /**
     Verifies a legacy workspace with no settings opens a second Bible as another split pane.

     The first pane is deliberately raw-unpinned to reproduce the simulator regression. Android's
     missing/default `autoPin=true` value makes both panes effectively pinned, so creating the clone
     must not minimize the original Bible.
     */
    func testLegacyWorkspaceWithoutSettingsKeepsTwoBiblePanesVisible() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Legacy")
        let first = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        workspace.workspaceSettings = nil
        first.isPinMode = false
        first.pageManager?.bibleDocument = "KJV"
        store.persistChanges()
        manager.setActiveWorkspace(workspace)

        let second = try XCTUnwrap(manager.addWindow(document: "ESV2011", from: first))

        XCTAssertTrue(manager.isEffectivelyPinned(first))
        XCTAssertTrue(manager.isEffectivelyPinned(second))
        XCTAssertEqual(manager.visibleWindows.map(\.id), [first.id, second.id])
        XCTAssertEqual(first.layoutState, "split")
        XCTAssertEqual(second.layoutState, "split")
    }

    /**
     Protects visible-window controller readiness tracking during workspace activation.

     The setup activates a workspace before any pane controller has registered. The expected result is
     that the visible primary window is pending until its controller registers, then readiness clears.
     A failure means UI coordination can treat unregistered panes as ready and issue reader commands
     before the target view exists.
     */
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

    /**
     Verifies adding a pane only marks the newly created visible window as controller-pending.

     The first pane is registered before a second pane is added. The expected result is that the
     registered pane stays ready while the new pane waits for controller registration. A failure means
     adding windows can reopen or block already registered panes, causing unnecessary reader reloads.
     */
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

    /**
     Ensures add-window focus never points at a pane missing from the managed window lists.

     The reader footer and semantic state export render from `WindowManager.allWindows`, while pane
     focus reads `activeWindow`. A failure here means tapping add can produce an active pane that has
     no corresponding footer tab, which leaves UI automation and users without a stable activation
     target.
     */
    func testWindowManagerAddWindowKeepsActiveWindowInManagedWindowLists() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Add Window Active List")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        windowManager.registerController(NSObject(), for: firstWindow.id)

        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))

        XCTAssertEqual(windowManager.activeWindow?.id, secondWindow.id)
        XCTAssertTrue((workspace.windows ?? []).contains(where: { $0.id == secondWindow.id }))
        XCTAssertTrue(windowManager.allWindows.contains(where: { $0.id == secondWindow.id }))
        XCTAssertTrue(windowManager.visibleWindows.contains(where: { $0.id == secondWindow.id }))
        XCTAssertEqual(windowManager.allWindows.map(\.orderNumber), [0, 1])
    }

    /**
     Verifies active workspace selection is rebound into the manager's SwiftData context.

     App startup and fixture setup can resolve `Workspace` objects through a short-lived
     `ModelContext`, while `WindowManager` owns a long-lived store for later pane mutations.
     Passing the foreign-context workspace into the manager must not make later add-window actions
     attach new windows to an object graph the manager cannot save or refresh.
     */
    func testWindowManagerRebindsForeignContextWorkspaceBeforeAddingWindow() throws {
        let container = try makeWorkspaceModelContainer()
        let seedStore = WorkspaceStore(modelContext: ModelContext(container))
        let workspace = seedStore.createWorkspace(name: "Foreign Context Workspace")
        let workspaceID = workspace.id

        let managerStore = WorkspaceStore(modelContext: ModelContext(container))
        let windowManager = WindowManager(workspaceStore: managerStore)
        let externalStore = WorkspaceStore(modelContext: ModelContext(container))
        let externalWorkspace = try XCTUnwrap(externalStore.workspace(id: workspaceID))

        windowManager.setActiveWorkspace(externalWorkspace)
        let firstWindow = try XCTUnwrap(windowManager.activeWindow)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))

        XCTAssertEqual(windowManager.activeWorkspace?.id, workspaceID)
        XCTAssertEqual(windowManager.activeWindow?.id, secondWindow.id)
        XCTAssertEqual(windowManager.allWindows.map(\.orderNumber), [0, 1])
        XCTAssertTrue(managerStore.windows(workspaceId: workspaceID).contains { $0.id == secondWindow.id })
    }

    /**
     Ensures new-window creation exits maximized layout before waiting for controller registration.

     The setup maximizes the only pane, then adds a sibling pane. The expected result is that the
     workspace clears its maximized window, focuses the new pane, and marks that pane pending. A
     failure means newly added panes can remain hidden behind maximized state and never register.
     */
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

    /**
     Verifies minimized windows do not block visible-controller readiness until they are restored.

     The second pane starts pending, is minimized, then restored. The expected result is that pending
     readiness is ignored while hidden and re-applied when visible again. A failure means hidden panes
     can either stall workspace readiness or resume without a controller registration gate.
     */
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

    /**
     Protects Android-style primary links-window routing for normal reader panes.

     The setup opens links from two ordinary windows in the same workspace. The expected result is
     that both windows share the workspace primary links window, the links pane is pinned and
     unsynchronized, and it remains ordered after the normal panes. A failure indicates links routing
     can create duplicate auxiliary panes or attach normal windows to per-pane targets incorrectly.
     */
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

    /**
     Verifies links creation classifies the pane before enforcing unpinned-normal visibility.

     The source starts raw-unpinned with auto-pin disabled. Creating its links target must preserve
     source visibility and focus, clone the raw pin value, expose both panes as effectively unpinned,
     and keep the normal-only one-visible invariant intact. Toggling auto-pin must alter only each
     pane's effective state, and a fresh persistence context must recover the original raw values.
     */
    func testWindowManagerLinksCreationPreservesUnpinnedSourceAndRawPinAcrossAutoPin() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Unpinned Links")
        let workspaceID = workspace.id
        workspace.workspaceSettings = WorkspaceSettings(autoPin: false)
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        source.isPinMode = false
        source.layoutWeight = 0.63
        store.persistChanges()
        manager.setActiveWorkspace(workspace)

        let links = try XCTUnwrap(manager.linksWindow(for: source))

        XCTAssertFalse(source.isPinMode)
        XCTAssertFalse(links.isPinMode)
        XCTAssertFalse(manager.isEffectivelyPinned(source))
        XCTAssertFalse(manager.isEffectivelyPinned(links))
        XCTAssertEqual(source.layoutState, "split")
        XCTAssertEqual(links.layoutState, "split")
        XCTAssertEqual(manager.activeWindow?.id, source.id)
        XCTAssertEqual(
            manager.visibleWindows.filter { !$0.isLinksWindow && !manager.isEffectivelyPinned($0) }.map(\.id),
            [source.id]
        )
        XCTAssertEqual(workspace.unPinnedWeight ?? 0, 0.63, accuracy: 0.001)

        manager.setAutoPinEnabled(true)
        XCTAssertTrue(manager.isEffectivelyPinned(source))
        XCTAssertTrue(manager.isEffectivelyPinned(links))
        XCTAssertFalse(source.isPinMode)
        XCTAssertFalse(links.isPinMode)

        manager.setAutoPinEnabled(false)
        XCTAssertFalse(manager.isEffectivelyPinned(source))
        XCTAssertFalse(manager.isEffectivelyPinned(links))

        let reloadedStore = WorkspaceStore(modelContext: ModelContext(container))
        let reloadedWindows = reloadedStore.windows(workspaceId: workspaceID)
        let reloadedSource = try XCTUnwrap(reloadedWindows.first(where: { $0.id == source.id }))
        let reloadedLinks = try XCTUnwrap(reloadedWindows.first(where: { $0.id == links.id }))
        XCTAssertFalse(reloadedSource.isPinMode)
        XCTAssertFalse(reloadedLinks.isPinMode)
        XCTAssertEqual(reloadedSource.layoutState, "split")
        XCTAssertEqual(reloadedLinks.layoutState, "split")
    }

    /**
     Verifies stale primary-links metadata is repaired to an existing links pane.

     The setup creates a primary links window, then corrupts the workspace's stored primary target id.
     The expected result is that requesting links again reuses the existing links pane and rewrites the
     workspace primary id. A failure means stale metadata can orphan links panes or create duplicates.
     */
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

    /**
     Ensures a minimized primary links pane is restored and focused instead of recreated.

     The setup creates the primary links window, minimizes it, and then requests links from the reader
     pane again. The expected result is that the same links window returns to split layout, becomes
     visible, and receives focus. A failure means links commands can lose existing auxiliary context.
     */
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

    /**
     Verifies a normal restore-strip button toggles its pane through Android's manager-owned path.

     The setup creates two auto-pinned visible panes, then taps the second pane's restore button
     twice through `toggleWindowVisibility`. Android's `WindowControl.restoreWindow` first minimizes
     the visible pane and then restores and focuses it. A failure means iOS or macOS has reverted to
     treating the bottom control as a focus-only tab or cannot restore the hidden pane.
     */
    func testWindowManagerRestoreButtonTogglesNormalWindowVisibilityLikeAndroid() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Restore Button")
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(manager.addWindow(from: firstWindow))

        manager.toggleWindowVisibility(secondWindow)

        XCTAssertEqual(secondWindow.layoutState, "minimized")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id])
        XCTAssertEqual(manager.activeWindow?.id, firstWindow.id)

        manager.toggleWindowVisibility(secondWindow)

        XCTAssertEqual(secondWindow.layoutState, "split")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id, secondWindow.id])
        XCTAssertEqual(manager.activeWindow?.id, secondWindow.id)
    }

    /**
     Protects Android's distinct primary and terminal nested links restore-button behavior.

     The setup creates the workspace primary links window and one nested terminal links window.
     Android closes a visible non-primary links window with no live chained target, while its primary
     links window remains durable and follows ordinary minimize/restore toggling. A failure means
     transient links panes leak as hidden tabs or the reusable primary links pane is deleted.
     */
    func testWindowManagerRestoreButtonClosesTerminalNestedLinksButTogglesPrimaryLinks() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Links Restore Button")
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let primaryLinksWindow = try XCTUnwrap(manager.linksWindow(for: firstWindow))
        let nestedLinksWindow = try XCTUnwrap(manager.linksWindow(for: primaryLinksWindow))

        manager.toggleWindowVisibility(nestedLinksWindow)

        XCTAssertFalse(manager.allWindows.contains(where: { $0.id == nestedLinksWindow.id }))
        XCTAssertTrue(manager.allWindows.contains(where: { $0.id == primaryLinksWindow.id }))
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id, primaryLinksWindow.id])

        manager.toggleWindowVisibility(primaryLinksWindow)

        XCTAssertTrue(manager.allWindows.contains(where: { $0.id == primaryLinksWindow.id }))
        XCTAssertEqual(primaryLinksWindow.layoutState, "minimized")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id])

        manager.toggleWindowVisibility(primaryLinksWindow)

        XCTAssertEqual(primaryLinksWindow.layoutState, "split")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id, primaryLinksWindow.id])
        XCTAssertEqual(manager.activeWindow?.id, primaryLinksWindow.id)
    }

    /**
     Verifies visible-window ordering keeps pinned panes before unpinned panes.

     The setup flips pin state so a later pane is pinned while the first pane is not. The expected
     result is that refresh ordering surfaces the pinned pane first. A failure means tab/window chrome
     can diverge from the workspace ordering model used for pinned study panes.
     */
    func testWindowManagerDisplaysPinnedWindowsBeforeUnpinnedWindows() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Pinned Order")
        workspace.workspaceSettings = WorkspaceSettings(autoPin: false)
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

    /**
     Validates nested links-window routing for links opened from an existing links pane.

     The setup opens links from a normal window, then opens links from that links window. The expected
     result is a distinct chained target recorded on the first links pane while the workspace primary
     links target remains unchanged. A failure means nested auxiliary links can overwrite the primary
     target or route back into the same pane.
     */
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

    /**
     Verifies fresh and cloned windows preserve Android's raw pinned default contract.

     The setup creates a workspace, appends a fresh window, then clones a raw-unpinned workspace.
     The expected result is that fresh windows are pinned while clone rows preserve the source's raw
     choice. A failure means auto-pin toggles cannot restore prior per-window intent.
     */
    func testWorkspaceWindowsDefaultPinnedAndClonePreservesRawPinState() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let workspace = store.createWorkspace(name: "Pinned Defaults")
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let freshWindow = store.addWindow(to: workspace)

        XCTAssertTrue(firstWindow.isPinMode)
        XCTAssertTrue(freshWindow.isPinMode)

        firstWindow.isPinMode = false
        store.persistChanges()
        let clone = store.cloneWorkspace(workspace, newName: "Pinned Defaults Clone")
        let clonedFirstWindow = try XCTUnwrap(
            store.windows(workspaceId: clone.id).first(where: { $0.orderNumber == firstWindow.orderNumber })
        )

        XCTAssertFalse(clonedFirstWindow.isPinMode)
    }

    /**
     Verifies workspace cloning remaps layout references without collapsing raw and effective pins.

     The source graph combines auto-pin, a raw-unpinned normal pane, a links pane, shared unpinned
     geometry, maximize state, and both links-target identifiers. The clone must preserve raw values
     and effective behavior while remapping every identifier to its own window graph.
     */
    func testWorkspaceClonePreservesPinGeometryAndRemapsLayoutReferences() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let source = store.createWorkspace(name: "Clone Source")
        source.workspaceSettings = WorkspaceSettings(autoPin: true)
        source.unPinnedWeight = 0.72
        let sourceNormal = try XCTUnwrap(store.windows(workspaceId: source.id).first)
        sourceNormal.isPinMode = false
        let sourceLinks = store.addWindow(to: source)
        sourceLinks.isLinksWindow = true
        sourceNormal.targetLinksWindowId = sourceLinks.id
        source.primaryTargetLinksWindowId = sourceLinks.id
        source.maximizedWindowId = sourceNormal.id
        store.persistChanges()

        let clone = store.cloneWorkspace(source, newName: "Clone Target")
        let clonedWindows = store.windows(workspaceId: clone.id)
        let clonedNormal = try XCTUnwrap(clonedWindows.first(where: { !$0.isLinksWindow }))
        let clonedLinks = try XCTUnwrap(clonedWindows.first(where: { $0.isLinksWindow }))
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(clone)

        XCTAssertFalse(clonedNormal.isPinMode)
        XCTAssertTrue(clonedLinks.isPinMode)
        XCTAssertTrue(manager.isEffectivelyPinned(clonedNormal))
        XCTAssertTrue(manager.isEffectivelyPinned(clonedLinks))
        XCTAssertEqual(clone.unPinnedWeight ?? 0, 0.72, accuracy: 0.001)
        XCTAssertEqual(clone.maximizedWindowId, clonedNormal.id)
        XCTAssertEqual(clone.primaryTargetLinksWindowId, clonedLinks.id)
        XCTAssertEqual(clonedNormal.targetLinksWindowId, clonedLinks.id)
        XCTAssertNotEqual(clonedNormal.id, sourceNormal.id)
        XCTAssertNotEqual(clonedLinks.id, sourceLinks.id)

        manager.setAutoPinEnabled(false)

        XCTAssertFalse(clonedNormal.isPinMode)
        XCTAssertTrue(clonedLinks.isPinMode)
        XCTAssertFalse(manager.isEffectivelyPinned(clonedNormal))
        XCTAssertFalse(manager.isEffectivelyPinned(clonedLinks))
    }

    /**
     Verifies effective pin mode matches Android for normal and links windows.

     Normal windows become pinned while auto-pin is enabled but retain their raw value. Links windows
     expose exactly the workspace auto-pin value regardless of their raw stored pin.
     */
    func testWindowEffectivePinModeMatchesAndroidAutoPinRules() {
        let normal = Window(isPinMode: false)
        let links = Window(isPinMode: true, isLinksWindow: true)

        XCTAssertFalse(normal.effectivePinMode(autoPin: false))
        XCTAssertTrue(normal.effectivePinMode(autoPin: true))
        XCTAssertFalse(links.effectivePinMode(autoPin: false))
        XCTAssertTrue(links.effectivePinMode(autoPin: true))
    }

    /**
     Exercises clone and restore transitions for the one-visible-unpinned-normal invariant.

     Cloning an unpinned pane should copy its raw state, hide the previous unpinned normal pane, and
     focus the clone. Restoring the original should reverse which unpinned normal pane is visible.
     */
    func testWindowManagerCloneAndRestoreKeepOnlyOneUnpinnedNormalVisible() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Unpinned Clone")
        workspace.workspaceSettings = WorkspaceSettings(autoPin: false)
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        manager.setPinMode(firstWindow, value: false)

        let clonedWindow = try XCTUnwrap(manager.addWindow(from: firstWindow))

        XCTAssertFalse(clonedWindow.isPinMode)
        XCTAssertEqual(firstWindow.layoutState, "minimized")
        XCTAssertEqual(clonedWindow.layoutState, "split")
        XCTAssertEqual(manager.activeWindow?.id, clonedWindow.id)
        XCTAssertEqual(
            manager.visibleWindows.filter { !$0.isLinksWindow && !manager.isEffectivelyPinned($0) }.map(\.id),
            [clonedWindow.id]
        )

        manager.restoreWindow(firstWindow)

        XCTAssertEqual(firstWindow.layoutState, "split")
        XCTAssertEqual(clonedWindow.layoutState, "minimized")
        XCTAssertEqual(manager.activeWindow?.id, firstWindow.id)
    }

    /**
     Verifies unpinning a visible pane hides that pane when another unpinned normal remains visible.

     This mirrors Android's force-minimize branch and prevents two replaceable normal panes from
     becoming visible through a pin toggle.
     */
    func testWindowManagerUnpinMinimizesTargetWhenAnotherUnpinnedNormalIsVisible() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Unpin")
        workspace.workspaceSettings = WorkspaceSettings(autoPin: false)
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(manager.addWindow(from: firstWindow))

        manager.setPinMode(firstWindow, value: false)
        manager.setPinMode(secondWindow, value: false)

        XCTAssertEqual(firstWindow.layoutState, "split")
        XCTAssertEqual(secondWindow.layoutState, "minimized")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id])
    }

    /**
     Attacks auto-pin disable with multiple raw-unpinned visible panes.

     While auto-pin is enabled both panes are effectively pinned and may remain visible. Disabling it
     must keep the first persisted unpinned normal and minimize every later one without changing raw
     pin values.
     */
    func testWindowManagerAutoPinDisableNormalizesRawUnpinnedWindows() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let workspace = store.createWorkspace(name: "Auto Pin")
        workspace.workspaceSettings = WorkspaceSettings(autoPin: true)
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let secondWindow = store.addWindow(to: workspace)
        firstWindow.isPinMode = false
        secondWindow.isPinMode = false
        store.persistChanges()
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)

        XCTAssertEqual(manager.visibleWindows.count, 2)
        XCTAssertTrue(manager.visibleWindows.allSatisfy(manager.isEffectivelyPinned))

        manager.setAutoPinEnabled(false)

        XCTAssertFalse(firstWindow.isPinMode)
        XCTAssertFalse(secondWindow.isPinMode)
        XCTAssertEqual(firstWindow.layoutState, "split")
        XCTAssertEqual(secondWindow.layoutState, "minimized")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id])
    }

    /**
     Verifies workspace activation repairs legacy impossible unpinned visibility state.

     A persisted graph with two visible raw-unpinned normal windows is normalized before manager
     collections publish, preventing a relaunch from bypassing runtime pin controls.
     */
    func testWindowManagerActivationRepairsMultipleVisibleUnpinnedNormals() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let workspace = store.createWorkspace(name: "Legacy Visibility")
        workspace.workspaceSettings = WorkspaceSettings(autoPin: false)
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let secondWindow = store.addWindow(to: workspace)
        firstWindow.isPinMode = false
        secondWindow.isPinMode = false
        store.persistChanges()

        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)

        XCTAssertEqual(firstWindow.layoutState, "split")
        XCTAssertEqual(secondWindow.layoutState, "minimized")
        XCTAssertEqual(manager.visibleWindows.map(\.id), [firstWindow.id])
    }

    /**
     Verifies closing the only visible pane restores the nearest persisted hidden fallback.

     The second pane is hidden before the first is closed. The expected result is one surviving,
     focused, visible pane with reset weight, including after a new persistence context loads it.
     */
    func testWindowManagerCloseOnlyVisibleWindowRestoresNearestFallbackAndPersists() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Close Fallback")
        let workspaceID = workspace.id
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(manager.addWindow(from: firstWindow))
        secondWindow.layoutWeight = 0.4
        store.persistChanges()
        manager.minimizeWindow(secondWindow)

        manager.removeWindow(firstWindow)

        XCTAssertEqual(manager.allWindows.map(\.id), [secondWindow.id])
        XCTAssertEqual(manager.visibleWindows.map(\.id), [secondWindow.id])
        XCTAssertEqual(manager.activeWindow?.id, secondWindow.id)
        XCTAssertEqual(secondWindow.layoutState, "split")
        XCTAssertEqual(secondWindow.layoutWeight, 1.0, accuracy: 0.001)

        let reloadedStore = WorkspaceStore(modelContext: ModelContext(container))
        let reloadedWindow = try XCTUnwrap(reloadedStore.windows(workspaceId: workspaceID).first)
        XCTAssertEqual(reloadedWindow.layoutState, "split")
        XCTAssertEqual(reloadedWindow.layoutWeight, 1.0, accuracy: 0.001)
    }

    /**
     Verifies the final workspace window cannot be closed.

     A failure would leave a workspace with no pane and force startup code to invent state outside
     the window manager's lifecycle contract.
     */
    func testWindowManagerRejectsClosingFinalWindow() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Final Window")
        let onlyWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)

        manager.removeWindow(onlyWindow)

        XCTAssertEqual(manager.allWindows.map(\.id), [onlyWindow.id])
        XCTAssertEqual(manager.visibleWindows.map(\.id), [onlyWindow.id])
    }

    /**
     Exercises persisted maximize, restore-size, and maximized-close transitions as one state machine.

     A maximized pane must remain the sole published pane after reload. Restoring size must recover
     both underlying split panes, and closing a maximized pane while its peer is minimized must clear
     stale maximize metadata and restore that nearest peer as the visible, focused fallback.
     */
    func testWindowManagerMaximizeRestoreAndCloseMaintainPersistedVisibleFallback() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Maximize Lifecycle")
        let workspaceID = workspace.id
        let first = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let second = try XCTUnwrap(manager.addWindow(from: first))

        manager.maximizeWindow(second)

        XCTAssertEqual(workspace.maximizedWindowId, second.id)
        XCTAssertEqual(manager.visibleWindows.map(\.id), [second.id])
        XCTAssertEqual(manager.activeWindow?.id, second.id)

        let reloadedStore = WorkspaceStore(modelContext: ModelContext(container))
        let reloadedWorkspace = try XCTUnwrap(reloadedStore.workspace(id: workspaceID))
        let reloadedManager = WindowManager(workspaceStore: reloadedStore)
        reloadedManager.setActiveWorkspace(reloadedWorkspace)
        let reloadedWindows = reloadedStore.windows(workspaceId: workspaceID)
        let reloadedFirst = try XCTUnwrap(reloadedWindows.first(where: { $0.id == first.id }))
        let reloadedSecond = try XCTUnwrap(reloadedWindows.first(where: { $0.id == second.id }))

        XCTAssertEqual(reloadedManager.visibleWindows.map(\.id), [reloadedSecond.id])
        reloadedManager.unmaximize()
        XCTAssertNil(reloadedWorkspace.maximizedWindowId)
        XCTAssertEqual(reloadedManager.visibleWindows.map(\.id), [reloadedFirst.id, reloadedSecond.id])

        reloadedManager.minimizeWindow(reloadedFirst)
        reloadedManager.maximizeWindow(reloadedSecond)
        reloadedManager.removeWindow(reloadedSecond)

        XCTAssertNil(reloadedWorkspace.maximizedWindowId)
        XCTAssertEqual(reloadedFirst.layoutState, "split")
        XCTAssertEqual(reloadedManager.visibleWindows.map(\.id), [reloadedFirst.id])
        XCTAssertEqual(reloadedManager.activeWindow?.id, reloadedFirst.id)
    }

    /**
     Verifies manager-routed tab state and resize weights survive a new persistence context.

     The test changes pin, synchronization, group, pinned weights, and shared unpinned weight, then
     reloads the workspace graph. A failure identifies a tab/separator action that only mutated memory.
     */
    func testWindowManagerTabActionsAndResizeWeightsPersistAcrossReload() throws {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Persisted Actions")
        workspace.workspaceSettings = WorkspaceSettings(autoPin: false)
        let workspaceID = workspace.id
        let firstWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(manager.addWindow(from: firstWindow))

        manager.changeSyncGroup(firstWindow, groupNumber: 4)
        manager.setSynchronized(firstWindow, value: false)
        manager.resizeWindows(firstWindow, firstWeight: 1.75, secondWindow, secondWeight: 0.65, persist: true)
        manager.setPinMode(firstWindow, value: false)
        manager.resizeWindows(firstWindow, firstWeight: 0.8, secondWindow, secondWeight: 1.2, persist: true)

        let reloadedStore = WorkspaceStore(modelContext: ModelContext(container))
        let reloadedWorkspace = try XCTUnwrap(reloadedStore.workspace(id: workspaceID))
        let reloadedWindows = reloadedStore.windows(workspaceId: workspaceID)
        let reloadedFirst = try XCTUnwrap(reloadedWindows.first(where: { $0.id == firstWindow.id }))
        let reloadedSecond = try XCTUnwrap(reloadedWindows.first(where: { $0.id == secondWindow.id }))
        let reloadedManager = WindowManager(workspaceStore: reloadedStore)
        reloadedManager.setActiveWorkspace(reloadedWorkspace)

        XCTAssertFalse(reloadedFirst.isPinMode)
        XCTAssertFalse(reloadedFirst.isSynchronized)
        XCTAssertEqual(reloadedFirst.syncGroup, 4)
        XCTAssertEqual(reloadedFirst.layoutWeight, 1.75, accuracy: 0.001)
        XCTAssertEqual(reloadedWorkspace.unPinnedWeight ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(reloadedManager.effectiveLayoutWeight(for: reloadedFirst), 0.8, accuracy: 0.001)
        XCTAssertEqual(reloadedSecond.layoutWeight, 1.2, accuracy: 0.001)
    }

    /**
     Protects workspace activation persistence and visible-window rebinding.

     The setup creates two workspaces and activates each through `WorkspaceSelectionService`. The
     expected result is that `SettingsStore.activeWorkspaceId`, `WindowManager.activeWorkspace`, and
     visible windows all follow the selected workspace. A failure means selection can persist one
     workspace while displaying another.
     */
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

    /**
     Verifies workspace activation stops old speech before atomically applying new speech settings.

     A fake synthesizer holds an active session while the selector switches workspaces. The stopped
     callback observes the old workspace, and the final assertions require the new complete settings
     both in memory and in `SettingsStore` without firing the workspace-write callback. The shared
     bookmark owner must remain attached so resume and stopped-setting behavior keep working after
     the switch. A failure means a switch can persist settings into the workspace being left,
     retain stale TTS state, or disconnect Android's Speak-label lifecycle.
     */
    func testWorkspaceSelectionServiceStopsOldSpeechAndAppliesSelectedSettingsAtomically() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let speakService = SpeakService(synthesizer: FakeSpeechSynthesizer())
        speakService.settingsStore = settingsStore
        let bookmarkManager = BookmarkService(store: BookmarkStore(modelContext: context))
        speakService.bookmarkManager = bookmarkManager
        let selectionService = WorkspaceSelectionService(
            workspaceStore: workspaceStore,
            settingsStore: settingsStore,
            windowManager: windowManager,
            speakService: speakService
        )

        let first = workspaceStore.createWorkspace(name: "First")
        var firstSettings = WorkspaceSettings()
        firstSettings.speakSettings.playbackSettings.speed = 120
        first.workspaceSettings = firstSettings
        let second = workspaceStore.createWorkspace(name: "Second")
        var secondSettings = WorkspaceSettings()
        secondSettings.speakSettings = SpeakSettings(
            playbackSettings: PlaybackSettings(
                speakChapterChanges: false,
                speakTitles: false,
                speakFootnotes: true,
                speed: 177
            ),
            sleepTimer: 9,
            lastSleepTimer: 21,
            queue: false,
            repeatPlayback: true,
            numPagesToSpeakId: 44
        )
        second.workspaceSettings = secondSettings
        try context.save()
        XCTAssertEqual(second.workspaceSettings?.speakSettings, secondSettings.speakSettings)

        selectionService.activate(first)
        var activeWorkspaceWhenStopped: UUID?
        var workspaceWriteCount = 0
        speakService.onSpeechStopped = {
            activeWorkspaceWhenStopped = windowManager.activeWorkspace?.id
        }
        speakService.onSettingsChanged = { _ in workspaceWriteCount += 1 }
        speakService.speak(text: "Workspace transition")

        selectionService.activate(second)

        XCTAssertEqual(activeWorkspaceWhenStopped, first.id)
        XCTAssertEqual(windowManager.activeWorkspace?.id, second.id)
        XCTAssertEqual(settingsStore.activeWorkspaceId, second.id)
        XCTAssertFalse(speakService.isSpeaking)
        XCTAssertEqual(speakService.settings, secondSettings.speakSettings)
        XCTAssertEqual(
            SpeakSettings.fromAndroidJSON(try XCTUnwrap(settingsStore.getString("SpeakSettings"))),
            secondSettings.speakSettings
        )
        XCTAssertEqual(workspaceWriteCount, 0)
        XCTAssertTrue(speakService.bookmarkManager === bookmarkManager)
    }

    /**
     Verifies deleting the active workspace first repairs selection to a surviving workspace.

     The setup makes the first workspace active, then deletes it while another workspace remains. The
     expected result is that the deleted workspace is removed and both settings and visible windows
     point to the survivor. A failure means deletion can leave active workspace metadata dangling.
     */
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

    /**
     Ensures deleting an inactive workspace does not disturb the current active workspace.

     The setup activates the middle workspace and deletes a different one. The expected result is that
     only the target workspace is removed while settings and window-manager state stay on the active
     workspace. A failure means cleanup for inactive workspaces can cause unexpected workspace jumps.
     */
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

    /**
     Verifies batch deletion repairs active workspace state when the active workspace is included.

     The setup creates three workspaces, activates the first, and deletes the first two together. The
     expected result is that the remaining workspace becomes active and visible. A failure means bulk
     cleanup can leave persisted active workspace state pointing at deleted rows.
     */
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

    /**
     Protects the invariant that a workspace collection must keep at least one workspace.

     The setup activates the only workspace and attempts to delete it. The expected result is that
     deletion is rejected and active selection remains intact. A failure means users can delete the
     final workspace and leave reader startup without a workspace graph.
     */
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

    /**
     Validates global text-display propagation clears only child overrides that now match global values.

     The setup persists previous global settings, workspace overrides, and window overrides, then
     changes global values to match selected child overrides. The expected result is that matching
     workspace/window fields are cleared for inheritance while unrelated window line spacing remains
     explicit. A failure means global edits can either pin redundant child values or erase intentional
     per-window settings.
     */
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
     Creates an in-memory SwiftData container for workspace/window package tests.

     The schema mirrors the production graph owned by `WorkspaceStore`, `WindowManager`,
     and `WorkspaceSelectionService` so package tests exercise the same relationships without
     launching the app target.

     - Returns: A transient `ModelContainer` containing workspace, window, page-manager,
       history, and settings models.
     - Side effects: Allocates in-process SwiftData storage for the current test only.
     - Failure modes: Throws if SwiftData cannot build the in-memory container.
     */
    private func makeWorkspaceModelContainer() throws -> ModelContainer {
        let schema = Schema([
            Setting.self,
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
