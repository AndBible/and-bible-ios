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

    /**
     Protects the host-process capture helper from blocking on descendants that inherit stdout.
     *
     * Setup:
     * - runs a Python process that exits immediately after writing output
     * - forks a short-lived descendant that keeps the inherited stdout descriptor open
     *
     * Expected result:
     * - the helper returns after the direct child exits and captures the direct child's output
     *
     * Failure meaning:
     * - UI-test fixture bootstrap can stall when `simctl launch` or another host command leaves
     *   pipe descriptors attached to a launched process that outlives the command
     *
     * Side effects:
     * - starts one short-lived host `sleep` process that exits on its own
     */
    func testHostProcessCaptureReturnsAfterChildExitWhenDescendantKeepsPipeOpen() {
        let start = Date()
        let result = runHostProcess(
            executablePath: "/usr/bin/python3",
            arguments: [
                "-c",
                """
                import os
                import sys
                import time

                if os.fork() == 0:
                    time.sleep(8)
                    os._exit(0)

                sys.stdout.write("fixture-ready")
                sys.stdout.flush()
                os._exit(0)
                """
            ],
            timeout: 15
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "fixture-ready")
        XCTAssertLessThan(
            elapsed,
            5,
            "Host process capture should not block until inherited pipe descriptors close."
        )
    }
}
