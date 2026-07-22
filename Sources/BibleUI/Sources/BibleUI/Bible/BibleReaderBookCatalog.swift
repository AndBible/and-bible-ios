// BibleReaderBookCatalog.swift -- Active Bible book and versification lookup boundary

import BibleCore
import SwordKit

/**
 Owns reader book metadata and active-versification lookups for a Bible pane.

 Android obtains this class of data from JSword `Versification`, `BibleBook`, and `Verse` APIs.
 iOS mirrors that by asking the active `SwordModule` first whenever a Bible module is loaded, and
 by using a documented static 66-book compatibility catalog only when no active module exists.
 Keeping the fallback here prevents controller and UI code from silently mixing static KJV metadata
 into a live module with a different canon or verse system.
 */
struct BibleReaderBookCatalog {
    /// Active SWORD Bible module whose versification should be authoritative.
    private let activeModule: SwordModule?

    /// Ordered book list read from the active module's SWORD/JSword-compatible versification.
    private let moduleBookList: [BookInfo]

    /// Whether a non-SWORD active module owns JSword's exact KJVA ordinal domain.
    private let usesExactKJVAOrdinals: Bool

    /**
     Creates a catalog view over the current reader module state.

     - Parameters:
       - activeModule: Active Bible module, or `nil` when no Bible module is available.
       - moduleBookList: Book list previously read from `activeModule.getBookList()`.
       - usesExactKJVAOrdinals: True only for an active Android-compatible SQLite Bible whose
         source coordinates are defined by JSword KJVA.
     - Side effects: None during construction; lookup methods may query `activeModule`.
     - Failure modes: Empty active-module book lists remain empty so callers do not fall back to a
       static canon while a module is active.
     */
    init(
        activeModule: SwordModule?,
        moduleBookList: [BookInfo],
        usesExactKJVAOrdinals: Bool = false
    ) {
        self.activeModule = activeModule
        self.moduleBookList = moduleBookList
        self.usesExactKJVAOrdinals = usesExactKJVAOrdinals
    }

    /// Active ordered books: module books when available, the static fallback only with no module.
    var books: [BookInfo] {
        if !moduleBookList.isEmpty {
            return moduleBookList
        }
        return activeModule == nil && !usesExactKJVAOrdinals ? Self.defaultBooks : []
    }

