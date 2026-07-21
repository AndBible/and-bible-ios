// ScriptureReferenceLinker.swift -- Android-compatible localized scripture-reference detection

import Foundation

/**
 One ordered text fragment produced by Android-compatible scripture-reference detection.

 Plain fragments have a `nil` OSIS reference. Resolved fragments retain the source text exactly
 and carry the normalized KJVA OSIS reference that native HTML renderers place on a `reference`
 element.
 */
public struct ScriptureReferenceSegment: Equatable, Sendable {
    /// Exact source text represented by this segment.
    public let text: String

    /// Normalized JSword-style KJVA OSIS reference, or `nil` for ordinary text.
    public let osisRef: String?

    /**
     Creates one immutable reference-linking result segment.

     - Parameters:
       - text: Exact source text; callers must not normalize it for display.
       - osisRef: Resolved KJVA OSIS reference, or `nil` for unlinked text.
     - Side effects: None.
     - Failure modes: None; validation occurs before construction.
     */
    public init(text: String, osisRef: String?) {
        self.text = text
        self.osisRef = osisRef
    }
}

/**
 Detects and resolves localized scripture references with Android's EPUB contract.

 The candidate expression is the expression used by Android
 `SwordContentFacade.bibleRefSplit`. Resolution mirrors Android's fuzzy-disabled lookup order:
 current UI locale, bundled English fallback, then the source document language and its English
 fallback. Book names come verbatim from the `BibleNames*.properties` files pinned by Android's
 JSword commit `0da7412d7716731f402c9002a0b92e4c00ef30eb`; passage bounds and normalized OSIS output use
 the shared JSword KJVA canon table.

 This service is intentionally independent of EPUB/XML so any native-HTML producer that opts into
 Android's scripture-link behavior can share the same resolver. It performs bundled-resource reads
 only during static catalog initialization and has no mutable global state.
 */
public enum ScriptureReferenceLinker {
    /**
     Matches Android's scripture-candidate grammar without permitting partial numeric tokens.

     Android accepts comma/semicolon continuations before ordinary prose, then delegates the whole
     candidate to JSword. Separating punctuated and whitespace-only continuations prevents the regex
     engine from shortening `20` to `2` merely to satisfy a trailing prose lookahead.
     */
    private static let candidateExpression = try? NSRegularExpression(
        pattern: #"(?:(?:[0-9]\.?\p{Z}+)?\p{Lu}\p{L}+\.?)\p{Z}+[0-9]+(?::[0-9]+)?(?:\p{Pd}[0-9]+(?::[0-9]+)?)?(?![0-9:])(?:(?:[,;]\p{Z}*[0-9]+(?::[0-9]+)?(?:\p{Pd}[0-9]+(?::[0-9]+)?)?(?![0-9:\p{L}]))|(?:\p{Z}+[0-9]+(?::[0-9]+)?(?:\p{Pd}[0-9]+(?::[0-9]+)?)?(?![0-9:.])(?!\.?\p{Z}*\p{L})))*"#
    )

    /// Separates the candidate book token from its numeric passage expression.
    private static let candidatePartsExpression = try? NSRegularExpression(
        pattern: #"^((?:[0-9]\.?\p{Z}+)?\p{Lu}\p{L}+\.?)\p{Z}+(.+)$"#
    )

    /// Reads one passage token plus its separator while allowing Android's Unicode dash class.
    private static let passageTokenExpression = try? NSRegularExpression(
        pattern: #"([,;]?\p{Z}*)([0-9]+(?::[0-9]+)?)(?:\p{Pd}([0-9]+(?::[0-9]+)?))?"#
    )

    /// Immutable localized book-name catalogs loaded from the pinned JSword resources.
    private static let catalogs = JSwordBibleNameCatalog.loadBundledCatalogs()

