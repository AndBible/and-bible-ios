import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif

/**
 UI smoke tests for the core iPhone navigation shell.

 Data dependencies:
 - launches the production AndBible app target under XCUITest
 - relies on stable accessibility identifiers exposed by the reader overflow menu and settings form

 Side effects:
 - boots the app in a simulator-hosted UI automation session
 - opens the reader overflow menu and drives settings navigation

 Failure modes:
 - fails when the app no longer reaches the reader shell on launch
 - fails when the documented accessibility identifiers drift without coordinated test updates

 Concurrency:
 - runs on XCTest's serialized UI automation thread
 */
final class AndBibleUITests: XCTestCase {
    /// Tracks the currently launched app so each test can end with a deterministic teardown.
    var trackedApp: XCUIApplication?

    /**
     Configures each UI test for fail-fast execution.
     *
     * - Side effects:
     *   - disables XCTest's continue-after-failure behavior for the current test method
     * - Failure modes: This override cannot fail.
     */
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /**
     Tears down the currently running UI-test app through XCTest after each test method.
     *
     * - Side effects:
     *   - asks the tracked `XCUIApplication` to terminate its own launched process
     *   - clears the stored app handle for the completed test method
     * - Failure modes:
     *   - XCTest records an application-control failure if its launched process cannot terminate;
     *     the next fixture prepare still independently requires a host-confirmed stopped process
     */
    override func tearDownWithError() throws {
        trackedApp?.terminate()
        trackedApp = nil
    }

    /**
     Guards shared UI-test coordinate helpers against XCTest frames whose origin and size are finite
     but whose derived activation point overflows.
     *
     * Setup:
     * - builds a synthetic frame matching the unstable XCTest geometry class observed in CI
     *
     * Expected result:
     * - the frame is rejected before any helper tries to synthesize a tap coordinate from it
     *
     * Failure meaning:
     * - reader chrome and menu helpers can still crash a shard with an infinite tap coordinate
     *   instead of falling back to another stable surface.
     *
     * Side effects: none.
     */
    func testElementFrameGuardRejectsOverflowedDerivedCoordinates() {
        let overflowedMidpointFrame = CGRect(
            x: CGFloat.greatestFiniteMagnitude,
            y: 1,
            width: CGFloat.greatestFiniteMagnitude,
            height: 44
        )

        XCTAssertFalse(elementFrameIsUsable(overflowedMidpointFrame))
    }

}
