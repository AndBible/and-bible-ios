// SearchResult.swift — Key-only SWORD search configuration for SwordKit

import Foundation

/// Type of search to perform.
public enum SearchType: Int, Sendable, CaseIterable {
    case regex = 0
    case phrase = -1
    case multiWord = -2
    case entryAttribute = -3
    case lucene = -4
}

/// User-facing search word matching mode (maps to SearchType + query decoration).
public enum SearchWordMode: String, CaseIterable, Sendable {
    case allWords = "All Words"
    case anyWord = "Any Word"
    case phrase = "Phrase"

    /**
     The underlying SWORD search type.
     - allWords: multiWord (-2) — SWORD's multiWord already requires ALL words
     - anyWord: regex (0) — we build a "word1|word2" regex for OR matching
     - phrase: phrase (-1) — exact phrase match
     */
    public var searchType: SearchType {
        switch self {
        case .allWords: return .multiWord
        case .anyWord: return .regex
        case .phrase: return .phrase
        }
    }

    /**
     Decorate a query string for this search mode.
     - All Words: pass as-is (SWORD multiWord -2 already requires all words)
     - Any Word: build regex "word1|word2|word3" for OR matching
     - Phrase: pass as-is (SearchType.phrase handles it)
     */
    public func decorateQuery(_ query: String) -> String {
        switch self {
        case .allWords:
            return query
        case .anyWord:
            // Build a case-insensitive OR regex: "word1|word2|word3"
            let terms = query.split(separator: " ")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            return terms.joined(separator: "|")
        case .phrase:
            return query
        }
    }
}

/// Search scope options.
public enum SearchScopeOption: Sendable, Equatable {
    case wholeBible
    case oldTestament
    case newTestament
    case currentBook(String) // OSIS book ID, e.g. "Gen"

    public var swordScope: String? {
        switch self {
        case .wholeBible: return nil
        case .oldTestament: return "Gen-Mal"
        case .newTestament: return "Matt-Rev"
        case .currentBook(let osisId): return osisId
        }
    }

    public var label: String {
        switch self {
        case .wholeBible: return "Whole Bible"
        case .oldTestament: return "Old Testament"
        case .newTestament: return "New Testament"
        case .currentBook(let osisId): return osisId
        }
    }
}

/// Options for search execution.
public struct SearchOptions: Sendable {
    /// The search query string.
    public let query: String

    /// The type of search to perform.
    public let searchType: SearchType

    /// Whether the search is case-insensitive.
    public let caseInsensitive: Bool

    /**
     Optional scope key to limit search (e.g., "Gen-Rev" for whole Bible,
     "Gen-Mal" for OT, "Matt-Rev" for NT).
     */
    public let scope: String?

    public init(
        query: String,
        searchType: SearchType = .multiWord,
        caseInsensitive: Bool = true,
        scope: String? = nil
    ) {
        self.query = query
        self.searchType = searchType
        self.caseInsensitive = caseInsensitive
        self.scope = scope
    }
}
