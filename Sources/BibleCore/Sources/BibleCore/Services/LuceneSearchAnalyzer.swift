// LuceneSearchAnalyzer.swift - pinned JSword/Lucene 3.6.2 analyzer implementation

import CSearchStemmers
import Foundation

/**
 Implements the analyzer chains selected by JSword's pinned `AnalyzerFactory.properties`.

 The token filters below are direct ports of the Lucene 3.6.2 sources used by Android's pinned
 JSword revision. Lowercase, letter-classification, and ASCII-folding tables are generated from
 that Lucene runtime and bundled with BibleCore, avoiding host-language linguistic heuristics.
 */
enum LuceneSearchAnalyzer {
    /** One analyzed token paired with the exact source UTF-16 range that produced it. */
    struct TokenSpan: Sendable, Equatable {
        /// Analyzer-normalized term used by Search indexing and query matching.
        let term: String

        /// Half-open UTF-16 range in the original, unnormalized source string.
        let range: Range<Int>
    }

    /** Returns the exact analyzer token stream for one profile. */
    static func tokens(
        _ text: String,
        profile: SearchAnalyzerProfile
    ) throws -> [String] {
        try tokenSpans(text, profile: profile).map(\.term)
    }

    /**
     Returns the exact analyzer token stream with source ranges preserved for Search presentation.

     - Parameters:
       - text: Original visible verse text before analyzer normalization.
       - profile: Pinned JSword analyzer selected from module language metadata.
     - Returns: Analyzer-normalized terms in index order with half-open original UTF-16 ranges.
     - Side effects: Lazily loads the same immutable analyzer resources as `tokens`.
     - Failure modes: Propagates missing or malformed pinned-resource errors without returning a
       partial stream. Token terms are byte-for-byte identical to `tokens` for the same input.
     */
    static func tokenSpans(
        _ text: String,
        profile: SearchAnalyzerProfile
    ) throws -> [TokenSpan] {
        switch profile.kind {
        case .simple:
            return try lowerCaseLetterTokenSpans(text).map {
                TokenSpan(term: Lucene29CharacterTables.asciiFold($0.term), range: $0.range)
            }
        case .czech:
            return try lowerCaseLetterTokenSpans(text)
        case .german:
            return try lowerCaseLetterTokenSpans(text).map {
                TokenSpan(term: GermanStemmer.stem($0.term), range: $0.range)
            }
        case .arabic:
            return try arabicLetterTokenSpans(text).map {
                TokenSpan(
                    term: ArabicAnalyzer.stem(ArabicAnalyzer.normalize($0.term)),
                    range: $0.range
                )
            }
        case .persian:
            return try arabicLetterTokenSpans(text).map {
                TokenSpan(
                    term: PersianNormalizer.normalize(ArabicAnalyzer.normalize($0.term)),
                    range: $0.range
                )
            }
        case .greek:
            return try Lucene29ClassicTokenizer.tokenSpans(text).map {
                TokenSpan(term: try GreekLowerCaseFilter.normalize($0.term), range: $0.range)
            }
        case .hebrew:
            return try Lucene29ClassicTokenizer.tokenSpans(text).map {
                TokenSpan(term: HebrewPointingFilter.normalize($0.term), range: $0.range)
            }
        case .thai:
            return try Lucene29ThaiTokenizer.tokenSpans(text)
        case .cjk:
            return try Lucene29MMSegTokenizer.tokenSpans(text)
        case .snowball:
            let source = try lowerCaseLetterTokenSpans(text)
            return try source.map {
                TokenSpan(
                    term: try SnowballStemmer.stem($0.term, languageCode: profile.languageCode),
                    range: $0.range
                )
            }
        }
    }

    /** Lowercases an expanded Lucene prefix term without running its analyzer. */
    static func lowercasedExpandedTerm(_ term: String) throws -> String {
        try Lucene29CharacterTables.lowercase(term)
    }

    /**
     Tokenizes one visible source string with Lucene 3.6 `LowerCaseTokenizer` compatibility.

     - Parameter text: Original UTF-16 text whose letter runs and offsets must be preserved.
     - Returns: Lowercased Lucene terms paired with their exact half-open source ranges; runs longer
       than Lucene's 255-unit limit are emitted as consecutive tokens.
     - Side effects: Lazily reads the immutable pinned Lucene character tables.
     - Throws: Propagates a missing or malformed character-table resource without returning a
       partial token stream.
     */
    private static func lowerCaseLetterTokenSpans(_ text: String) throws -> [TokenSpan] {
        let tables = try Lucene29CharacterTables.loaded()
        var result: [TokenSpan] = []
        var current: [UInt16] = []
        var tokenStart = 0
        var cursor = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(TokenSpan(
                term: String(decoding: current, as: UTF16.self),
                range: tokenStart..<cursor
            ))
            current.removeAll(keepingCapacity: true)
        }

