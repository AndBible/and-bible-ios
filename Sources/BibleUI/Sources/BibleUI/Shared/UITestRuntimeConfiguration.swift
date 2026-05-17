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

    /**
     Search autofocus is useful in production, but it forces hosted UI tests to fight the
     software keyboard before they can reach scope and mode controls.
     */
    static var shouldAutofocusSearchField: Bool {
        !enablesDetailedAccessibilityExports
    }

    private static func argumentValue(after argument: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}
