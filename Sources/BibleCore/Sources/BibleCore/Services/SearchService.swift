// SearchService.swift — Full-text search

import Foundation
import Observation
import SwordKit

/// Maximum number of results per module (matches Android SearchControl.MAX_SEARCH_RESULTS).
private let maxSearchResults = 5000

/// Provides full-text search across SWORD modules.
///
/// `SearchService` is the direct-search path used when the app searches through
/// SWORD itself rather than the SQLite FTS index. It is responsible for:
/// - converting UI-facing word-mode and scope selections into `SearchOptions`
/// - preserving Strong's and lemma searches so SWORD can run entry-attribute lookups
/// - caching the most recent single-module and multi-module result sets for UI reuse
@Observable
public final class SearchService {
    private let swordManager: SwordManager

    /// Whether a search is currently in progress.
    public private(set) var isSearching = false

    /// The most recent search results.
    public private(set) var lastResults: SearchResults?

    /// The most recent multi-module search results.
    public private(set) var lastMultiResults: MultiSearchResults?

    /// Creates a search service backed by the active `SwordManager`.
    /// - Parameter swordManager: Module manager used to resolve target modules and execute SWORD searches.
    public init(swordManager: SwordManager) {
        self.swordManager = swordManager
    }

    /// Searches one module using raw SWORD search options.
    /// - Parameters:
    ///   - moduleName: Module abbreviation to search.
    ///   - query: Raw query string passed through to SWORD.
    ///   - searchType: Search algorithm to use, such as multi-word, phrase, or entry attribute.
    ///   - scope: Optional SWORD scope string limiting the search range.
    /// - Returns: Capped search results for the module, or `nil` when the module cannot be resolved.
    /// - Note: Results are truncated to `maxSearchResults` to match Android's result cap.
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

    /// Searches one module using Android-style word-mode and scope selections.
    /// - Parameters:
    ///   - moduleName: Module abbreviation to search.
    ///   - query: User-entered search text.
    ///   - wordMode: Query mode describing whether all words, any word, or an exact phrase should match.
    ///   - scopeOption: Scope selection to convert into a SWORD scope string.
    /// - Returns: Capped search results for the module, or `nil` when the module cannot be resolved.
    /// - Note: Strong's-style queries bypass word-mode decoration so SWORD can resolve them as tag searches.
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

    /// Searches multiple modules and groups the results by verse.
    /// - Parameters:
    ///   - moduleNames: Module abbreviations to search. Missing modules are skipped.
    ///   - query: User-entered search text.
    ///   - wordMode: Query mode describing whether all words, any word, or an exact phrase should match.
    ///   - scopeOption: Scope selection to convert into a SWORD scope string.
    /// - Returns: Combined multi-module results preserving each module's capped result set.
    /// - Note: This path shares one `SearchOptions` instance across all resolved modules so word mode and scope stay aligned.
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

    /// Clears cached single-module and multi-module search results.
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

    /// Returns whether a query looks like a Strong's or lemma lookup.
    /// - Parameter query: Raw user-entered query.
    /// - Returns: `true` for supported `strong:`, `lemma:`, `H1234`, or `G5620`-style searches.
    /// - Note: This intentionally accepts shorthand Hebrew/Greek keys because those must not be quoted or decorated as normal full-text queries.
    public func isStrongsQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("strong:") ||
               trimmed.hasPrefix("lemma:") ||
               (trimmed.count >= 2 && (trimmed.hasPrefix("h") || trimmed.hasPrefix("g")) &&
                trimmed.dropFirst().allSatisfy(\.isNumber))
    }

    /// Normalize a Strong's query for SWORD entry attribute search.
    /// - Parameter query: Raw user-entered query.
    /// - Returns: A normalized query plus the `SearchType` that should be used with SWORD.
    /// - Note: Shorthand values such as `H1234` or `G5620` are expanded to `lemma:strong:<value>` so entry-attribute lookup behaves like Android.
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
