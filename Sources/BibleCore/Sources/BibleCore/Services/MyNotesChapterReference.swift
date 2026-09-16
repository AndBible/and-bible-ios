// MyNotesChapterReference.swift - Android-compatible My Notes chapter identity and mapped span

import Foundation
import SwordKit

/**
 Identifies an exact source-versification chapter request used by My Notes navigation.

 The source chapter remains unnormalized so chapter `0` continues to identify the request that
 produced a result. Mapping applies Android's separate clamp-to-one rule without erasing this value.
 Copies are immutable and `Sendable`; they retain no SWORD or SwiftData state.
 */
public struct MyNotesSourceChapter: Sendable, Equatable {
    /// Canonical JSword source-versification name.
    public let versification: String

    /// Exact source OSIS book identifier.
    public let osisBookId: String

    /// Requested source chapter, including `0` for a book or chapter introduction.
    public let chapter: Int

    /**
     Creates a source chapter identity after its values have been validated by the caller.

     - Parameters:
       - versification: Canonical JSword versification name.
       - osisBookId: Exact source OSIS book identifier.
       - chapter: Requested chapter, including `0` for an introduction.
     - Side effects: None; the value stores independent string and integer copies.
     - Failure modes: This initializer does not validate inputs. Use
       ``MyNotesChapterReference/init(sourceVersification:sourceOSISBookId:sourceChapter:locale:)``
       when constructing a mapped My Notes document identity.
     */
    public init(versification: String, osisBookId: String, chapter: Int) {
        self.versification = versification
        self.osisBookId = osisBookId
        self.chapter = chapter
    }
}

/**
 Carries Android's authoritative KJVA span and heading for one source My Notes chapter.

 This is the chapter-expansion boundary, not the admission policy for every My Notes route.
 Pseudo-document selection and synchronized target updates through `currentBible.doSetKey` can
 retain an active-source chapter here.
 Explicit links, passage choices, and next/previous first map their selected verse to KJVA; callers
 must pass that resulting KJVA chapter rather than expand the original source chapter.

 Expansion disables introductions, clamps both endpoint chapters and verses to at least one,
 converts each endpoint through JSword, and constructs a KJVA `VerseRange`. This immutable value
 preserves the exact request identity while exposing only strict mapped or identity KJVA results.
 Public-converter coordinate fallbacks never become authoritative ordinals.
 */
public struct MyNotesChapterReference: Sendable, Equatable {
    /// Exact validated source request, retaining chapter `0` when selected.
    public let source: MyNotesSourceChapter

    /// Effective source chapter used for both clamped conversion endpoints.
    public let effectiveSourceChapter: Int

    /// First authoritative KJVA coordinate in display order.
    public let mappedKJVAStart: SwordVersification.Reference

    /// Last authoritative KJVA coordinate in display order.
    public let mappedKJVAEnd: SwordVersification.Reference

    /// Inclusive first Android KJVA ordinal.
    public let kjvaOrdinalStart: Int

    /// Inclusive last Android KJVA ordinal.
    public let kjvaOrdinalEnd: Int

    /// Android-style compact name derived from the mapped KJVA span.
    public let displayHeading: String

