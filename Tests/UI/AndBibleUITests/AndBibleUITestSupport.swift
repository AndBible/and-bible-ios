import Foundation
import XCTest

/** Operations owned by the macOS fixture service for this one test invocation. */
private enum UITestFixtureHostOperation: String, Encodable {
    case prepare
    case releaseDownload
    case awaitDownloadConnected
    case awaitDownloadCancelled
    case awaitDownloadCompleted
}

/** One atomic request; the host owns tool paths, process control, and container resolution. */
private struct UITestFixtureHostRequest: Encodable {
    let requestID: String
    let operation: UITestFixtureHostOperation
    let scenario: String?
    let simulatorID: String
    let bundleIdentifier: String
}

/** Completion published only after the host has finished all requested fixture work. */
private struct UITestFixtureHostResponse: Decodable {
    let requestID: String
    let succeeded: Bool
    let encodedPreferences: String?
    let dataContainerPath: String?
    let downloadFixtureEndpoint: String?
    let downloadFixtureAttempt: Int?
    let downloadFixtureState: String?
    let downloadFixtureBytesSent: Int?
    let downloadFixturePackageByteCount: Int?
    let error: String?
}

/** Transport states exposed by the bounded Downloads package fixture. */
enum UITestDownloadFixtureState: String {
    case connected
    case cancelled
    case completed
}

