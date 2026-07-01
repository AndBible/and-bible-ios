import Foundation

/// Shared runtime flags consumed by deterministic UI-test instrumentation.
enum UITestRuntimeConfiguration {
    private static let detailedAccessibilityExportsEnvironmentKey = "UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"
    private static let detailedAccessibilityExportsArgument = "-UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"
    private static let myNotesAppendTextEnvironmentKey = "UITEST_MY_NOTES_APPEND_TEXT"
    private static let myNotesAppendTextArgument = "-UITEST_MY_NOTES_APPEND_TEXT"
    private static let studyPadCreatedNoteTextEnvironmentKey = "UITEST_STUDYPAD_CREATED_NOTE_TEXT"
    private static let studyPadCreatedNoteTextArgument = "-UITEST_STUDYPAD_CREATED_NOTE_TEXT"
    private static let remoteSyncBootstrapScenarioEnvironmentKey = "UITEST_REMOTE_SYNC_BOOTSTRAP_SCENARIO"
    private static let remoteSyncBootstrapScenarioArgument = "-UITEST_REMOTE_SYNC_BOOTSTRAP_SCENARIO"
    private static let firstRunDocumentSetupHandledEnvironmentKey = "UITEST_FIRST_RUN_DOCUMENT_SETUP_HANDLED"
    private static let firstRunDocumentSetupHandledArgument = "-UITEST_FIRST_RUN_DOCUMENT_SETUP_HANDLED"
    private static let heldDownloadModulesEnvironmentKey = "UITEST_HELD_DOWNLOAD_MODULES"
    private static let heldDownloadModulesArgument = "-UITEST_HELD_DOWNLOAD_MODULES"

    /// Test-only remote sync bootstrap paths that can replace live backend transport in UI tests.
    enum RemoteSyncBootstrapScenario: String {
        case adoptExisting = "adopt-existing"
    }

    /// Upper bound for test-only row-token exports embedded into accessibility state strings.
    static let detailedAccessibilityRowTokenLimit = 50

    /// Whether the current process should expose detailed accessibility state for UI automation.
    static var enablesDetailedAccessibilityExports: Bool {
        if ProcessInfo.processInfo.environment[detailedAccessibilityExportsEnvironmentKey] == "1" {
            return true
        }
        return ProcessInfo.processInfo.arguments.contains(detailedAccessibilityExportsArgument)
    }

    /// Optional text for deterministic My Notes append actions exposed only during UI tests.
    static var myNotesAppendText: String? {
        if let value = ProcessInfo.processInfo.environment[myNotesAppendTextEnvironmentKey],
           !value.isEmpty {
            return value
        }
        guard let value = argumentValue(after: myNotesAppendTextArgument), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Optional text for deterministic StudyPad create-note actions exposed only during UI tests.
    static var studyPadCreatedNoteText: String? {
        if let value = ProcessInfo.processInfo.environment[studyPadCreatedNoteTextEnvironmentKey],
           !value.isEmpty {
            return value
        }
        guard let value = argumentValue(after: studyPadCreatedNoteTextArgument), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Optional deterministic remote-sync bootstrap path requested by UI automation.
    static var remoteSyncBootstrapScenario: RemoteSyncBootstrapScenario? {
        if let value = ProcessInfo.processInfo.environment[remoteSyncBootstrapScenarioEnvironmentKey],
           !value.isEmpty {
            return RemoteSyncBootstrapScenario(rawValue: value)
        }
        guard let value = argumentValue(after: remoteSyncBootstrapScenarioArgument), !value.isEmpty else {
            return nil
        }
        return RemoteSyncBootstrapScenario(rawValue: value)
    }

    /// Whether UI automation should treat the informational first-run setup prompt as handled.
    static var treatsFirstRunDocumentSetupAsHandled: Bool {
        isFirstRunDocumentSetupHandled(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /**
     Resolves the test-only first-run setup marker from a supplied process shape.

     - Parameters:
       - environment: Process environment to inspect.
       - arguments: Process arguments to inspect.
     - Returns: `true` only when the explicit UI-test environment variable or argument is present.
     */
    static func isFirstRunDocumentSetupHandled(
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        if environment[firstRunDocumentSetupHandledEnvironmentKey] == "1" {
            return true
        }
        return arguments.contains(firstRunDocumentSetupHandledArgument)
    }

    /**
     Search autofocus is useful in production, but it forces hosted UI tests to fight the
     software keyboard before they can reach scope and mode controls.
     */
    static var shouldAutofocusSearchField: Bool {
        !enablesDetailedAccessibilityExports
    }

    /**
     Resolves whether a UI test has requested a deterministic held Downloads install.

     The downloads row-order smoke needs the row to remain in Android's `BEING_INSTALLED` state
     long enough for accessibility polling to observe it. Production never enables this path; UI
     automation must opt in with detailed accessibility exports and an explicit comma-delimited
     module list.

     - Parameter moduleName: Module initials for the row whose install is starting.
     - Returns: `true` only for a named module in an explicitly opted-in UI-test launch.
     - Side effects: reads process environment and arguments.
     - Failure modes: malformed or empty lists are treated as no held modules.
     */
    static func shouldHoldDownloadInstall(for moduleName: String) -> Bool {
        isDownloadInstallHeld(
            for: moduleName,
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /**
     Resolves the held-download fixture marker from a supplied process shape.

     This pure variant keeps the UI-test fixture contract covered by package tests without mutating
     the process environment. The detailed-accessibility flag is required so accidental production
     environment values cannot hold a real install.

     - Parameters:
       - moduleName: Module initials for the row whose install is starting.
       - environment: Process environment to inspect.
       - arguments: Process arguments to inspect.
     - Returns: `true` only when detailed accessibility exports and a matching module name are
       both present.
     - Side effects: none.
     - Failure modes: malformed or empty lists are treated as no held modules.
     */
    static func isDownloadInstallHeld(
        for moduleName: String,
        environment: [String: String],
        arguments: [String]
    ) -> Bool {
        guard environment[detailedAccessibilityExportsEnvironmentKey] == "1"
                || arguments.contains(detailedAccessibilityExportsArgument) else {
            return false
        }
        let rawValue = environment[heldDownloadModulesEnvironmentKey]
            ?? argumentValue(after: heldDownloadModulesArgument, arguments: arguments)
            ?? ""
        let heldModules = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return heldModules.contains(moduleName)
    }

    private static func argumentValue(after argument: String) -> String? {
        argumentValue(after: argument, arguments: ProcessInfo.processInfo.arguments)
    }

    private static func argumentValue(after argument: String, arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}