        for unit in text.utf16 {
            if tables.isLetter(unit) {
                if current.isEmpty { tokenStart = cursor }
                current.append(tables.lowercase(unit))
                if current.count == 255 {
                    cursor += 1
                    flush()
                    continue
                }
            } else {
                flush()
            }
            cursor += 1
        }
        flush()
        return result
    }

    /**
     Tokenizes one Arabic/Persian source string with Lucene 3.6 legacy UTF-16 boundaries.

     - Parameter text: Original UTF-16 text whose letter/nonspacing-mark runs must be preserved.
     - Returns: Lowercased terms paired with exact half-open source ranges; Lucene's 255-unit token
       limit is applied before later Arabic or Persian normalization.
     - Side effects: Lazily reads the immutable pinned Lucene character tables.
     - Throws: Propagates a missing or malformed character-table resource without returning a
       partial token stream.
     */
    private static func arabicLetterTokenSpans(_ text: String) throws -> [TokenSpan] {
        let tables = try Lucene29CharacterTables.loaded()
        var result: [TokenSpan] = []
        var current: [UInt16] = []
        var tokenStart = 0
        var cursor = 0

        func flush() {
            guard !current.isEmpty else { return }
            result.append(TokenSpan(
                term: String(decoding: current, as: UTF16.self),
                range: tokenStart..<cursor
            ))
            current.removeAll(keepingCapacity: true)
        }

        for unit in text.utf16 {
            if tables.isLetter(unit) || tables.isNonspacingMark(unit) {
                if current.isEmpty { tokenStart = cursor }
                current.append(tables.lowercase(unit))
                if current.count == 255 {
                    cursor += 1
                    flush()
                    continue
                }
            } else {
                flush()
            }
            cursor += 1
        }
        flush()
        return result
    }

}

/** Source-generated Lucene/JVM UTF-16 character tables and ASCII folding map. */
final class Lucene29CharacterTables: @unchecked Sendable {
    private struct CharacterCategoryRange {
        let range: ClosedRange<UInt16>
        let mask: UInt8
    }

    private struct Resources {
        let letterRanges: [ClosedRange<UInt16>]
        let lowercaseMap: [UInt16: UInt16]
        let asciiFoldingMap: [UInt16: String]
        let characterCategories: [CharacterCategoryRange]
    }

    private static let resourceResult: Result<Resources, Error> = Result {
        let letterLines = try resourceLines(named: "lucene-letter-ranges")
        let lowerLines = try resourceLines(named: "lucene-lowercase")
        let foldingLines = try resourceLines(named: "lucene-ascii-folding")
        let categoryLines = try resourceLines(named: "lucene-character-categories")

        let letterRanges = try letterLines.map { line -> ClosedRange<UInt16> in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let lower = UInt16(fields[0], radix: 16),
                  let upper = UInt16(fields[1], radix: 16) else {
                throw SearchIndexError.analyzerResourceUnavailable(name: "lucene-letter-ranges.tsv")
            }
            return lower...upper
        }

        let lowercaseMap = try Dictionary(uniqueKeysWithValues: lowerLines.map { line -> (UInt16, UInt16) in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let source = UInt16(fields[0], radix: 16),
                  let target = UInt16(fields[1], radix: 16) else {
                throw SearchIndexError.analyzerResourceUnavailable(name: "lucene-lowercase.tsv")
            }
            return (source, target)
        })

        let asciiFoldingMap = try Dictionary(uniqueKeysWithValues: foldingLines.map { line -> (UInt16, String) in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let source = UInt16(fields[0], radix: 16) else {
                throw SearchIndexError.analyzerResourceUnavailable(name: "lucene-ascii-folding.tsv")
            }
            return (source, String(fields[1]))
        })

        let characterCategories = try categoryLines.map { line -> CharacterCategoryRange in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let lower = UInt16(fields[0], radix: 16),
                  let upper = UInt16(fields[1], radix: 16),
                  let mask = UInt8(fields[2], radix: 16) else {
                throw SearchIndexError.analyzerResourceUnavailable(
                    name: "lucene-character-categories.tsv"
                )
            }
            return CharacterCategoryRange(range: lower...upper, mask: mask)
        }

        return Resources(
            letterRanges: letterRanges,
            lowercaseMap: lowercaseMap,
            asciiFoldingMap: asciiFoldingMap,
            characterCategories: characterCategories
        )
    }

