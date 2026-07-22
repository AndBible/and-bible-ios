import SwiftData
import XCTest
@testable import BibleCore

/**
 Protects Android `WindowControl.changeSyncGroup` ordering and peer-selection parity.

 Tests use in-memory SwiftData and lightweight registered controller doubles. Failures indicate group
 state was posted without immediate peer alignment, an ineligible peer was selected, or source-local
 position data was lost before the reader conversion path.
 */
final class WindowManagerSyncGroupParityTests: XCTestCase {
    /**
     Verifies group flags are visible before a synchronous peer callback and persist afterward.

     Android sets `isSynchronised` and the zero-based group, calls `WindowSync.synchronizeWindows`
     with a peer, then posts changed state. The callback must therefore observe the new flags and the
     exact source-local payload. The in-memory container is discarded with the test.
     */
    func testChangeSyncGroupImmediatelyEmitsPeerBeforePersistedRefresh() throws {
        let container = try makeContainer()
        let store = WorkspaceStore(modelContext: ModelContext(container))
        let manager = WindowManager(workspaceStore: store)
        let workspace = store.createWorkspace(name: "Immediate Sync Group")
        let target = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        manager.setActiveWorkspace(workspace)
        let peer = try XCTUnwrap(manager.addWindow(from: target))
        peer.syncGroup = 4
        peer.isSynchronized = true
        let source = SyncSourceFixture(
            canProvidePosition: true,
            position: WindowSynchronizationPosition(ordinal: 902, key: "John.3.16")
        )
        manager.registerController(source, for: peer.id)

        var callbackCount = 0
        manager.onSyncVerseChanged = { sourceWindow, ordinal, key in
            callbackCount += 1
            XCTAssertEqual(sourceWindow.id, peer.id)
            XCTAssertEqual(ordinal, 902)
            XCTAssertEqual(key, "John.3.16")
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
     Verifies peer selection skips a visible synchronized controller that cannot expose a verse key.

     Android filters peers by page syncability before selecting the first source. The fixture places
     an ineligible peer first and a valid peer second; only the valid peer may drive the immediate
     callback. In-memory controller registrations are released with the manager.
     */
    func testChangeSyncGroupUsesFirstEligibleVisiblePeer() throws {
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
            for: ineligiblePeer.id
        )
        manager.registerController(
            SyncSourceFixture(
                canProvidePosition: true,
                position: WindowSynchronizationPosition(ordinal: 77, key: "Exod.2.3")
            ),
            for: eligiblePeer.id
        )

        var selectedSourceID: UUID?
        manager.onSyncVerseChanged = { sourceWindow, ordinal, key in
            selectedSourceID = sourceWindow.id
            XCTAssertEqual(ordinal, 77)
            XCTAssertEqual(key, "Exod.2.3")
        }

        manager.changeSyncGroup(target, groupNumber: 2)

        XCTAssertEqual(selectedSourceID, eligiblePeer.id)
    }

    /**
     Registered-controller double for manager-only synchronization tests.

     The fixture exposes deterministic eligibility and source position without importing BibleUI or
     touching SWORD. It records no calls and has no side effects beyond returning configured values.
     */
    private final class SyncSourceFixture: WindowSynchronizationSource {
        /// Configured Android-style verse-source eligibility.
        let canProvideWindowSynchronizationPosition: Bool

        /// Deterministic source-local payload returned to the manager.
        private let position: WindowSynchronizationPosition?

        /** Creates a deterministic source fixture with no external resources. */
        init(canProvidePosition: Bool, position: WindowSynchronizationPosition?) {
            self.canProvideWindowSynchronizationPosition = canProvidePosition
            self.position = position
        }

        /// Returns the configured payload without mutation or failure.
        func currentWindowSynchronizationPosition() -> WindowSynchronizationPosition? {
            position
        }
    }

    /**
     Creates the minimal in-memory workspace schema required by these manager tests.

     - Returns: An isolated SwiftData container discarded after each test.
     - Side Effects: Allocates only in-memory model storage.
     - Failure Modes: Rethrows SwiftData schema/container construction errors.
     */
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Workspace.self, Window.self, PageManager.self, HistoryItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
