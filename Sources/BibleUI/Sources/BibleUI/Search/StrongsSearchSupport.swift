import Foundation
import SwordKit

/**
 Normalized Strong's query variants used for SWORD entry-attribute searches.

 The search flow may need more than one query because SWORD lemma values can be stored with or
 without leading zeroes.
 */
struct NormalizedStrongsQueryOptions: Equatable, Sendable {
    /// Canonical JSword/Lucene Strong's tokens to match in parsed verse lexical data.
    let canonicalStrongTokens: [String]

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

        guard let parsedQuery = parseStrongNumber(candidate) else { return nil }
        let prefix = parsedQuery.language
        let digitsRaw = parsedQuery.digits

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
            canonicalStrongTokens: canonicalStrongNumberTokens(from: parsedQuery).queryTokens,
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
     Extracts JSword/Lucene Strong's index tokens from raw OSIS and rendered SWORD entry text.

     - Parameters:
       - rawEntry: Raw SWORD entry, usually OSIS with `<w lemma="strong:...">` values.
       - renderedText: Rendered SWORD HTML fallback for modules whose raw markup is not OSIS.
       - book: Human-readable book name used to infer Hebrew/Greek prefix for rendered SWORD
         Strong's links that carry only digits.
     - Returns: Ordered unique canonical tokens matching JSword `StrongsNumberFilter` output.
     */
    static func canonicalStrongTokens(rawEntry: String, renderedText: String, book: String) -> [String] {
        var tokens: [String] = []
        tokens.append(contentsOf: canonicalStrongTokensFromRawOSIS(rawEntry))
        tokens.append(contentsOf: canonicalStrongTokensFromRenderedText(renderedText, book: book))
        return orderedUnique(tokens)
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

    private static func searchVerseHitsByCanonicalTokens(
        in module: SwordModule,
        queryOptions: NormalizedStrongsQueryOptions,
        scope: String?
    ) -> (hits: [StrongsSearchVerseHit], sawLexicalTokens: Bool) {
        var hits: [StrongsSearchVerseHit] = []
        var seenReferences = Set<String>()
        var sawLexicalTokens = false

        for key in module.allKeys() {
            let inspection = module.setKeyAndInspect(
                key,
                includeRenderedText: false,
                includeStrippedText: false
            )
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
                renderedText: inspection.renderedText,
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

            let preview = module.setKeyAndInspect(
                key,
                includeRenderedText: false,
                includeStrippedText: true
            ).strippedText

            hits.append(StrongsSearchVerseHit(
                book: normalizedBook,
                chapter: parsed.chapter,
                verse: parsed.verse,
                previewText: String(preview.prefix(200))
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

    private struct ParsedStrongNumber: Equatable {
        let language: Character
        let digits: String
        let part: String?

        var numericValue: Int {
            Int(digits) ?? 0
        }
    }

    private struct CanonicalStrongNumberTokens: Equatable {
        let baseToken: String
        let fullToken: String?

        var indexTokens: [String] {
            guard !baseToken.isEmpty else { return [] }
            if let fullToken {
                return [baseToken, fullToken]
            }
            return [baseToken]
        }

        var queryTokens: [String] {
            guard !baseToken.isEmpty else { return [] }
            if let fullToken {
                return [fullToken]
            }
            return [baseToken]
        }
    }

    private static func parseStrongNumber(_ text: String) -> ParsedStrongNumber? {
        let pattern = #"^([GgHh])([0-9]+)!?([A-Za-z]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let languageRange = Range(match.range(at: 1), in: text),
              let digitsRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let language = Character(String(text[languageRange]).uppercased())
        let digits = String(text[digitsRange])
        let part: String?
        if match.range(at: 3).location != NSNotFound,
           let partRange = Range(match.range(at: 3), in: text) {
            part = String(text[partRange])
        } else {
            part = nil
        }

        return ParsedStrongNumber(language: language, digits: digits, part: part)
    }

    private static func canonicalStrongNumberTokens(
        from parsed: ParsedStrongNumber
    ) -> CanonicalStrongNumberTokens {
        guard isValidStrongsNumber(parsed) else {
            return CanonicalStrongNumberTokens(baseToken: "", fullToken: nil)
        }

        let base = "\(parsed.language)\(String(format: "%04d", parsed.numericValue))"
        let part = parsed.part?.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = part?.isEmpty == false ? base + (part ?? "") : nil
        return CanonicalStrongNumberTokens(baseToken: base, fullToken: full)
    }

    private static func isValidStrongsNumber(_ parsed: ParsedStrongNumber) -> Bool {
        let number = parsed.numericValue
        switch parsed.language {
        case "H":
            return (1...8674).contains(number)
        case "G":
            return (number >= 1 && number < 1418)
                || (number > 1418 && number < 2717)
                || (number > 2717 && number < 3203)
                || (number > 3302 && number < 5624)
                || (number > 5999 && number < 10000)
        default:
            return false
        }
    }

    private static func canonicalStrongTokensFromRawOSIS(_ rawEntry: String) -> [String] {
        let pattern = #"strong:([GgHh][0-9]+!?[A-Za-z]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let matches = regex.matches(in: rawEntry, range: NSRange(rawEntry.startIndex..., in: rawEntry))
        return matches.flatMap { match -> [String] in
            guard let range = Range(match.range(at: 1), in: rawEntry),
                  let parsed = parseStrongNumber(String(rawEntry[range])) else {
                return []
            }
            return canonicalStrongNumberTokens(from: parsed).indexTokens.filter { !$0.isEmpty }
        }
    }

    private static func canonicalStrongTokensFromRenderedText(_ renderedText: String, book: String) -> [String] {
        let pattern = #"showStrong=([0-9]+!?[A-Za-z]*)#cv"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let prefix = BibleReaderController.isNewTestament(normalizedBookName(book)) ? "G" : "H"

        let matches = regex.matches(in: renderedText, range: NSRange(renderedText.startIndex..., in: renderedText))
        return matches.flatMap { match -> [String] in
            guard let range = Range(match.range(at: 1), in: renderedText),
                  let parsed = parseStrongNumber(prefix + String(renderedText[range])) else {
                return []
            }
            return canonicalStrongNumberTokens(from: parsed).indexTokens.filter { !$0.isEmpty }
        }
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
