// SearchQueryCompiler.swift - JSword analyzer selection and validated FTS5 query compilation

import Foundation
import SwordKit

/** Analyzer family selected from the module's ISO language code. */
public enum SearchAnalyzerKind: String, Sendable, Codable, Equatable {
    case simple
    case arabic
    case czech
    case german
    case greek
    case persian
    case hebrew
    case cjk
    case thai
    case snowball
}

/**
 Persistable analyzer profile corresponding to JSword's pinned `AnalyzerFactory.properties`.

 The language code remains part of the identifier for Snowball analyzers because each language
 uses a different stemmer. Stop-word removal is intentionally disabled, matching JSword's default.
 */
public struct SearchAnalyzerProfile: Sendable, Codable, Equatable {
    public let kind: SearchAnalyzerKind
    public let languageCode: String

    public var identifier: String {
        switch kind {
        case .snowball:
            return "jsword-0da7412d:lucene-3.6.2:snowball:\(languageCode)"
        case .cjk:
            return "jsword-0da7412d:mmseg4j-1.8.6"
        case .thai:
            return "jsword-0da7412d:lucene-3.6.2:temurin-17.0.19:thai-break"
        default:
            return "jsword-0da7412d:lucene-3.6.2:\(kind.rawValue)"
        }
    }

    public init(kind: SearchAnalyzerKind, languageCode: String) {
        self.kind = kind
        self.languageCode = languageCode
    }
}

/** Explicit query/index failures surfaced to Search UI instead of becoming empty results. */
public enum SearchIndexError: Error, Sendable, Equatable, LocalizedError {
    case databaseUnavailable(operation: String)
    case sqlite(operation: String, code: Int32, message: String)
    case indexUnavailable(moduleName: String)
    case indexContainsNoVerses(moduleName: String)
    case indexVerificationFailed(moduleName: String)
    case emptyQuery
    case invalidQuery(reason: String)
    case unsupportedQuerySyntax(token: String)
    case analyzerResourceUnavailable(name: String)

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let operation):
            return "Search index database is unavailable while \(operation)."
        case .sqlite(let operation, _, let message):
            return "Search index failed while \(operation): \(message)"
        case .indexUnavailable(let moduleName):
            return "Search index is not available for \(moduleName)."
        case .indexContainsNoVerses(let moduleName):
            return "No searchable Bible verses were found while indexing \(moduleName)."
        case .indexVerificationFailed(let moduleName):
            return "The search index for \(moduleName) could not be verified."
        case .emptyQuery:
            return "Enter text or a Bible reference to search."
        case .invalidQuery(let reason):
            return "The search query is invalid: \(reason)"
        case .unsupportedQuerySyntax(let token):
            return "This Lucene query syntax is not supported: \(token)"
        case .analyzerResourceUnavailable(let name):
            return "The pinned search analyzer resource is unavailable: \(name)."
        }
    }
}

/**
 Selects and applies the pinned JSword analyzer used for both indexed text and query operands.

 The implementation delegates to direct Lucene 3.6.2 filter ports, source-generated Lucene
 character tables, verified historical Snowball C stemmers, and the mmseg4j 1.8.6 dictionary.
 Missing pinned resources throw explicitly; there is no linguistic or per-scalar fallback.
 */
public enum SearchTextAnalyzer {
    private static let snowballLanguages: Set<String> = [
        "da", "es", "fi", "fr", "it", "nl", "no", "pt", "ru", "sv",
    ]

    /** Resolves Android's analyzer choice for an ISO language code. */
    public static func profile(for languageCode: String) -> SearchAnalyzerProfile {
        let language = normalizedLanguageCode(languageCode)
        let kind: SearchAnalyzerKind
        switch language {
        case "ar": kind = .arabic
        case "cs": kind = .czech
        case "de": kind = .german
        case "el", "grc": kind = .greek
        case "fa": kind = .persian
        case "he": kind = .hebrew
        case "ja", "zh": kind = .cjk
        case "th": kind = .thai
        case let code where snowballLanguages.contains(code): kind = .snowball
        default: kind = .simple
        }
        return SearchAnalyzerProfile(kind: kind, languageCode: language)
    }

    /**
     Returns the analyzer token stream in its lossless FTS5 storage representation.

     - Parameters:
       - text: Module text whose complete analyzer-token boundaries must be preserved.
       - profile: Analyzer selected from the module language.
     - Returns: Space-delimited opaque ASCII tokens suitable for `search_text`.
     - Side effects: Lazily loads immutable pinned analyzer resources.
     - Failure modes: Propagates analyzer resource failures without emitting partially encoded text.
     */
    public static func analyzedText(
        _ text: String,
        profile: SearchAnalyzerProfile
    ) throws -> String {
        SearchIndexTokenCodec.encodedText(try analyzedTokens(text, profile: profile))
    }

    /**
     Produces the normalized tokens used by both indexing and query compilation.

     - Parameters:
       - text: Module text or one query operand.
       - profile: Analyzer selected from the module language.
     - Returns: Ordered, non-empty analyzer tokens with stop words retained.
     - Side effects: Lazily loads immutable pinned analyzer resources.
     - Failure modes: Throws `SearchIndexError.analyzerResourceUnavailable` when a required pinned
       table or dictionary cannot be loaded. Unknown language metadata uses JSword's simple analyzer.
     */
    public static func analyzedTokens(
        _ text: String,
        profile: SearchAnalyzerProfile
    ) throws -> [String] {
        try LuceneSearchAnalyzer.tokens(text, profile: profile)
    }

