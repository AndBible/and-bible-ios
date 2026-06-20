// JSwordKJVAVersification.swift - Android JSword KJVA ordinal compatibility contract

/**
 JSword `SystemKJVA` ordinal metadata used by Android database compatibility code.

 Android progress and bookmark data is normalized through JSword's `KJVA` versification. iOS does
 not embed JSword, so this contract carries the source-derived constants needed to validate Android
 KJVA ordinals without switching to SWORD's different address space.

 The counts mirror JSword's local source:
 - `SystemKJVA` uses 80 canonical/deuterocanonical books.
 - `Versification` adds `INTRO_BIBLE`, `INTRO_OT`, and `INTRO_NT` pseudo-books.
 - every book and pseudo-book has chapter 0, and every real chapter has verse 0.

 - Returns: Static JSword KJVA ordinal metadata for Android-compatible persistence.
 - Side effects: none.
 - Failure modes: none.
 */
public enum JSwordKJVAVersification {
    /// Android and JSword name for this versification.
    public static let name = "KJVA"

    /// Real books in JSword `SystemKJVA`, including deuterocanonical books.
    public static let canonicalBookCount = 80

    /// JSword book-list entries after adding Bible, OT, and NT introduction pseudo-books.
    public static let bookCount = canonicalBookCount + 3

    /// Real chapters in JSword `SystemKJVA`, excluding chapter 0 introductions.
    public static let chapterCount = 1_371

    /// Real verses in JSword `SystemKJVA`, excluding introduction ordinals.
    public static let verseCount = 36_819

    /// JSword introduction ordinals contributed by book chapter 0 and real chapter verse 0.
    public static let introductionOrdinalCount = bookCount + chapterCount

    /// Addressable JSword ordinals, including ordinal 0 for the Bible introduction.
    public static let addressableOrdinalCount = verseCount + introductionOrdinalCount

    /// Highest ordinal returned by JSword `Versification.maximumOrdinal()` for `SystemKJVA`.
    public static let maximumOrdinal = addressableOrdinalCount - 1

    /// Full JSword KJVA ordinal domain, including the Bible introduction at ordinal 0.
    public static let ordinalRange = 0...maximumOrdinal

    /// Android progress rows normally store verse/range ordinals, not the Bible intro sentinel 0.
    public static let progressOrdinalRange = 1...maximumOrdinal

    /// First KJVA table index that belongs to the New Testament, before which JSword inserts `INTRO_NT`.
    private static let firstNewTestamentTableIndex = 53

    /// Lookup from canonical or accepted alias OSIS id to the KJVA table index.
    private static let bookIndexByOsisId: [String: Int] = {
        var result = Dictionary(
            uniqueKeysWithValues: JSwordKJVAVersificationData.bookTable.enumerated().map { index, book in
                (book.osisId, index)
            }
        )
        for (alias, canonical) in JSwordKJVAVersificationData.canonicalOsisAliases {
            result[alias] = result[canonical]
        }
        return result
    }()

    /// Cached KJVA ordinal offsets by source table index.
    private static let ordinalIndexByBookIndex: [Int: JSwordKJVAOrdinalBookIndex] = {
        var result: [Int: JSwordKJVAOrdinalBookIndex] = [:]
        var ordinal = 0
        ordinal += 1 // INTRO_OT book-introduction ordinal.

        for (index, book) in JSwordKJVAVersificationData.bookTable.enumerated() {
            if index == firstNewTestamentTableIndex {
                ordinal += 1 // INTRO_NT book-introduction ordinal.
            }

            ordinal += 1 // Current book chapter-0 introduction ordinal.
            var chapterStartOrdinals: [Int] = []
            chapterStartOrdinals.reserveCapacity(book.chapterVerseCounts.count)

            for lastVerse in book.chapterVerseCounts {
                ordinal += 1 // Current chapter verse-0 introduction ordinal.
                chapterStartOrdinals.append(ordinal + 1)
                ordinal += lastVerse
            }

            result[index] = JSwordKJVAOrdinalBookIndex(
                book: book,
                chapterStartOrdinals: chapterStartOrdinals
            )
        }

        return result
    }()

