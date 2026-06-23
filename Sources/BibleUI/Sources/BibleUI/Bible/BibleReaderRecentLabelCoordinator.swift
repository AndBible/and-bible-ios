import Foundation

/**
 Coordinates the reader's recently used bookmark-label state for configuration payloads.

 `BibleReaderController` owns bridge orchestration, while this value owns the state rules for the
 label IDs that Vue receives as `recentLabels`: load the legacy setting, keep the newest label at
 the front, remove duplicates, cap the list at five entries, and provide the value to persist.

 - Side effects: The coordinator mutates only its in-memory `labelIds`; persistence is performed by
   the caller through the closure passed to `track(_:persist:)`.
 - Failure modes: Invalid or empty label identifiers are not validated here, matching the previous
   controller behavior that treated stored and bridge-provided IDs as opaque strings.
 - Note: Stored values are parsed with the legacy comma-separated format without trimming or
   filtering so existing settings continue to round-trip unchanged.
 */
struct BibleReaderRecentLabelCoordinator {
    /// Settings key used by the legacy reader configuration path.
    static let settingsKey = "recent_labels"

    /// Most-recent-first label IDs to send in the reader configuration payload.
    private(set) var labelIds: [String] = []

    /**
     Restores recently used labels from the legacy persisted setting.

     - Parameter storedValue: Optional comma-separated setting value from `SettingsStore`.
     - Side effects: Replaces `labelIds` only when `storedValue` is non-empty, preserving the prior
       controller behavior for missing and empty settings.
     - Failure modes: No parsing errors are surfaced because the legacy format is a plain string.
     */
    mutating func load(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else { return }
        labelIds = storedValue.components(separatedBy: ",")
    }

    /**
     Marks a label ID as recently used and returns the new persisted representation.

     - Parameters:
       - labelId: Opaque bookmark label ID selected by the user or bridge action.
       - persist: Non-escaping sink that writes the comma-separated label list.
     - Side effects: Mutates `labelIds` and invokes `persist` exactly once with the joined value.
     - Failure modes: The coordinator does not validate label existence; stale IDs are preserved
       until caller-provided configuration consumers ignore or replace them.
     - Note: The list is capped at five entries to match the previous controller-owned state rule.
     */
    mutating func track(_ labelId: String, persist: (String) -> Void) {
        labelIds.removeAll { $0 == labelId }
        labelIds.insert(labelId, at: 0)
        if labelIds.count > 5 {
            labelIds = Array(labelIds.prefix(5))
        }
        persist(labelIds.joined(separator: ","))
    }
}
