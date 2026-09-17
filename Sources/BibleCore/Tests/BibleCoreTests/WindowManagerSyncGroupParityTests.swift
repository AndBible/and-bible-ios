import SwiftData
import XCTest
@testable import BibleCore

/** Protects typed, immutable sync-group admission and peer selection. */
final class WindowManagerSyncGroupParityTests: XCTestCase {
    /**
     Verifies group flags are visible before immediate delivery of the peer's exact typed position.

     The fixture registers a KJVA Bible-style provider, joins another pane to its stored group, and
     then reloads persistence. Failure means group ordering or typed identity was lost at peer join.
     */
    func testChangeSyncGroupImmediatelyEmitsTypedPeerBeforePersistedRefresh() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Immediate Sync Group")
        let target = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let peer = try XCTUnwrap(manager.addWindow(from: target))
        peer.syncGroup = 4
        peer.isSynchronized = true
        let expected = WindowSynchronizationPosition(
            sourceVersification: "KJVA",
            osisBookId: "John",
            chapter: 3,
            verse: 16,
            sourceKey: "John.3.16"
        )
        manager.registerController(
            SyncSourceFixture(canProvidePosition: true, position: expected),
            for: peer
        )

        var callbackCount = 0
        manager.onSyncVerseChanged = { sourceWindow, delivery in
            callbackCount += 1
            XCTAssertEqual(sourceWindow.id, peer.id)
            XCTAssertEqual(delivery.position, expected)
            XCTAssertTrue(target.isSynchronized)
            XCTAssertEqual(target.syncGroup, 4)
        }

        manager.changeSyncGroup(target, groupNumber: 4)