    /**
     Checks whether an ordinal is addressable by JSword `SystemKJVA`.

     - Parameter ordinal: Candidate JSword KJVA ordinal.
     - Returns: `true` for the full `0...maximumOrdinal` JSword address space.
     - Side effects: none.
     - Failure modes: none.
     */
    public static func containsOrdinal(_ ordinal: Int) -> Bool {
        ordinalRange.contains(ordinal)
    }

    /**
     Checks whether an ordinal is valid for Android progress database rows.

     Android progress flows create rows from rendered verses/ranges, so iOS accepts the same
     JSword KJVA address space while excluding ordinal 0's global Bible introduction sentinel.

     - Parameter ordinal: Candidate Android `progress.sqlite3` ordinal.
     - Returns: `true` when the ordinal can be represented as Android progress data.
     - Side effects: none.
     - Failure modes: none.
     */
    public static func containsProgressOrdinal(_ ordinal: Int) -> Bool {
        progressOrdinalRange.contains(ordinal)
    }

    /**
     Returns JSword's `BibleBook.ordinal()` value for an OSIS id.

     Android stores this ordinal on chapter-reading rows independently from the KJVA verse ordinal
     address space. The deuterocanonical `BibleBook` enum order differs from `SystemKJVA` book
     order, so callers must use this explicit lookup rather than deriving the value from table
     position.

     - Parameter osisId: Canonical OSIS id or supported alias such as `WisSol`.
     - Returns: JSword `BibleBook.ordinal()` or `nil` when the id is outside `SystemKJVA`.
     - Side effects: none.
     - Failure modes: Unknown ids return `nil`.
     */
    public static func bibleBookOrdinal(forOsisId osisId: String) -> Int? {
        if let aliasOrdinal = JSwordKJVAVersificationData.bibleBookOrdinalAliases[osisId] {
            return aliasOrdinal
        }
        guard let index = bookIndexByOsisId[osisId] else {
            return nil
        }
        return JSwordKJVAVersificationData.bookTable[index].bibleBookOrdinal
    }

    /**
     Returns the last one-based chapter number for a KJVA book.

     - Parameter osisId: Canonical OSIS id or supported alias.
     - Returns: Chapter count for the book, or `nil` for unsupported ids.
     - Side effects: none.
     - Failure modes: Unknown ids return `nil`.
     */
    public static func lastChapter(osisId: String) -> Int? {
        book(forOsisId: osisId)?.chapterVerseCounts.count
    }

    /**
     Returns the last one-based verse number for a KJVA chapter.

     - Parameters:
       - osisId: Canonical OSIS id or supported alias.
       - chapter: One-based chapter number.
     - Returns: Last verse number for the chapter, or `nil` for unsupported ids/chapters.
     - Side effects: none.
     - Failure modes: Unknown ids and out-of-range chapters return `nil`.
     */
    public static func verseCount(osisId: String, chapter: Int) -> Int? {
        guard chapter > 0,
              let book = book(forOsisId: osisId),
              chapter <= book.chapterVerseCounts.count else {
            return nil
        }
        return book.chapterVerseCounts[chapter - 1]
    }

    /**
     Returns the number of real verses in a KJVA book.

     Android book-level memorization progress divides memorized verse ordinals by this count.

     - Parameter osisId: Canonical OSIS id or supported alias.
     - Returns: Sum of all chapter verse counts, or `nil` for unsupported ids.
     - Side effects: none.
     - Failure modes: Unknown ids return `nil`.
     */
    public static func bookVerseCount(osisId: String) -> Int? {
        book(forOsisId: osisId)?.chapterVerseCounts.reduce(0, +)
    }

