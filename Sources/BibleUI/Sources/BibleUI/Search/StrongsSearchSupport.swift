import Foundation
import BibleCore
import SwordKit

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

    /// Annotation-free preview projected from the exact source-filtered SWORD verse.
    let previewText: String

    /// Human-readable `Book Chapter:Verse` reference string.
    var reference: String { "\(book) \(chapter):\(verse)" }
}

/**
 Shared helpers for normalizing Strong's queries and mapping SWORD search results into verse hits.

 Candidate lookup performs bounded native reads, but every inspection restores the caller's exact
 key and VerseKey ordinal before publishing a hit or miss.
 */
enum StrongsSearchSupport {
    /**
     Normalizes a user-entered Strong's query into JSword canonical tokens and SWORD fallback
     entry-attribute queries.

     - Parameter query: User-entered query such as `H02022`, `strong:g00123`, or
       `lemma:strong:h08414`.
     - Returns: Ordered query variants, or `nil` when the input does not contain a Strong's
       prefix-plus-number form.

     Failure modes:
     - returns `nil` for empty input or unsupported prefixes
     - returns an options value with no canonical tokens for syntactically Strong's-shaped but
       JSword-invalid values so callers do not fall through to plain full-text search
     */
    static func normalizedQueryOptions(for query: String) -> NormalizedStrongsQueryOptions? {
        StrongsTokenNormalizer.normalizedQueryOptions(for: query)
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
     Searches one module for verse hits matching normalized Strong's query options.

     Android's "find all occurrences" path searches JSword's Lucene `strong` field. JSword builds
     that field by extracting `strong:` lemma values from parsed OSIS `<w>` elements and normalizing
     them with `StrongsNumberFilter`; part-suffixed values are indexed as both their base token and
     their full token. iOS mirrors that semantic path by scanning the module's verse entries for the
     same lexical tokens before falling back to SWORD entry-attribute search only when no lexical
     tokens are exposed by raw/rendered entries.

     - Parameters:
       - module: Module to search.
       - queryOptions: Normalized Strong's query variants to try in order.
       - scope: Optional SWORD search scope string.
     - Returns: Verse hits from the first query variant that produces matches, capped to the first
       5000 verse results.

     - Side effects: Runs bounded SWORD searches and inspections while restoring the caller's exact
       module key and VerseKey ordinal before every candidate returns.

     Failure modes:
     - returns an empty array when no JSword-valid canonical tokens are present
     - ignores raw SWORD entries whose keys cannot be mapped into verse coordinates
     */
    static func searchVerseHits(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String? = nil
    ) -> [StrongsSearchVerseHit] {
        guard !queryOptions.canonicalStrongTokens.isEmpty else { return [] }

        let indexedCandidateResult = searchVerseHitsByEntryAttributeCandidates(
            in: module,
            queryOptions: queryOptions,
            scope: scope
        )
        if !indexedCandidateResult.hits.isEmpty {
            return indexedCandidateResult.hits
        }

        let canonicalResult = searchVerseHitsByCanonicalTokens(
            in: module,
            queryOptions: queryOptions,
            scope: scope
        )
        if canonicalResult.sawLexicalTokens || !canonicalResult.hits.isEmpty {
            return canonicalResult.hits
        }

        return searchVerseHitsByEntryAttributes(
            in: module,
            queryOptions: queryOptions,
            scope: scope
        )
    }

    /**
     Extracts JSword/Lucene Strong's index tokens from raw OSIS, with rendered SWORD text fallback.

     - Parameters:
       - rawEntry: Raw SWORD entry, usually OSIS with `<w lemma="strong:...">` values.
       - renderedText: Rendered SWORD HTML fallback for modules whose raw markup is not OSIS.
       - book: Human-readable book name used to infer Hebrew/Greek prefix for rendered SWORD
         Strong's links that carry only digits.
     - Returns: Ordered unique canonical tokens matching JSword `StrongsNumberFilter` output.
     */
    static func canonicalStrongTokens(rawEntry: String, renderedText: String, book: String) -> [String] {
        canonicalStrongTokens(
            rawEntry: rawEntry,
            renderedTextProvider: { renderedText },
            book: book
        )
    }

    /**
     Extracts JSword/Lucene Strong's index tokens while preserving Android's raw-OSIS-first
     behavior.

     Android's JSword index reads Strong's numbers from parsed OSIS. Rendering is an iOS fallback
     for modules whose raw entries do not expose lexical tokens; the provider keeps that fallback
     lazy so normal OSIS-backed modules do not render every verse during "find all occurrences".

     - Parameters:
       - rawEntry: Raw SWORD entry, usually OSIS with `<w lemma="strong:...">` values.
       - renderedTextProvider: Lazy rendered HTML provider used only when raw extraction finds no
         lexical tokens.
       - book: Human-readable book name used to infer Hebrew/Greek prefix for rendered SWORD
         Strong's links that carry only digits.
     - Returns: Ordered unique canonical tokens matching JSword `StrongsNumberFilter` output.
     */
    static func canonicalStrongTokens(
        rawEntry: String,
        renderedTextProvider: () -> String,
        book: String
    ) -> [String] {
        StrongsTokenNormalizer.canonicalTokens(
            rawEntry: rawEntry,
            renderedTextProvider: renderedTextProvider,
            isNewTestamentBook: BibleReaderController.isNewTestament(normalizedBookName(book))
        )
    }

    /**
     Uses SWORD entry-attribute search as a candidate index, then validates candidates against
     JSword-style canonical Strong's tokens.

     Android's find-all path is backed by JSword's indexed `strong` field. iOS does not yet have a
     persistent Strong's index, but SWORD entry attributes can cheaply identify candidate verses for
     many modules. This helper treats those candidates only as a narrowing mechanism: each candidate
     still has to expose the requested canonical lexical tokens before it is returned.

     - Parameters:
       - module: Module to search.
       - queryOptions: Normalized Strong's query variants to try in order.
       - scope: Optional SWORD search scope string.
     - Returns: Canonically validated candidate hits plus whether any candidate exposed lexical
       Strong's tokens.
     */
    static func searchVerseHitsByEntryAttributeCandidates(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String? = nil
    ) -> (hits: [StrongsSearchVerseHit], sawLexicalTokens: Bool) {
        let candidateKeys = entryAttributeCandidateKeys(
            in: module,
            queryOptions: queryOptions,
            scope: scope
        )
        guard !candidateKeys.isEmpty else {
            return ([], false)
        }

        return searchVerseHitsByCanonicalTokens(
            in: module,
            queryOptions: queryOptions,
            scope: scope,
            candidateKeys: candidateKeys
        )
    }

    private static func searchVerseHitsByEntryAttributes(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String?
    ) -> [StrongsSearchVerseHit] {
        for query in queryOptions.entryAttributeQueries {
            let options = SearchOptions(
                query: query,
                searchType: .entryAttribute,
                caseInsensitive: true,
                scope: scope
            )
            let candidateKeys = (try? module.searchKeys(options, limit: 5000)) ?? []
            let hits: [StrongsSearchVerseHit] = candidateKeys.compactMap { key in
                guard let inspection = try? module.inspectVerseKeyOSISSourceRestoringPrevious(key),
                      let parsed = inspection.verseKey.map({
                          (
                              book: normalizedBookName($0.bookName),
                              chapter: $0.chapter,
                              verse: $0.verse
                          )
                      }) ?? parseVerseKey(inspection.actualKey),
                      scopeAllows(book: parsed.book, scope: scope) else { return nil }
                let preview = SwordBibleSearchTextProjection.project(
                    sourceXML: inspection.osisFragment,
                    moduleInitials: module.info.name
                ).previewText
                return StrongsSearchVerseHit(
                    book: parsed.book,
                    chapter: parsed.chapter,
                    verse: parsed.verse,
                    previewText: preview
                )
            }
            if !hits.isEmpty {
                return hits
            }
        }
        return []
    }

    private static func entryAttributeCandidateKeys(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String?
    ) -> [String] {
        var candidateKeys: [String] = []
        var seenKeys = Set<String>()

        for query in queryOptions.entryAttributeQueries {
            let options = SearchOptions(
                query: query,
                searchType: .entryAttribute,
                caseInsensitive: true,
                scope: scope
            )
            let keys = (try? module.searchKeys(options, limit: 5000)) ?? []
            for key in keys where seenKeys.insert(key).inserted {
                candidateKeys.append(key)
            }
        }

        return candidateKeys
    }

    private static func searchVerseHitsByCanonicalTokens(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String?,
        candidateKeys: [String]? = nil
    ) -> (hits: [StrongsSearchVerseHit], sawLexicalTokens: Bool) {
        var hits: [StrongsSearchVerseHit] = []
        var seenReferences = Set<String>()
        var sawLexicalTokens = false

        for key in candidateKeys ?? module.allKeys() {
            guard let inspection = try? module.inspectVerseKeySearchSourceRestoringPrevious(
                key,
                includeRenderedText: false,
                includeOSISFragment: false
            ) else {
                continue
            }
            guard let parsed = parseVerseReference(
                actualKey: inspection.actualKey,
                rawEntry: inspection.rawEntry
            ) else {
                continue
            }

            let normalizedBook = normalizedBookName(parsed.book)
            guard scopeAllows(book: normalizedBook, scope: scope) else { continue }

            let tokens = canonicalStrongTokens(
                rawEntry: inspection.rawEntry,
                renderedTextProvider: {
                    (try? module.inspectVerseKeySearchSourceRestoringPrevious(
                        key,
                        includeRenderedText: true,
                        includeOSISFragment: false
                    ).renderedText) ?? ""
                },
                book: normalizedBook
            )
            if !tokens.isEmpty {
                sawLexicalTokens = true
            }

            guard queryOptions.canonicalStrongTokens.allSatisfy({ tokens.contains($0) }) else {
                continue
            }

            let referenceKey = "\(normalizedBook)|\(parsed.chapter)|\(parsed.verse)"
            guard seenReferences.insert(referenceKey).inserted else { continue }

            let previewSource = (try? module.inspectVerseKeySearchSourceRestoringPrevious(
                key,
                includeRenderedText: false,
                includeOSISFragment: true
            ).osisFragment) ?? ""
            let preview = SwordBibleSearchTextProjection.project(
                sourceXML: previewSource,
                moduleInitials: module.info.name
            ).previewText

            hits.append(StrongsSearchVerseHit(
                book: normalizedBook,
                chapter: parsed.chapter,
                verse: parsed.verse,
                previewText: preview
            ))

            if hits.count >= 5000 {
                break
            }
        }

        return (hits, sawLexicalTokens)
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

    private static func parseVerseReference(
        actualKey: String,
        rawEntry: String
    ) -> (book: String, chapter: Int, verse: Int)? {
        if let osisID = firstVerseOsisID(in: rawEntry),
           let parsed = parseOsisVerseKey(osisID) {
            return parsed
        }
        return parseVerseKey(actualKey)
    }

    private static func firstVerseOsisID(in rawEntry: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"osisID\s*=\s*["']([^"']+)["']"#) else {
            return nil
        }
        let range = NSRange(rawEntry.startIndex..., in: rawEntry)
        guard let match = regex.firstMatch(in: rawEntry, range: range),
              let osisRange = Range(match.range(at: 1), in: rawEntry) else {
            return nil
        }
        return rawEntry[osisRange].split(separator: " ").first.map(String.init)
    }

