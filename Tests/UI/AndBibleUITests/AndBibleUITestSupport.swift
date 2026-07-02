import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Creates a configured app handle for one UI-test launch.
     *
     * - Parameters:
     *   - searchQuery: Optional launch-seeded search query for tests that intentionally start in
     *     search mode.
     *   - remoteSyncBootstrapScenario: Optional remote-sync scenario name passed to the app under
     *     test.
     *   - heldDownloadModules: Optional comma-delimited UI-test fixture list of Downloads module
     *     initials whose install tasks should remain in progress until cancelled.
     * - Returns: A configured `XCUIApplication` that has not yet been launched by the caller.
     * - Side effects:
     *   - terminates any previously launched app process through CoreSimulator when possible
     *   - assigns a fresh `UITEST_SESSION_ID` and standard locale/accessibility launch flags
     *   - prepares the fixture scenario declared for the current test method
     * - Failure modes:
     *   - fixture preparation records XCTest failures when required host-side setup cannot complete
     */
    func makeApp(
        searchQuery: String? = nil,
        remoteSyncBootstrapScenario: String? = nil,
        heldDownloadModules: [String] = []
    ) -> XCUIApplication {
        if let trackedApp {
            _ = terminateAppReliably(trackedApp)
        } else {
            _ = terminateInstalledAppProcessIfPresent()
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
        if !heldDownloadModules.isEmpty {
            let heldDownloadModuleList = heldDownloadModules.joined(separator: ",")
            app.launchEnvironment["UITEST_HELD_DOWNLOAD_MODULES"] = heldDownloadModuleList
            app.launchArguments += ["-UITEST_HELD_DOWNLOAD_MODULES", heldDownloadModuleList]
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
     *   - best-effort terminates the bootstrap app before fixture reset and seed work begins
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
            defer {
                app.launchEnvironment.removeValue(forKey: "UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH")
            }
            app.launch()
            if let bootstrappedPath = waitForInstalledAppDataContainer(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier,
                timeout: 45
            ) {
                if !waitForAppToStop(app, timeout: 5),
                   !terminateInstalledAppProcessIfPresent(
                       bundleIdentifier: bundleIdentifier,
                       simulatorID: simulatorID,
                       timeout: 10
                   ) {
                    print(
                        "Bootstrap app '\(bundleIdentifier)' did not report stopped after data container creation; continuing after best-effort cleanup."
                    )
                }
                return bootstrappedPath
            }
            if !waitForAppToStop(app, timeout: 5) {
                _ = terminateInstalledAppProcessIfPresent(
                    bundleIdentifier: bundleIdentifier,
                    simulatorID: simulatorID,
                    timeout: 10
                )
            }
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
     Terminates the installed app process directly through CoreSimulator.
     *
     * XCTest can lose a valid process handle while the simulator still has the application process
     * alive. This helper deliberately uses the simulator host as the source of truth so a fresh
     * `XCUIApplication.launch()` does not inherit a stale process from the previous test.
     *
     * - Parameters:
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - simulatorID: Current simulator UDID when already known.
     *   - timeout: Maximum time to wait for `simctl terminate`.
     * - Returns: `true` when `simctl terminate` exits successfully.
     * - Side effects:
     *   - resolves the simulator UDID from the current test environment when needed
     *   - runs `xcrun simctl terminate` against the app under test
     * - Failure modes: Returns `false` when the simulator cannot be resolved or the host-side
     *   terminate command reports that no matching app process was stopped.
     */
    @discardableResult
    func terminateInstalledAppProcessIfPresent(
        bundleIdentifier: String? = nil,
        simulatorID: String? = nil,
        timeout: TimeInterval = 10
    ) -> Bool {
        let resolvedBundleIdentifier = bundleIdentifier ?? currentUITestBundleIdentifier()
        guard let resolvedSimulatorID = simulatorID ?? resolveCurrentSimulatorID() else {
            return false
        }

        let terminateResult = runHostProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", resolvedSimulatorID, resolvedBundleIdentifier],
            timeout: timeout
        )
        return terminateResult.status == 0
    }

    /**
     Terminates the app under test through CoreSimulator instead of XCTest's direct terminate path.
     *
     * XCTest's `terminate()` is not reliable for apps launched solely to materialize the simulator
     * data container during fixture seeding. It can also report `.notRunning` after losing the
     * process ID for an app that CoreSimulator still needs to terminate before the next launch.
     * Host-side `simctl terminate` is a better source of truth because the fixture tool and the
     * launch preflight also run against the simulator host.
     *
     * - Parameters:
     *   - app: App handle to stop when XCTest still tracks it.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - simulatorID: Current simulator UDID when already known.
     * - Returns: `true` when the app is already stopped from XCTest's perspective or a host-side
     *   terminate succeeds.
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
        let resolvedBundleIdentifier = bundleIdentifier ?? currentUITestBundleIdentifier()
        let resolvedSimulatorID = simulatorID ?? resolveCurrentSimulatorID()
        let alreadyStopped = app.state == .notRunning

        guard let resolvedSimulatorID else {
            return alreadyStopped
        }

        for _ in 0..<3 {
            if terminateInstalledAppProcessIfPresent(
                bundleIdentifier: resolvedBundleIdentifier,
                simulatorID: resolvedSimulatorID,
                timeout: 15
            ) {
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
     * - checked-in `Tests/UI/Fixtures/ui_test_fixture_manifest.json` entry for the current test method
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
                .appendingPathComponent("Tests/UI/Fixtures", isDirectory: true)
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
        var candidateURL = fileURL.deletingLastPathComponent()
        while true {
            let manifestURL = candidateURL
                .appendingPathComponent("Tests/UI/Fixtures", isDirectory: true)
                .appendingPathComponent("ui_test_fixture_manifest.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return candidateURL
            }

            let parentURL = candidateURL.deletingLastPathComponent()
            if parentURL.path == candidateURL.path {
                break
            }
            candidateURL = parentURL
        }

        XCTFail(
            "Unable to resolve repository root from '\(fileURL.path)'; missing Tests/UI/Fixtures/ui_test_fixture_manifest.json in parent directories.",
            file: file,
            line: line
        )
        return nil
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
     *   - passes through the test-runner environment so Xcode tool lookup and fixture overrides
     *     use a simulator-capable Xcode, preferring explicit test overrides, the selected
     *     `xcode-select` developer directory, and only then an inherited `DEVELOPER_DIR`
     *   - drains stdout and stderr while the child runs so pipe buffers cannot stall the child
     *   - terminates the child process when it exceeds the timeout budget
     * - Failure modes:
     *   - returns `-1` when the subprocess cannot be launched
     *   - returns `-2` when the subprocess is terminated after exceeding the timeout budget
     *   - captures only output available from the direct command before it exits; descriptors kept
     *     open by descendants are deliberately not treated as command progress
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
        guard makeReadDescriptorNonBlocking(stdoutPipe[0]),
              makeReadDescriptorNonBlocking(stderrPipe[0]) else {
            close(stdoutPipe[0])
            close(stdoutPipe[1])
            close(stderrPipe[0])
            close(stderrPipe[1])
            return (-1, "", "Failed to configure host-process pipes.")
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[1])

        let command = [executablePath] + arguments
        let cArguments = command.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cArguments.count + 1)
        defer { argv.deallocate() }
        for (index, pointer) in cArguments.enumerated() {
            argv[index] = pointer
        }
        argv[cArguments.count] = nil

        let childEnvironment = hostProcessEnvironment(from: ProcessInfo.processInfo.environment)

        let environmentStrings = childEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let cEnvironment: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        defer { cEnvironment.forEach { free($0) } }
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cEnvironment.count + 1)
        defer { envp.deallocate() }
        for (index, pointer) in cEnvironment.enumerated() {
            envp[index] = pointer
        }
        envp[cEnvironment.count] = nil

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executablePath, &fileActions, nil, argv, envp)
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
        var stdoutData = Data()
        var stderrData = Data()
        while true {
            stdoutData.append(readAvailableData(from: stdoutPipe[0]))
            stderrData.append(readAvailableData(from: stderrPipe[0]))
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

        stdoutData.append(readAvailableData(from: stdoutPipe[0]))
        stderrData.append(readAvailableData(from: stderrPipe[0]))
        close(stdoutPipe[0])
        close(stderrPipe[0])
        let stdout = decodeCapturedOutput(stdoutData)
        let stderr = decodeCapturedOutput(stderrData)

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
     Builds the macOS environment used for host-side subprocesses launched by UI tests.
     *
     * - Parameters:
     *   - environment: Raw environment visible to the XCTest host process.
     *   - selectedDeveloperDir: Optional test override for the selected Xcode developer directory.
     * - Returns: A subprocess environment with simulator-capable Xcode tooling and macOS user
     *   directory values restored for `xcrun`, `simctl`, and fixture tools.
     * - Side effects: None.
     * - Failure modes: Falls back to inherited values when explicit host overrides are absent.
     */
    func hostProcessEnvironment(
        from environment: [String: String],
        selectedDeveloperDir: String? = nil
    ) -> [String: String] {
        var childEnvironment = environment
        let resolvedDeveloperDir = selectedDeveloperDir
            ?? selectedDeveloperDirForHostProcess(environment: childEnvironment)
        if let resolvedDeveloperDir {
            childEnvironment["DEVELOPER_DIR"] = resolvedDeveloperDir
            childEnvironment["UITEST_DEVELOPER_DIR"] = resolvedDeveloperDir
        }
        applyHostUserDirectoryOverrides(to: &childEnvironment)
        if childEnvironment["PATH"]?.isEmpty != false {
            childEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return childEnvironment
    }

    /**
     Restores macOS user-directory values for host tools spawned from an XCTest environment.
     *
     * - Parameter environment: Environment dictionary to update in place.
     * - Side effects: Rewrites `HOME`, `TMPDIR`, user identity, and CoreFoundation user-home values
     *   from `UITEST_HOST_*` variables supplied by the CI wrapper.
     * - Failure modes: Leaves existing values unchanged when no host override is available.
     */
    func applyHostUserDirectoryOverrides(to environment: inout [String: String]) {
        let variablePairs = [
            ("UITEST_HOST_HOME", "HOME"),
            ("UITEST_HOST_TMPDIR", "TMPDIR"),
            ("UITEST_HOST_USER", "USER"),
            ("UITEST_HOST_LOGNAME", "LOGNAME"),
            ("UITEST_HOST_CF_USER_TEXT_ENCODING", "__CF_USER_TEXT_ENCODING"),
        ]
        for (sourceKey, targetKey) in variablePairs {
            if let value = environment[sourceKey], !value.isEmpty {
                environment[targetKey] = value
            }
        }
        if let home = environment["UITEST_HOST_HOME"], !home.isEmpty {
            environment["CFFIXED_USER_HOME"] = home
        }
    }

    /**
     Selects the Xcode developer directory that host-side UI-test subprocesses should inherit.
     *
     * - Parameters:
     *   - environment: Environment visible to the XCTest host process. Explicit
     *     `UITEST_DEVELOPER_DIR` and CI `MD_APPLE_SDK_ROOT` values are treated as operator
     *     overrides; an inherited `DEVELOPER_DIR` is treated as a fallback because CI can preserve
     *     a stale value inside the XCTest host even after `xcodebuild` uses the selected Xcode.
     * - Returns: A developer directory that contains simulator tooling, or `nil` when none of the
     *   configured candidates can safely run CoreSimulator commands.
     * - Side effects: Reads host toolchain selection with `xcode-select` when explicit environment
     *   overrides do not already provide a simulator-capable developer directory.
     * - Failure modes: Ignores empty paths, command-line-tools directories without `simctl`, and
     *   nonexistent Xcode bundles so a bad candidate cannot poison every fixture subprocess.
     */
    func selectedDeveloperDirForHostProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        selectedDeveloperDirForHostProcess(
            environment: environment,
            xcodeSelectDeveloperDir: selectedDeveloperDirFromXcodeSelect,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /**
     Selects a simulator-capable developer directory from injectable host-tool candidates.
     *
     * - Parameters:
     *   - environment: Environment dictionary to inspect for explicit and inherited Xcode paths.
     *   - xcodeSelectDeveloperDir: Reader for the host's selected Xcode developer directory.
     *   - fileExists: Filesystem predicate used to validate candidate directories and `simctl`.
     * - Returns: The first simulator-capable candidate in Android-independent CI precedence order,
     *   or `nil` when no candidate is usable.
     * - Side effects: none except the injected `xcodeSelectDeveloperDir` and `fileExists` calls.
     * - Failure modes: Invalid candidates are skipped without throwing so host fixture work can
     *   fall back to a later valid Xcode path.
     */
    func selectedDeveloperDirForHostProcess(
        environment: [String: String],
        xcodeSelectDeveloperDir: () -> String?,
        fileExists: (String) -> Bool
    ) -> String? {
        let sdkDeveloperDir = environment["MD_APPLE_SDK_ROOT"].flatMap { sdkRoot -> String? in
            let trimmedRoot = sdkRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedRoot.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: trimmedRoot)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Developer", isDirectory: true)
                .path
        }

        for candidate in [environment["UITEST_DEVELOPER_DIR"], sdkDeveloperDir] {
            guard let candidate else { continue }
            let developerDir = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard developerDirSupportsSimulatorTools(developerDir, fileExists: fileExists) else {
                continue
            }
            return developerDir
        }

        if let xcodeSelectCandidate = xcodeSelectDeveloperDir() {
            let developerDir = xcodeSelectCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if developerDirSupportsSimulatorTools(developerDir, fileExists: fileExists) {
                return developerDir
            }
        }

        for candidate in [environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer"] {
            guard let candidate else { continue }
            let developerDir = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard developerDirSupportsSimulatorTools(developerDir, fileExists: fileExists) else {
                continue
            }
            return developerDir
        }
        return nil
    }

    /**
     Reads the host machine's selected Xcode developer directory from `xcode-select` state.
     *
     * - Returns: The trimmed selected developer directory, or `nil` when the selection symlink is
     *   missing or empty.
     * - Side effects:
     *   - reads `/var/db/xcode_select_link`, the macOS symlink updated by `xcode-select -s`
     *   - avoids invoking `/usr/bin/xcode-select -p` because that command honors a stale
     *     `DEVELOPER_DIR` inherited by the XCTest host
     * - Failure modes: Returns `nil` when the symlink cannot be read or reports no usable path;
     *   callers remain responsible for validating that the returned directory contains simulator
     *   tools.
     */
    func selectedDeveloperDirFromXcodeSelect() -> String? {
        guard let selectedPath = try? FileManager.default.destinationOfSymbolicLink(
            atPath: "/var/db/xcode_select_link"
        ) else {
            return nil
        }
        let trimmedPath = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return nil
        }
        if trimmedPath.hasSuffix(".app") {
            return URL(fileURLWithPath: trimmedPath)
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Developer", isDirectory: true)
                .path
        }
        return trimmedPath
    }

    /**
     Validates that a developer directory can run simulator host tools.
     *
     * - Parameters:
     *   - developerDir: Candidate `Contents/Developer` path.
     *   - fileExists: Filesystem predicate, injectable for deterministic precedence tests.
     * - Returns: `true` only when the directory exists and contains `usr/bin/simctl`.
     * - Side effects: none beyond filesystem existence checks performed by `fileExists`.
     * - Failure modes: Returns `false` for empty paths, command-line-tools directories, and stale
     *   Xcode paths that no longer provide simulator tooling.
     */
    func developerDirSupportsSimulatorTools(
        _ developerDir: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let trimmedDeveloperDir = developerDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDeveloperDir.isEmpty, fileExists(trimmedDeveloperDir) else {
            return false
        }
        let simctlPath = URL(fileURLWithPath: trimmedDeveloperDir)
            .appendingPathComponent("usr", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("simctl", isDirectory: false)
            .path
        return fileExists(simctlPath)
    }

    /**
     Configures a pipe read descriptor so draining output never waits for inherited writers.
     *
     * - Parameter fileDescriptor: Open pipe descriptor that the current process owns.
     * - Returns: `true` when `O_NONBLOCK` is set successfully.
     * - Side effects: Mutates file descriptor flags for the current process only.
     * - Failure modes: Returns `false` when `fcntl` cannot read or update the descriptor flags.
     */
    func makeReadDescriptorNonBlocking(_ fileDescriptor: Int32) -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags != -1 else {
            return false
        }
        return fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1
    }

    /**
     Drains bytes that are immediately available from one nonblocking pipe.
     *
     * - Parameter fileDescriptor: Nonblocking pipe descriptor to read from.
     * - Returns: Captured bytes available at the time of the call.
     * - Side effects:
     *   - advances the descriptor read position for bytes that were already buffered
     * - Failure modes:
     *   - returns bytes read before an interrupt, EOF, or nonblocking no-data condition
     *   - treats other read errors as an empty capture so process status remains the source of truth
     */
    func readAvailableData(from fileDescriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
                continue
            }
            if bytesRead == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            break
        }

        return data
    }

    /**
     Converts captured subprocess bytes to UTF-8 text for XCTest failure messages.
     *
     * - Parameter data: Raw bytes captured from stdout or stderr.
     * - Returns: UTF-8 decoded text, or an empty string when the stream is not valid UTF-8.
     * - Side effects: none.
     * - Failure modes: Invalid UTF-8 is intentionally discarded because callers use process status
     *   and stderr text as diagnostic context, not as a binary transport.
     */
    func decodeCapturedOutput(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

}
