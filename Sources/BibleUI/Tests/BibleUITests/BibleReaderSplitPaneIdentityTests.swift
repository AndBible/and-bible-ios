import BibleCore
import BibleView
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import BibleUI

/** Verifies the live split hierarchy keys pane-local reader state by exact window graph identity. */
@MainActor
final class BibleReaderSplitPaneIdentityTests: XCTestCase {
    /**
     A rotation-style layout update preserves the controller/session for the same `Window` object,
     while a replacement object with the same persisted UUID reconstructs that pane state.
     */
    func testSameIDGraphReplacementReconstructsPaneControllerAndSession() async throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let workspace = store.createWorkspace(name: "Pane identity")
        let originalWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        let recorder = PaneIdentityRecorder()

        let firstAppearance = expectation(description: "original pane appears")
        recorder.onNextObservation = { firstAppearance.fulfill() }
        let host = UIHostingController(
            rootView: splitContent(
                window: originalWindow,
                reverseSplitMode: false,
                manager: manager,
                recorder: recorder
            )
        )
        let hostWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        hostWindow.rootViewController = host
        hostWindow.makeKeyAndVisible()
        defer { hostWindow.isHidden = true }
        host.beginAppearanceTransition(true, animated: false)
        host.endAppearanceTransition()
        layout(host)
        await fulfillment(of: [firstAppearance], timeout: 2)
        let original = try XCTUnwrap(recorder.latest)

        let sameObjectUpdate = expectation(description: "same pane observes layout update")
        recorder.onNextObservation = { sameObjectUpdate.fulfill() }
        host.rootView = splitContent(
            window: originalWindow,
            reverseSplitMode: true,
            manager: manager,
            recorder: recorder
        )
        layout(host)
        await fulfillment(of: [sameObjectUpdate], timeout: 2)

        let afterSameObjectLayoutChange = try XCTUnwrap(recorder.latest)
        XCTAssertTrue(afterSameObjectLayoutChange.controller === original.controller)
        XCTAssertTrue(afterSameObjectLayoutChange.session === original.session)

        let replacementWindow = BibleCore.Window(id: originalWindow.id)
        let replacementAppearance = expectation(description: "replacement pane appears")
        recorder.onNextObservation = { replacementAppearance.fulfill() }
        host.rootView = splitContent(
            window: replacementWindow,
            reverseSplitMode: true,
            manager: manager,
            recorder: recorder
        )
        layout(host)
        await fulfillment(of: [replacementAppearance], timeout: 2)

        let replacement = try XCTUnwrap(recorder.latest)
        XCTAssertEqual(replacement.windowID, original.windowID)
        XCTAssertNotEqual(replacement.windowIdentity, original.windowIdentity)
        XCTAssertFalse(replacement.controller === original.controller)
        XCTAssertFalse(replacement.session === original.session)
    }

    /** Builds the production split boundary with a state-owning reader-controller probe. */
    private func splitContent(
        window: BibleCore.Window,
        reverseSplitMode: Bool,
        manager: WindowManager,
        recorder: PaneIdentityRecorder
    ) -> some View {
        BibleReaderSplitContent(windows: [window], reverseSplitMode: reverseSplitMode) { window in
            PaneIdentityProbe(
                window: window,
                layoutToken: reverseSplitMode,
                recorder: recorder
            )
        }
        .environment(manager)
    }

    /** Forces one synchronous UIKit/SwiftUI layout pass after replacing the root value. */
    private func layout<Content: View>(_ host: UIHostingController<Content>) {
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }
}

/** Pane-shaped view whose retained owner mirrors `BibleWindowPane` controller/session state. */
@MainActor
private struct PaneIdentityProbe: View {
    let window: BibleCore.Window
    let layoutToken: Bool
    let recorder: PaneIdentityRecorder

    @State private var owner = PaneIdentityOwner()

    var body: some View {
        Color.clear
            .onAppear {
                recorder.record(window: window, owner: owner)
            }
            .onChange(of: layoutToken) { _, _ in
                recorder.record(window: window, owner: owner)
            }
    }
}

/** Owns a real reader controller and its paired render session for identity assertions. */
@MainActor
private final class PaneIdentityOwner {
    let controller: BibleReaderController
    let session: BibleWebViewSession

    init() {
        let bridge = BibleBridge()
        let session = BibleWebViewSession(bridge: bridge)
        self.session = session
        controller = BibleReaderController(
            bridge: bridge,
            webViewSession: session,
            initializesSword: false
        )
    }
}

/** Captures the exact state owner exposed by each mounted split-pane identity. */
@MainActor
private final class PaneIdentityRecorder {
    struct Observation {
        let windowID: UUID
        let windowIdentity: ObjectIdentifier
        let controller: BibleReaderController
        let session: BibleWebViewSession
    }

    var onNextObservation: (() -> Void)?
    private(set) var latest: Observation?

    func record(window: BibleCore.Window, owner: PaneIdentityOwner) {
        latest = Observation(
            windowID: window.id,
            windowIdentity: ObjectIdentifier(window),
            controller: owner.controller,
            session: owner.session
        )
        let callback = onNextObservation
        onNextObservation = nil
        callback?()
    }
}
