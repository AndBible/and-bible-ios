// BibleReaderReferenceResolver.swift -- JSword-compatible reader reference parsing

import Foundation
import SwordKit

/**
 Resolves reader-entered references using the same parser hierarchy as Android.

 Android delegates editor reference parsing to JSword `PassageKeyFactory` and serializes the
 resulting passage through `osisRef`. iOS still has to use SWORD for active-module validation, but
 this resolver keeps those semantics out of `BibleReaderController`: active module parsing is tried
 first, OSIS-looking text is validated before use, and human-readable fallback parsing uses the
 active module's book list when available.

 - Side effects: May temporarily move the active SWORD module cursor through `SwordModule` parser
   and versification helpers; those helpers restore the cursor before returning.
 - Failure modes: Returns `nil` for empty text, unknown books, out-of-range coordinates, reverse
   ranges, or parser results that cannot be validated against the active module/fallback canon.
 */
struct BibleReaderReferenceResolver {
    /**
     Active SWORD module used for parser and versification checks.

     `nil` means the reader is resolving during startup or in a test/fallback path where no module
     can validate references. When this is non-`nil`, resolver lookups must use module metadata and
     fail closed if that metadata is missing, because Android resolves through the active document's
     JSword versification rather than a global KJV-shaped canon.
     */
    private let activeModule: SwordModule?
    /**
     Ordered book metadata for `activeModule`.

     Empty with an active module is treated as unavailable active-module metadata, not as permission
     to use the static fallback canon. This preserves Android parity by preventing iOS from accepting
     references the active module cannot prove.
     */
    private let bookList: [BookInfo]
    /**
     Static compatibility canon used only when no active module exists.

     This supports controller startup and legacy tests that predate module loading. It is deliberately
     excluded whenever `activeModule` is present, so it cannot mask module import or versification
     failures.
     */
    private let fallbackBooks: [BookInfo]
    /**
     Verse-count lookup paired with `fallbackBooks` for no-module validation.

     The closure has no side effects and must only be consulted in fallback mode. Active-module
     resolution uses SWORD ordinals and verse counts instead.
     */
    private let fallbackVerseCount: (String, Int) -> Int

    /**
     Creates a resolver for one reader pane's current module and versification state.

     - Parameters:
       - activeModule: Active Bible module used for JSword/SWORD-compatible parsing.
       - bookList: Ordered books reported by the active module.
       - fallbackBooks: Static fallback canon used when no active module is available.
       - fallbackVerseCount: Static fallback verse-count lookup used when no active module exists.
     - Side effects: None.
     - Failure modes: None; invalid or empty inputs cause individual resolution calls to return
       `nil`.
     */
    init(
        activeModule: SwordModule?,
        bookList: [BookInfo],
        fallbackBooks: [BookInfo],
        fallbackVerseCount: @escaping (String, Int) -> Int
    ) {
        self.activeModule = activeModule
        self.bookList = bookList
        self.fallbackBooks = fallbackBooks
        self.fallbackVerseCount = fallbackVerseCount
    }

    /**
     Resolves human-readable or OSIS-format reference text into JSword-style OSIS reference text.

     - Parameter text: Raw reference text supplied by the web bridge or native UI.
     - Returns: Resolved OSIS reference text, or `nil` when the input cannot be parsed.
     - Side effects: May query the active SWORD module parser and exact verse metadata.
     - Failure modes: Returns `nil` for invalid or out-of-range input.
     */
    func resolveReference(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let osisRef = resolveReferenceWithActiveModuleParser(trimmed) {
            return osisRef
        }
        if let osisRef = resolveOsisRef(trimmed) {
            return osisRef
        }
        if let osisRef = resolveHumanRef(trimmed) {
            return osisRef
        }
        return nil
    }

    /**
     Resolves reference text through the active SWORD parser and serializes it like JSword.

     Android's text editor calls `LinkControl.resolveRef`, which delegates to JSword
     `PassageKeyFactory` and returns `key.osisRef`. This helper mirrors that path for iOS by
     asking the active module to parse each comma-separated passage item, then joining normalized
     OSIS range strings with JSword's space delimiter.

     - Parameter text: Non-empty user-entered reference text after caller trimming.
     - Returns: JSword-style OSIS reference text, or `nil` when no active module exists or the active
       parser/validator cannot prove the input is valid.
     - Side effects: May move the active SWORD module cursor while parsing and validating keys; the
       SwordKit helpers restore the prior cursor before returning.
     - Failure modes: Returns `nil` for unknown books, invalid explicit coordinates, reverse ranges,
       SWORD parser normalization that cannot be validated back to exact verses, or parser output that
       cannot be serialized to OSIS.
     */
    private func resolveReferenceWithActiveModuleParser(_ text: String) -> String? {
        guard let activeModule else { return nil }
        let explicitValidation = validateExplicitReferenceText(text, module: activeModule)
        if case .invalid = explicitValidation {
            return nil
        }

        let parsedKeys = activeModule.parseKeyList(text)
        guard !parsedKeys.isEmpty else { return nil }

        if case let .parsed(ranges) = explicitValidation,
           let osisRef = moduleParsedOsisRef(ranges: ranges, module: activeModule) {
            return osisRef
        }

        let refs = parsedKeys.compactMap { key -> OsisRef? in
            guard let ref = parseOsisRef(key),
                  isValidResolvedReference(
                    osisBookId: ref.osisId,
                    chapter: ref.chapter,
                    verse: ref.verse
                  ) else {
                return nil
            }
            return ref
        }
        guard refs.count == parsedKeys.count else { return nil }
        return moduleParsedOsisRef(refs, module: activeModule)
    }

