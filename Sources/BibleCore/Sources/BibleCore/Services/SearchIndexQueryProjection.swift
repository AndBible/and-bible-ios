// SearchIndexQueryProjection.swift — Deterministic Search token, identity, and highlight projections

import Foundation
import SwordKit

/**
 Projects backend-neutral Search entries and selections into deterministic SQLite/query values.

 This namespace owns no database connection or mutable state. Token deduplication intentionally uses
 Swift value equality for normalized lexical tokens, while installed module names use exact Java
 UTF-16 identity so canonically equivalent Android books remain distinct.

 - Side effects: None.
 - Failure modes: Malformed/out-of-bounds highlight data is omitted rather than producing an unsafe
 string slice; all selection helpers are total and deterministic.
 */
enum SearchIndexQueryProjection {
    /**
     Maps structured Strong's lemma tokens to exact visible-preview ranges for one verse.

     - Parameter entry: Backend-neutral row whose lemma spans came from the same source-filtered
       projection as `previewText`.
     - Returns: Canonical base/full Strong's tokens mapped to sorted unique valid ranges.
     - Side effects: None.
     - Failure modes: Invalid/out-of-bounds spans and malformed lemma tokens are omitted; raw/tagged
       Strong's indexing remains available without a highlight rather than guessing visible text.
     */
    static func strongHighlightRangesByToken(
        _ entry: BibleSearchIndexEntry
    ) -> [String: [SearchTextHighlightRange]] {
        let previewLength = entry.previewText.utf16.count
        var result: [String: [SearchTextHighlightRange]] = [:]
        for span in entry.lemmaSpans {
            let (upper, overflow) = span.location.addingReportingOverflow(span.length)
            guard !overflow,
                  span.location >= 0,
                  span.length > 0,
                  upper <= previewLength else { continue }
            let range = SearchTextHighlightRange(location: span.location, length: span.length)
            for token in StrongsTokenNormalizer.canonicalTokens(lemmaAttribute: span.lemma) {
                if !result[token, default: []].contains(range) {
                    result[token, default: []].append(range)
                }
            }
        }
        for token in Array(result.keys) {
            result[token]?.sort {
                $0.location == $1.location
                    ? $0.length < $1.length
                    : $0.location < $1.location
            }
        }
        return result
    }

    /**
     Encodes one Strong's token's visible ranges into deterministic SQLite text.

     - Parameter ranges: Valid sorted UTF-16 ranges for one token/verse row.
     - Returns: Comma-delimited `location:length` pairs; no ranges produce an empty string.
     - Side effects: None.
     - Failure modes: None; values are emitted as base-10 integers without locale formatting.
     */
    static func encodeStrongHighlightRanges(
        _ ranges: [SearchTextHighlightRange]
    ) -> String {
        ranges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
    }

    /**
     Decodes all Strong's token ranges selected by one grouped lexical query.

     - Parameter encoded: Semicolon-separated token rows containing comma-separated range pairs.
     - Returns: Sorted unique nonnegative ranges; final preview validation occurs in
       `SearchModuleHit.snippetSegments`.
     - Side effects: None.
     - Failure modes: Malformed/overflowing pairs are ignored individually; storage corruption
       cannot produce an out-of-bounds string slice.
     */
    static func decodeStrongHighlightRanges(
        _ encoded: String
    ) -> [SearchTextHighlightRange] {
        var result: [SearchTextHighlightRange] = []
        for row in encoded.split(separator: ";", omittingEmptySubsequences: true) {
            for pair in row.split(separator: ",", omittingEmptySubsequences: true) {
                let fields = pair.split(separator: ":", omittingEmptySubsequences: false)
                guard fields.count == 2,
                      let location = Int(fields[0]),
                      let length = Int(fields[1]),
                      location >= 0,
                      length > 0 else { continue }
                let range = SearchTextHighlightRange(location: location, length: length)
                if !result.contains(range) { result.append(range) }
            }
        }
        return result.sorted {
            $0.location == $1.location
                ? $0.length < $1.length
                : $0.location < $1.location
        }
    }

    /**
     Keeps first-occurrence order for already normalized lexical tokens.

     - Parameter values: Canonical token values whose Swift equality is the intended identity.
     - Returns: First-occurrence order with duplicates removed.
     - Side effects: None.
     - Failure modes: None.
     */
    static func orderedUniqueTokens(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /**
     Keeps the first selected module for each exact Java UTF-16 initials value.

     - Parameter values: Caller-ordered installed module names.
     - Returns: First-occurrence order with only Java `String.equals` duplicates removed.
     - Side effects: None.
     - Failure modes: None; canonically equivalent Swift strings intentionally remain separate.
     */
    static func orderedUniqueModuleNames(_ values: [String]) -> [String] {
        var seen = Set<SwordJavaExactStringIdentity>()
        return values.filter {
            seen.insert(SwordJavaExactStringIdentity($0)).inserted
        }
    }

    /**
     Keeps the first exact source identity for each selected Java module name.

     - Parameter values: Caller-ordered installed source generations.
     - Returns: First source for each code-unit-identical module initials value.
     - Side effects: None.
     - Failure modes: None; different generations of the same exact initials keep the first, while
       canonically equivalent Java-distinct initials both remain selected.
     */
    static func orderedUniqueIdentities(
        _ values: [SearchIndexSourceIdentity]
    ) -> [SearchIndexSourceIdentity] {
        var seen = Set<SwordJavaExactStringIdentity>()
        return values.filter {
            seen.insert(SwordJavaExactStringIdentity($0.moduleName)).inserted
        }
    }
}