extension AndBibleUITests {
    /**
     Creates an app handle after its fixture has been prepared by the macOS owner.

     - Inputs: Optional fixture, sync/download test data and passive accessibility export policy.
     - Returns: An app handle ready for its first explicit launch by the test.
     - Side effects: The host stops the preceding app and prepares the selected data fixture.
       Assigns a fresh preference-session identity and the test's locale/diagnostic configuration.
     - Failure modes: Records a failure before launch when host preparation cannot complete.
     */
    func makeApp(
        fixtureScenario: String? = nil,
        remoteSyncBootstrapScenario: String? = nil,
        enablesDetailedAccessibilityExports: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        trackedApp = app
        app.launchEnvironment["UITEST_SESSION_ID"] = UUID().uuidString
        if enablesDetailedAccessibilityExports {
            app.launchEnvironment["UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"] = "1"
            app.launchArguments += ["-UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"]
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let remoteSyncBootstrapScenario {
            app.launchEnvironment["UITEST_REMOTE_SYNC_BOOTSTRAP_SCENARIO"] = remoteSyncBootstrapScenario
            app.launchArguments += ["-UITEST_REMOTE_SYNC_BOOTSTRAP_SCENARIO", remoteSyncBootstrapScenario]
        }
        prepareFixtureIfRequested(for: app, fixtureScenario: fixtureScenario)
        return app
    }

    /**
     Waits for host-owned process isolation, container resolution and fixture materialization.

     - Inputs: Explicit fixture override or the current method's fixture manifest entry.
     - Output: The completed fixture's preference seed is attached to the next app launch.
     - Side effects: Sends one prepare request and passively awaits its atomic response. The host
       stops the app before resetting data; the simulator runner never launches host subprocesses.
     - Failure modes: Fails without launching the app on missing service, timeout, host error,
       mismatched response identity or malformed preference data. The `none` fixture does no work.
     */
    func prepareFixtureIfRequested(
        for app: XCUIApplication,
        fixtureScenario: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scenario = fixtureScenario.flatMap { $0.isEmpty ? nil : $0 }
            ?? resolveFixtureScenario(
                environment: ProcessInfo.processInfo.environment, file: file, line: line
            )
        guard let scenario, scenario != "none" else { return }
        guard let response = requestFixtureHostOperation(
            .prepare, scenario: scenario, timeout: 90, file: file, line: line
        ) else { return }
        guard let preferences = response.encodedPreferences, !preferences.isEmpty,
              Data(base64Encoded: preferences) != nil,
              let container = response.dataContainerPath, container.hasPrefix("/") else {
            XCTFail("Fixture host returned incomplete preparation data.", file: file, line: line)
            return
        }
        print("Prepared fixture '\(scenario)' in '\(container)' through the macOS host.")
        app.launchEnvironment["UITEST_PREFERENCE_SEED_BASE64"] = preferences
        if let endpoint = response.downloadFixtureEndpoint {
            guard let components = URLComponents(string: endpoint),
                  components.scheme == "http",
                  components.host == "127.0.0.1",
                  components.port != nil,
                  !components.path.isEmpty,
                  components.path != "/" else {
                XCTFail("Fixture host returned an invalid Downloads endpoint.", file: file, line: line)
                return
            }
            app.launchEnvironment["UITEST_DOWNLOAD_FIXTURE_ENDPOINT"] = endpoint
        }
    }

    /** Releases the currently connected deterministic package transfer exactly once. */
    func releaseDownloadFixture(file: StaticString = #filePath, line: UInt = #line) {
        _ = requestFixtureHostOperation(
            .releaseDownload, timeout: 20, file: file, line: line
        )
    }

    /** Passively waits for one host-observed package transport state. */
    @discardableResult
    func awaitDownloadFixtureState(
        _ expectedState: UITestDownloadFixtureState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int? {
        let operation: UITestFixtureHostOperation
        switch expectedState {
        case .connected:
            operation = .awaitDownloadConnected
        case .cancelled:
            operation = .awaitDownloadCancelled
        case .completed:
            operation = .awaitDownloadCompleted
        }
        guard let response = requestFixtureHostOperation(
            operation, timeout: 20, file: file, line: line
        ) else {
            return nil
        }
        guard response.downloadFixtureState == expectedState.rawValue,
              let attempt = response.downloadFixtureAttempt,
              let bytesSent = response.downloadFixtureBytesSent,
              let packageByteCount = response.downloadFixturePackageByteCount,
              packageByteCount > 0,
              bytesSent >= 0,
              bytesSent <= packageByteCount else {
            XCTFail(
                "Fixture host returned incomplete Downloads state for '\(expectedState.rawValue)'.",
                file: file,
                line: line
            )
            return nil
        }
        switch expectedState {
        case .connected, .cancelled:
            guard bytesSent > 0, bytesSent < packageByteCount else {
                XCTFail(
                    "Fixture host did not retain a partial package transfer for "
                        + "'\(expectedState.rawValue)'.",
                    file: file,
                    line: line
                )
                return nil
            }
        case .completed:
            guard bytesSent == packageByteCount else {
                XCTFail(
                    "Fixture host reported completion before the full package was sent.",
                    file: file,
                    line: line
                )
                return nil
            }
        }
        return attempt
    }

    /**
     Exchanges one request with the macOS wrapper without crossing simulator process namespaces.

     - Inputs: Bounded fixture operation, optional scenario and response deadline.
     - Returns: The matching successful response, or nil after recording an XCTest failure.
     - Side effects: Atomically writes a request in the wrapper's private invocation directory and
       polls only its matching response. No UI input, process launch or fixture file mutation occurs here.
     - Failure modes: Fails on absent wrapper setup, inconsistent simulator identity, malformed
       response, host rejection or deadline. A timeout never permits the app to launch over live seeding.
     */
    private func requestFixtureHostOperation(
        _ operation: UITestFixtureHostOperation,
        scenario: String? = nil,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UITestFixtureHostResponse? {
        let environment = ProcessInfo.processInfo.environment
        guard let directoryPath = environment["UITEST_FIXTURE_SERVICE_DIRECTORY"],
              directoryPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: directoryPath) else {
            XCTFail(
                "UI fixture tests require scripts/run_xcodebuild_with_test_selection.py; "
                    + "the macOS fixture service is unavailable.", file: file, line: line
            )
            return nil
        }
        let runtimeSimulator = environment["SIMULATOR_UDID"]
        let configuredSimulator = environment["UITEST_SIMULATOR_ID"]
        if let runtimeSimulator, let configuredSimulator,
           runtimeSimulator.caseInsensitiveCompare(configuredSimulator) != .orderedSame {
            XCTFail("Fixture destination differs from the running simulator.", file: file, line: line)
            return nil
        }
        guard let simulatorID = runtimeSimulator ?? configuredSimulator,
              UUID(uuidString: simulatorID) != nil else {
            XCTFail("Cannot identify the fixture simulator.", file: file, line: line)
            return nil
        }
        let requestID = UUID().uuidString
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let requestURL = directory.appendingPathComponent("\(requestID).request.json")
        let responseURL = directory.appendingPathComponent("\(requestID).response.json")
        let request = UITestFixtureHostRequest(
            requestID: requestID, operation: operation, scenario: scenario,
            simulatorID: simulatorID,
            bundleIdentifier: environment["UITEST_BUNDLE_ID"] ?? "org.andbible.ios"
        )
        do {
            try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if FileManager.default.fileExists(atPath: responseURL.path) {
                    let response = try JSONDecoder().decode(
                        UITestFixtureHostResponse.self, from: Data(contentsOf: responseURL)
                    )
                    guard response.requestID == requestID else {
                        XCTFail("Fixture host response identity mismatch.", file: file, line: line)
                        return nil
                    }
                    guard response.succeeded else {
                        XCTFail("Fixture host failed: \(response.error ?? "unspecified error")",
                                file: file, line: line)
                        return nil
                    }
                    return response
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            } while Date() < deadline
            XCTFail("Fixture host did not finish '\(operation.rawValue)' within \(timeout) seconds "
                    + "(request \(requestID)); the app was not launched.", file: file, line: line)
        } catch {
            XCTFail("Fixture host exchange failed: \(error)", file: file, line: line)
        }
        return nil
    }

    /**
     Resolves the fixture scenario for the current UI test.
     *
     * Resolution order:
     * - explicit `UITEST_FIXTURE_SCENARIO` host environment override
     * - explicit `UITEST_FIXTURE_MANIFEST_PATH` host environment
     * - checked-in `Tests/UI/Fixtures/ui_test_fixture_manifest.json` for local source builds
     *
     * - Parameters:
     *   - environment: Current XCTest host environment.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Fixture scenario name, or `nil` only when the current test is intentionally
     *   absent from the manifest.
     * - Side effects:
     *   - reads the explicit artifact-bundled manifest in product-reuse runs
     *   - reads the checked-in fixture manifest for local source builds
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
              let manifestURL = resolveFixtureManifestURL(
                environment: environment,
                file: file,
                line: line
              ) else {
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
     Resolves the fixture manifest while preserving the product-reuse checkout boundary.

     An explicit artifact path is authoritative. If it is missing, resolution fails instead of
     falling back to the source path compiled into `#filePath`, which may identify the producer's
     checkout rather than the consumer's checkout. Local builds without the environment value retain
     repository discovery for developer convenience.

     - Parameters:
       - environment: Current XCTest host environment.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Returns: Readable fixture manifest URL, or `nil` after recording a failure.
     - Side effects: probes the selected manifest path.
     - Failure modes: records an XCTest failure when an explicit path is missing or local repository
       discovery cannot find the checked-in manifest.
     */
    func resolveFixtureManifestURL(
        environment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL? {
        if let explicitPath = environment["UITEST_FIXTURE_MANIFEST_PATH"], !explicitPath.isEmpty {
            let explicitURL = URL(fileURLWithPath: explicitPath, isDirectory: false)
            guard FileManager.default.isReadableFile(atPath: explicitURL.path) else {
                XCTFail(
                    "Explicit UI fixture manifest is not readable at '\(explicitURL.path)'.",
                    file: file,
                    line: line
                )
                return nil
            }
            return explicitURL
        }

        guard let repoRootURL = resolveRepositoryRootURL(file: file, line: line) else {
            return nil
        }
        return repoRootURL
            .appendingPathComponent("Tests/UI/Fixtures", isDirectory: true)
            .appendingPathComponent("ui_test_fixture_manifest.json", isDirectory: false)
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
}
