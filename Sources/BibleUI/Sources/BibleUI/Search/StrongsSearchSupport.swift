import Foundation
import SwordKit

/**
 Normalized Strong's query variants used for SWORD entry-attribute searches.

 The search flow may need more than one query because SWORD lemma values can be stored with or
 without leading zeroes.
 */
struct NormalizedStrongsQueryOptions: Equatable {
    /// Ordered set of entry-attribute query strings to try against SWORD.
    let entryAttributeQueries: [String]
}

/**
 One Strong's search hit mapped into verse coordinates and preview text.
 */
struct StrongsSearchVerseHit: Equatable {
    /// Resolved human-readable book name.
    let book: String

    /// 1-based chapter number of the hit.
    let chapter: Int

    /// 1-based verse number of the hit.
    let verse: Int

    /// Preview text returned by SWORD for this hit.
    let previewText: String

    /// Human-readable `Book Chapter:Verse` reference string.
    var reference: String { "\(book) \(chapter):\(verse)" }
}

/**
 Pure helpers for normalizing Strong's queries and mapping SWORD search results into verse hits.

 The helper is intentionally side-effect free so it can be reused from both production search flows
 and regression tests.
 */
enum StrongsSearchSupport {
    /**
     Normalizes a user-entered Strong's query into one or more SWORD entry-attribute queries.

     - Parameter query: User-entered query such as `H02022`, `strong:g00123`, or
       `lemma:strong:h08414`.
     - Returns: Ordered query variants to try, or `nil` when the input does not contain a valid
       Strong's prefix-plus-number form.

     Failure modes:
     - returns `nil` for empty input, unsupported prefixes, or non-numeric suffixes
     */
    static func normalizedQueryOptions(for query: String) -> NormalizedStrongsQueryOptions? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed.uppercased()
        if candidate.hasPrefix("LEMMA:STRONG:") {
            candidate = String(candidate.dropFirst("LEMMA:STRONG:".count))
        } else if candidate.hasPrefix("STRONG:") {
            candidate = String(candidate.dropFirst("STRONG:".count))
        } else if candidate.hasPrefix("LEMMA:") {
            candidate = String(candidate.dropFirst("LEMMA:".count))
        }

        guard let prefix = candidate.first, prefix == "H" || prefix == "G" else { return nil }
        let digitsRaw = String(candidate.dropFirst())
        guard !digitsRaw.isEmpty, digitsRaw.allSatisfy(\.isNumber) else { return nil }

        // SWORD lemma storage is inconsistent about zero padding. Some modules use
        // the fully padded key, some use a partially trimmed key (for example
        // H00430 -> H0430), and some use the fully stripped form.
        var digitVariants: [String] = [digitsRaw]
        var currentDigits = digitsRaw
        while currentDigits.hasPrefix("0"), currentDigits.count > 1 {
            currentDigits.removeFirst()
            digitVariants.append(currentDigits)
        }

        let entryAttributeQueries = orderedUnique(
            digitVariants.map { "Word//Lemma./\(prefix)\($0)" }
        )

        return NormalizedStrongsQueryOptions(
            entryAttributeQueries: entryAttributeQueries
        )
    }

    /**
     Parses a SWORD result key into human-readable verse coordinates.

     - Parameter key: Result key in either human-readable or OSIS-style form.
     - Returns: Parsed book/chapter/verse coordinates, or `nil` when the key format is unsupported.
     */
    static func parseVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        if let parsed = parseHumanVerseKey(key) {
            return parsed
        }
        if let parsed = parseOsisVerseKey(key) {
            return parsed
        }
        return nil
    }

    /**
     Searches one module for verse hits matching the normalized Strong's query options.

     - Parameters:
       - module: Module to search.
       - queryOptions: Normalized Strong's query variants to try in order.
       - scope: Optional SWORD search scope string.
     - Returns: Verse hits from the first query variant that produces matches, capped to the first
       5000 raw SWORD results.

     Failure modes:
     - returns an empty array when no query variant produces parseable verse hits
     - ignores raw SWORD results whose keys cannot be mapped into verse coordinates
     */
    static func searchVerseHits(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String? = nil
    ) -> [StrongsSearchVerseHit] {
        for query in queryOptions.entryAttributeQueries {
            let options = SearchOptions(
                query: query,
                searchType: .entryAttribute,
                caseInsensitive: true,
                scope: scope
            )
            let swordResults = module.search(options)
            let hits: [StrongsSearchVerseHit] = swordResults.results.prefix(5000).compactMap { result in
                guard let parsed = parseVerseKey(result.key) else { return nil }
                return StrongsSearchVerseHit(
                    book: parsed.book,
                    chapter: parsed.chapter,
                    verse: parsed.verse,
                    previewText: result.previewText
                )
            }
            if !hits.isEmpty {
                return hits
            }
        }
        return []
    }

    /**
     Parses a human-readable verse key such as `Matthew 5:3`.

     - Parameter key: Human-readable result key.
     - Returns: Parsed verse coordinates, or `nil` when the key does not contain the expected
       `Book Chapter:Verse` shape.
     */
    private static func parseHumanVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        guard let colonIdx = key.lastIndex(of: ":") else { return nil }
        let verseStr = String(key[key.index(after: colonIdx)...])
        let beforeColon = String(key[..<colonIdx])
        guard let spaceIdx = beforeColon.lastIndex(of: " ") else { return nil }
        let chapterStr = String(beforeColon[beforeColon.index(after: spaceIdx)...])
        let bookPart = String(beforeColon[..<spaceIdx])
        guard let chapter = Int(chapterStr), let verse = Int(verseStr) else { return nil }
        return (bookPart, chapter, verse)
    }

    /**
     Parses an OSIS-style verse key such as `Matt.5.3` or `Matt.5.3!note`.

     - Parameter key: OSIS-style result key.
     - Returns: Parsed verse coordinates, or `nil` when the key lacks book/chapter/verse parts.
     */
    private static func parseOsisVerseKey(_ key: String) -> (book: String, chapter: Int, verse: Int)? {
        let base = key.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? key
        let parts = base.split(separator: ".")
        guard parts.count >= 3 else { return nil }

        guard let chapter = Int(parts[parts.count - 2]),
              let verse = Int(parts[parts.count - 1]) else {
            return nil
        }

        let osisId = String(parts[parts.count - 3])
        let bookName = BibleReaderController.bookName(forOsisId: osisId) ?? osisId
        return (bookName, chapter, verse)
    }

    /**
     Removes duplicate query strings while preserving the original order.

     - Parameter values: Candidate query strings.
     - Returns: Deduplicated query strings in first-seen order.
     */
    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