    private let resources: Resources

    private init(resources: Resources) {
        self.resources = resources
    }

    /** Loads and validates all source-generated tables exactly once. */
    static func loaded() throws -> Lucene29CharacterTables {
        Lucene29CharacterTables(resources: try resourceResult.get())
    }

    /** Java `Character.isLetter(char)` from the oracle runtime. */
    func isLetter(_ unit: UInt16) -> Bool {
        var lower = 0
        var upper = resources.letterRanges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let range = resources.letterRanges[middle]
            if unit < range.lowerBound {
                upper = middle
            } else if unit > range.upperBound {
                lower = middle + 1
            } else {
                return true
            }
        }
        return false
    }

    /** Java `Character.toLowerCase(char)` from the oracle runtime. */
    func lowercase(_ unit: UInt16) -> UInt16 {
        resources.lowercaseMap[unit] ?? unit
    }

    /** Applies Java lowercase to every UTF-16 code unit without locale-sensitive expansion. */
    static func lowercase(_ text: String) throws -> String {
        let tables = try loaded()
        return String(decoding: text.utf16.map(tables.lowercase), as: UTF16.self)
    }

    /** Lucene 3.6.2 `ASCIIFoldingFilter`, including one-to-many replacements. */
    static func asciiFold(_ token: String) -> String {
        guard case .success(let resources) = resourceResult else { return token }
        var result = ""
        result.reserveCapacity(token.utf16.count)
        for unit in token.utf16 {
            if let replacement = resources.asciiFoldingMap[unit] {
                result.append(replacement)
            } else {
                result.append(String(decoding: [unit], as: UTF16.self))
            }
        }
        return result
    }

    func isNonspacingMark(_ unit: UInt16) -> Bool {
        hasCategory(unit, mask: 1 << 0)
    }

    func isDecimalDigit(_ unit: UInt16) -> Bool {
        hasCategory(unit, mask: 1 << 1)
    }

    func isLetterNumber(_ unit: UInt16) -> Bool {
        hasCategory(unit, mask: 1 << 2)
    }

    func isOtherNumber(_ unit: UInt16) -> Bool {
        hasCategory(unit, mask: 1 << 3)
    }

    func isOtherLetter(_ unit: UInt16) -> Bool {
        hasCategory(unit, mask: 1 << 4)
    }

    func isCasedOrModifierLetter(_ unit: UInt16) -> Bool {
        hasCategory(unit, mask: 1 << 5)
    }

    /** Looks up one pinned Java `Character.getType(char)` category bit. */
    private func hasCategory(_ unit: UInt16, mask: UInt8) -> Bool {
        var lower = 0
        var upper = resources.characterCategories.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let item = resources.characterCategories[middle]
            if unit < item.range.lowerBound {
                upper = middle
            } else if unit > item.range.upperBound {
                lower = middle + 1
            } else {
                return item.mask & mask != 0
            }
        }
        return false
    }

    private static func resourceLines(named name: String) throws -> [Substring] {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: "tsv",
            subdirectory: "search"
        ), let value = try? String(contentsOf: url, encoding: .utf8) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "\(name).tsv")
        }
        return value.split(whereSeparator: \.isNewline)
    }
}

/** Direct port of Lucene 3.6.2 `GermanStemmer`. */
private enum GermanStemmer {
    static func stem(_ term: String) -> String {
        var buffer = Array(term)
        guard buffer.allSatisfy({ $0.isLetter }) else { return term }
        var substitutionCount = substitute(&buffer)
        strip(&buffer, substitutionCount: substitutionCount)
        optimize(&buffer, substitutionCount: &substitutionCount)
        resubstitute(&buffer)
        removeParticleDenotion(&buffer)
        return String(buffer)
    }

    private static func strip(_ buffer: inout [Character], substitutionCount: Int) {
        var shouldContinue = true
        while shouldContinue && buffer.count > 3 {
            if buffer.count + substitutionCount > 5 && buffer.suffix(2) == ["n", "d"] {
                buffer.removeLast(2)
            } else if buffer.count + substitutionCount > 4 && buffer.suffix(2) == ["e", "m"] {
                buffer.removeLast(2)
            } else if buffer.count + substitutionCount > 4 && buffer.suffix(2) == ["e", "r"] {
                buffer.removeLast(2)
            } else if let last = buffer.last, ["e", "s", "n", "t"].contains(last) {
                buffer.removeLast()
            } else {
                shouldContinue = false
            }
        }
    }

