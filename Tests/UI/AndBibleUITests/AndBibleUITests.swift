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
     * - runs a shell process that exits immediately after writing output
     * - starts a nohup descendant shell that keeps the inherited stdout descriptor open and writes
     *   a marker after the direct shell exits
     *
     * Expected result:
     * - the helper returns after the direct child exits and captures the direct child's output
     * - the descendant marker appears after the helper returns, proving capture did not wait for
     *   inherited pipe descriptors to close and the descendant survived the shell exit
     *
     * Failure meaning:
     * - UI-test fixture bootstrap can stall when `simctl launch` or another host command leaves
     *   pipe descriptors attached to a launched process that outlives the command
     *
     * Side effects:
     * - creates and removes one temporary marker file
     * - starts and terminates one descendant host shell process that inherits stdout
     */
    func testHostProcessCaptureReturnsAfterChildExitWhenDescendantKeepsPipeOpen() {
        var descendantPID: pid_t?
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("andbible-host-process-\(UUID().uuidString).marker")
        defer {
            if let descendantPID {
                _ = kill(descendantPID, SIGTERM)
            }
            try? FileManager.default.removeItem(at: markerURL)
        }

        let result = runHostProcess(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                """
                /usr/bin/nohup /bin/sh -c 'sleep 2; printf alive > "$1"; sleep 30' descriptor-descendant "$1" &
                child_pid=$!
                printf "fixture-ready:%s" "$child_pid"
                exit 0
                """,
                "descriptor-fixture",
                markerURL.path
            ],
            timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        let outputParts = result.stdout.split(separator: ":", maxSplits: 1)
        XCTAssertEqual(outputParts.first, "fixture-ready")
        XCTAssertEqual(outputParts.count, 2)
        descendantPID = outputParts.last.flatMap { pid_t(String($0)) }
        XCTAssertNotNil(descendantPID)

        let markerDeadline = Date().addingTimeInterval(6)
        while Date() < markerDeadline,
              !FileManager.default.fileExists(atPath: markerURL.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "Host process capture should return before inherited pipe descriptors close while the descendant keeps running."
        )
    }

    /**
     Protects host-side `xcrun simctl` calls from inheriting simulator/XCTest user-directory values
     or stale command-line-tool selections.
     *
     * Setup:
     * - starts from an environment with explicit CI host user-directory overrides
     * - includes stale XCTest-style home values that should not reach host subprocesses
     * - models an inherited stale Xcode, a selected full Xcode, and selected CommandLineTools
     *
     * Expected result:
     * - subprocesses inherit the selected Xcode developer directory
     * - `HOME`, `TMPDIR`, user identity, and CoreFoundation user-home values match the host runner
     * - simulator-capable selected Xcode paths beat stale inherited `DEVELOPER_DIR` values
     * - CommandLineTools is skipped in favor of the default full Xcode when it lacks `simctl`
     *
     * Failure meaning:
     * - UI-test fixture bootstrapping can fail before product behavior runs because `xcrun` cannot
     *   resolve macOS user directories or CoreSimulator preferences from the XCTest process context
     * - CI fixture bootstrap can run host tools against an Xcode that cannot drive the simulator
     *
     * Side effects: None.
     */
    func testHostProcessEnvironmentRestoresMacOSUserDirectories() {
        let environment = [
            "DEVELOPER_DIR": "/Applications/Xcode_16.4.app/Contents/Developer",
            "PATH": "",
            "HOME": "/var/empty",
            "TMPDIR": "/var/folders/zz/zyxvpxvq6csfxvn_n00001ym0000gn/T/",
            "CFFIXED_USER_HOME": "/var/folders/zz/zyxvpxvq6csfxvn_n00001ym0000gn/",
            "UITEST_HOST_HOME": "/Users/runner",
            "UITEST_HOST_TMPDIR": "/var/folders/ci/T/",
            "UITEST_HOST_USER": "runner",
            "UITEST_HOST_LOGNAME": "runner",
            "UITEST_HOST_CF_USER_TEXT_ENCODING": "501:0:0",
        ]

        let sanitizedEnvironment = hostProcessEnvironment(
            from: environment,
            selectedDeveloperDir: "/Applications/Xcode_26.3.app/Contents/Developer"
        )

        XCTAssertEqual(
            sanitizedEnvironment["DEVELOPER_DIR"],
            "/Applications/Xcode_26.3.app/Contents/Developer"
        )
        XCTAssertEqual(
            sanitizedEnvironment["UITEST_DEVELOPER_DIR"],
            sanitizedEnvironment["DEVELOPER_DIR"]
        )
        XCTAssertEqual(sanitizedEnvironment["HOME"], "/Users/runner")
        XCTAssertEqual(sanitizedEnvironment["CFFIXED_USER_HOME"], "/Users/runner")
        XCTAssertEqual(sanitizedEnvironment["TMPDIR"], "/var/folders/ci/T/")
        XCTAssertEqual(sanitizedEnvironment["USER"], "runner")
        XCTAssertEqual(sanitizedEnvironment["LOGNAME"], "runner")
        XCTAssertEqual(sanitizedEnvironment["__CF_USER_TEXT_ENCODING"], "501:0:0")
        XCTAssertEqual(sanitizedEnvironment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")

        let staleDeveloperDir = "/Applications/Xcode_16.4.app/Contents/Developer"
        let selectedDeveloperDir = "/Applications/Xcode_26.3.app/Contents/Developer"
        let selectedXcodePaths = Set([
            staleDeveloperDir,
            "\(staleDeveloperDir)/usr/bin/simctl",
            selectedDeveloperDir,
            "\(selectedDeveloperDir)/usr/bin/simctl",
        ])

        let resolvedDeveloperDir = selectedDeveloperDirForHostProcess(
            environment: [
                "DEVELOPER_DIR": staleDeveloperDir,
            ],
            xcodeSelectDeveloperDir: { selectedDeveloperDir },
            fileExists: { selectedXcodePaths.contains($0) }
        )

        XCTAssertEqual(resolvedDeveloperDir, selectedDeveloperDir)

        let commandLineToolsDir = "/Library/Developer/CommandLineTools"
        let defaultDeveloperDir = "/Applications/Xcode.app/Contents/Developer"
        let commandLineToolsFallbackPaths = Set([
            commandLineToolsDir,
            defaultDeveloperDir,
            "\(defaultDeveloperDir)/usr/bin/simctl",
        ])

        let fallbackDeveloperDir = selectedDeveloperDirForHostProcess(
            environment: [:],
            xcodeSelectDeveloperDir: { commandLineToolsDir },
            fileExists: { commandLineToolsFallbackPaths.contains($0) }
        )

        XCTAssertEqual(fallbackDeveloperDir, defaultDeveloperDir)
    }

}
