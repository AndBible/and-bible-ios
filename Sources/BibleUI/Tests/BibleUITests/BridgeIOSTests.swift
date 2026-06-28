import XCTest
@testable import BibleUI
@testable import BibleView

#if os(iOS)

/**
 BibleUI reader bridge behavior that requires iOS package execution but not the app host.

 These tests protect reader modal-key routing contracts that sit above the raw BibleView bridge.
 The lower-level `BibleBridge` and `WebViewCoordinator` lifecycle tests live in `BibleViewTests`
 so package placement follows the migration plan's lowest-owning-module rule.
 */
final class BridgeIOSTests: XCTestCase {
    @MainActor
    func testReaderBridgeModalStateBlocksKeyNavigationAndRequestsClose() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)

        XCTAssertFalse(controller.webModalIsOpen)
        XCTAssertEqual(bridge.dispatchMessage(method: "reportModalState", args: [true]), .handled)
        XCTAssertTrue(controller.webModalIsOpen)

        XCTAssertEqual(bridge.dispatchMessage(method: "onKeyDown", args: ["ArrowRight"]), .handled)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)

        XCTAssertEqual(bridge.dispatchMessage(method: "onKeyDown", args: ["Escape"]), .handled)
        XCTAssertTrue(recordedScripts().contains { $0.contains("bibleView.emit('close_modals'") })

        XCTAssertEqual(bridge.dispatchMessage(method: "reportModalState", args: [false]), .handled)
        XCTAssertFalse(controller.webModalIsOpen)

        XCTAssertEqual(bridge.dispatchMessage(method: "onKeyDown", args: ["ArrowRight"]), .handled)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 2)
    }

    /**
     Verifies bridge event routing keeps modal state and host callback dispatch outside the reader controller.

     - Setup: Uses the focused router with closure recorders instead of a full reader controller so
       the test protects routing ownership rather than document payload generation.
     - Expected result: Modal-open key events do not navigate, Escape asks Vue to close modals, host
       callbacks are forwarded through injected closures, and fullscreen honors the injected
       preference gate.
     - Failure meaning: A failure means the #146 extraction has either left routing behavior in the
       controller or changed the existing bridge event semantics while moving it.
     */
    @MainActor
    func testBridgeEventRouterOwnsModalKeyboardAndHostCallbackRouting() {
        var emittedEvents: [String] = []
        var previousCount = 0
        var nextCount = 0
        var toasts: [String] = []
        var sharedHTML: [String] = []
        var downloadSeeds: [String?] = []
        var fullscreenAllowed = false
        var fullscreenToggleCount = 0

        let router = BibleReaderBridgeEventRouter(
            emitBridgeEvent: { event in
                emittedEvents.append(event)
                return true
            },
            navigatePrevious: { previousCount += 1 },
            navigateNext: { nextCount += 1 },
            showToast: { toasts.append($0) },
            shareHtml: { sharedHTML.append($0) },
            openDownloads: { downloadSeeds.append($0) },
            shouldToggleFullScreen: { fullscreenAllowed },
            toggleFullScreen: { fullscreenToggleCount += 1 }
        )

        XCTAssertFalse(router.webModalIsOpen)
        router.reportModalState(true)
        XCTAssertTrue(router.webModalIsOpen)

        router.handleKeyDown("ArrowRight")
        router.handleKeyDown("Escape")
        XCTAssertEqual(nextCount, 0)
        XCTAssertEqual(emittedEvents, ["close_modals"])

        router.reportModalState(false)
        router.handleKeyDown("ArrowLeft")
        router.handleKeyDown("ArrowRight")
        XCTAssertEqual(previousCount, 1)
        XCTAssertEqual(nextCount, 1)

        router.showToast("Saved")
        router.shareHtml("<p>Shared</p>")
        router.requestOpenDownloads(searchText: "KJV")
        XCTAssertEqual(toasts, ["Saved"])
        XCTAssertEqual(sharedHTML, ["<p>Shared</p>"])
        XCTAssertEqual(downloadSeeds.count, 1)
        XCTAssertEqual(downloadSeeds.first ?? nil, "KJV")

        router.requestToggleFullScreen()
        XCTAssertEqual(fullscreenToggleCount, 0)
        fullscreenAllowed = true
        router.requestToggleFullScreen()
        XCTAssertEqual(fullscreenToggleCount, 1)
    }
}
#endif