    private static func optimize(_ buffer: inout [Character], substitutionCount: inout Int) {
        if buffer.count > 5 && buffer.suffix(5) == ["e", "r", "i", "n", "*"] {
            buffer.removeLast()
            strip(&buffer, substitutionCount: substitutionCount)
        }
        if buffer.last == "z" {
            buffer[buffer.count - 1] = "x"
        }
    }

    private static func substitute(_ buffer: inout [Character]) -> Int {
        var substitutionCount = 0
        var index = 0
        while index < buffer.count {
            if index > 0 && buffer[index] == buffer[index - 1] {
                buffer[index] = "*"
            } else if buffer[index] == "ä" {
                buffer[index] = "a"
            } else if buffer[index] == "ö" {
                buffer[index] = "o"
            } else if buffer[index] == "ü" {
                buffer[index] = "u"
            } else if buffer[index] == "ß" {
                buffer[index] = "s"
                buffer.insert("s", at: index + 1)
                substitutionCount += 1
            }

            if index < buffer.count - 1 {
                if index < buffer.count - 2,
                   buffer[index] == "s", buffer[index + 1] == "c", buffer[index + 2] == "h" {
                    buffer[index] = "$"
                    buffer.removeSubrange((index + 1)...(index + 2))
                    substitutionCount = 2 // Preserves Lucene's historical `substCount =+ 2` behavior.
                } else if buffer[index] == "c", buffer[index + 1] == "h" {
                    buffer[index] = "§"
                    buffer.remove(at: index + 1)
                    substitutionCount += 1
                } else if buffer[index] == "e", buffer[index + 1] == "i" {
                    buffer[index] = "%"
                    buffer.remove(at: index + 1)
                    substitutionCount += 1
                } else if buffer[index] == "i", buffer[index + 1] == "e" {
                    buffer[index] = "&"
                    buffer.remove(at: index + 1)
                    substitutionCount += 1
                } else if buffer[index] == "i", buffer[index + 1] == "g" {
                    buffer[index] = "#"
                    buffer.remove(at: index + 1)
                    substitutionCount += 1
                } else if buffer[index] == "s", buffer[index + 1] == "t" {
                    buffer[index] = "!"
                    buffer.remove(at: index + 1)
                    substitutionCount += 1
                }
            }
            index += 1
        }
        return substitutionCount
    }

    private static func resubstitute(_ buffer: inout [Character]) {
        var index = 0
        while index < buffer.count {
            switch buffer[index] {
            case "*": buffer[index] = buffer[index - 1]
            case "$":
                buffer[index] = "s"
                buffer.insert(contentsOf: ["c", "h"], at: index + 1)
            case "§":
                buffer[index] = "c"
                buffer.insert("h", at: index + 1)
            case "%":
                buffer[index] = "e"
                buffer.insert("i", at: index + 1)
            case "&":
                buffer[index] = "i"
                buffer.insert("e", at: index + 1)
            case "#":
                buffer[index] = "i"
                buffer.insert("g", at: index + 1)
            case "!":
                buffer[index] = "s"
                buffer.insert("t", at: index + 1)
            default:
                break
            }
            index += 1
        }
    }

    private static func removeParticleDenotion(_ buffer: inout [Character]) {
        guard buffer.count > 4 else { return }
        for index in 0..<(buffer.count - 3) where Array(buffer[index..<(index + 4)]) == ["g", "e", "g", "e"] {
            buffer.removeSubrange(index..<(index + 2))
            return
        }
    }
}

/** Direct ports of Lucene 3.6.2 `ArabicNormalizer` and `ArabicStemmer`. */
private enum ArabicAnalyzer {
    private static let prefixes: [[UInt16]] = strings(["ال", "وال", "بال", "كال", "فال", "لل", "و"])
    private static let suffixes: [[UInt16]] = strings(["ها", "ان", "ات", "ون", "ين", "يه", "ية", "ه", "ة", "ي"])