    /**
     Builds the mapped My Notes chapter identity using the pinned Android JSword resources.

     The source chapter's verse-zero start is clamped to verse 1. The end is the source canon's
     last verse for the requested chapter, with a chapter-0 end also clamped to chapter 1 verse 1.
     Each endpoint must convert authoritatively to KJVA and resolve to a real or chapter-intro KJVA
     ordinal. Results are ordered by ordinal together with their coordinates.

     - Parameters:
       - sourceVersification: JSword versification owning the selected chapter; whitespace-only
         input uses Android's KJV default.
       - sourceOSISBookId: Exact OSIS book identifier in the source versification.
       - sourceChapter: Selected source chapter; `0` denotes an introduction request.
       - locale: Locale for JSword's KJVA book name in the display heading.
     - Returns: A self-contained mapped value, or `nil` when source dimensions or either strict
       endpoint conversion are unavailable.
     - Side effects: Lazily reads immutable bundled JSword canon, mapping, and name resources. It
       performs no database writes and does not move an installed SWORD module cursor.
     - Failure modes: Unknown systems/books/chapters, negative chapters, public conversion
       fallbacks, invalid target coordinates, and malformed resources fail atomically with `nil`.
     */
    public init?(
        sourceVersification: String,
        sourceOSISBookId: String,
        sourceChapter: Int,
        locale: Locale = .current
    ) {
        guard sourceChapter >= 0,
              let normalizedVersification = JSwordCanon.normalizedName(sourceVersification),
              let sourceLastVerse = JSwordCanon.lastVerse(
                  osisBookId: sourceOSISBookId,
                  chapter: sourceChapter,
                  versification: normalizedVersification
              ) else {
            return nil
        }

        let effectiveChapter = max(sourceChapter, 1)
        let sourceStart = SwordVersification.Reference(
            osisBookId: sourceOSISBookId,
            chapter: effectiveChapter,
            verse: 1
        )
        let sourceEnd = SwordVersification.Reference(
            osisBookId: sourceOSISBookId,
            chapter: effectiveChapter,
            verse: max(sourceLastVerse, 1)
        )
        guard let start = Self.authoritativeKJVAEndpoint(
                  sourceStart,
                  sourceVersification: normalizedVersification
              ),
              let end = Self.authoritativeKJVAEndpoint(
                  sourceEnd,
                  sourceVersification: normalizedVersification
              ) else {
            return nil
        }

        let ordered = start.ordinal <= end.ordinal ? (start, end) : (end, start)
        guard let heading = Self.heading(
            start: ordered.0.reference,
            end: ordered.1.reference,
            locale: locale
        ) else {
            return nil
        }

        source = MyNotesSourceChapter(
            versification: normalizedVersification,
            osisBookId: sourceOSISBookId,
            chapter: sourceChapter
        )
        effectiveSourceChapter = effectiveChapter
        mappedKJVAStart = ordered.0.reference
        mappedKJVAEnd = ordered.1.reference
        kjvaOrdinalStart = ordered.0.ordinal
        kjvaOrdinalEnd = ordered.1.ordinal
        displayHeading = heading
    }

