import Foundation

/**
 Page identity needed to decide which native selection actions may include Bible references.

 Android treats normal Bible pages differently from `Multi`/generic result documents: Bible pages
 may copy or share the selected text with the active passage and module, while generic pages must
 keep their own document identity and must not fabricate a stale Bible reference. This value carries
 only the immutable page facts needed for that decision.

 - Important: The type is intentionally side-effect free and may be built repeatedly from controller
   state whenever an action executes.
 */
struct BibleReaderSelectionPageContext {
    /// Whether the current page is eligible for Bible-reference copy/share actions.
    let canUseBibleReferenceActions: Bool

    /// Display book name for Bible-reference payloads.
    let currentBook: String

    /// One-based chapter number for Bible-reference payloads.
    let currentChapter: Int

    /// Active module initials displayed with Bible-reference payloads.
    let activeModuleName: String
}

/**
 Owns native text-selection state and deterministic payload decisions for reader actions.

 The controller receives selection events from the Vue bridge and performs platform side effects
 such as pasteboard writes, share presentation, and opening URLs. This coordinator keeps the
 Android-compatible state and pure payload rules in one place so controller orchestration no longer
 needs to mutate `hasActiveSelection` and `selectedText` directly.
 */
struct BibleReaderSelectionCoordinator {
    /// Whether the web client currently reports an active text selection.
    private(set) var hasActiveSelection = false

    /// Latest selected text reported by the web client.
    private(set) var selectedText = ""

    /**
     Records the latest web-client text selection.

     - Parameter text: Selection text reported by Vue; empty text still represents an active bridge
       selection until the client emits a clear event.
     - Side effects: Mutates coordinator state only.
     - Failure modes: None.
     */
    mutating func selectionChanged(_ text: String) {
        hasActiveSelection = true
        selectedText = text
    }

    /**
     Clears native selection state after deselection or document replacement.

     - Side effects: Mutates coordinator state only.
     - Failure modes: None.
     */
    mutating func clearSelection() {
        hasActiveSelection = false
        selectedText = ""
    }

    /**
     Builds the text payload used by the native copy action.

     - Parameter context: Current page identity and Bible-reference eligibility.
     - Returns: Bible pages return selected text plus `Book Chapter (Module)`; generic pages return
       text only; empty selections return `nil`.
     - Side effects: None.
     - Failure modes: Returns `nil` when no usable selection text exists.
     */
    func copyText(context: BibleReaderSelectionPageContext) -> String? {
        guard !selectedText.isEmpty else { return nil }
        guard context.canUseBibleReferenceActions else { return selectedText }
        return "\(selectedText)\n\u{2014} \(referenceText(context: context))"
    }

    /**
     Builds the text payload used by native share UI.

     - Parameter context: Current page identity and Bible-reference eligibility.
     - Returns: Bible-reference payload for eligible pages; `nil` for generic pages or empty text.
     - Side effects: None.
     - Failure modes: Returns `nil` when sharing should not be offered for the current selection.
     */
    func shareText(context: BibleReaderSelectionPageContext) -> String? {
        guard context.canUseBibleReferenceActions else { return nil }
        return copyText(context: context)
    }

    /**
     Builds the external Google search URL for the selected text.

     - Returns: Encoded Google search URL, or `nil` when the selection is empty or cannot form a URL.
     - Side effects: None; callers open the URL on the appropriate platform.
     - Failure modes: Returns `nil` if URL encoding or URL construction fails.
     */
    func webSearchURL() -> URL? {
        guard !selectedText.isEmpty,
              let encoded = selectedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    /**
     Normalizes the selected text into a dictionary lookup key.

     - Returns: Normalized lookup query, or `nil` when there is no selected text.
     - Side effects: None.
     - Failure modes: Empty normalized results are returned as an empty string so callers can
       preserve existing user-facing "not found" behavior.
     */
    func normalizedDictionaryQuery() -> String? {
        guard !selectedText.isEmpty else { return nil }
        return BibleReaderWordLookupDocumentBuilder.normalizeQuery(selectedText)
    }

    /**
     Formats the Android-compatible Bible reference suffix for copy/share payloads.

     - Parameter context: Current Bible page identity.
     - Returns: `Book Chapter (Module)` display text.
     - Side effects: None.
     - Failure modes: None.
     */
    private func referenceText(context: BibleReaderSelectionPageContext) -> String {
        "\(context.currentBook) \(context.currentChapter) (\(context.activeModuleName))"
    }
}