    /**
     Validates and parses explicit numeric coordinates before trusting SWORD's parser output.

     JSword's `PassageKeyFactory` validates every constructed `VerseRange` through
     `Versification.validate(...)`. SWORD's `SWModule_parseKeyList` instead normalizes references
     such as `Gen.1.99` to a later valid verse. This preserves JSword semantics by checking
     user-supplied chapter/verse numbers that iOS can unambiguously identify.

     - Parameters:
       - text: Raw explicit reference text, including comma/semicolon lists and hyphen ranges.
       - module: Active SWORD module whose versification validates coordinates.
     - Returns: `.parsed` with explicit ranges when iOS can parse all coordinates, `.unknown` when
       text should be left to the module parser, or `.invalid` when the input is provably outside the
       active versification.
     - Side effects: Queries module verse ordinals/counts; does not mutate reader state.
     - Failure modes: Invalidates malformed ranges, out-of-range chapter/verse values, unparseable
       range endpoints, and reverse ranges.
     */
    private func validateExplicitReferenceText(
        _ text: String,
        module: SwordModule
    ) -> ExplicitReferenceValidation {
        let normalized = text.replacingOccurrences(
            of: #"\p{Pd}"#,
            with: "-",
            options: .regularExpression
        )
        var basis: ReferenceCoordinate?
        var ranges: [ReferenceRange] = []
        for segment in normalized.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSegment.isEmpty else { continue }
            let rangeParts = trimmedSegment.components(separatedBy: "-")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard rangeParts.count <= 2 else { return .invalid }
            guard let firstPart = rangeParts.first,
                  let start = parseReferenceCoordinate(firstPart, basis: basis) else {
                return .unknown
            }
            guard isValidReferenceCoordinate(start, module: module) else { return .invalid }

            var end = start
            if rangeParts.count > 1 {
                guard let parsedEnd = parseReferenceCoordinate(
                    rangeParts[1],
                    basis: start,
                    rangeEndUsesChapterWhenStartIsChapterOnly: start.verse == nil
                ),
                      isValidReferenceCoordinate(parsedEnd, module: module),
                      let startOrdinal = referenceOrdinal(start, module: module),
                      let endOrdinal = referenceOrdinal(parsedEnd, module: module),
                      endOrdinal >= startOrdinal else {
                    return .invalid
                }
                end = parsedEnd
            }

            ranges.append(ReferenceRange(start: start, end: end))
            basis = end
        }