    /** Lowercases a Lucene prefix/wildcard term without applying the language analyzer. */
    public static func lowercasedExpandedTerm(_ term: String) throws -> String {
        try LuceneSearchAnalyzer.lowercasedExpandedTerm(term)
    }

    private static func normalizedLanguageCode(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { String($0).lowercased() } ?? ""
    }

}

/**
 Compiles the Lucene subset exposed by Android Search into equivalent SQLite FTS5 syntax.

 Supported contracts are words, quoted phrases, suffix prefix-wildcards, parentheses, uppercase
 `AND`/`OR`/binary `NOT`, and Android's punctuation cleanup. Fuzzy, range, boost, field, leading
 wildcard, and single-character wildcard syntax is rejected explicitly instead of being silently
 reinterpreted.
 */
public enum SearchQueryCompiler {
    /**
     Compiles one user query for a module analyzer and Android Search word mode.

     The input is cleaned and decorated in the same order as Android `SearchControl` and JSword's
     `LuceneQueryDecorator`, then parsed using Lucene 3.6.2's default-OR clause rules. The returned
     expression is an FTS5 query with the same matching set for the supported syntax subset.

     - Parameters:
       - query: Raw user input before Android punctuation cleanup and word-mode decoration.
       - wordMode: Android Search mode (`ALL_WORDS`, `ANY_WORDS`, or `PHRASE`).
       - analyzer: Pinned analyzer profile for the module being searched.
     - Returns: A validated SQLite FTS5 expression.
     - Side effects: Lazily reads pinned analyzer resources through `SearchTextAnalyzer`.
     - Throws: `SearchIndexError` for empty, malformed, unsupported, or resource-blocked queries.
     - Note: Prefix terms follow Lucene multi-term handling and are lowercased without stemming.
     */
    public static func compile(
        query: String,
        wordMode: SearchWordMode,
        analyzer: SearchAnalyzerProfile
    ) throws -> String {
        try Lucene29QueryCompiler.compile(
            query: query,
            wordMode: wordMode,
            analyzer: analyzer
        )
    }

    /**
     Compiles one query's FTS expression and analyzer-bound visible emphasis together.

     - Parameters:
       - query: Raw user input before Android cleanup and word-mode decoration.
       - wordMode: Android Search matching mode.
       - analyzer: Persisted module analyzer that authorizes both index matching and preview terms.
     - Returns: Validated FTS expression plus an immutable positive-clause highlight plan.
     - Side effects: Lazily loads pinned analyzer resources.
     - Failure modes: Throws exactly the same typed errors as `compile`; no presentation plan is
       emitted for invalid or prohibited-only syntax.
     */
    static func compileWithHighlightPlan(
        query: String,
        wordMode: SearchWordMode,
        analyzer: SearchAnalyzerProfile
    ) throws -> (ftsQuery: String, highlightPlan: SearchTextHighlightPlan) {
        let compiled = try Lucene29QueryCompiler.compileWithHighlightClauses(
            query: query,
            wordMode: wordMode,
            analyzer: analyzer
        )
        return (
            compiled.ftsQuery,
            SearchTextHighlightPlan(clauses: compiled.highlightClauses)
        )
    }

    /**
     Compiles a query by selecting Android's analyzer directly from document language metadata.

     This additive entry point is the shared contract for non-Bible indexed documents such as EPUBs:
     callers supply the document's ISO language code and do not duplicate analyzer-selection logic.
     The analyzer-profile overload remains available to Bible index code that must first verify its
     persisted analyzer identifier.

     - Parameters:
       - query: Raw user input before Android punctuation cleanup and word-mode decoration.
       - wordMode: Android Search mode selected by the user.
       - languageCode: Document ISO language code, including optional region subtags.
     - Returns: A validated SQLite FTS5 expression.
     - Side effects: Lazily reads pinned analyzer resources.
     - Throws: `SearchIndexError` for empty, malformed, unsupported, or resource-blocked queries.
     */
    public static func compile(
        query: String,
        wordMode: SearchWordMode,
        languageCode: String
    ) throws -> String {
        try compile(
            query: query,
            wordMode: wordMode,
            analyzer: SearchTextAnalyzer.profile(for: languageCode)
        )
    }

    /**
     Compiles an EPUB query using Android's complete persisted mode contract.

     Android EPUB Search indexes original BVA text with SQLite `unicode61`; it does not use
     JSword's Bible analyzers or Lucene parser. Its results activity surrounds phrase input with
     quotes, joins space-delimited words with uppercase `AND`/`OR`, and passes advanced FTS5 input
     unchanged. Keeping this branch separate prevents language stemming from changing raw FTS5
     operands while retaining one public compiler API for EPUB consumers.

     - Parameters:
       - query: Raw user input.
       - epubMode: Persisted Android EPUB mode, including raw FTS5 syntax.
       - languageCode: Retained for API stability; Android EPUB query decoration is language-neutral.
     - Returns: Android's exact FTS5 decoration or the unchanged advanced expression.
     - Throws: `SearchIndexError.emptyQuery` for blank input.
     */
    public static func compile(
        query: String,
        epubMode: EpubSearchMode,
        languageCode _: String
    ) throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SearchIndexError.emptyQuery
        }
        switch epubMode {
        case .allWords:
            return query.split(separator: " ", omittingEmptySubsequences: false)
                .joined(separator: " AND ")
        case .anyWords:
            return query.split(separator: " ", omittingEmptySubsequences: false)
                .joined(separator: " OR ")
        case .phrase:
            return "\"\(query)\""
        case .fullTextQuery:
            return query
        }
    }

}