        XCTAssertEqual(callbackCount, 1)
        let reloadedStore = WorkspaceStore(modelContext: ModelContext(container))
        let reloadedTarget = try XCTUnwrap(
            reloadedStore.windows(workspaceId: workspace.id).first(where: { $0.id == target.id })
        )
        XCTAssertTrue(reloadedTarget.isSynchronized)
        XCTAssertEqual(reloadedTarget.syncGroup, 4)
    }

    /**
     Verifies selection remains delegated to the first eligible registered page-family provider.

     BibleCore intentionally does not infer categories. The eligible fixture supplies a structurally
     valid KJVA position shaped like a rendered My Notes source but makes no claim that UI eligibility
     is implemented; BibleUI must separately prove that its My Notes controller opts in.
     */
    func testChangeSyncGroupUsesFirstEligibleTypedProvider() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Eligible Sync Peer")
        let target = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let ineligiblePeer = try XCTUnwrap(manager.addWindow(from: target))
        let eligiblePeer = try XCTUnwrap(manager.addWindow(from: ineligiblePeer))
        for peer in [ineligiblePeer, eligiblePeer] {
            peer.syncGroup = 2
            peer.isSynchronized = true
        }
        manager.registerController(
            SyncSourceFixture(canProvidePosition: false, position: nil),
            for: ineligiblePeer
        )
        let renderedMyNotesPosition = WindowSynchronizationPosition(
            sourceVersification: "KJVA",
            osisBookId: "Ps",
            chapter: 11,
            verse: 0,
            sourceKey: "Ps.11"
        )
        manager.registerController(
            SyncSourceFixture(canProvidePosition: true, position: renderedMyNotesPosition),
            for: eligiblePeer
        )

        var selectedSourceID: UUID?
        manager.onSyncVerseChanged = { sourceWindow, delivery in
            selectedSourceID = sourceWindow.id
            XCTAssertEqual(delivery.position, renderedMyNotesPosition)
        }

        manager.changeSyncGroup(target, groupNumber: 2)

        XCTAssertEqual(selectedSourceID, eligiblePeer.id)
    }

    /**
     Verifies debounce delivery retains the admitted value rather than reading later mutable state.

     The exact source controller is registered, a KJVA position is admitted, and persisted position
     fields change before delivery. The callback must receive the original typed value once.
     */
    func testDebouncedNotificationRetainsAdmissionTimeTypedIdentity() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Typed Debounce")
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        source.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: source))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = source.syncGroup
        let owner = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(owner, for: source))
        let admitted = WindowSynchronizationPosition(
            sourceVersification: "KJVA",
            osisBookId: "Ps",
            chapter: 11,
            verse: 0,
            sourceKey: "Ps.11"
        )
        let delivered = expectation(description: "typed admission is delivered")
        manager.onSyncVerseChanged = { deliveredSource, delivery in
            XCTAssertEqual(deliveredSource.id, source.id)
            XCTAssertEqual(delivery.position, admitted)
            XCTAssertEqual(delivery.targets.map(\.id), [admittedTarget.id])
            delivered.fulfill()
        }

        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: admitted)
        owner.replacePosition(WindowSynchronizationPosition(
            sourceVersification: "Vulg", osisBookId: "Ps", chapter: 147, verse: 1
        ))
        // Model a source controller changing module/category before the debounce fires. The manager
        // owns the admitted value and performs no later controller lookup or ordinal reconstruction.
        source.pageManager?.bibleChapterNo = 147
        source.pageManager?.bibleVerseNo = 1

        wait(for: [delivered], timeout: 1)
    }

    /**
     Verifies a queued source loses authority when its registered controller is replaced.

     The position is valid when admitted, but replacement retires the exact producer before the
     debounce fires. Delivery must be suppressed even though the same Window object remains managed.
     */
    func testDebouncedNotificationRejectsReplacedSourceController() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Replaced Sync Source")
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        source.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: source))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = source.syncGroup
        let original = SyncSourceFixture(canProvidePosition: true, position: nil)
        let replacement = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(original, for: source))
        let callback = expectation(description: "retired source cannot deliver")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }

        manager.notifyVerseChanged(
            sourceWindow: source,
            source: original,
            position: WindowSynchronizationPosition(
                sourceVersification: "KJVA",
                osisBookId: "Ps",
                chapter: 11,
                verse: 0,
                sourceKey: "Ps.11"
            )
        )
        XCTAssertTrue(manager.registerController(replacement, for: source))

        assertNoCallbackAfterDebounce(callback)
    }

    /**
     Verifies a retired producer cannot borrow a replacement controller's authority.

     Replacement occurs before the old provider attempts admission. Passing the old provider as the
     identity witness must fail immediately even though its Window object is still managed and the
     slot now contains another eligible provider.
     */
    func testNotificationRejectsRetiredProducerCallingAfterReplacement() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Late Retired Sync Producer")
        let sourceWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        sourceWindow.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: sourceWindow))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = sourceWindow.syncGroup
        let retired = SyncSourceFixture(canProvidePosition: true, position: nil)
        let replacement = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(retired, for: sourceWindow))
        XCTAssertTrue(manager.registerController(replacement, for: sourceWindow))
        let callback = expectation(description: "retired producer cannot borrow slot")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }

        manager.notifyVerseChanged(
            sourceWindow: sourceWindow,
            source: retired,
            position: WindowSynchronizationPosition(
                sourceVersification: "KJVA",
                osisBookId: "Ps",
                chapter: 11,
                verse: 0,
                sourceKey: "Ps.11"
            )
        )

        assertNoCallbackAfterDebounce(callback)
    }

    /**
     Verifies a workspace transition revokes a queued source window's authority.

     The old Window remains strongly captured until the bounded dispatch item executes, but the
     manager has rebound to a different exact graph and must reject delivery before invoking UI.
     */
    func testDebouncedNotificationRejectsSourceAfterWorkspaceTransition() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let oldWorkspace = store.createWorkspace(name: "Old Sync Workspace")
        let source = try XCTUnwrap(store.windows(workspaceId: oldWorkspace.id).first)
        manager.setActiveWorkspace(oldWorkspace)
        source.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: source))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = source.syncGroup
        let owner = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(owner, for: source))
        let callback = expectation(description: "old graph cannot deliver")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }

        manager.notifyVerseChanged(
            sourceWindow: source,
            source: owner,
            position: WindowSynchronizationPosition(
                sourceVersification: "KJVA",
                osisBookId: "Ps",
                chapter: 11,
                verse: 0,
                sourceKey: "Ps.11"
            )
        )
        let replacementWorkspace = store.createWorkspace(name: "Replacement Sync Workspace")
        manager.setActiveWorkspace(replacementWorkspace)

        assertNoCallbackAfterDebounce(callback)
    }

    /** Verifies two valid observations coalesce to only the latest immutable position. */
    func testDebouncedNotificationsCoalesceToLatestValidPosition() throws {
        let (manager, sourceWindow, owner) = try makeRegisteredSource(named: "Coalesced Typed Sync")
        let first = WindowSynchronizationPosition(sourceVersification: "KJVA", osisBookId: "Gen", chapter: 1, verse: 1)
        let latest = WindowSynchronizationPosition(sourceVersification: "KJVA", osisBookId: "Gen", chapter: 1, verse: 2)
        let delivered = expectation(description: "latest position delivered")
        delivered.assertForOverFulfill = true
        manager.onSyncVerseChanged = { _, delivery in
            XCTAssertEqual(delivery.position, latest)
            delivered.fulfill()
        }
        manager.notifyVerseChanged(sourceWindow: sourceWindow, source: owner, position: first)
        manager.notifyVerseChanged(sourceWindow: sourceWindow, source: owner, position: latest)
        wait(for: [delivered], timeout: 1)
    }

    /** Verifies returning to the original group cannot revive pre-transition work. */
    func testSyncGroupAwayAndBackRevokesPendingPosition() throws {
        let (manager, sourceWindow, owner) = try makeRegisteredSource(named: "Group Revocation")
        sourceWindow.syncGroup = 0
        let callback = expectation(description: "pre-transition work stays revoked")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }
        manager.notifyVerseChanged(
            sourceWindow: sourceWindow,
            source: owner,
            position: WindowSynchronizationPosition(sourceVersification: "KJVA", osisBookId: "Gen", chapter: 1, verse: 1)
        )
        manager.changeSyncGroup(sourceWindow, groupNumber: 1)
        manager.changeSyncGroup(sourceWindow, groupNumber: 0)
        assertNoCallbackAfterDebounce(callback)
    }

    /** Verifies an invalid latest observation from the current owner revokes older valid work. */
    func testInvalidLatestPositionFromCurrentOwnerRevokesPriorValidWork() throws {
        let (manager, sourceWindow, owner) = try makeRegisteredSource(named: "Invalid Latest")
        let callback = expectation(description: "old valid work is revoked")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }
        manager.notifyVerseChanged(
            sourceWindow: sourceWindow,
            source: owner,
            position: WindowSynchronizationPosition(sourceVersification: "KJVA", osisBookId: "Gen", chapter: 1, verse: 1)
        )
        manager.notifyVerseChanged(
            sourceWindow: sourceWindow,
            source: owner,
            position: WindowSynchronizationPosition(sourceVersification: "", osisBookId: "Gen", chapter: 1, verse: 2)
        )
        assertNoCallbackAfterDebounce(callback)
    }

    /** Verifies an invalid retired caller cannot revoke the replacement owner's valid work. */
    func testInvalidRetiredProducerCannotRevokeReplacementWork() throws {
        let (manager, sourceWindow, retired) = try makeRegisteredSource(named: "Foreign Revocation")
        let replacement = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(replacement, for: sourceWindow))
        let latest = WindowSynchronizationPosition(sourceVersification: "KJVA", osisBookId: "Gen", chapter: 1, verse: 2)
        let delivered = expectation(description: "replacement work survives")
        manager.onSyncVerseChanged = { _, delivery in
            XCTAssertEqual(delivery.position, latest)
            delivered.fulfill()
        }
        manager.notifyVerseChanged(sourceWindow: sourceWindow, source: replacement, position: latest)
        manager.notifyVerseChanged(
            sourceWindow: sourceWindow,
            source: retired,
            position: WindowSynchronizationPosition(sourceVersification: "", osisBookId: "Gen", chapter: 1, verse: 3)
        )
        wait(for: [delivered], timeout: 1)
    }

    /** Verifies queued work does not keep a displaced producer alive. */
    func testDebouncedNotificationDoesNotRetainDisplacedProducer() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Weak Producer")
        let sourceWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        sourceWindow.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: sourceWindow))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = sourceWindow.syncGroup
        var original: SyncSourceFixture? = SyncSourceFixture(canProvidePosition: true, position: nil)
        weak var weakOriginal = original
        XCTAssertTrue(manager.registerController(try XCTUnwrap(original), for: sourceWindow))
        manager.notifyVerseChanged(
            sourceWindow: sourceWindow,
            source: try XCTUnwrap(original),
            position: WindowSynchronizationPosition(sourceVersification: "KJVA", osisBookId: "Gen", chapter: 1, verse: 1)
        )
        XCTAssertTrue(manager.registerController(SyncSourceFixture(canProvidePosition: true, position: nil), for: sourceWindow))
        original = nil
        XCTAssertNil(weakOriginal)
    }

    /**
     Verifies malformed typed coordinates never enter delayed delivery.

     An empty source versification is structurally invalid. No registered controller or later state
     can make that payload authoritative, and the callback must remain silent.
     */
    func testStructurallyInvalidPositionIsNotAdmitted() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Invalid Typed Sync")
        let source = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        source.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: source))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = source.syncGroup
        let owner = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(owner, for: source))
        let callback = expectation(description: "invalid source is rejected")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }

        manager.notifyVerseChanged(
            sourceWindow: source,
            source: owner,
            position: WindowSynchronizationPosition(
                sourceVersification: "",
                osisBookId: "Ps",
                chapter: 11,
                verse: 1
            )
        )

        assertNoCallbackAfterDebounce(callback)
    }

    /** Unrelated target toggles do not discard a source update admitted for an unchanged peer. */
    func testPendingSourcePositionSurvivesUnrelatedTargetSynchronizationToggle() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Unrelated Toggle")
        let unchanged = try XCTUnwrap(manager.visibleWindows.first(where: { $0.id != source.id }))
        let changed = try XCTUnwrap(manager.addWindow(from: unchanged))
        changed.isSynchronized = true
        changed.syncGroup = source.syncGroup
        let delivered = expectation(description: "unchanged peer receives admitted position")
        manager.onSyncVerseChanged = { _, delivery in
            XCTAssertEqual(delivery.targets.map(\.id), [unchanged.id])
            delivered.fulfill()
        }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: testPosition(1))
        manager.setSynchronized(changed, value: false)
        manager.setSynchronized(changed, value: true)
        wait(for: [delivered], timeout: 1)
    }

    /** Unrelated target group movement excludes only that target from an admitted delivery. */
    func testPendingSourcePositionSurvivesUnrelatedTargetGroupChange() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Unrelated Group")
        let unchanged = try XCTUnwrap(manager.visibleWindows.first(where: { $0.id != source.id }))
        let changed = try XCTUnwrap(manager.addWindow(from: unchanged))
        changed.isSynchronized = true
        changed.syncGroup = source.syncGroup
        let delivered = expectation(description: "unchanged peer survives group change")
        manager.onSyncVerseChanged = { _, delivery in
            XCTAssertEqual(delivery.targets.map(\.id), [unchanged.id])
            delivered.fulfill()
        }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: testPosition(1))
        manager.changeSyncGroup(changed, groupNumber: 1)
        wait(for: [delivered], timeout: 1)
    }

    /** A source synchronized away and back cannot revive its pre-transition position. */
    func testSourceSynchronizationAwayAndBackRevokesPendingPosition() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Source Toggle")
        let callback = expectation(description: "source transition revokes work")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: testPosition(1))
        manager.setSynchronized(source, value: false)
        manager.setSynchronized(source, value: true)
        assertNoCallbackAfterDebounce(callback)
    }

    /** Current full-group alignment supersedes every recipient of an older same-group value. */
    func testJoiningTargetIsNotOverwrittenByOlderAdmittedPosition() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Joining Target")
        let unchanged = try XCTUnwrap(manager.visibleWindows.first(where: { $0.id != source.id }))
        let joining = try XCTUnwrap(manager.addWindow(from: unchanged))
        joining.isSynchronized = false
        let old = testPosition(1)
        let current = testPosition(2)
        let immediate = expectation(description: "current peer value aligns complete group")
        let stale = expectation(description: "older admission never follows immediate alignment")
        stale.isInverted = true
        manager.onSyncVerseChanged = { _, delivery in
            if delivery.position == old {
                stale.fulfill()
            } else if delivery.position == current {
                XCTAssertEqual(delivery.targets.map(\.id), [unchanged.id, joining.id])
                immediate.fulfill()
            }
        }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: old)
        owner.replacePosition(current)
        manager.changeSyncGroup(joining, groupNumber: source.syncGroup)
        wait(for: [immediate], timeout: 0.1)
        assertNoCallbackAfterDebounce(stale)
    }

    /** Immediate alignment in another group does not cancel this group's pending source value. */
    func testUnrelatedGroupImmediateJoinPreservesPendingSourceDelivery() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Independent Groups")
        let unchanged = try XCTUnwrap(manager.visibleWindows.first(where: { $0.id != source.id }))
        let groupOnePeer = try XCTUnwrap(manager.addWindow(from: unchanged))
        groupOnePeer.isSynchronized = true
        groupOnePeer.syncGroup = 1
        let groupOnePosition = testPosition(3)
        let groupOneOwner = SyncSourceFixture(canProvidePosition: true, position: groupOnePosition)
        XCTAssertTrue(manager.registerController(groupOneOwner, for: groupOnePeer))
        let joining = try XCTUnwrap(manager.addWindow(from: groupOnePeer))
        joining.isSynchronized = false
        let pending = testPosition(1)
        let immediate = expectation(description: "other group aligns immediately")
        let delayed = expectation(description: "original group still receives pending value")
        manager.onSyncVerseChanged = { deliveredSource, delivery in
            if delivery.position == groupOnePosition {
                XCTAssertEqual(deliveredSource.id, groupOnePeer.id)
                XCTAssertEqual(delivery.targets.map(\.id), [joining.id])
                immediate.fulfill()
            } else if delivery.position == pending {
                XCTAssertEqual(deliveredSource.id, source.id)
                XCTAssertEqual(delivery.targets.map(\.id), [unchanged.id])
                delayed.fulfill()
            }
        }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: pending)
        manager.changeSyncGroup(joining, groupNumber: 1)
        wait(for: [immediate, delayed], timeout: 1)
    }

    /** Target away-and-back changes membership identity and cannot reenter an older delivery. */
    func testTargetAwayAndBackCannotReenterOlderRecipientSnapshot() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Target Epoch")
        let target = try XCTUnwrap(manager.visibleWindows.first(where: { $0.id != source.id }))
        let callback = expectation(description: "changed target excluded")
        callback.isInverted = true
        manager.onSyncVerseChanged = { _, _ in callback.fulfill() }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: testPosition(1))
        manager.changeSyncGroup(target, groupNumber: 1)
        manager.changeSyncGroup(target, groupNumber: source.syncGroup)
        assertNoCallbackAfterDebounce(callback)
    }

    /** Latest coalesced position retains the unchanged recipient admitted with it. */
    func testUnchangedRecipientGetsLatestCoalescedSourcePosition() throws {
        let (manager, source, owner) = try makeRegisteredSource(named: "Recipient Coalescing")
        let target = try XCTUnwrap(manager.visibleWindows.first(where: { $0.id != source.id }))
        let delivered = expectation(description: "latest delivered to admitted target")
        manager.onSyncVerseChanged = { _, delivery in
            XCTAssertEqual(delivery.position, self.testPosition(2))
            XCTAssertEqual(delivery.targets.map(\.id), [target.id])
            delivered.fulfill()
        }
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: testPosition(1))
        manager.notifyVerseChanged(sourceWindow: source, source: owner, position: testPosition(2))
        wait(for: [delivered], timeout: 1)
    }

    /// Deterministic provider double for core selection and exact-owner admission tests.
    private final class SyncSourceFixture: WindowSynchronizationSource {
        /// Whether WindowManager may select this provider during immediate peer alignment.
        let canProvideWindowSynchronizationPosition: Bool
        /// Fully resolved position returned without consulting mutable reader state.
        private var position: WindowSynchronizationPosition?

        /** Creates a provider with explicit eligibility and typed output. */
        init(canProvidePosition: Bool, position: WindowSynchronizationPosition?) {
            self.canProvideWindowSynchronizationPosition = canProvidePosition
            self.position = position
        }

        func replacePosition(_ position: WindowSynchronizationPosition?) {
            self.position = position
        }

        func currentWindowSynchronizationPosition() -> WindowSynchronizationPosition? {
            position
        }
    }

    /** Creates one synchronized source with its exact provider registered. */
    private func makeRegisteredSource(
        named name: String
    ) throws -> (WindowManager, Window, SyncSourceFixture) {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: name)
        let sourceWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        sourceWindow.isSynchronized = true
        let admittedTarget = try XCTUnwrap(manager.addWindow(from: sourceWindow))
        admittedTarget.isSynchronized = true
        admittedTarget.syncGroup = sourceWindow.syncGroup
        let owner = SyncSourceFixture(canProvidePosition: true, position: nil)
        XCTAssertTrue(manager.registerController(owner, for: sourceWindow))
        return (manager, sourceWindow, owner)
    }

    private func testPosition(_ verse: Int) -> WindowSynchronizationPosition {
        WindowSynchronizationPosition(
            sourceVersification: "KJVA",
            osisBookId: "Gen",
            chapter: 1,
            verse: verse
        )
    }

    /** Waits beyond the debounce and proves the main queue crossed the delivery deadline. */
    private func assertNoCallbackAfterDebounce(_ inverted: XCTestExpectation) {
        let deadlineCrossed = expectation(description: "main queue crossed debounce deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { deadlineCrossed.fulfill() }
        wait(for: [inverted, deadlineCrossed], timeout: 0.5)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