        return ranges.isEmpty ? .unknown : .parsed(ranges)
    }

    /**
     Serializes one parser result segment into the compact OSIS form JSword would expose.

     `SWModule_parseKeyList` returns expanded verse keys. JSword's `Passage.getOsisRef()` reports
     a single verse as `Book.Chapter.Verse`, a same-chapter range as
     `Book.Chapter.Start-Book.Chapter.End`, and a whole chapter as `Book.Chapter`.

     - Parameters:
       - refs: Expanded verse references returned from active-module parsing.
       - module: Active module used to convert parsed coordinates into ordinal-aware verse keys.
     - Returns: Compact OSIS reference text with space-separated discontiguous ranges, or `nil` when
       any parsed reference cannot be mapped back to the active module.
     - Side effects: Reads module verse ordinals and verse references only.
     - Failure modes: Returns `nil` for empty input or any coordinate that no longer validates against
       the module's versification.
     */
    private func moduleParsedOsisRef(_ refs: [OsisRef], module: SwordModule) -> String? {
        guard !refs.isEmpty else { return nil }

        let references = refs.compactMap { ref -> VerseKeyReference? in
            guard let ordinal = module.verseOrdinal(
                osisBookId: ref.osisId,
                chapter: ref.chapter,
                verse: ref.verse
            ) else {
                return nil
            }
            return module.verseReference(osisBookId: ref.osisId, ordinal: ordinal)
        }
        guard references.count == refs.count else { return nil }

        var ranges: [(start: VerseKeyReference, end: VerseKeyReference)] = []
        var rangeStart = references[0]
        var rangeEnd = references[0]

        for reference in references.dropFirst() {
            if reference.ordinal == rangeEnd.ordinal + 1 {
                rangeEnd = reference
            } else {
                ranges.append((rangeStart, rangeEnd))
                rangeStart = reference
                rangeEnd = reference
            }
        }
        ranges.append((rangeStart, rangeEnd))

        return ranges
            .map { moduleParsedOsisRange(start: $0.start, end: $0.end, module: module) }
            .joined(separator: " ")
    }

    /**
     Serializes parsed explicit ranges using the same contiguous-range normalization as JSword.

     - Parameters:
       - ranges: Explicit ranges already validated against the active module.
       - module: Active module used to expand chapter-level boundaries to concrete verse keys.
     - Returns: JSword-style OSIS text for merged contiguous ranges, or `nil` when a boundary cannot
       be resolved to the active module.
     - Side effects: Reads module verse counts and ordinals only.
     - Failure modes: Returns `nil` for empty ranges or for any start/end coordinate that cannot be
       represented by a concrete verse key.
     */
    private func moduleParsedOsisRef(ranges: [ReferenceRange], module: SwordModule) -> String? {
        let resolvedRanges = ranges.compactMap { range -> (start: VerseKeyReference, end: VerseKeyReference)? in
            guard let start = verseKeyReference(forStartOf: range.start, module: module),
                  let end = verseKeyReference(forEndOf: range.end, module: module) else {
                return nil
            }
            return (start, end)
        }
        guard resolvedRanges.count == ranges.count, !resolvedRanges.isEmpty else { return nil }

        var merged: [(start: VerseKeyReference, end: VerseKeyReference)] = []
        var current = resolvedRanges[0]
        for range in resolvedRanges.dropFirst() {
            if range.start.ordinal == current.end.ordinal + 1 {
                current.end = range.end
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)

        return merged
            .map { moduleParsedOsisRange(start: $0.start, end: $0.end, module: module) }
            .joined(separator: " ")
    }

    /**
     Formats one contiguous verse run using JSword `VerseRange.getOsisRef()` semantics.

     - Parameters:
       - start: First concrete verse in the run.
       - end: Last concrete verse in the run.
       - module: Active module used to detect whole-chapter and whole-book boundaries.
     - Returns: Compact OSIS text for a single verse, chapter, book, same-chapter range, or cross-book
       range.
     - Side effects: Reads module verse counts only.
     - Failure modes: None for validated inputs; malformed start/end ordering is expected to be
       rejected before this formatter is called.
     */
    private func moduleParsedOsisRange(
        start: VerseKeyReference,
        end: VerseKeyReference,
        module: SwordModule
    ) -> String {
        if start == end {
            return start.osisRef
        }

        if start.osisBookId == end.osisBookId,
           start.chapter == 1,
           start.verse == 1,
           let bookName = bookName(forOsisId: start.osisBookId),
           end.chapter == chapterCount(for: bookName),
           module.verseCount(osisBookId: end.osisBookId, chapter: end.chapter) == end.verse {
            return start.osisBookId
        }

        if start.osisBookId == end.osisBookId, start.chapter == end.chapter {
            if start.verse == 1,
               module.verseCount(osisBookId: start.osisBookId, chapter: start.chapter) == end.verse {
                return "\(start.osisBookId).\(start.chapter)"
            }
            return "\(start.osisRef)-\(end.osisRef)"
        }

        let startText = start.verse == 1
            ? "\(start.osisBookId).\(start.chapter)"
            : start.osisRef
        let endText = module.verseCount(osisBookId: end.osisBookId, chapter: end.chapter) == end.verse
            ? "\(end.osisBookId).\(end.chapter)"
            : end.osisRef
        return "\(startText)-\(endText)"
    }

    /**
     Validated coordinate parser result from user reference text.

     `verse == nil` represents a chapter-level coordinate. That distinction is required because
     JSword interprets `Gen 1-2` as a chapter range but `Gen 1:1-2` as a verse range.
     */
    private enum ExplicitReferenceValidation {
        /// All explicit coordinates were parsed and validated into concrete start/end ranges.
        case parsed([ReferenceRange])
        /// Text was not an explicit coordinate shape and should be delegated to the active parser.
        case unknown
        /// Text was explicit enough to validate and was proven invalid for the active module.
        case invalid
    }

    /// Start/end pair from explicit reference text before chapter-level boundaries are expanded.
    private struct ReferenceRange {
        /// First coordinate in the range.
        let start: ReferenceCoordinate
        /// Last coordinate in the range; equal to `start` for single references.
        let end: ReferenceCoordinate
    }

    /// Book/chapter/optional-verse coordinate parsed from OSIS, human-readable, or shorthand text.
    private struct ReferenceCoordinate {
        /// OSIS book identifier resolved through active-module or allowed fallback metadata.
        let osisBookId: String
        /// One-based chapter number supplied by the user.
        let chapter: Int
        /// Optional one-based verse number; `nil` represents a chapter-level coordinate.
        let verse: Int?
    }

    /**
     Parses one range endpoint using OSIS, human-readable, or basis-relative shorthand forms.

     - Parameters:
       - text: Endpoint text such as `Gen.1.1`, `Genesis 1:1`, `1:2`, or `2`.
       - basis: Prior coordinate used to interpret shorthand endpoints.
       - rangeEndUsesChapterWhenStartIsChapterOnly: Whether a bare number at the end of a
         chapter-level range should be treated as a chapter rather than a verse.
     - Returns: A coordinate resolved to an OSIS book ID, or `nil` when the endpoint cannot be parsed.
     - Side effects: None.
     - Failure modes: Returns `nil` for empty text, unknown book aliases, malformed numbers, or
       shorthand that lacks a basis.
     */
    private func parseReferenceCoordinate(
        _ text: String,
        basis: ReferenceCoordinate?,
        rangeEndUsesChapterWhenStartIsChapterOnly: Bool = false
    ) -> ReferenceCoordinate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let osis = parseOsisCoordinate(trimmed) {
            return osis
        }

        if let human = parseHumanCoordinate(trimmed) {
            return human
        }

        if let chapterVerse = parseRelativeChapterVerseCoordinate(trimmed, basis: basis) {
            return chapterVerse
        }

        if let number = Int(trimmed), let basis {
            if rangeEndUsesChapterWhenStartIsChapterOnly || basis.verse == nil {
                return ReferenceCoordinate(osisBookId: basis.osisBookId, chapter: number, verse: nil)
            }
            return ReferenceCoordinate(osisBookId: basis.osisBookId, chapter: basis.chapter, verse: number)
        }

        return nil
    }

    /**
     Parses an OSIS-looking coordinate without validating chapter or verse ranges.

     - Parameter text: Candidate OSIS coordinate such as `Gen.1` or `Gen.1.1`.
     - Returns: A coordinate when the OSIS book exists in the resolver lookup set and numeric parts
       parse, otherwise `nil`.
     - Side effects: None.
     - Failure modes: Returns `nil` for unknown books, missing chapter values, or non-numeric verse
       values.
     */
    private func parseOsisCoordinate(_ text: String) -> ReferenceCoordinate? {
        let parts = text.components(separatedBy: ".")
        guard parts.count == 2 || parts.count == 3,
              bookName(forOsisId: parts[0]) != nil,
              let chapter = Int(parts[1]) else {
            return nil
        }
        let verse = parts.count == 3 ? Int(parts[2]) : nil
        if parts.count == 3, verse == nil { return nil }
        return ReferenceCoordinate(osisBookId: parts[0], chapter: chapter, verse: verse)
    }

    /**
     Parses a human-readable book/chapter/verse coordinate using resolver book aliases.

     - Parameter text: Candidate text such as `Genesis 1`, `Gen 1:1`, or `III John 1:2`.
     - Returns: A coordinate with an OSIS book ID, or `nil` when the text does not match the supported
       human-readable pattern.
     - Side effects: Builds an in-memory alias regular expression; does not mutate state.
     - Failure modes: Returns `nil` for unknown aliases, missing numeric chapter, or malformed verse.
     */
    private func parseHumanCoordinate(_ text: String) -> ReferenceCoordinate? {
        let aliases = referenceBookAliases()
            .sorted { $0.alias.count > $1.alias.count }
            .map { NSRegularExpression.escapedPattern(for: $0.alias) }
            .joined(separator: "|")
        guard !aliases.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"(?i)^(\#(aliases))\s+(\d+)(?::(\d+))?$"#
              ),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let aliasRange = Range(match.range(at: 1), in: text),
              let chapterRange = Range(match.range(at: 2), in: text),
              let chapter = Int(text[chapterRange]) else {
            return nil
        }

        let alias = canonicalReferenceAlias(String(text[aliasRange]))
        guard let osisBookId = referenceBookAliasMap()[alias] else { return nil }
        let verse: Int?
        if match.range(at: 3).location != NSNotFound,
           let verseRange = Range(match.range(at: 3), in: text) {
            verse = Int(text[verseRange])
            if verse == nil { return nil }
        } else {
            verse = nil
        }

        return ReferenceCoordinate(osisBookId: osisBookId, chapter: chapter, verse: verse)
    }

    /**
     Parses shorthand `chapter:verse` endpoints relative to an existing book basis.

     - Parameters:
       - text: Shorthand coordinate such as `1:2`.
       - basis: Existing coordinate supplying the OSIS book ID.
     - Returns: A coordinate in the basis book, or `nil` when there is no basis or the shorthand is
       malformed.
     - Side effects: None.
     - Failure modes: Returns `nil` for missing basis, missing colon parts, or non-numeric values.
     */
    private func parseRelativeChapterVerseCoordinate(
        _ text: String,
        basis: ReferenceCoordinate?
    ) -> ReferenceCoordinate? {
        guard let basis else { return nil }
        let parts = text.components(separatedBy: ":")
        guard parts.count == 2,
              let chapter = Int(parts[0]),
              let verse = Int(parts[1]) else {
            return nil
        }
        return ReferenceCoordinate(osisBookId: basis.osisBookId, chapter: chapter, verse: verse)
    }

    /**
     Converts active-parser OSIS verse keys into the reader's legacy `OsisRef` value.

     - Parameter osis: Verse-level OSIS key emitted by SWORD, for example `Gen.1.1`.
     - Returns: `OsisRef` for verse-level keys whose book exists in the resolver lookup set.
     - Side effects: None.
     - Failure modes: Returns `nil` for chapter-only keys, unknown books, or non-numeric chapter/verse
       components.
     */
    private func parseOsisRef(_ osis: String) -> OsisRef? {
        let parts = osis.components(separatedBy: ".")
        guard parts.count >= 3,
              let book = bookName(forOsisId: parts[0]),
              let chapter = Int(parts[1]),
              let verse = Int(parts[2]) else { return nil }
        return OsisRef(book: book, chapter: chapter, verse: verse, osisId: parts[0])
    }

    /**
     Checks whether a parsed explicit coordinate exists in the active module's versification.

     - Parameters:
       - coordinate: Book/chapter/optional-verse coordinate from user input.
       - module: Active module that owns the authoritative versification.
     - Returns: `true` when the verse exists, or when a chapter-level coordinate has a valid chapter.
     - Side effects: Reads module verse ordinals/counts only.
     - Failure modes: Returns `false` for out-of-range chapters or verses.
     */
    private func isValidReferenceCoordinate(_ coordinate: ReferenceCoordinate, module: SwordModule) -> Bool {
        if let verse = coordinate.verse {
            return module.verseOrdinal(
                osisBookId: coordinate.osisBookId,
                chapter: coordinate.chapter,
                verse: verse
            ) != nil
        }
        return module.verseCount(osisBookId: coordinate.osisBookId, chapter: coordinate.chapter) != nil
    }

    /**
     Resolves a coordinate to the active module ordinal used for range ordering.

     - Parameters:
       - coordinate: Coordinate to order.
       - module: Active module that provides ordinal lookup.
     - Returns: Ordinal for the exact verse, or the first verse of a chapter-level coordinate.
     - Side effects: Reads module ordinal metadata only.
     - Failure modes: Returns `nil` when the coordinate cannot be represented in the active module.
     */
    private func referenceOrdinal(_ coordinate: ReferenceCoordinate, module: SwordModule) -> Int? {
        if let verse = coordinate.verse {
            return module.verseOrdinal(
                osisBookId: coordinate.osisBookId,
                chapter: coordinate.chapter,
                verse: verse
            )
        }
        return module.verseOrdinal(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: 1
        )
    }

    /**
     Expands a coordinate to the first concrete verse covered by that coordinate.

     - Parameters:
       - coordinate: Explicit coordinate, possibly chapter-level.
       - module: Active module that supplies ordinals.
     - Returns: Verse key for `coordinate.verse` or verse 1 of the coordinate's chapter.
     - Side effects: Reads module ordinal metadata only.
     - Failure modes: Returns `nil` when the start verse does not exist in the active module.
     */
    private func verseKeyReference(
        forStartOf coordinate: ReferenceCoordinate,
        module: SwordModule
    ) -> VerseKeyReference? {
        let verse = coordinate.verse ?? 1
        guard let ordinal = module.verseOrdinal(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse
        ) else {
            return nil
        }
        return VerseKeyReference(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    /**
     Expands a coordinate to the last concrete verse covered by that coordinate.

     - Parameters:
       - coordinate: Explicit coordinate, possibly chapter-level.
       - module: Active module that supplies verse counts and ordinals.
     - Returns: Verse key for `coordinate.verse` or the last verse of the coordinate's chapter.
     - Side effects: Reads module verse counts and ordinal metadata only.
     - Failure modes: Returns `nil` when the chapter or resolved end verse does not exist.
     */
    private func verseKeyReference(
        forEndOf coordinate: ReferenceCoordinate,
        module: SwordModule
    ) -> VerseKeyReference? {
        let verse: Int
        if let coordinateVerse = coordinate.verse {
            verse = coordinateVerse
        } else if let chapterVerseCount = module.verseCount(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter
        ) {
            verse = chapterVerseCount
        } else {
            return nil
        }

        guard let ordinal = module.verseOrdinal(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse
        ) else {
            return nil
        }
        return VerseKeyReference(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    /**
     Builds a canonical alias-to-OSIS lookup for human-readable reference parsing.

     - Returns: Dictionary keyed by canonicalized aliases with OSIS book IDs as values.
     - Side effects: None.
     - Failure modes: Duplicate aliases are resolved by the last generated alias, matching the ordered
       lookup behavior used by the resolver's current book metadata.
     */
    private func referenceBookAliasMap() -> [String: String] {
        var map: [String: String] = [:]
        for alias in referenceBookAliases() {
            map[alias.alias] = alias.osisBookId
        }
        return map
    }

    /**
     Generates book aliases from active-module metadata plus common English abbreviations.

     - Returns: Canonical alias/OSIS pairs used by human-readable parsing.
     - Side effects: None.
     - Failure modes: Returns only common aliases when resolver metadata is empty; active-module
       callers still fail closed because `booksForLookup` is empty when module metadata is missing.
     */
    private func referenceBookAliases() -> [(alias: String, osisBookId: String)] {
        var aliases: [(alias: String, osisBookId: String)] = []
        for book in booksForLookup {
            appendReferenceAlias(book.name, osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias(book.abbreviation, osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias(book.osisId, osisBookId: book.osisId, to: &aliases)
            appendNumberedBookReferenceAliases(for: book, to: &aliases)
        }
        for (alias, osisBookId) in Self.commonReferenceAliasOsisIds {
            appendReferenceAlias(alias, osisBookId: osisBookId, to: &aliases)
        }
        return aliases
    }

    /**
     English alias table that supplements active-module book metadata for JSword-like parsing.

     The table covers common abbreviations and alternate numbered-book spellings that users and
     Android/JSword parsing accept in editor references. It is not a fallback book list by itself:
     successful resolution still requires the OSIS ID to exist in `booksForLookup`.
     */
    private static let commonReferenceAliasOsisIds: [String: String] = [
        "gen": "Gen", "ex": "Exod", "exo": "Exod", "lev": "Lev",
        "num": "Num", "deut": "Deut", "deu": "Deut", "dt": "Deut",
        "josh": "Josh", "judg": "Judg", "jdg": "Judg",
        "1 sam": "1Sam", "2 sam": "2Sam", "1 ki": "1Kgs", "2 ki": "2Kgs",
        "1 chr": "1Chr", "2 chr": "2Chr", "neh": "Neh", "est": "Esth",
        "ps": "Ps", "psa": "Ps", "prov": "Prov", "pro": "Prov",
        "eccl": "Eccl", "ecc": "Eccl", "song": "Song", "sos": "Song",
        "isa": "Isa", "jer": "Jer", "lam": "Lam", "ezek": "Ezek", "eze": "Ezek",
        "dan": "Dan", "hos": "Hos", "joe": "Joel", "amo": "Amos",
        "oba": "Obad", "jon": "Jonah", "mic": "Mic", "nah": "Nah",
        "hab": "Hab", "zeph": "Zeph", "zep": "Zeph",
        "hag": "Hag", "zech": "Zech", "zec": "Zech", "mal": "Mal",
        "matt": "Matt", "mat": "Matt", "mk": "Mark", "luk": "Luke", "lk": "Luke",
        "jn": "John", "joh": "John", "act": "Acts",
        "rom": "Rom", "1 cor": "1Cor", "2 cor": "2Cor",
        "gal": "Gal", "eph": "Eph", "phil": "Phil", "php": "Phil",
        "col": "Col", "1 thess": "1Thess", "2 thess": "2Thess",
        "1 th": "1Thess", "2 th": "2Thess",
        "1 tim": "1Tim", "2 tim": "2Tim", "tit": "Titus", "phm": "Phlm", "philem": "Phlm",
        "heb": "Heb", "jas": "Jas", "jam": "Jas",
        "1 pet": "1Pet", "2 pet": "2Pet", "1 pe": "1Pet", "2 pe": "2Pet",
        "1 jn": "1John", "2 jn": "2John", "3 jn": "3John",
        "1 john": "1John", "2 john": "2John", "3 john": "3John",
        "jude": "Jude", "jud": "Jude",
        "rev": "Rev", "reve": "Rev",
    ]

    /**
     Adds roman-numeral, word-number, and compact-number aliases for numbered books.

     - Parameters:
       - book: Book metadata whose name may begin with `1 `, `2 `, `3 `, or `4 `.
       - aliases: Alias accumulator mutated in place.
     - Returns: Nothing.
     - Side effects: Appends aliases to the supplied accumulator.
     - Failure modes: No-op for non-numbered books.
     */
    private func appendNumberedBookReferenceAliases(
        for book: BookInfo,
        to aliases: inout [(alias: String, osisBookId: String)]
    ) {
        let numberedPrefixes: [(numeric: String, roman: String, word: String)] = [
            ("1", "I", "First"),
            ("2", "II", "Second"),
            ("3", "III", "Third"),
            ("4", "IV", "Fourth"),
        ]
        for prefix in numberedPrefixes where book.name.hasPrefix("\(prefix.numeric) ") {
            let baseName = String(book.name.dropFirst(2))
            appendReferenceAlias("\(prefix.roman) \(baseName)", osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias("\(prefix.word) \(baseName)", osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias("\(prefix.numeric)\(baseName)", osisBookId: book.osisId, to: &aliases)
        }
    }

    /**
     Canonicalizes and appends a single alias when it has searchable content.

     - Parameters:
       - alias: Raw alias from module metadata or the common alias table.
       - osisBookId: OSIS book ID associated with the alias.
       - aliases: Alias accumulator mutated in place.
     - Returns: Nothing.
     - Side effects: Appends to `aliases`.
     - Failure modes: Empty canonical aliases are ignored.
     */
    private func appendReferenceAlias(
        _ alias: String,
        osisBookId: String,
        to aliases: inout [(alias: String, osisBookId: String)]
    ) {
        let canonical = canonicalReferenceAlias(alias)
        guard !canonical.isEmpty else { return }
        aliases.append((canonical, osisBookId))
    }

    /**
     Normalizes alias spelling for case-insensitive human-reference lookup.

     - Parameter alias: Raw book name, abbreviation, OSIS ID, or common alias.
     - Returns: Lowercase alias with periods/underscores/collapsed whitespace normalized.
     - Side effects: None.
     - Failure modes: Empty or whitespace-only aliases return an empty string.
     */
    private func canonicalReferenceAlias(_ alias: String) -> String {
        alias
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: #"[\s_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /**
     Validates and resolves an OSIS-format reference like `Gen.1.1`.

     `navigateToRef` uses this narrower path before human parsing so legacy navigation semantics stay
     intact: a valid OSIS reference is returned exactly as entered and then handed to
     `navigateToOsisRef`.

     - Parameter text: Candidate OSIS text with dot-separated book, chapter, and optional verse.
     - Returns: The original text when the book and coordinate validate, otherwise `nil`.
     - Side effects: May query the active module's versification metadata.
     - Failure modes: Returns `nil` for unknown books, non-numeric chapters/verses, missing chapter,
       out-of-range coordinates, or missing active-module book metadata.
     */
    func resolveOsisRef(_ text: String) -> String? {
        let parts = text.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        guard bookName(forOsisId: parts[0]) != nil else { return nil }
        guard let chapter = Int(parts[1]) else { return nil }
        let verse = parts.count >= 3 ? Int(parts[2]) : nil
        guard isValidResolvedReference(osisBookId: parts[0], chapter: chapter, verse: verse) else {
            return nil
        }
        return text
    }

    /**
     Validates a resolved OSIS reference against the active module when one exists.

     Android delegates parsed references to JSword's `PassageKeyFactory`, which rejects invalid
     chapter and verse coordinates instead of accepting text that merely looks like OSIS.

     - Parameters:
       - osisBookId: Candidate OSIS book ID.
       - chapter: One-based chapter number.
       - verse: Optional one-based verse number.
     - Returns: `true` when the coordinate exists in the active module or, without an active module,
       in the static fallback canon.
     - Side effects: Reads active-module verse metadata when available.
     - Failure modes: Returns `false` for missing books, non-positive chapters, out-of-range
       coordinates, or unavailable active-module book metadata.
     */
    private func isValidResolvedReference(osisBookId: String, chapter: Int, verse: Int?) -> Bool {
        guard chapter > 0, let book = bookName(forOsisId: osisBookId) else { return false }
        if let activeModule {
            if let verse {
                return activeModule.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse) != nil
            }
            return activeModule.verseCount(osisBookId: osisBookId, chapter: chapter) != nil
        }

        guard chapter <= chapterCount(for: book) else { return false }
        if let verse {
            return verse > 0 && verse <= fallbackVerseCount(book, chapter)
        }
        return true
    }

    /**
     Resolves human-readable references like `Genesis 1:1` or `Gen 1:1`.

     This is the navigation fallback path, not the full editor parser. It intentionally supports the
     legacy single-book/same-chapter shapes that `navigateToRef` accepted before the resolver
     extraction while delegating final coordinate validation to `resolveOsisRef`.

     - Parameter text: Candidate human-readable reference with a book name/alias, chapter, optional
       verse, and optional same-chapter end verse.
     - Returns: OSIS text for the validated reference or same-chapter verse range, or `nil` when the
       reference cannot be resolved.
     - Side effects: May query active-module metadata through `resolveOsisRef`.
     - Failure modes: Returns `nil` for unsupported grammar, unknown aliases, invalid coordinates,
       reverse same-chapter ranges, or missing active-module book metadata.
     */
    func resolveHumanRef(_ text: String) -> String? {
        let pattern = #"^(\d?\s*[A-Za-z]+(?:\s+[A-Za-z]+)*)\s+(\d+)(?::(\d+)(?:-(\d+))?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        guard let bookRange = Range(match.range(at: 1), in: text),
              let chapterRange = Range(match.range(at: 2), in: text) else { return nil }

        let bookText = String(text[bookRange]).trimmingCharacters(in: .whitespaces)
        guard let chapter = Int(text[chapterRange]) else { return nil }
        guard let osisId = osisBookId(forHumanName: bookText) else { return nil }

        if match.range(at: 3).location != NSNotFound,
           let verseRange = Range(match.range(at: 3), in: text),
           let verse = Int(text[verseRange]) {
            let startRef = "\(osisId).\(chapter).\(verse)"
            guard resolveOsisRef(startRef) != nil else { return nil }
            if match.range(at: 4).location != NSNotFound,
               let endRange = Range(match.range(at: 4), in: text),
               let endVerse = Int(text[endRange]) {
                let endRef = "\(osisId).\(chapter).\(endVerse)"
                guard endVerse >= verse, resolveOsisRef(endRef) != nil else { return nil }
                return "\(startRef)-\(endRef)"
            }
            return startRef
        }
        let chapterRef = "\(osisId).\(chapter)"
        return resolveOsisRef(chapterRef)
    }

    /**
     Resolves a human book name or abbreviation to an OSIS book ID.

     - Parameter name: Book text captured from a human-readable reference.
     - Returns: Matching OSIS book ID from exact, case-insensitive, prefix, or common-alias lookup.
     - Side effects: None.
     - Failure modes: Returns `nil` when the resolver has no valid lookup metadata for the supplied
       book name.
     */
    private func osisBookId(forHumanName name: String) -> String? {
        let lower = name.lowercased()
        let books = booksForLookup
        if let info = books.first(where: { $0.name == name }) {
            return info.osisId
        }
        for info in books where info.name.lowercased() == lower {
            return info.osisId
        }
        for info in books
            where info.name.lowercased().hasPrefix(lower)
            || lower.hasPrefix(info.name.lowercased().prefix(3).description) {
            return info.osisId
        }
        return Self.commonReferenceAliasOsisIds[lower]
    }

    /**
     Selects the authoritative book metadata for lookup and validation.

     Active-module metadata wins. Static fallback metadata is only allowed when there is no active
     module at all, which prevents iOS from accepting references through a default canon after active
     module metadata fails to load.

     - Returns: Active module books, static fallback books in no-module mode, or an empty list in
       active-module fail-closed mode.
     - Side effects: None.
     - Failure modes: Empty result intentionally causes reference resolution to reject book lookups.
     */
    private var booksForLookup: [BookInfo] {
        if !bookList.isEmpty {
            return bookList
        }
        return activeModule == nil ? fallbackBooks : []
    }

    /**
     Reads a chapter count from the resolver's current lookup metadata.

     - Parameter book: Human-readable book name from the selected lookup set.
     - Returns: Known chapter count, or `1` as a defensive fallback for formatter paths that have
       already validated their inputs elsewhere.
     - Side effects: None.
     - Failure modes: Unknown books return `1`; callers that need validation must use module ordinals
       or `bookName(forOsisId:)` first.
     */
    private func chapterCount(for book: String) -> Int {
        booksForLookup.first(where: { $0.name == book })?.chapterCount ?? 1
    }

    /**
     Resolves an OSIS book ID to the current lookup-set book name.

     - Parameter osisId: OSIS book identifier.
     - Returns: Book name from active-module or allowed fallback metadata.
     - Side effects: None.
     - Failure modes: Returns `nil` when active-module metadata is unavailable or the OSIS ID is not
       part of the selected lookup set.
     */
    private func bookName(forOsisId osisId: String) -> String? {
        booksForLookup.first(where: { $0.osisId == osisId })?.name
    }
}