    static func normalize(_ token: String) -> String {
        var units = Array(token.utf16)
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0x0622, 0x0623, 0x0625: units[index] = 0x0627
            case 0x0649: units[index] = 0x064A
            case 0x0629: units[index] = 0x0647
            case 0x0640, 0x064B...0x0652:
                units.remove(at: index)
                continue
            default: break
            }
            index += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    static func stem(_ token: String) -> String {
        var units = Array(token.utf16)
        for prefix in prefixes where canRemovePrefix(prefix, from: units) {
            units.removeFirst(prefix.count)
            break
        }
        for suffix in suffixes where canRemoveSuffix(suffix, from: units) {
            units.removeLast(suffix.count)
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func canRemovePrefix(_ prefix: [UInt16], from value: [UInt16]) -> Bool {
        if prefix.count == 1 && value.count < 4 { return false }
        if value.count < prefix.count + 2 { return false }
        return value.starts(with: prefix)
    }

    private static func canRemoveSuffix(_ suffix: [UInt16], from value: [UInt16]) -> Bool {
        value.count >= suffix.count + 2 && value.suffix(suffix.count).elementsEqual(suffix)
    }

    private static func strings(_ values: [String]) -> [[UInt16]] {
        values.map { Array($0.utf16) }
    }
}

/** Direct port of Lucene 3.6.2 `PersianNormalizer`. */
private enum PersianNormalizer {
    static func normalize(_ token: String) -> String {
        var units = Array(token.utf16)
        var index = 0
        while index < units.count {
            switch units[index] {
            case 0x06CC, 0x06D2: units[index] = 0x064A
            case 0x06A9: units[index] = 0x0643
            case 0x06C0, 0x06C1: units[index] = 0x0647
            case 0x0654:
                units.remove(at: index)
                continue
            default: break
            }
            index += 1
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/** Direct port of Lucene 3.6.2 `GreekLowerCaseFilter` in Lucene 2.9 mode. */
private enum GreekLowerCaseFilter {
    static func normalize(_ token: String) throws -> String {
        let tables = try Lucene29CharacterTables.loaded()
        let mapped = token.utf16.map { unit -> UInt16 in
            switch unit {
            case 0x03C2: return 0x03C3
            case 0x0386, 0x03AC: return 0x03B1
            case 0x0388, 0x03AD: return 0x03B5
            case 0x0389, 0x03AE: return 0x03B7
            case 0x038A, 0x03AA, 0x03AF, 0x03CA, 0x0390: return 0x03B9
            case 0x038E, 0x03AB, 0x03CD, 0x03CB, 0x03B0: return 0x03C5
            case 0x038C, 0x03CC: return 0x03BF
            case 0x038F, 0x03CE: return 0x03C9
            case 0x03A2: return 0x03C2
            default:
                return tables.lowercase(unit)
            }
        }
        return String(decoding: mapped, as: UTF16.self)
    }
}

/** Direct port of JSword's `HebrewPointingFilter.unPoint(word, false)`. */
private enum HebrewPointingFilter {
    private static let dageshGap = UInt16(0xFB44 - 0x05E3)

    static func normalize(_ token: String) -> String {
        var units = Array(token.utf16)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit < 0x0591 || unit > 0xFB4F {
                index += 1
            } else if unit < 0x05B0 {
                units.remove(at: index)
            } else if unit >= 0xFB1D && unit < 0xFB4F {
                units[index] = unit - dageshGap
                index += 1
            } else {
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/** Calls the exact historical Snowball C implementations verified against Lucene fixtures. */
private enum SnowballStemmer {
    static func stem(_ token: String, languageCode: String) throws -> String {
        guard let language = cLanguage(for: languageCode) else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "Snowball \(languageCode)")
        }
        let input = Array(token.utf8)
        var output = [UInt8](repeating: 0, count: max(64, input.count * 4 + 16))
        let count = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                ab_search_stem_utf8(
                    language,
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    outputBuffer.baseAddress,
                    outputBuffer.count
                )
            }
        }
        guard count >= 0 else {
            throw SearchIndexError.analyzerResourceUnavailable(name: "Snowball \(languageCode) runtime")
        }
        return String(decoding: output.prefix(Int(count)), as: UTF8.self)
    }

    private static func cLanguage(for languageCode: String) -> ABSearchStemmerLanguage? {
        switch languageCode {
        case "da": return AB_SEARCH_STEMMER_DANISH
        case "nl": return AB_SEARCH_STEMMER_DUTCH
        case "fi": return AB_SEARCH_STEMMER_FINNISH
        case "fr": return AB_SEARCH_STEMMER_FRENCH
        case "it": return AB_SEARCH_STEMMER_ITALIAN
        case "no": return AB_SEARCH_STEMMER_NORWEGIAN
        case "pt": return AB_SEARCH_STEMMER_PORTUGUESE
        case "ru": return AB_SEARCH_STEMMER_RUSSIAN
        case "es": return AB_SEARCH_STEMMER_SPANISH
        case "sv": return AB_SEARCH_STEMMER_SWEDISH
        default: return nil
        }
    }
}
