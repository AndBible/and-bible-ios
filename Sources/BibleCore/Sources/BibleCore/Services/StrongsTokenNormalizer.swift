import Foundation

/**
 Normalized Strong's query variants shared by indexed and direct SWORD search paths.

 Android's JSword search indexes canonical `strong` field tokens while SWORD entry-attribute
 fallback searches need the original zero-padded lookup forms. Keeping both representations in one
 shared value prevents iOS search, dictionary, and index code from drifting in how they interpret
 the same Strong's number.
 */
public struct NormalizedStrongsQueryOptions: Equatable, Sendable {
    /// Canonical JSword/Lucene Strong's tokens to match in parsed verse lexical data.
    public let canonicalStrongTokens: [String]

    /// Ordered SWORD entry-attribute query strings to try against modules without an index.
    public let entryAttributeQueries: [String]

    /**
     Creates a normalized Strong's query option set.

     - Parameters:
       - canonicalStrongTokens: JSword-style tokens such as `H0430` or `G0123a`.
       - entryAttributeQueries: SWORD entry-attribute lookup strings such as
         `Word//Lemma./H00430`.
     - Side effects: none.
     - Failure modes: none; callers are responsible for supplying already-normalized values.
     */
    public init(canonicalStrongTokens: [String], entryAttributeQueries: [String]) {
        self.canonicalStrongTokens = canonicalStrongTokens
        self.entryAttributeQueries = entryAttributeQueries
    }
}

/**
 Shared Strong's normalization utilities matching Android's JSword indexing behavior.

 JSword extracts `strong:` lemma values from OSIS `<w>` elements and normalizes numbers through
 `StrongsNumberFilter` before adding them to the Lucene `strong` field. This type centralizes the
 same token rules for iOS FTS indexing, Search UI routing, and SWORD fallback validation.
 */
public enum StrongsTokenNormalizer {
    /// Compiled once because token extraction runs for every verse of a full-Bible index build.
    private static let taggedTextTokenRegex = try? NSRegularExpression(
        pattern: #"<\s*([GgHh][0-9]+!?[A-Za-z]*)\s*>"#
    )

    /// Compiled once because token extraction runs for every verse of a full-Bible index build.
    private static let rawOSISTokenRegex = try? NSRegularExpression(
        pattern: #"strong:([GgHh][0-9]+!?[A-Za-z]*)"#
    )

    /// Compiled once because token extraction runs for every verse of a full-Bible index build.
    private static let renderedTextTokenRegex = try? NSRegularExpression(
        pattern: #"showStrong=([0-9]+!?[A-Za-z]*)#cv"#
    )

    /// Compiled once because number parsing runs for every extracted token of every verse.
    private static let strongNumberRegex = try? NSRegularExpression(
        pattern: #"^([GgHh])([0-9]+)!?([A-Za-z]+)?"#
    )

    /**
     Normalizes a user-entered Strong's query into JSword canonical tokens and SWORD fallback
     entry-attribute queries.

     - Parameter query: User-entered query such as `H02022`, `strong:g00123`, or
       `lemma:strong:h08414`.
     - Returns: Ordered query variants, or `nil` when the input does not contain a Strong's
       prefix-plus-number form.
     - Side effects: none.
     - Failure modes:
       - returns `nil` for empty input or unsupported prefixes
       - returns an options value with no canonical tokens for syntactically Strong's-shaped but
         JSword-invalid values so callers do not fall through to plain full-text search
     */
    public static func normalizedQueryOptions(for query: String) -> NormalizedStrongsQueryOptions? {
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
     Extracts JSword/Lucene Strong's index tokens while preserving Android's raw-OSIS-first
     behavior.

     - Parameters:
       - rawEntry: Raw SWORD entry, usually OSIS with `<w lemma="strong:...">` values.
       - renderedTextProvider: Lazy rendered HTML provider used only when raw extraction finds no
         lexical tokens.
       - isNewTestamentBook: Whether unprefixed rendered Strong's links should receive a Greek
         prefix.
     - Returns: Ordered unique canonical tokens matching JSword `StrongsNumberFilter` output.
     - Side effects: Calls `renderedTextProvider` only when raw OSIS exposes no Strong's tokens.
     - Failure modes: Malformed token fragments are ignored.
     */
    public static func canonicalTokens(
        rawEntry: String,
        renderedTextProvider: () -> String,
        isNewTestamentBook: Bool
    ) -> [String] {
        let rawTokens = canonicalTokensFromRawOSIS(rawEntry)
        if !rawTokens.isEmpty {
            return orderedUnique(rawTokens)
        }

        return orderedUnique(canonicalTokensFromRenderedText(
            renderedTextProvider(),
            isNewTestamentBook: isNewTestamentBook
        ))
    }

    /**
     Extracts canonical Strong's tokens from SWORD stripped text tags such as `<H0430>`.

     The FTS index receives stripped verse text from SWORD. Some Strong's modules preserve lexical
     numbers as inline angle-bracket tags in that stripped text. Indexing those tags into a separate
     Strong's table gives iOS the same query shape Android gets from JSword's Lucene `strong` field
     without polluting normal full-text searches.

     - Parameter taggedText: SWORD stripped text before normal text cleanup removes lexical tags.
     - Returns: Ordered unique canonical Strong's tokens found in the text.
     - Side effects: none.
     - Failure modes: Malformed or out-of-range Strong's values are ignored.
     */
    public static func canonicalTokens(taggedText: String) -> [String] {
        guard let regex = taggedTextTokenRegex else { return [] }

        let matches = regex.matches(in: taggedText, range: NSRange(taggedText.startIndex..., in: taggedText))
        return orderedUnique(matches.flatMap { match -> [String] in
            guard let range = Range(match.range(at: 1), in: taggedText),
                  let parsed = parseStrongNumber(String(taggedText[range])) else {
                return []
            }
            return canonicalStrongNumberTokens(from: parsed).indexTokens.filter { !$0.isEmpty }
        })
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

    private static func canonicalTokensFromRawOSIS(_ rawEntry: String) -> [String] {
        guard let regex = rawOSISTokenRegex else { return [] }

        let matches = regex.matches(in: rawEntry, range: NSRange(rawEntry.startIndex..., in: rawEntry))
        return matches.flatMap { match -> [String] in
            guard let range = Range(match.range(at: 1), in: rawEntry),
                  let parsed = parseStrongNumber(String(rawEntry[range])) else {
                return []
            }
            return canonicalStrongNumberTokens(from: parsed).indexTokens.filter { !$0.isEmpty }
        }
    }

    private static func canonicalTokensFromRenderedText(
        _ renderedText: String,
        isNewTestamentBook: Bool
    ) -> [String] {
        guard let regex = renderedTextTokenRegex else { return [] }
        let prefix = isNewTestamentBook ? "G" : "H"

        let matches = regex.matches(in: renderedText, range: NSRange(renderedText.startIndex..., in: renderedText))
        return matches.flatMap { match -> [String] in
            guard let range = Range(match.range(at: 1), in: renderedText),
                  let parsed = parseStrongNumber(prefix + String(renderedText[range])) else {
                return []
            }
            return canonicalStrongNumberTokens(from: parsed).indexTokens.filter { !$0.isEmpty }
        }
    }

    private static func parseStrongNumber(_ text: String) -> ParsedStrongNumber? {
        guard let regex = strongNumberRegex,
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

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