    /**
     Resolves one strict KJVA endpoint and its intro-inclusive Android ordinal.

     - Parameters:
       - source: Clamped source coordinate.
       - sourceVersification: Validated canonical JSword source system.
     - Returns: The authoritative KJVA coordinate and ordinal, or `nil` for a strict miss or an
       invalid KJVA coordinate.
     - Side effects: Lazily reads immutable mapping resources; no native module is accessed.
     - Failure modes: Public-converter fallbacks are excluded because this method calls only the
       strict converter.
     */
    private static func authoritativeKJVAEndpoint(
        _ source: SwordVersification.Reference,
        sourceVersification: String
    ) -> (reference: SwordVersification.Reference, ordinal: Int)? {
        guard let conversion = VersificationMapper.convertStrictly(
                  osisBookId: source.osisBookId,
                  chapter: source.chapter,
                  verse: source.verse,
                  from: sourceVersification,
                  to: JSwordKJVAVersification.name
              ) else {
            return nil
        }
        let reference = conversion.reference
        let ordinal: Int?
        if reference.verse == 0 {
            ordinal = JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: reference.osisBookId,
                chapter: reference.chapter
            )
        } else {
            ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: reference.osisBookId,
                chapter: reference.chapter,
                verse: reference.verse
            )
        }
        guard let ordinal else { return nil }
        return (reference, ordinal)
    }

    /**
     Formats the mapped KJVA span using JSword's compact `VerseRange.getName()` shapes.

     A complete one-chapter book omits the chapter, a complete chapter uses `Book chapter`, and a
     complete multi-chapter span uses `Book first-last`. Partial ranges retain verse coordinates.

     - Parameters:
       - start: First mapped KJVA coordinate in ordinal order.
       - end: Last mapped KJVA coordinate in ordinal order.
       - locale: Locale used to resolve JSword's long book name.
     - Returns: Compact localized heading, or `nil` when either coordinate is outside KJVA.
     - Side effects: Lazily loads immutable JSword name resources.
     - Failure modes: Unknown books, reversed coordinates, and unavailable chapter dimensions
       return `nil`.
     */
    private static func heading(
        start: SwordVersification.Reference,
        end: SwordVersification.Reference,
        locale: Locale
    ) -> String? {
        guard start.chapter > 0,
              end.chapter > 0,
              let startBookName = JSwordKJVAVersification.localizedLongBookName(
                  osisId: start.osisBookId,
                  locale: locale
              ),
              let endBookName = JSwordKJVAVersification.localizedLongBookName(
                  osisId: end.osisBookId,
                  locale: locale
              ),
              let lastStartBookChapter = JSwordKJVAVersification.lastChapter(
                  osisId: start.osisBookId
              ),
              let lastEndBookChapter = JSwordKJVAVersification.lastChapter(
                  osisId: end.osisBookId
              ),
              let endVerse = JSwordKJVAVersification.verseCount(
                  osisId: end.osisBookId,
                  chapter: end.chapter
              ) else {
            return nil
        }

        let beginsAtChapterStart = start.verse == 0 || start.verse == 1
        let endsAtChapterEnd = end.verse == endVerse
        if start.osisBookId != end.osisBookId {
            let beginsAtBookStart = start.chapter == 1 && beginsAtChapterStart
            let endsAtBookEnd = end.chapter == lastEndBookChapter && endsAtChapterEnd
            if beginsAtBookStart && endsAtBookEnd {
                return "\(startBookName)-\(endBookName)"
            }
            if beginsAtChapterStart && endsAtChapterEnd {
                return "\(startBookName) \(start.chapter)-\(endBookName) \(end.chapter)"
            }
            return "\(Self.verseHeading(start, bookName: startBookName))-\(Self.verseHeading(end, bookName: endBookName))"
        }
        guard end.chapter >= start.chapter else { return nil }

        if beginsAtChapterStart && endsAtChapterEnd {
            if start.chapter == 1, end.chapter == lastStartBookChapter {
                return startBookName
            }
            if start.chapter == end.chapter {
                return "\(startBookName) \(start.chapter)"
            }
            return "\(startBookName) \(start.chapter)-\(end.chapter)"
        }

        if start.chapter == end.chapter {
            if start.verse == end.verse {
                return Self.verseHeading(start, bookName: startBookName)
            }
            return "\(Self.verseHeading(start, bookName: startBookName))-\(end.verse)"
        }
        return "\(Self.verseHeading(start, bookName: startBookName))-\(end.chapter):\(end.verse)"
    }

    /**
     Formats one KJVA coordinate as JSword's standalone full-book verse name.

     - Parameters:
       - reference: Valid mapped KJVA coordinate.
       - bookName: Already localized long book name for the coordinate.
     - Returns: `Book chapter:verse` with no range compaction.
     - Side effects: None; output is deterministic for the supplied values.
     - Failure modes: None; the caller validates KJVA coordinates before invoking this helper.
     */
    private static func verseHeading(
        _ reference: SwordVersification.Reference,
        bookName: String
    ) -> String {
        "\(bookName) \(reference.chapter):\(reference.verse)"
    }
}

/**
 Applies Android `BibleTraverser` chapter stepping to a source My Notes identity.

 Eligible books represent the active document's available scripture books. Navigation follows the
 pinned source canon order, skips unavailable books and books whose KJV-scripture classification
 differs from the current book, wraps forward to Genesis 1 when no eligible next book exists, and
 leaves the first chapter unchanged when no previous eligible book exists.
 */
