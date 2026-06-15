import Foundation
import Darwin
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
     Tears down the currently running UI-test app process after each test method.
     *
     * - Side effects:
     *   - asks CoreSimulator to terminate the tracked app process so the next test gets a clean launch
     *   - clears the stored app handle for the completed test method
     * - Failure modes:
     *   - silently ignores already-stopped app processes because termination is only cleanup
     */
    override func tearDownWithError() throws {
        if let trackedApp {
            _ = terminateAppReliably(trackedApp)
        }
        trackedApp = nil
    }
}
