import Foundation
import BibleCore

/// Shared runtime flags consumed by deterministic UI-test instrumentation.
public enum UITestRuntimeConfiguration {
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

    /**
     Creates the deterministic remote transport override requested by UI automation.

     The returned service shares the process-session adapter between settings-driven and lifecycle-
     driven synchronization while retaining the caller's real `RemoteSyncSettingsStore`, device
     identity, model contexts, and lifecycle admission. Normal launches return `nil` so callers use
     their production synchronization factory.

     - Parameter remoteSettingsStore: Real local settings owner for the active persistence runtime.
     - Returns: A deterministic synchronization service only for the adopt-existing scenario.
     - Side effects: May persist the stable source-device identifier on first construction.
     - Failure modes: This factory cannot fail.
     */
    @MainActor
    public static func makeRemoteSynchronizationServiceOverride(
        using remoteSettingsStore: RemoteSyncSettingsStore
    ) -> RemoteSyncSynchronizationService? {
        guard remoteSyncBootstrapScenario == .adoptExisting else { return nil }
        return RemoteSyncSynchronizationService(
            adapter: UITestRemoteSyncAdapter.appSession,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.andbible.ios",
            deviceIdentifier: remoteSettingsStore.deviceIdentifier(),
            nowProvider: { 1_735_689_900_000 }
        )
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
