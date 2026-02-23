// SearchService.swift — Full-text search

import Foundation
import Observation
import SwordKit

/// Maximum number of results per module (matches Android SearchControl.MAX_SEARCH_RESULTS).
private let maxSearchResults = 5000

/// Provides full-text search across SWORD modules.
@Observable
public final class SearchService {
    private let swordManager: SwordManager

    /// Whether a search is currently in progress.
    public private(set) var isSearching = false

    /// The most recent search results.
    public private(set) var lastResults: SearchResults?

    /// The most recent multi-module search results.
    public private(set) var lastMultiResults: MultiSearchResults?

    public init(swordManager: SwordManager) {
        self.swordManager = swordManager
    }

    /// Search a single module.
    public func search(
        moduleName: String,
        query: String,
        searchType: SearchType = .multiWord,
        scope: String? = nil
    ) -> SearchResults? {
        guard let module = swordManager.module(named: moduleName) else { return nil }

        isSearching = true
        defer { isSearching = false }

        let options = SearchOptions(
            query: query,
            searchType: searchType,
            scope: scope
        )

        let results = module.search(options)
        let capped = capResults(results)
        lastResults = capped
        return capped
    }

    /// Search a single module using word mode + scope option.
    public func search(
        moduleName: String,
        query: String,
        wordMode: SearchWordMode,
        scopeOption: SearchScopeOption
    ) -> SearchResults? {
        let decorated = preprocessQuery(query, wordMode: wordMode)
        return search(
            moduleName: moduleName,
            query: decorated,
            searchType: wordMode.searchType,
            scope: scopeOption.swordScope
        )
    }

    /// Search multiple modules simultaneously and group results by verse.
    public func searchMultiple(
        moduleNames: [String],
        query: String,
        wordMode: SearchWordMode,
        scopeOption: SearchScopeOption
    ) -> MultiSearchResults {
        isSearching = true
        defer { isSearching = false }

        let decorated = preprocessQuery(query, wordMode: wordMode)
        let options = SearchOptions(
            query: decorated,
            searchType: wordMode.searchType,
            scope: scopeOption.swordScope
        )

        var allModuleResults: [SearchResults] = []
        for name in moduleNames {
            guard let module = swordManager.module(named: name) else { continue }
            let results = module.search(options)
            allModuleResults.append(capResults(results))
        }

        let multi = MultiSearchResults(moduleResults: allModuleResults)
        lastMultiResults = multi
        return multi
    }

    /// Clear the last search results.
    public func clearResults() {
        lastResults = nil
        lastMultiResults = nil
    }

    // MARK: - Query Preprocessing

    /// Preprocess a query: apply word mode decoration and detect Strong's numbers.
    private func preprocessQuery(_ query: String, wordMode: SearchWordMode) -> String {
        // Detect Strong's number pattern (e.g. "strong:H1234", "strong:G5620")
        if isStrongsQuery(query) {
            return query
        }
        return wordMode.decorateQuery(query)
    }

    /// Check if a query is a Strong's number search.
    public func isStrongsQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("strong:") ||
               trimmed.hasPrefix("lemma:") ||
               (trimmed.count >= 2 && (trimmed.hasPrefix("h") || trimmed.hasPrefix("g")) &&
                trimmed.dropFirst().allSatisfy(\.isNumber))
    }

    /// Normalize a Strong's query for SWORD entry attribute search.
    /// Converts shorthand like "H1234" or "G5620" to "lemma:strong:H1234".
    public func normalizeStrongsQuery(_ query: String) -> (query: String, searchType: SearchType) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("strong:") || trimmed.lowercased().hasPrefix("lemma:") {
            return (trimmed, .entryAttribute)
        }
        // Shorthand: "H1234" → "lemma:strong:H1234"
        let upper = trimmed.uppercased()
        if upper.count >= 2 && (upper.hasPrefix("H") || upper.hasPrefix("G")) &&
           upper.dropFirst().allSatisfy(\.isNumber) {
            return ("lemma:strong:\(upper)", .entryAttribute)
        }
        return (trimmed, .multiWord)
    }

    // MARK: - Private

    private func capResults(_ results: SearchResults) -> SearchResults {
        if results.count <= maxSearchResults { return results }
        return SearchResults(
            options: results.options,
            moduleName: results.moduleName,
            results: Array(results.results.prefix(maxSearchResults))
        )
    }
}