    /**
     Resolves a verse ordinal through active SWORD versification.

     - Parameters:
       - osisBookId: OSIS book identifier such as `Gen` or `1Cor`.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: SWORD/JSword intro-inclusive ordinal when a module is active, compatibility ordinal
       only when no module exists, or `nil` for invalid active-module references.
     - Side effects: May temporarily move the active SWORD module cursor; `SwordModule` restores it.
     */
    func verseOrdinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        if let activeModule {
            return activeModule.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
        }
        if usesExactKJVAOrdinals {
            return JSwordKJVAVersification.verseOrdinal(
                osisId: osisBookId,
                chapter: chapter,
                verse: verse
            )
        }
        return Self.compatibilityOrdinal(chapter: chapter, verse: verse)
    }

    /**
     Resolves a persisted ordinal back to a verse in the requested book.

     - Parameters:
       - book: Display book name from the active catalog.
       - ordinal: SWORD/JSword-style ordinal or no-module compatibility ordinal.
     - Returns: Verse reference constrained to `book`, or `nil` when invalid.
     - Side effects: May temporarily move the active SWORD module cursor; `SwordModule` restores it.
     */
    func verseReference(book: String, ordinal: Int) -> VerseKeyReference? {
        guard ordinal > 0 else { return nil }
        let osisBookId = osisBookId(for: book)
        if let activeModule {
            return activeModule.verseReference(osisBookId: osisBookId, ordinal: ordinal)
        }

        if usesExactKJVAOrdinals {
            guard let reference = JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: ordinal
            ), reference.osisId == osisBookId else {
                return nil
            }
            return VerseKeyReference(
                osisBookId: reference.osisId,
                chapter: reference.chapter,
                verse: reference.verse,
                ordinal: reference.ordinal
            )
        }

        let chapter = max(1, ((ordinal - 1) / 40) + 1)
        let verse = ordinal - ((chapter - 1) * 40)
        guard verse > 0 else { return nil }
        return VerseKeyReference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    /**
     Resolves the ordinal range for a chapter.

     - Parameters:
       - book: Display book name from the active catalog.
       - chapter: One-based chapter number.
       - verseCount: Optional already-resolved last verse.
     - Returns: Start/end ordinals and verse count, or `nil` when an active module cannot resolve
       the chapter exactly.
     - Side effects: May query the active SWORD module for verse counts and ordinals.
     */
    func chapterOrdinalRange(book: String, chapter: Int, verseCount: Int? = nil) -> (start: Int, end: Int, verseCount: Int)? {
        let osisBookId = osisBookId(for: book)
        let resolvedVerseCount: Int
        if let verseCount {
            resolvedVerseCount = verseCount
        } else if let activeModule {
            guard let moduleVerseCount = activeModule.verseCount(osisBookId: osisBookId, chapter: chapter) else {
                return nil
            }
            resolvedVerseCount = moduleVerseCount
        } else if usesExactKJVAOrdinals {
            guard let kjvaVerseCount = JSwordKJVAVersification.verseCount(
                osisId: osisBookId,
                chapter: chapter
            ) else {
                return nil
            }
            resolvedVerseCount = kjvaVerseCount
        } else {
            resolvedVerseCount = Self.verseCount(for: book, chapter: chapter)
        }
        guard let ordinalStart = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: 1),
              let ordinalEnd = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: resolvedVerseCount) else {
            return nil
        }
        return (ordinalStart, ordinalEnd, resolvedVerseCount)
    }

    /**
     Resolves chapter count from active module metadata.

     - Parameter book: Display book name.
     - Returns: Active-module chapter count, static fallback only without a module, or `0` when an
       active module does not expose the book.
     */
    func chapterCount(for book: String) -> Int {
        if let chapterCount = books.first(where: { $0.name == book })?.chapterCount {
            return chapterCount
        }
        return activeModule == nil && !usesExactKJVAOrdinals ? Self.chapterCount(for: book) : 0
    }

    /// Next book after `book` in the active catalog order.
    func nextBook(after book: String) -> String? {
        guard let index = books.firstIndex(where: { $0.name == book }), index + 1 < books.count else { return nil }
        return books[index + 1].name
    }

    /// Previous book before `book` in the active catalog order.
    func previousBook(before book: String) -> String? {
        guard let index = books.firstIndex(where: { $0.name == book }), index > 0 else { return nil }
        return books[index - 1].name
    }

    /**
     Resolves an OSIS book identifier.

     - Parameter bookName: Display book name.
     - Returns: Active catalog OSIS id, static fallback only without a module, or an empty string
       when an active module does not contain the book.
     */
    func osisBookId(for bookName: String) -> String {
        if let osisId = books.first(where: { $0.name == bookName })?.osisId {
            return osisId
        }
        return activeModule == nil && !usesExactKJVAOrdinals
            ? Self.osisBookId(for: bookName)
            : ""
    }

    /// JSword/KJVA book ordinal used by Android-compatible reading-progress persistence.
    func kjvBookOrdinal(for bookName: String) -> Int? {
        Self.jswordBibleBookOrdinalByOsisId[osisBookId(for: bookName)]
    }

    /// Reverse lookup from OSIS id to active catalog display name.
    func bookName(forOsisId osisId: String) -> String? {
        books.first(where: { $0.osisId == osisId })?.name
    }

    /// Whether `bookName` belongs to the New Testament in the active catalog.
    func isNewTestament(_ bookName: String) -> Bool {
        books.first(where: { $0.name == bookName })?.isNewTestament ?? false
    }

    /**
     Returns the verse count for a chapter using active module versification.

     - Parameters:
       - book: Display book name.
       - chapter: One-based chapter number.
     - Returns: Active-module last verse, static fallback only without a module, or `nil` when the
       active module cannot resolve the chapter.
     - Side effects: May temporarily move the active module cursor through `SwordModule`.
     */
    func verseCount(book: String, chapter: Int) -> Int? {
        let osisId = osisBookId(for: book)
        if let activeModule {
            guard let count = activeModule.verseCount(osisBookId: osisId, chapter: chapter),
                  count > 0 else {
                return nil
            }
            return count
        }
        if usesExactKJVAOrdinals {
            guard let count = JSwordKJVAVersification.verseCount(
                osisId: osisId,
                chapter: chapter
            ), count > 0 else {
                return nil
            }
            return count
        }
        return Self.verseCount(for: book, chapter: chapter)
    }

    /// Legacy ordinal fallback used only when no SWORD verse-key module can resolve a reference.
    static func compatibilityOrdinal(chapter: Int, verse: Int) -> Int {
        BibleChapterDocumentBuilder.ordinal(chapter: chapter, verse: verse)
    }

    /// Static chapter count using the default 66-book Protestant list.
    static func chapterCount(for book: String) -> Int {
        defaultBooks.first(where: { $0.name == book })?.chapterCount ?? 1
    }

    /// Static OSIS book ID lookup using the default list.
    static func osisBookId(for bookName: String) -> String {
        defaultBooks.first(where: { $0.name == bookName })?.osisId ?? bookName.prefix(3).description
    }

    /// Static reverse lookup using the default list.
    static func bookName(forOsisId osisId: String) -> String? {
        defaultBooks.first(where: { $0.osisId == osisId })?.name
    }

    /// Static New Testament check using the default list.
    static func isNewTestament(_ bookName: String) -> Bool {
        defaultBooks.first(where: { $0.name == bookName })?.isNewTestament ?? false
    }

    /// Static verse count for no-module placeholder rendering. Defaults to 30 if unknown.
    static func verseCount(for book: String, chapter: Int) -> Int {
        let key = "\(osisBookId(for: book)).\(chapter)"
        return knownVerseCounts[key] ?? 30
    }

    /// Default 66-book Protestant canon, used as fallback when no module is loaded.
    static let defaultBooks: [BookInfo] = {
        let books: [(String, String, String, Int, Int)] = [
            ("Genesis", "Gen", "Gen", 50, 1), ("Exodus", "Exod", "Exod", 40, 1),
            ("Leviticus", "Lev", "Lev", 27, 1), ("Numbers", "Num", "Num", 36, 1),
            ("Deuteronomy", "Deut", "Deut", 34, 1), ("Joshua", "Josh", "Josh", 24, 1),
            ("Judges", "Judg", "Judg", 21, 1), ("Ruth", "Ruth", "Ruth", 4, 1),
            ("1 Samuel", "1Sam", "1Sam", 31, 1), ("2 Samuel", "2Sam", "2Sam", 24, 1),
            ("1 Kings", "1Kgs", "1Kgs", 22, 1), ("2 Kings", "2Kgs", "2Kgs", 25, 1),
            ("1 Chronicles", "1Chr", "1Chr", 29, 1), ("2 Chronicles", "2Chr", "2Chr", 36, 1),
            ("Ezra", "Ezra", "Ezra", 10, 1), ("Nehemiah", "Neh", "Neh", 13, 1),
            ("Esther", "Esth", "Esth", 10, 1), ("Job", "Job", "Job", 42, 1),
            ("Psalms", "Ps", "Ps", 150, 1), ("Proverbs", "Prov", "Prov", 31, 1),
            ("Ecclesiastes", "Eccl", "Eccl", 12, 1), ("Song of Solomon", "Song", "Song", 8, 1),
            ("Isaiah", "Isa", "Isa", 66, 1), ("Jeremiah", "Jer", "Jer", 52, 1),
            ("Lamentations", "Lam", "Lam", 5, 1), ("Ezekiel", "Ezek", "Ezek", 48, 1),
            ("Daniel", "Dan", "Dan", 12, 1), ("Hosea", "Hos", "Hos", 14, 1),
            ("Joel", "Joel", "Joel", 3, 1), ("Amos", "Amos", "Amos", 9, 1),
            ("Obadiah", "Obad", "Obad", 1, 1), ("Jonah", "Jonah", "Jonah", 4, 1),
            ("Micah", "Mic", "Mic", 7, 1), ("Nahum", "Nah", "Nah", 3, 1),
            ("Habakkuk", "Hab", "Hab", 3, 1), ("Zephaniah", "Zeph", "Zeph", 3, 1),
            ("Haggai", "Hag", "Hag", 2, 1), ("Zechariah", "Zech", "Zech", 14, 1),
            ("Malachi", "Mal", "Mal", 4, 1),
            ("Matthew", "Matt", "Matt", 28, 2), ("Mark", "Mark", "Mark", 16, 2),
            ("Luke", "Luke", "Luke", 24, 2), ("John", "John", "John", 21, 2),
            ("Acts", "Acts", "Acts", 28, 2), ("Romans", "Rom", "Rom", 16, 2),
            ("1 Corinthians", "1Cor", "1Cor", 16, 2), ("2 Corinthians", "2Cor", "2Cor", 13, 2),
            ("Galatians", "Gal", "Gal", 6, 2), ("Ephesians", "Eph", "Eph", 6, 2),
            ("Philippians", "Phil", "Phil", 4, 2), ("Colossians", "Col", "Col", 4, 2),
            ("1 Thessalonians", "1Thess", "1Thess", 5, 2), ("2 Thessalonians", "2Thess", "2Thess", 3, 2),
            ("1 Timothy", "1Tim", "1Tim", 6, 2), ("2 Timothy", "2Tim", "2Tim", 4, 2),
            ("Titus", "Titus", "Titus", 3, 2), ("Philemon", "Phlm", "Phlm", 1, 2),
            ("Hebrews", "Heb", "Heb", 13, 2), ("James", "Jas", "Jas", 5, 2),
            ("1 Peter", "1Pet", "1Pet", 5, 2), ("2 Peter", "2Pet", "2Pet", 3, 2),
            ("1 John", "1John", "1John", 5, 2), ("2 John", "2John", "2John", 1, 2),
            ("3 John", "3John", "3John", 1, 2), ("Jude", "Jude", "Jude", 1, 2),
            ("Revelation", "Rev", "Rev", 22, 2),
        ]
        return books.map { BookInfo(name: $0.0, osisId: $0.1, abbreviation: $0.2, chapterCount: $0.3, testament: $0.4) }
    }()

    /// JSword `BibleBook.ordinal` values persisted by Android reading-progress rows.
    private static let jswordBibleBookOrdinalByOsisId: [String: Int] = [
        "Gen": 2, "Exod": 3, "Lev": 4, "Num": 5, "Deut": 6,
        "Josh": 7, "Judg": 8, "Ruth": 9, "1Sam": 10, "2Sam": 11,
        "1Kgs": 12, "2Kgs": 13, "1Chr": 14, "2Chr": 15, "Ezra": 16,
        "Neh": 17, "Esth": 18, "Job": 19, "Ps": 20, "Prov": 21,
        "Eccl": 22, "Song": 23, "Isa": 24, "Jer": 25, "Lam": 26,
        "Ezek": 27, "Dan": 28, "Hos": 29, "Joel": 30, "Amos": 31,
        "Obad": 32, "Jonah": 33, "Mic": 34, "Nah": 35, "Hab": 36,
        "Zeph": 37, "Hag": 38, "Zech": 39, "Mal": 40,
        "Matt": 42, "Mark": 43, "Luke": 44, "John": 45, "Acts": 46,
        "Rom": 47, "1Cor": 48, "2Cor": 49, "Gal": 50, "Eph": 51,
        "Phil": 52, "Col": 53, "1Thess": 54, "2Thess": 55,
        "1Tim": 56, "2Tim": 57, "Titus": 58, "Phlm": 59, "Heb": 60,
        "Jas": 61, "1Pet": 62, "2Pet": 63, "1John": 64,
        "2John": 65, "3John": 66, "Jude": 67, "Rev": 68,
        "1Esd": 84, "2Esd": 85, "Tob": 69, "Jdt": 70, "AddEsth": 71,
        "Wis": 72, "WisSol": 72, "Sir": 73, "Bar": 74, "EpJer": 75,
        "PrAzar": 76, "Sus": 77, "Bel": 78, "PrMan": 83,
        "1Macc": 79, "2Macc": 80,
    ]

    /// Partial static verse-count table used only for no-module placeholder rendering.
    private static let knownVerseCounts: [String: Int] = [
        "Gen.1": 31, "Gen.2": 25, "Gen.3": 24, "Gen.4": 26, "Gen.5": 32,
        "Gen.6": 22, "Gen.7": 24, "Gen.8": 22, "Gen.9": 29, "Gen.10": 32,
        "Gen.11": 32, "Gen.12": 20, "Gen.50": 26,
        "Ps.1": 6, "Ps.23": 6, "Ps.91": 16, "Ps.119": 176, "Ps.150": 6,
        "Prov.1": 33, "Prov.3": 35, "Prov.31": 31,
        "Isa.1": 31, "Isa.40": 31, "Isa.53": 12,
        "Matt.1": 25, "Matt.5": 48, "Matt.6": 34, "Matt.28": 20,
        "Mark.1": 45, "Mark.16": 20,
        "Luke.1": 80, "Luke.2": 52, "Luke.24": 53,
        "John.1": 51, "John.3": 36, "John.14": 31, "John.21": 25,
        "Acts.1": 26, "Acts.2": 47,
        "Rom.1": 32, "Rom.8": 39, "Rom.12": 21,
        "1Cor.13": 13, "1Cor.15": 58,
        "Eph.1": 23, "Eph.6": 24,
        "Phil.4": 23,
        "Heb.11": 40,
        "Rev.1": 20, "Rev.21": 27, "Rev.22": 21,
    ]
}