    private static func scopeAllows(book: String, scope: String?) -> Bool {
        guard let scope, !scope.isEmpty else { return true }
        let normalizedBook = normalizedBookName(book)
        switch scope {
        case "Gen-Mal":
            return !BibleReaderController.isNewTestament(normalizedBook)
        case "Matt-Rev":
            return BibleReaderController.isNewTestament(normalizedBook)
        default:
            return BibleReaderController.osisBookId(for: normalizedBook) == scope
                || normalizedBook.caseInsensitiveCompare(scope) == .orderedSame
        }
    }

    private static func normalizedBookName(_ book: String) -> String {
        let trimmed = book.trimmingCharacters(in: .whitespacesAndNewlines)
        if BibleReaderController.defaultBooks.contains(where: { $0.name == trimmed }) {
            return trimmed
        }

        let aliases = [
            "I Samuel": "1 Samuel",
            "II Samuel": "2 Samuel",
            "I Kings": "1 Kings",
            "II Kings": "2 Kings",
            "I Chronicles": "1 Chronicles",
            "II Chronicles": "2 Chronicles",
            "I Corinthians": "1 Corinthians",
            "II Corinthians": "2 Corinthians",
            "I Thessalonians": "1 Thessalonians",
            "II Thessalonians": "2 Thessalonians",
            "I Timothy": "1 Timothy",
            "II Timothy": "2 Timothy",
            "I Peter": "1 Peter",
            "II Peter": "2 Peter",
            "I John": "1 John",
            "II John": "2 John",
            "III John": "3 John",
        ]
        return aliases[trimmed] ?? trimmed
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
