import Foundation

/**
 One searchable settings row or shortcut.

 `SettingsView` uses entries to keep search text, identifiers, summaries, and Android-parity
 keywords out of ad hoc string comparisons. Entries are value types so tests can exercise the
 matcher without rendering SwiftUI.

 - Parameters:
   - identifier: Stable accessibility or settings-row identifier.
   - title: User-visible row title.
   - summary: Optional row summary text.
   - detail: Optional state/detail text.
   - keywords: Additional non-visible search aliases such as Android category names.
 - Side effects: none.
 - Failure modes: none.
 */
struct AndBibleSettingsSearchEntry: Equatable {
    /// Stable accessibility or settings-row identifier.
    let identifier: String

    /// User-visible row title.
    let title: String

    /// Optional row summary text.
    let summary: String

    /// Optional state/detail text.
    let detail: String

    /// Additional aliases that should match search terms even when not visible.
    let keywords: [String]

    /**
     Creates one searchable settings entry.

     - Parameters:
       - identifier: Stable accessibility or settings-row identifier.
       - title: User-visible row title.
       - summary: Optional row summary text.
       - detail: Optional state/detail text.
       - keywords: Additional non-visible search aliases.
     - Side effects: none.
     - Failure modes: none.
     */
    init(
        identifier: String,
        title: String,
        summary: String = "",
        detail: String = "",
        keywords: [String] = []
    ) {
        self.identifier = identifier
        self.title = title
        self.summary = summary
        self.detail = detail
        self.keywords = keywords
    }
}

/**
 Normalizes and evaluates Settings search queries.

 Matching is intentionally independent from SwiftUI so the search contract can be tested directly
 and reused by future settings hosts. Every query term must appear somewhere in the entry text,
 matching Android's preference-search expectation that multi-word queries narrow results instead
 of widening them.
 */
enum AndBibleSettingsSearchMatcher {
    /**
     Splits and normalizes a raw query into comparable search terms.

     - Parameter query: User-entered search text.
     - Returns: Lowercase, diacritic-insensitive, whitespace-delimited terms.
     - Side effects: none.
     - Failure modes: Malformed Unicode is handled by Foundation string folding.
     */
    static func normalizedTerms(from query: String) -> [String] {
        normalized(query)
            .split { $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /**
     Returns whether one settings entry matches a raw query.

     Empty queries match all entries. Non-empty queries require every normalized term to be present
     in the combined identifier, visible text, detail text, or keyword aliases.

     - Parameters:
       - query: User-entered search text.
       - entry: Searchable settings entry.
     - Returns: `true` when the entry should remain visible for the query.
     - Side effects: none.
     - Failure modes: none.
     */
    static func matches(query: String, entry: AndBibleSettingsSearchEntry) -> Bool {
        let terms = normalizedTerms(from: query)
        guard !terms.isEmpty else {
            return true
        }

        let haystack = normalized(
            ([entry.identifier, entry.title, entry.summary, entry.detail] + entry.keywords)
                .joined(separator: " ")
        )
        return terms.allSatisfy { haystack.contains($0) }
    }

    /**
     Returns whether one concrete rendered row should remain visible for a query.

     Settings sections can match because any child row matches, but row rendering must stay tied to
     the specific entry behind that row. This helper centralizes that exact-entry lookup so
     `SettingsView` does not duplicate matcher rules or accidentally keep unrelated rows visible.

     - Parameters:
       - identifier: Stable identifier of the row that is about to be rendered.
       - query: User-entered search text.
       - entries: Search entries for the containing visible section.
     - Returns: `true` when search is empty, or when the matching entry exists and satisfies the
       query; `false` for unknown identifiers during active search.
     - Side effects: none.
     - Failure modes: none.
     */
    static func matchesIdentifier(
        _ identifier: String,
        query: String,
        entries: [AndBibleSettingsSearchEntry]
    ) -> Bool {
        guard !normalizedTerms(from: query).isEmpty else {
            return true
        }
        guard let entry = entries.first(where: { $0.identifier == identifier }) else {
            return false
        }
        return matches(query: query, entry: entry)
    }

    /**
     Applies the shared case/diacritic normalization used for both query and entry text.

     - Parameter value: Raw text to normalize.
     - Returns: Folded lowercase text suitable for containment checks.
     - Side effects: none.
     - Failure modes: Foundation folding handles text without throwing.
     */
    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