public enum MyNotesChapterTraversal {
    /**
     Returns the source chapter reached by Android's forward chapter action.

     - Parameters:
       - source: Current exact source identity.
       - eligibleBookOSISIDs: Source books present in the active document.
     - Returns: The next chapter, the next eligible book's first chapter, or Genesis 1 when no
       eligible later book exists. Invalid source identities return `nil`.
     - Side effects: Lazily reads immutable JSword canon dimensions; no reader state is mutated.
     - Failure modes: Unknown systems/books and out-of-range chapters return `nil`. Genesis wrap is
       returned exactly as Android does even when Genesis is absent from the eligible set.
     */
    public static func next(
        after source: MyNotesSourceChapter,
        eligibleBookOSISIDs: Set<String>
    ) -> MyNotesSourceChapter? {
        guard let dimensions = JSwordCanon.bookDimensions(
                  versification: source.versification
              ),
              let kjvBooks = JSwordCanon.bookDimensions(versification: "KJV"),
              let currentIndex = dimensions.firstIndex(where: {
                  $0.osisBookId == source.osisBookId
              }),
              (0...dimensions[currentIndex].lastChapter).contains(source.chapter) else {
            return nil
        }
        let kjvScriptureIDs = Set(kjvBooks.map(\.osisBookId))
        let currentIsKJVScripture = kjvScriptureIDs.contains(source.osisBookId)
        let current = dimensions[currentIndex]
        if source.chapter < current.lastChapter {
            return MyNotesSourceChapter(
                versification: source.versification,
                osisBookId: source.osisBookId,
                chapter: source.chapter + 1
            )
        }
        if let nextBook = dimensions.dropFirst(currentIndex + 1).first(where: {
            eligibleBookOSISIDs.contains($0.osisBookId)
                && kjvScriptureIDs.contains($0.osisBookId) == currentIsKJVScripture
        }) {
            return MyNotesSourceChapter(
                versification: source.versification,
                osisBookId: nextBook.osisBookId,
                chapter: 1
            )
        }
        guard dimensions.contains(where: { $0.osisBookId == "Gen" }) else { return nil }
        return MyNotesSourceChapter(
            versification: source.versification,
            osisBookId: "Gen",
            chapter: 1
        )
    }

    /**
     Returns the source chapter reached by Android's backward chapter action.

     - Parameters:
       - source: Current exact source identity.
       - eligibleBookOSISIDs: Source books present in the active document.
     - Returns: The preceding chapter, the preceding eligible book's last chapter, or the unchanged
       source when no eligible previous book exists.
     - Side effects: Lazily reads immutable JSword canon dimensions; no reader state is mutated.
     - Failure modes: Unknown systems/books and out-of-range chapters return `nil`; absence of a
       previous eligible book is a successful no-op, matching Android.
     */
    public static func previous(
        before source: MyNotesSourceChapter,
        eligibleBookOSISIDs: Set<String>
    ) -> MyNotesSourceChapter? {
        guard let dimensions = JSwordCanon.bookDimensions(
                  versification: source.versification
              ),
              let kjvBooks = JSwordCanon.bookDimensions(versification: "KJV"),
              let currentIndex = dimensions.firstIndex(where: {
                  $0.osisBookId == source.osisBookId
              }),
              (0...dimensions[currentIndex].lastChapter).contains(source.chapter) else {
            return nil
        }
        let kjvScriptureIDs = Set(kjvBooks.map(\.osisBookId))
        let currentIsKJVScripture = kjvScriptureIDs.contains(source.osisBookId)
        if source.chapter > 1 {
            return MyNotesSourceChapter(
                versification: source.versification,
                osisBookId: source.osisBookId,
                chapter: source.chapter - 1
            )
        }
        if let previousBook = dimensions[..<currentIndex].reversed().first(where: {
            eligibleBookOSISIDs.contains($0.osisBookId)
                && kjvScriptureIDs.contains($0.osisBookId) == currentIsKJVScripture
        }) {
            return MyNotesSourceChapter(
                versification: source.versification,
                osisBookId: previousBook.osisBookId,
                chapter: previousBook.lastChapter
            )
        }
        return source
    }
}
