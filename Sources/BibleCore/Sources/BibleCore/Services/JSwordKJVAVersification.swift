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
enum JSwordKJVAVersification {
    /// Android and JSword name for this versification.
    static let name = "KJVA"

    /// Real books in JSword `SystemKJVA`, including deuterocanonical books.
    static let canonicalBookCount = 80

    /// JSword book-list entries after adding Bible, OT, and NT introduction pseudo-books.
    static let bookCount = canonicalBookCount + 3

    /// Real chapters in JSword `SystemKJVA`, excluding chapter 0 introductions.
    static let chapterCount = 1_371

    /// Real verses in JSword `SystemKJVA`, excluding introduction ordinals.
    static let verseCount = 36_819

    /// JSword introduction ordinals contributed by book chapter 0 and real chapter verse 0.
    static let introductionOrdinalCount = bookCount + chapterCount

    /// Addressable JSword ordinals, including ordinal 0 for the Bible introduction.
    static let addressableOrdinalCount = verseCount + introductionOrdinalCount

    /// Highest ordinal returned by JSword `Versification.maximumOrdinal()` for `SystemKJVA`.
    static let maximumOrdinal = addressableOrdinalCount - 1

    /// Full JSword KJVA ordinal domain, including the Bible introduction at ordinal 0.
    static let ordinalRange = 0...maximumOrdinal

    /// Android progress rows normally store verse/range ordinals, not the Bible intro sentinel 0.
    static let progressOrdinalRange = 1...maximumOrdinal

    /**
     Checks whether an ordinal is addressable by JSword `SystemKJVA`.

     - Parameter ordinal: Candidate JSword KJVA ordinal.
     - Returns: `true` for the full `0...maximumOrdinal` JSword address space.
     - Side effects: none.
     - Failure modes: none.
     */
    static func containsOrdinal(_ ordinal: Int) -> Bool {
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
    static func containsProgressOrdinal(_ ordinal: Int) -> Bool {
        progressOrdinalRange.contains(ordinal)
    }
}
