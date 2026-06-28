import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

/**
 Package-level reader interaction policy tests migrated from the app-host bundle.

 These tests exercise BibleUI reader gesture and fullscreen policy contracts with injected
 dependencies. They do not require app delegate, scene, or installed app bootstrap behavior.
 */
final class ReaderInteractionPolicyTests: XCTestCase {
    /**
     Verifies that the native fullscreen bridge honors the user preference gate.

     The bridge should acknowledge the Vue double-tap fullscreen request in every case, but the
     native toggle callback must only fire while the BibleCore setting is enabled. A failure means
     reader gesture behavior can drift from the persisted text-display preference contract.
     */
    func testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest() throws {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let settingsStore = try makeInMemorySettingsStore()
        controller.settingsStore = settingsStore

        var toggleCount = 0
        controller.onToggleFullScreen = { toggleCount += 1 }

        XCTAssertEqual(bridge.dispatchMessage(method: "toggleFullScreen", args: []), .handled)
        XCTAssertEqual(toggleCount, 1)

        settingsStore.setBool(.doubleTapToFullscreen, value: false)
        XCTAssertEqual(bridge.dispatchMessage(method: "toggleFullScreen", args: []), .handled)
        XCTAssertEqual(toggleCount, 1)

        settingsStore.setBool(.doubleTapToFullscreen, value: true)
        XCTAssertEqual(bridge.dispatchMessage(method: "toggleFullScreen", args: []), .handled)
        XCTAssertEqual(toggleCount, 2)
    }

    /**
     Protects the configured horizontal-swipe action mapping used by the reader shell.

     The policy should map chapter, page, and disabled modes deterministically while suppressing
     navigation when text selection or modal UI is active. A failure means gesture configuration can
     trigger the wrong Android-parity reader action.
     */
    func testReaderHorizontalSwipePolicyMapsConfiguredModes() {
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "CHAPTER",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .navigateNextChapter
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "CHAPTER",
                direction: .right,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .navigatePreviousChapter
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "PAGE",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .scrollPageDown
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "PAGE",
                direction: .right,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .scrollPageUp
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "NONE",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .none
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "PAGE",
                direction: .left,
                hasActiveSelection: true,
                hasOpenModal: false
            ),
            .none
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "CHAPTER",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: true
            ),
            .none
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "unexpected",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .navigateNextChapter
        )
    }

    /**
     Verifies auto-fullscreen threshold accumulation across scroll directions.

     The policy should accumulate deltas until the Android-parity threshold is crossed, reset after
     firing, and track direction changes independently. A failure means normal scrolling can enter
     or exit fullscreen too early or too late.
     */
    func testAutoFullscreenPolicyAccumulatesThresholdByDirection() {
        var tracking = ReaderAutoFullscreenTracking()

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: 20,
                isEnabled: true,
                isFullScreen: false,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking.directionDown, true)
        XCTAssertEqual(tracking.distance, 20)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: 36,
                isEnabled: true,
                isFullScreen: false,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .enterFullscreen
        )
        XCTAssertEqual(tracking.directionDown, true)
        XCTAssertEqual(tracking.distance, 0)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: -10,
                isEnabled: true,
                isFullScreen: true,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking.directionDown, false)
        XCTAssertEqual(tracking.distance, 10)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: -46,
                isEnabled: true,
                isFullScreen: true,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .exitFullscreen
        )
        XCTAssertEqual(tracking.distance, 0)
    }

    /**
     Verifies disabled and double-tap-locked auto-fullscreen states.

     Disabled auto-fullscreen must reset tracking state, while double-tap lock must suppress the
     exit action even when scroll distance crosses the threshold. A failure means explicit user
     fullscreen state can be overridden by passive scroll callbacks.
     */
    func testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock() {
        var tracking = ReaderAutoFullscreenTracking(directionDown: true, distance: 24)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: 10,
                isEnabled: false,
                isFullScreen: false,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking, ReaderAutoFullscreenTracking())

        tracking = ReaderAutoFullscreenTracking()
        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: -56,
                isEnabled: true,
                isFullScreen: true,
                fullscreenLockedByDoubleTap: true,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking.directionDown, false)
        XCTAssertEqual(tracking.distance, 0)
    }
}
