// SearchSubmissionRouter.swift — Android-compatible Search submission precedence

import BibleCore

/**
 Typed outcome of classifying one submitted Search query before asynchronous index work begins.

 Android makes Find All an explicit Strong's field query before its reference preflight. Keeping
 that precedence in one value prevents permissive SWORD reference parsing from consuming Strong's
 identifiers and dismissing Search.
 */
enum SearchSubmissionRoute: Equatable, Sendable {
    /// The non-Strong input was accepted and opened by the reader's reference resolver.
    case openedReference

    /// Search should execute, with non-`nil` options selecting the Strong's index facet.
    case indexedSearch(strongsQueryOptions: NormalizedStrongsQueryOptions?)

    /// Explicit Find All input did not contain recognizable Strong's syntax and must fail closed.
    case invalidStrongsFindAll
}

/**
 Classifies Search submissions with Android's Strong's-before-reference precedence.

 Strong-shaped input always remains in the indexed Strong's lane, including syntactically shaped
 but out-of-range values whose normalized options contain no canonical tokens. Explicit Find All
 input never falls through to Bible navigation or ordinary text search.
 */
enum SearchSubmissionRouter {
    /**
     Resolves one already-trimmed Search query into its synchronous dispatch lane.

     - Parameters:
       - query: Trimmed Search input supplied by the user or Find All link. Production filters
         empty input first; an empty explicit Find All value still fails closed when tested directly.
       - isStrongsFindAll: Whether the reader opened Search through Android's Find All action.
       - openReference: Optional reader callback that recognizes and opens Bible references.
     - Returns: Strong/text Search work, an already-opened reference, or an invalid Find All result.
     - Side effects: Invokes `openReference` at most once, and only for non-Strong input outside
       explicit Find All mode; that callback may navigate the reader.
     - Failure modes: Does not throw. Missing or malformed explicit Find All input returns
       `invalidStrongsFindAll` rather than entering an unrelated routing lane.
     */
    static func route(
        query: String,
        isStrongsFindAll: Bool,
        openReference: ((String) -> Bool)?
    ) -> SearchSubmissionRoute {
        if let strongsQueryOptions = StrongsSearchSupport.normalizedQueryOptions(for: query) {
            return .indexedSearch(strongsQueryOptions: strongsQueryOptions)
        }
        if isStrongsFindAll {
            return .invalidStrongsFindAll
        }
        if openReference?(query) == true {
            return .openedReference
        }
        return .indexedSearch(strongsQueryOptions: nil)
    }
}
