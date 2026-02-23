// SearchResult.swift — Search hit types for SwordKit

import Foundation

/// Type of search to perform.
public enum SearchType: Int, Sendable, CaseIterable {
    case regex = 0
    case phrase = 1
    case multiWord = -1
    case entryAttribute = -2
    case lucene = -3
}

/// User-facing search word matching mode (maps to SearchType + query decoration).
public enum SearchWordMode: String, CaseIterable, Sendable {
    case allWords = "All Words"
    case anyWord = "Any Word"
    case phrase = "Phrase"

    /// The underlying SWORD search type.
    /// - allWords: multiWord (-1) — SWORD's multiWord already requires ALL words
    /// - anyWord: regex (0) — we build a "word1|word2" regex for OR matching
    /// - phrase: phrase (1) — exact phrase match
    public var searchType: SearchType {
        switch self {
        case .allWords: return .multiWord
        case .anyWord: return .regex
        case .phrase: return .phrase
        }
    }

    /// Decorate a query string for this search mode.
    /// - All Words: pass as-is (SWORD multiWord -1 already requires all words)
    /// - Any Word: build regex "word1|word2|word3" for OR matching
    /// - Phrase: pass as-is (SearchType.phrase handles it)
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

    /// Optional scope key to limit search (e.g., "Gen-Rev" for whole Bible,
    /// "Gen-Mal" for OT, "Matt-Rev" for NT).
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

/// A single search result from a SWORD module search.
public struct SearchResult: Sendable, Identifiable {
    /// The key (verse reference) where the hit was found.
    public let key: String

    /// Module name this result came from.
    public let moduleName: String

    /// Preview text snippet around the match.
    public let previewText: String

    /// Unique identifier combining module and key.
    public var id: String { "\(moduleName):\(key)" }

    public init(key: String, moduleName: String, previewText: String = "") {
        self.key = key
        self.moduleName = moduleName
        self.previewText = previewText
    }
}

/// Aggregate search results with metadata.
public struct SearchResults: Sendable {
    /// The original search options used.
    public let options: SearchOptions

    /// Module that was searched.
    public let moduleName: String

    /// Individual results.
    public let results: [SearchResult]

    /// Total number of hits found.
    public var count: Int { results.count }

    public init(options: SearchOptions, moduleName: String, results: [SearchResult]) {
        self.options = options
        self.moduleName = moduleName
        self.results = results
    }
}

/// Results from searching multiple modules, grouped by verse.
public struct MultiSearchResults: Sendable {
    /// Per-module result sets.
    public let moduleResults: [SearchResults]

    /// All results grouped by normalized verse key (e.g. "Genesis 1:1").
    /// Each group contains results from different modules for the same verse.
    public let groupedResults: [GroupedVerseResult]

    /// Total hits across all modules.
    public var totalCount: Int { moduleResults.reduce(0) { $0 + $1.count } }

    public init(moduleResults: [SearchResults]) {
        self.moduleResults = moduleResults

        // Group by verse key across modules
        var groups: [String: [SearchResult]] = [:]
        for modResults in moduleResults {
            for result in modResults.results {
                groups[result.key, default: []].append(result)
            }
        }

        self.groupedResults = groups.map { key, results in
            GroupedVerseResult(verseKey: key, results: results)
        }.sorted { $0.verseKey < $1.verseKey }
    }
}

/// A single verse key with results from potentially multiple modules.
public struct GroupedVerseResult: Sendable, Identifiable {
    public let verseKey: String
    public let results: [SearchResult]
    public var id: String { verseKey }

    /// Module names that had hits for this verse.
    public var moduleNames: [String] {
        results.map(\.moduleName)
    }
}