    /**
     Splits text into plain and resolved scripture-reference fragments.

     - Parameters:
       - text: Decoded native-HTML text node content.
       - documentLanguage: Source language from package metadata; BCP-47 and Java-style locale
         identifiers are accepted.
       - userLocale: Current interface locale used for Android's first resolution attempt.
     - Returns: Ordered fragments whose text concatenates exactly to `text`. Candidates that fail
       localized book lookup or KJVA validation remain plain text.
     - Side effects: Lazily reads bundled JSword name catalogs on first use.
     - Failure modes: Missing or malformed locale resources fall back to the pinned English base;
       if that base is unavailable, all candidates remain unlinked.
     */
    public static func segments(
        in text: String,
        documentLanguage: String,
        userLocale: Locale = .current
    ) -> [ScriptureReferenceSegment] {
        guard let candidateExpression else {
            return [ScriptureReferenceSegment(text: text, osisRef: nil)]
        }
        let nsText = text as NSString
        let matches = candidateExpression.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            return [ScriptureReferenceSegment(text: text, osisRef: nil)]
        }

        var result: [ScriptureReferenceSegment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result.append(ScriptureReferenceSegment(
                    text: nsText.substring(with: NSRange(
                        location: cursor,
                        length: match.range.location - cursor
                    )),
                    osisRef: nil
                ))
            }
            let candidate = nsText.substring(with: match.range)
            result.append(ScriptureReferenceSegment(
                text: candidate,
                osisRef: resolve(
                    candidate,
                    documentLanguage: documentLanguage,
                    userLocale: userLocale
                )
            ))
            cursor = NSMaxRange(match.range)
        }
        if cursor < nsText.length {
            result.append(ScriptureReferenceSegment(
                text: nsText.substring(from: cursor),
                osisRef: nil
            ))
        }
        return result
    }

    /**
     Resolves one Android-shaped candidate into a normalized KJVA OSIS reference.

     - Parameters:
       - candidate: Complete candidate such as `John 3:16-18, 4:1`.
       - documentLanguage: Source language used only after the current locale attempt fails.
       - userLocale: Current interface locale.
     - Returns: Canonically ordered and coalesced JSword-style OSIS ranges, or `nil` when any token
       is not addressable in KJVA.
     - Side effects: None after immutable catalog initialization.
     - Failure modes: Invalid books, chapter zero, out-of-range verses, reversed ranges, and syntax
       not accepted by Android's candidate grammar return `nil`.
     */
    public static func resolve(
        _ candidate: String,
        documentLanguage: String,
        userLocale: Locale = .current
    ) -> String? {
        guard let candidatePartsExpression,
              let passageTokenExpression else {
            return nil
        }
        let nsCandidate = candidate as NSString
        let fullRange = NSRange(location: 0, length: nsCandidate.length)
        guard let match = candidatePartsExpression.firstMatch(in: candidate, range: fullRange),
              match.range == fullRange,
              match.numberOfRanges >= 3 else {
            return nil
        }
        let rawBook = nsCandidate.substring(with: match.range(at: 1))
        let passage = nsCandidate.substring(with: match.range(at: 2))
        guard let book = resolveBook(
            rawBook,
            documentLanguage: documentLanguage,
            userLocale: userLocale
        ) else {
            return nil
        }

        let nsPassage = passage as NSString
        let tokenMatches = passageTokenExpression.matches(
            in: passage,
            range: NSRange(location: 0, length: nsPassage.length)
        )
        guard !tokenMatches.isEmpty else { return nil }

        var cursor = 0
        var basis: ScriptureInterval?
        var intervals: [ScriptureInterval] = []
        for (index, tokenMatch) in tokenMatches.enumerated() {
            guard tokenMatch.range.location == cursor,
                  tokenMatch.numberOfRanges >= 4 else {
                return nil
            }
            let separator = nsPassage.substring(with: tokenMatch.range(at: 1))
            if index == 0 {
                guard separator.isEmpty else { return nil }
            } else if separator.isEmpty {
                return nil
            }

            let startToken = nsPassage.substring(with: tokenMatch.range(at: 2))
            let endToken = tokenMatch.range(at: 3).location == NSNotFound
                ? nil
                : nsPassage.substring(with: tokenMatch.range(at: 3))
            guard let interval = interval(
                book: book,
                startToken: startToken,
                endToken: endToken,
                basis: basis,
                isFirst: index == 0
            ) else {
                return nil
            }
            intervals.append(interval)
            basis = interval
            cursor = NSMaxRange(tokenMatch.range)
        }
        guard cursor == nsPassage.length else { return nil }

        return coalesced(intervals).map(osisRef).joined(separator: " ")
    }

    /// Resolves OSIS or localized book names using Android's current-locale/source-locale order.
    private static func resolveBook(
        _ rawBook: String,
        documentLanguage: String,
        userLocale: Locale
    ) -> JSwordKJVABookSummary? {
        let englishNormalized = JSwordBibleNameCatalog.normalize(rawBook, locale: Locale(identifier: "en"))
        if let direct = JSwordKJVAVersification.books.first(where: {
            JSwordBibleNameCatalog.normalize($0.osisId, locale: Locale(identifier: "en")) == englishNormalized
        }) {
            return direct
        }

        var locales = [userLocale]
        let documentLocale = Locale(identifier: documentLanguage.replacingOccurrences(of: "-", with: "_"))
        if JSwordBibleNameCatalog.localeKey(for: documentLocale)
            != JSwordBibleNameCatalog.localeKey(for: userLocale) {
            locales.append(documentLocale)
        }
        for locale in locales {
            guard let catalog = JSwordBibleNameCatalog.catalog(for: locale, in: catalogs),
                  let osisID = catalog.osisID(for: rawBook, locale: locale),
                  let book = JSwordKJVAVersification.books.first(where: { $0.osisId == osisID }) else {
                continue
            }
            return book
        }
        return nil
    }

    /// Parses and validates one numeric token/range using JSword's one-chapter-book rules.
    private static func interval(
        book: JSwordKJVABookSummary,
        startToken: String,
        endToken: String?,
        basis: ScriptureInterval?,
        isFirst: Bool
    ) -> ScriptureInterval? {
        guard let startAddress = address(
            token: startToken,
            book: book,
            implicitVerse: book.chapterCount == 1 || (!isFirst && !isWholeChapter(basis)),
            inheritedChapter: basis?.end.chapter
        ) else {
            return nil
        }
        let endAddress: ScriptureAddress
        if let endToken {
            guard let parsedEnd = address(
                token: endToken,
                book: book,
                implicitVerse: startAddress.isVerse,
                inheritedChapter: startAddress.chapter
            ) else {
                return nil
            }
            endAddress = parsedEnd
        } else {
            endAddress = startAddress
        }

        guard let startVerse = boundaryVerse(for: startAddress, book: book, start: true),
              let endVerse = boundaryVerse(for: endAddress, book: book, start: false),
              startVerse.ordinal <= endVerse.ordinal else {
            return nil
        }
        return ScriptureInterval(
            book: book,
            start: startVerse,
            end: endVerse,
            sourceWasVerse: startAddress.isVerse
        )
    }

    /// Mirrors JSword `VerseRange.isWholeChapter()` when interpreting the next bare number.
    private static func isWholeChapter(_ interval: ScriptureInterval?) -> Bool {
        guard let interval,
              interval.start.chapter == interval.end.chapter,
              interval.start.verse == 1,
              interval.end.verse == JSwordKJVAVersification.verseCount(
                osisId: interval.book.osisId,
                chapter: interval.end.chapter
              ) else {
            return false
        }
        return true
    }

    /// Parses `chapter`, `chapter:verse`, or context-relative `verse` syntax.
    private static func address(
        token: String,
        book: JSwordKJVABookSummary,
        implicitVerse: Bool,
        inheritedChapter: Int? = nil
    ) -> ScriptureAddress? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let first = Int(parts[0]), first > 0 else {
            return nil
        }
        if parts.count == 2 {
            guard let verse = Int(parts[1]), verse > 0 else { return nil }
            return ScriptureAddress(chapter: first, verse: verse)
        }
        if implicitVerse {
            return ScriptureAddress(chapter: inheritedChapter ?? 1, verse: first)
        }
        return ScriptureAddress(chapter: first, verse: nil)
    }

    /// Expands a chapter or verse address to the requested inclusive interval boundary.
    private static func boundaryVerse(
        for address: ScriptureAddress,
        book: JSwordKJVABookSummary,
        start: Bool
    ) -> ScriptureVerse? {
        guard address.chapter > 0,
              address.chapter <= book.chapterCount,
              let lastVerse = JSwordKJVAVersification.verseCount(
                osisId: book.osisId,
                chapter: address.chapter
              ) else {
            return nil
        }
        let verse = address.verse ?? (start ? 1 : lastVerse)
        guard verse > 0, verse <= lastVerse,
              let ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: book.osisId,
                chapter: address.chapter,
                verse: verse
              ) else {
            return nil
        }
        return ScriptureVerse(chapter: address.chapter, verse: verse, ordinal: ordinal)
    }

    /// Sorts and merges overlapping/adjacent ranges as JSword passage implementations do.
    private static func coalesced(_ intervals: [ScriptureInterval]) -> [ScriptureInterval] {
        let sorted = intervals.sorted {
            if $0.start.ordinal == $1.start.ordinal { return $0.end.ordinal < $1.end.ordinal }
            return $0.start.ordinal < $1.start.ordinal
        }
        var result: [ScriptureInterval] = []
        for interval in sorted {
            guard let prior = result.last,
                  interval.start.ordinal <= prior.end.ordinal + 1 else {
                result.append(interval)
                continue
            }
            result[result.count - 1] = ScriptureInterval(
                book: prior.book,
                start: prior.start,
                end: interval.end.ordinal > prior.end.ordinal ? interval.end : prior.end,
                sourceWasVerse: prior.sourceWasVerse
            )
        }
        return result
    }

    /// Formats one validated interval with JSword's whole-book/chapter endpoint compaction.
    private static func osisRef(_ interval: ScriptureInterval) -> String {
        let book = interval.book
        let firstChapter = 1
        let lastChapter = book.chapterCount
        let firstVerse = interval.start.chapter == firstChapter && interval.start.verse == 1
        let lastVerse = interval.end.chapter == lastChapter
            && interval.end.verse == JSwordKJVAVersification.verseCount(
                osisId: book.osisId,
                chapter: lastChapter
            )
        if firstVerse && lastVerse { return book.osisId }

        if isWholeChapter(interval) {
            return "\(book.osisId).\(interval.start.chapter)"
        }

        let start = compactEndpoint(interval.start, book: book, isStart: true)
        let end = compactEndpoint(interval.end, book: book, isStart: false)
        return interval.start.ordinal == interval.end.ordinal ? start : "\(start)-\(end)"
    }

    /// Compacts an endpoint to `Book.chapter` when it lies on the relevant chapter boundary.
    private static func compactEndpoint(
        _ verse: ScriptureVerse,
        book: JSwordKJVABookSummary,
        isStart: Bool
    ) -> String {
        let isBoundary: Bool
        if isStart {
            isBoundary = verse.verse == 1
        } else {
            isBoundary = verse.verse == JSwordKJVAVersification.verseCount(
                osisId: book.osisId,
                chapter: verse.chapter
            )
        }
        return isBoundary
            ? "\(book.osisId).\(verse.chapter)"
            : "\(book.osisId).\(verse.chapter).\(verse.verse)"
    }
}

/// Parsed chapter or verse address before KJVA bounds expansion.
private struct ScriptureAddress {
    /// One-based chapter.
    let chapter: Int

    /// One-based verse, or `nil` when the address denotes a whole chapter.
    let verse: Int?

    /// Whether this address has verse precision.
    var isVerse: Bool { verse != nil }
}

/// One concrete verse boundary plus its globally ordered KJVA ordinal.
private struct ScriptureVerse {
    /// One-based chapter.
    let chapter: Int

    /// One-based verse.
    let verse: Int

    /// JSword KJVA ordinal used only for ordering and coalescing.
    let ordinal: Int
}

/// One validated inclusive interval within a single KJVA book.
private struct ScriptureInterval {
    /// Canonical KJVA book.
    let book: JSwordKJVABookSummary

    /// Inclusive first verse.
    let start: ScriptureVerse

    /// Inclusive last verse.
    let end: ScriptureVerse

    /// Whether the source start token used verse rather than chapter precision.
    let sourceWasVerse: Bool
}