    /**
     Computes JSword's KJVA ordinal for a verse reference.

     JSword reserves ordinal `0` for `INTRO_BIBLE`, inserts `INTRO_OT` before Genesis, inserts
     `INTRO_NT` before Matthew, gives every real book a chapter-0 introduction ordinal, and gives
     every real chapter a verse-0 introduction ordinal. Real verse ordinals are then counted in
     `SystemKJVA` book order.

     - Parameters:
       - osisId: Canonical OSIS id or supported alias.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: JSword KJVA ordinal for the verse, or `nil` when the reference is invalid.
     - Side effects: none.
     - Failure modes: Unknown ids and out-of-range chapters/verses return `nil`.
     */
    public static func verseOrdinal(osisId: String, chapter: Int, verse: Int) -> Int? {
        guard chapter > 0,
              verse > 0,
              let targetIndex = bookIndexByOsisId[osisId],
              let ordinalIndex = ordinalIndexByBookIndex[targetIndex],
              chapter <= ordinalIndex.book.chapterVerseCounts.count else {
            return nil
        }

        let lastVerse = ordinalIndex.book.chapterVerseCounts[chapter - 1]
        guard verse <= lastVerse else {
            return nil
        }
        return ordinalIndex.chapterStartOrdinals[chapter - 1] + verse - 1
    }

    /**
     Computes the JSword KJVA ordinal range for a chapter's real verses.

     - Parameters:
       - osisId: Canonical OSIS id or supported alias.
       - chapter: One-based chapter number.
     - Returns: Closed range from verse 1 through the chapter's last verse, or `nil` when invalid.
     - Side effects: none.
     - Failure modes: Unknown ids and out-of-range chapters return `nil`.
     */
    public static func verseOrdinalRange(osisId: String, chapter: Int) -> ClosedRange<Int>? {
        guard chapter > 0,
              let targetIndex = bookIndexByOsisId[osisId],
              let ordinalIndex = ordinalIndexByBookIndex[targetIndex],
              chapter <= ordinalIndex.book.chapterVerseCounts.count else {
            return nil
        }
        let lastVerse = ordinalIndex.book.chapterVerseCounts[chapter - 1]
        let start = ordinalIndex.chapterStartOrdinals[chapter - 1]
        let end = start + lastVerse - 1
        return start...end
    }

    /**
     Computes the JSword KJVA ordinal range for a whole book's real verses.

     - Parameter osisId: Canonical OSIS id or supported alias.
     - Returns: Closed range from the first verse through the last verse, or `nil` when invalid.
     - Side effects: none.
     - Failure modes: Unknown ids or books without chapters return `nil`.
     */
    public static func verseOrdinalRange(osisId: String) -> ClosedRange<Int>? {
        guard let targetIndex = bookIndexByOsisId[osisId],
              let ordinalIndex = ordinalIndexByBookIndex[targetIndex],
              let start = ordinalIndex.chapterStartOrdinals.first,
              let lastChapterStart = ordinalIndex.chapterStartOrdinals.last,
              let lastVerse = ordinalIndex.book.chapterVerseCounts.last else {
            return nil
        }
        let end = lastChapterStart + lastVerse - 1
        return start...end
    }

    /**
     Resolves a source-derived KJVA book entry.

     - Parameter osisId: Canonical OSIS id or supported alias.
     - Returns: KJVA table row, or `nil` when unsupported.
     - Side effects: none.
     - Failure modes: Unknown ids return `nil`.
     */
    private static func book(forOsisId osisId: String) -> JSwordKJVABookData? {
        guard let index = bookIndexByOsisId[osisId] else {
            return nil
        }
        return JSwordKJVAVersificationData.bookTable[index]
    }
}

/// Cached per-book KJVA ordinal offsets derived from JSword's `SystemKJVA` table.
private struct JSwordKJVAOrdinalBookIndex: Sendable {
    /// Source book row used for chapter and verse bounds checks.
    let book: JSwordKJVABookData

    /// One-based verse-1 ordinal for each real chapter in the book.
    let chapterStartOrdinals: [Int]
}
