import Foundation

/// Shared runtime flags consumed by deterministic UI-test instrumentation.
enum UITestRuntimeConfiguration {
    private static let detailedAccessibilityExportsEnvironmentKey = "UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"
    private static let detailedAccessibilityExportsArgument = "-UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"

    /// Upper bound for test-only row-token exports embedded into accessibility state strings.
    static let detailedAccessibilityRowTokenLimit = 50

    /// Whether the current process should expose detailed accessibility state for UI automation.
    static var enablesDetailedAccessibilityExports: Bool {
        if ProcessInfo.processInfo.environment[detailedAccessibilityExportsEnvironmentKey] == "1" {
            return true
        }
        return ProcessInfo.processInfo.arguments.contains(detailedAccessibilityExportsArgument)
    }

    /// Search autofocus is useful in production, but it forces hosted UI tests to fight the
    /// software keyboard before they can reach scope and mode controls.
    static var shouldAutofocusSearchField: Bool {
        !enablesDetailedAccessibilityExports
    }
}
