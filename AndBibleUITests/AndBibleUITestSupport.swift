import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func makeApp(
        searchQuery: String? = nil,
        remoteSyncBootstrapScenario: String? = nil
    ) -> XCUIApplication {
        if let trackedApp, trackedApp.state != .notRunning {
            _ = terminateAppReliably(trackedApp)
        }
        let app = XCUIApplication()
        trackedApp = app
        app.launchEnvironment["UITEST_SESSION_ID"] = UUID().uuidString
        app.launchEnvironment["UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"] = "1"
        app.launchArguments += ["-UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let remoteSyncBootstrapScenario {
            app.launchEnvironment["UITEST_REMOTE_SYNC_BOOTSTRAP_SCENARIO"] = remoteSyncBootstrapScenario
            app.launchArguments += ["-UITEST_REMOTE_SYNC_BOOTSTRAP_SCENARIO", remoteSyncBootstrapScenario]
        }
        if let searchQuery {
            app.launchEnvironment["UITEST_SEARCH_QUERY"] = searchQuery
            app.launchArguments += ["-UITEST_SEARCH_QUERY", searchQuery]
        }
        prepareFixtureIfRequested(for: app)
        return app
    }

    /**
     Applies one host-side fixture scenario to the simulator app container before launching the app.
     *
     * - Side effects:
     *   - resolves the app data container from the current simulator UDID
     *   - runs `UITestFixtureTool reset` and `seed` against that installed app container
     *   - skips host-side fixture work when the manifest uses the `none` sentinel for a
     *     launch-configuration-only test
     * - Failure modes:
     *   - records an XCTest failure when the fixture tool path, simulator UDID, or data container
     *     cannot be resolved from the current test-host environment
     *   - records an XCTest failure when the fixture reset or seed subprocess exits non-zero
     */
    func prepareFixtureIfRequested(
        for app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let scenario = resolveFixtureScenario(
            environment: environment,
            file: file,
            line: line
        ) else {
            return
        }
        guard scenario != "none" else {
            return
        }
        guard let fixtureToolPath = resolveFixtureToolPath(
            environment: environment,
            file: file,
            line: line
        ) else {
            return
        }
        let bundleID = environment["UITEST_BUNDLE_ID"] ?? "org.andbible.ios"
        guard let dataContainerPath = ensureInstalledAppDataContainer(
            for: app,
            bundleIdentifier: bundleID,
            file: file,
            line: line
        ) else {
            return
        }

        print(
            "Preparing fixture scenario '\(scenario)' with container '\(dataContainerPath)'."
        )

        let resetResult = runHostProcess(
            executablePath: fixtureToolPath,
            arguments: [
                "reset",
                "--data-container",
                dataContainerPath,
                "--bundle-id",
                bundleID,
            ],
            timeout: 30
        )
        XCTAssertEqual(
            resetResult.status,
            0,
            "Fixture reset failed for scenario '\(scenario)':\nstdout:\n\(resetResult.stdout)\nstderr:\n\(resetResult.stderr)",
            file: file,
            line: line
        )

        let seedResult = runHostProcess(
            executablePath: fixtureToolPath,
            arguments: [
                "seed",
                "--data-container",
                dataContainerPath,
                "--scenario",
                scenario,
                "--bundle-id",
                bundleID,
            ],
            timeout: 30
        )
        XCTAssertEqual(
            seedResult.status,
            0,
            "Fixture seed failed for scenario '\(scenario)':\nstdout:\n\(seedResult.stdout)\nstderr:\n\(seedResult.stderr)",
            file: file,
            line: line
        )
    }

    /**
     Ensures the app under test has a real simulator data container before fixture seeding runs.
     *
     * - Parameters:
     *   - app: Application under test that will later be launched for the real test body.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute simulator data-container path for the installed app.
     * - Side effects:
     *   - performs one bootstrap launch/terminate cycle when the simulator has not yet created the
     *     app data container
     * - Failure modes:
     *   - records an XCTest failure when the bootstrap launch cannot materialize the data
     *     container before fixture seeding needs it
     */
    func ensureInstalledAppDataContainer(
        for app: XCUIApplication,
        bundleIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let simulatorID = environment["UITEST_SIMULATOR_ID"] ?? environment["SIMULATOR_UDID"]
        let forceXCTestBootstrap = environment["UITEST_FORCE_XCTEST_BOOTSTRAP"] == "1"

        if let existingPath = waitForInstalledAppDataContainer(
            simulatorID: simulatorID,
            bundleIdentifier: bundleIdentifier,
            timeout: 5
        ) {
            return existingPath
        }

        print("Bootstrapping app container for bundle '\(bundleIdentifier)' before fixture seeding.")
        var usedXCTestBootstrap = simulatorID == nil || forceXCTestBootstrap
        if forceXCTestBootstrap {
            print("Forcing XCTest bootstrap launch for bundle '\(bundleIdentifier)'.")
        } else if let simulatorID {
            let launchResult = runHostProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "launch", simulatorID, bundleIdentifier],
                timeout: 20
            )
            if launchResult.status == 0 {
                if let bootstrappedPath = waitForInstalledAppDataContainer(
                    simulatorID: simulatorID,
                    bundleIdentifier: bundleIdentifier,
                    timeout: 30
                ) {
                    _ = runHostProcess(
                        executablePath: "/usr/bin/xcrun",
                        arguments: ["simctl", "terminate", simulatorID, bundleIdentifier],
                        timeout: 10
                    )
                    return bootstrappedPath
                }
                _ = runHostProcess(
                    executablePath: "/usr/bin/xcrun",
                    arguments: ["simctl", "terminate", simulatorID, bundleIdentifier],
                    timeout: 10
                )
            } else {
                print(
                    """
                    simctl bootstrap launch failed for '\(bundleIdentifier)'; falling back to XCTest launch.
                    stdout:
                    \(launchResult.stdout)
                    stderr:
                    \(launchResult.stderr)
                    """
                )
                usedXCTestBootstrap = true
            }
        }

        if usedXCTestBootstrap {
            app.launchEnvironment["UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH"] = "1"
            app.launch()
            if let bootstrappedPath = waitForInstalledAppDataContainer(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier,
                timeout: 45
            ) {
                XCTAssertTrue(
                    waitForAppToStop(app, timeout: 30) || terminateAppReliably(
                        app,
                        bundleIdentifier: bundleIdentifier,
                        simulatorID: simulatorID
                    ),
                    "Expected bootstrap app '\(bundleIdentifier)' to stop before fixture seeding.",
                    file: file,
                    line: line
                )
                app.launchEnvironment.removeValue(forKey: "UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH")
                return bootstrappedPath
            }
            XCTAssertTrue(
                waitForAppToStop(app, timeout: 30) || terminateAppReliably(
                    app,
                    bundleIdentifier: bundleIdentifier,
                    simulatorID: simulatorID
                ),
                "Expected bootstrap app '\(bundleIdentifier)' to stop before fixture seeding.",
                file: file,
                line: line
            )
            app.launchEnvironment.removeValue(forKey: "UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH")
        }

        if let bootstrappedPath = waitForInstalledAppDataContainer(
            simulatorID: simulatorID,
            bundleIdentifier: bundleIdentifier,
            timeout: 45
        ) {
            return bootstrappedPath
        }

        if let simulatorID {
            _ = resolveInstalledAppDataContainer(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier,
                timeout: 5,
                recordFailure: true,
                file: file,
                line: line
            )
            return nil
        }

        XCTFail(
            "Unable to resolve simulator data container for '\(bundleIdentifier)' after bootstrap launch.",
            file: file,
            line: line
        )
        return nil
    }

    /**
     Terminates the app under test through CoreSimulator instead of XCTest's direct terminate path.
     *
     * XCTest's `terminate()` is not reliable for apps launched solely to materialize the simulator
     * data container during fixture seeding. When that bootstrap launch cannot be terminated cleanly,
     * the actual problem is not the test flow but the process-lifecycle helper. Host-side
     * `simctl terminate` is a better source of truth because the fixture tool also runs against the
     * simulator host, not the XCUIApplication bridge.
     *
     * - Parameters:
     *   - app: Running app handle to stop.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - simulatorID: Current simulator UDID when already known.
     * - Returns: `true` when the app is already stopped or a host-side terminate succeeds.
     * - Side effects:
     *   - resolves the simulator UDID from the current test environment when needed
     *   - retries `xcrun simctl terminate` a small number of times before giving up
     * - Failure modes: This helper does not record XCTest failures directly.
     */
    func terminateAppReliably(
        _ app: XCUIApplication,
        bundleIdentifier: String? = nil,
        simulatorID: String? = nil
    ) -> Bool {
        if app.state == .notRunning {
            return true
        }

        let resolvedBundleIdentifier = bundleIdentifier ?? currentUITestBundleIdentifier()
        let resolvedSimulatorID = simulatorID ?? resolveCurrentSimulatorID()

        guard let resolvedSimulatorID else {
            return false
        }

        for _ in 0..<3 {
            let terminateResult = runHostProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "terminate", resolvedSimulatorID, resolvedBundleIdentifier],
                timeout: 15
            )
            if terminateResult.status == 0 {
                return true
            }
            if app.state == .notRunning {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        return app.state == .notRunning
    }

    /**
     Waits for one XCUIApplication handle to report a stopped state.
     *
     * - Parameters:
     *   - app: Application handle that should eventually stop.
     *   - timeout: Maximum time to wait for `.notRunning`.
     * - Returns: `true` when the app stops within the timeout, otherwise `false`.
     * - Side effects: Pumps the current run loop while waiting for state propagation.
     * - Failure modes: This helper does not record XCTest failures directly.
     */
    func waitForAppToStop(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.state == .notRunning {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return app.state == .notRunning
    }

    /**
     Resolves the bundle identifier of the app under test for host-side simulator commands.
     *
     * - Returns: Explicit UI-test bundle identifier override, or the production app default.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func currentUITestBundleIdentifier() -> String {
        ProcessInfo.processInfo.environment["UITEST_BUNDLE_ID"] ?? "org.andbible.ios"
    }

    /**
     Resolves the current simulator UDID for host-side `simctl` commands.
     *
     * Resolution order:
     * - explicit UI-test host overrides
     * - the simulator runtime environment
     * - the `Devices/<UDID>/...` segment in the current bundle path
     *
     * - Returns: Current simulator UDID when it can be derived, otherwise `nil`.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func resolveCurrentSimulatorID() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let simulatorID = environment["UITEST_SIMULATOR_ID"], !simulatorID.isEmpty {
            return simulatorID
        }
        if let simulatorID = environment["SIMULATOR_UDID"], !simulatorID.isEmpty {
            return simulatorID
        }

        let pathComponents = Bundle.main.bundleURL.pathComponents
        guard let devicesIndex = pathComponents.firstIndex(of: "Devices"),
              pathComponents.indices.contains(devicesIndex + 1) else {
            return nil
        }
        return pathComponents[devicesIndex + 1]
    }

    /**
     Waits for the installed app data container to become visible through either `simctl` or the
     simulator filesystem scan.
     *
     * - Parameters:
     *   - simulatorID: Optional simulator UDID used for `simctl get_app_container`.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - timeout: Maximum time to keep polling both host-side resolution strategies.
     * - Returns: Absolute simulator data-container path once available, otherwise `nil`.
     * - Side effects:
     *   - repeatedly queries `simctl get_app_container` when a simulator UDID is known
     *   - scans the simulator filesystem for container metadata while installation settles
     * - Failure modes: This helper does not fail directly.
     */
    func waitForInstalledAppDataContainer(
        simulatorID: String?,
        bundleIdentifier: String,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let simulatorID,
               let path = resolveInstalledAppDataContainer(
                   simulatorID: simulatorID,
                   bundleIdentifier: bundleIdentifier,
                   timeout: 2,
                   recordFailure: false
               ) {
                return path
            }
            if let path = findInstalledAppDataContainerFromFilesystem(
                bundleIdentifier: bundleIdentifier
            ) {
                return path
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return nil
    }

    /**
     Resolves the installed simulator data container by scanning mobile-container metadata on disk.
     *
     * - Parameters:
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute simulator data-container path for the installed app.
     * - Side effects:
     *   - scans the current simulator's `Containers/Data/Application` directories
     * - Failure modes:
     *   - records an XCTest failure when the simulator data root or matching container metadata
     *     cannot be resolved from the installed app bundle path
     */
    func findInstalledAppDataContainerFromFilesystem(
        bundleIdentifier: String
    ) -> String? {
        let installedAppBundleURL = Bundle.main.bundleURL
        let simulatorDataRootURL = installedAppBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dataApplicationsURL = simulatorDataRootURL
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Application", isDirectory: true)

        guard FileManager.default.fileExists(atPath: dataApplicationsURL.path) else {
            return nil
        }

        let candidateURLs = (try? FileManager.default.contentsOfDirectory(
            at: dataApplicationsURL,
            includingPropertiesForKeys: nil
        )) ?? []

        for candidateURL in candidateURLs {
            let metadataURL = candidateURL.appendingPathComponent(
                ".com.apple.mobile_container_manager.metadata.plist",
                isDirectory: false
            )
            guard let metadata = NSDictionary(contentsOf: metadataURL) as? [String: Any],
                  let identifier = metadata["MCMMetadataIdentifier"] as? String,
                  identifier == bundleIdentifier else {
                continue
            }
            return candidateURL.path
        }

        return nil
    }

    /**
     Resolves the fixture scenario for the current UI test.
     *
     * Resolution order:
     * - explicit `UITEST_FIXTURE_SCENARIO` host environment override
     * - checked-in `scripts/ui_test_fixture_manifest.json` entry for the current test method
     *
     * - Parameters:
     *   - environment: Current XCTest host environment.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Fixture scenario name, or `nil` only when the current test is intentionally
     *   absent from the manifest.
     * - Side effects:
     *   - reads the checked-in fixture manifest from the repository root when no explicit override
     *     is present
     * - Failure modes:
     *   - records an XCTest failure when the manifest cannot be read or the current test name
     *     cannot be normalized into a manifest key
     */
    func resolveFixtureScenario(
        environment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        if let scenario = environment["UITEST_FIXTURE_SCENARIO"], !scenario.isEmpty {
            return scenario
        }

        guard let testIdentifier = currentFixtureManifestTestIdentifier(file: file, line: line),
              let manifestURL = resolveRepositoryRootURL(file: file, line: line)?
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent("ui_test_fixture_manifest.json", isDirectory: false) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode([String: String].self, from: data)
            if let scenario = manifest[testIdentifier] {
                return scenario
            }
            XCTFail(
                "Fixture manifest is missing an entry for '\(testIdentifier)'.",
                file: file,
                line: line
            )
            return nil
        } catch {
            XCTFail(
                "Unable to load fixture manifest at '\(manifestURL.path)': \(error)",
                file: file,
                line: line
            )
            return nil
        }
    }

    /**
     Resolves the built host-side fixture tool path.
     *
     * Resolution order:
     * - explicit `UITEST_FIXTURE_TOOL_PATH` host environment override
     * - `.build/debug/UITestFixtureTool`
     * - architecture-specific `.build/<triple>/debug/UITestFixtureTool`
     *
     * - Parameters:
     *   - environment: Current XCTest host environment.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute executable path for the fixture tool.
     * - Side effects:
     *   - probes the repository-local SwiftPM build outputs for the fixture tool binary
     * - Failure modes:
     *   - records an XCTest failure when the fixture tool cannot be resolved
     */
    func resolveFixtureToolPath(
        environment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        if let fixtureToolPath = environment["UITEST_FIXTURE_TOOL_PATH"], !fixtureToolPath.isEmpty {
            return fixtureToolPath
        }

        guard let repoRootURL = resolveRepositoryRootURL(file: file, line: line) else {
            return nil
        }

        let candidateURLs = [
            repoRootURL.appendingPathComponent(".build/debug/UITestFixtureTool", isDirectory: false),
            repoRootURL.appendingPathComponent(".build/arm64-apple-macosx/debug/UITestFixtureTool", isDirectory: false),
            repoRootURL.appendingPathComponent(".build/x86_64-apple-macosx/debug/UITestFixtureTool", isDirectory: false),
        ]

        if let candidate = candidateURLs.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return candidate.path
        }

        XCTFail(
            "Unable to resolve UITestFixtureTool in \(candidateURLs.map(\.path).joined(separator: ", ")).",
            file: file,
            line: line
        )
        return nil
    }

    /**
     Resolves the canonical fixture-manifest key for the current XCTest method.
     *
     * - Parameters:
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Manifest key shaped like `AndBibleUITests/AndBibleUITests/testExample`.
     * - Side effects: none.
     * - Failure modes:
     *   - records an XCTest failure when the XCTest name cannot be normalized
     */
    func currentFixtureManifestTestIdentifier(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let rawName = name
        guard let methodName = rawName.split(separator: " ").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "]")),
              methodName.hasPrefix("test") else {
            XCTFail(
                "Unable to derive fixture manifest identifier from XCTest name '\(rawName)'.",
                file: file,
                line: line
            )
            return nil
        }
        return "AndBibleUITests/AndBibleUITests/\(methodName)"
    }

    /**
     Resolves the repository root from the checked-in UI-test source file path.
     *
     * - Parameters:
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute repository root URL.
     * - Side effects: none.
     * - Failure modes:
     *   - records an XCTest failure when the source path cannot be normalized
     */
    func resolveRepositoryRootURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL? {
        let fileURL = URL(fileURLWithPath: String(describing: file), isDirectory: false)
        let repoRootURL = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repoRootURL
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("ui_test_fixture_manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            XCTFail(
                "Unable to resolve repository root from '\(fileURL.path)'; missing '\(manifestURL.path)'.",
                file: file,
                line: line
            )
            return nil
        }
        return repoRootURL
    }

    /**
     Resolves the installed simulator app data container for the current test run.
     *
     * - Parameters:
     *   - simulatorID: Target simulator UDID.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - timeout: Maximum time to keep retrying `simctl get_app_container`.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute data-container path, or `nil` after recording a failure.
     * - Side effects:
     *   - polls the simulator host for the installed app container while xcodebuild finishes
     *     test-run installation
     * - Failure modes:
     *   - records an XCTest failure when no installed app container can be resolved before timeout
     */
    func resolveInstalledAppDataContainer(
        simulatorID: String,
        bundleIdentifier: String,
        timeout: TimeInterval,
        recordFailure: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = ""

        repeat {
            let result = runHostProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "get_app_container", simulatorID, bundleIdentifier, "data"],
                timeout: 10
            )
            let trimmedPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !trimmedPath.isEmpty {
                return trimmedPath
            }
            if let fallbackPath = resolveInstalledAppDataContainerFromListApps(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier
            ) {
                return fallbackPath
            }
            lastError = result.stderr.isEmpty ? result.stdout : result.stderr
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        if recordFailure {
            XCTFail(
                "Unable to resolve app data container for '\(bundleIdentifier)' on simulator '\(simulatorID)' within \(timeout) seconds.\nLast host output:\n\(lastError)",
                file: file,
                line: line
            )
        }
        return nil
    }

    /**
     Falls back to `simctl listapps` when `get_app_container` is temporarily stale.
     *
     * CoreSimulator can already know the installed app metadata, including `DataContainer`, even
     * while `get_app_container ... data` is still returning an empty result during early
     * installation windows.
     *
     * - Parameters:
     *   - simulatorID: Target simulator UDID.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     * - Returns: Absolute data-container path when `listapps` reports one, otherwise `nil`.
     * - Side effects:
     *   - runs `xcrun simctl listapps` on the host and parses the OpenStep property-list output
     * - Failure modes: This helper does not fail directly.
     */
    func resolveInstalledAppDataContainerFromListApps(
        simulatorID: String,
        bundleIdentifier: String
    ) -> String? {
        let result = runHostProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "listapps", simulatorID, bundleIdentifier],
            timeout: 10
        )
        guard result.status == 0 else {
            return nil
        }
        let escapedIdentifier = NSRegularExpression.escapedPattern(for: bundleIdentifier)
        let pattern = #"(?s)""# + escapedIdentifier + #""\s*=\s*\{.*?DataContainer\s*=\s*"([^"]+)";"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: result.stdout,
                  range: NSRange(result.stdout.startIndex..., in: result.stdout)
              ),
              let containerRange = Range(match.range(at: 1), in: result.stdout),
              let url = URL(string: String(result.stdout[containerRange])) else {
            return nil
        }

        return url.path
    }

    /**
     Runs one host-side subprocess from the macOS XCTest runner and captures its output.
     *
     * - Parameters:
     *   - executablePath: Absolute executable path to run.
     *   - arguments: CLI arguments excluding the executable itself.
     *   - timeout: Maximum time to wait before terminating the subprocess.
     * - Returns: Exit status plus captured stdout/stderr text.
     * - Side effects:
     *   - spawns one host-side child process from the XCTest runner
     *   - terminates the child process when it exceeds the timeout budget
     * - Failure modes:
     *   - returns `-1` when the subprocess cannot be launched
     *   - returns `-2` when the subprocess is terminated after exceeding the timeout budget
     */
    func runHostProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, stdout: String, stderr: String) {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            return (-1, "", "Failed to create host-process pipes.")
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])

        let command = [executablePath] + arguments
        let cArguments = command.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cArguments.count + 1)
        defer { argv.deallocate() }
        for (index, pointer) in cArguments.enumerated() {
            argv[index] = pointer
        }
        argv[cArguments.count] = nil

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executablePath, &fileActions, nil, argv, nil)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        if spawnStatus != 0 {
            let stderr = String(cString: strerror(spawnStatus))
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return (-1, "", "Failed to launch \(executablePath): \(stderr)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        var timedOut = false
        while true {
            let waitResult = waitpid(pid, &waitStatus, WNOHANG)
            if waitResult == pid {
                break
            }
            if Date() >= deadline {
                timedOut = true
                kill(pid, SIGKILL)
                _ = waitpid(pid, &waitStatus, 0)
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let stdout = readAll(from: stdoutPipe[0])
        let stderr = readAll(from: stderrPipe[0])
        close(stdoutPipe[0])
        close(stderrPipe[0])

        if timedOut {
            return (-2, stdout, stderr)
        }
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return ((waitStatus >> 8) & 0xff, stdout, stderr)
        }
        if terminatingSignal != 0 {
            return (-3, stdout, stderr.isEmpty ? "Process terminated by signal \(terminatingSignal)." : stderr)
        }
        return (-4, stdout, stderr)
    }

    /**
     Reads all currently available UTF-8 text from one file descriptor.
     *
     * - Parameter fileDescriptor: Open descriptor positioned at the start of the captured stream.
     * - Returns: Best-effort UTF-8 decoded contents.
     * - Side effects:
     *   - drains the descriptor until EOF
     * - Failure modes:
     *   - returns an empty string when the descriptor cannot be read or the bytes are not valid
     *     UTF-8
     */
    func readAll(from fileDescriptor: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

}
