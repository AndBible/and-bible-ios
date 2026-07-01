// JSwordKJVAVersificationData.swift - Source-derived JSword KJVA chapter table

/**
 One JSword `SystemKJVA` book entry used for Android-compatible ordinal calculations.

 `bibleBookOrdinal` is JSword `BibleBook.ordinal()`, while `chapterVerseCounts` follows
 `SystemKJVA` versification order. The two orders differ for deuterocanonical books, so both
 values are stored explicitly instead of deriving one from the other.
*/
struct JSwordKJVABookData: Equatable, Sendable {
    /// OSIS identifier used by SWORD, JSword, and imported Android progress rows.
    let osisId: String

    /// JSword `BibleBook.ordinal()` value persisted by Android reading-progress rows.
    let bibleBookOrdinal: Int

    /// Last verse number for each one-based chapter in this KJVA book.
    let chapterVerseCounts: [Int]
}

/**
 Source-derived table for JSword `SystemKJVA`.

 The data is generated from the local JSword source tree used for Android parity and mirrors
 `SystemKJVA` book order: KJV Old Testament, deuterocanonical books, then New Testament.
 It has no runtime side effects; callers use it only for deterministic ordinal math.
*/
enum JSwordKJVAVersificationData {
    /// Canonical OSIS aliases accepted by Android import and progress compatibility code.
    static let canonicalOsisAliases: [String: String] = [
        "WisSol": "Wis",
    ]

    /// JSword `BibleBook.ordinal()` aliases for books not represented as standalone KJVA table entries.
    static let bibleBookOrdinalAliases: [String: Int] = [
        "EpJer": 75,
        "WisSol": 72,
    ]

    /// JSword English `BibleNames.properties` long and short names for KJVA display parity.
    static let displayNamesByOsisId: [String: (long: String, short: String)] = [
        "Gen": (long: "Genesis", short: "Gen"),
        "Exod": (long: "Exodus", short: "Exo"),
        "Lev": (long: "Leviticus", short: "Lev"),
        "Num": (long: "Numbers", short: "Num"),
        "Deut": (long: "Deuteronomy", short: "Deu"),
        "Josh": (long: "Joshua", short: "Jos"),
        "Judg": (long: "Judges", short: "Judg"),
        "Ruth": (long: "Ruth", short: "Rut"),
        "1Sam": (long: "1 Samuel", short: "1 Sa"),
        "2Sam": (long: "2 Samuel", short: "2 Sa"),
        "1Kgs": (long: "1 Kings", short: "1 Ki"),
        "2Kgs": (long: "2 Kings", short: "2 Ki"),
        "1Chr": (long: "1 Chronicles", short: "1 Ch"),
        "2Chr": (long: "2 Chronicles", short: "2 Ch"),
        "Ezra": (long: "Ezra", short: "Ezr"),
        "Neh": (long: "Nehemiah", short: "Neh"),
        "Esth": (long: "Esther", short: "Est"),
        "Job": (long: "Job", short: "Job"),
        "Ps": (long: "Psalms", short: "Psa"),
        "Prov": (long: "Proverbs", short: "Pro"),
        "Eccl": (long: "Ecclesiastes", short: "Ecc"),
        "Song": (long: "Song of Solomon", short: "Song"),
        "Isa": (long: "Isaiah", short: "Isa"),
        "Jer": (long: "Jeremiah", short: "Jer"),
        "Lam": (long: "Lamentations", short: "Lam"),
        "Ezek": (long: "Ezekiel", short: "Eze"),
        "Dan": (long: "Daniel", short: "Dan"),
        "Hos": (long: "Hosea", short: "Hos"),
        "Joel": (long: "Joel", short: "Joe"),
        "Amos": (long: "Amos", short: "Amo"),
        "Obad": (long: "Obadiah", short: "Obd"),
        "Jonah": (long: "Jonah", short: "Jon"),
        "Mic": (long: "Micah", short: "Mic"),
        "Nah": (long: "Nahum", short: "Nah"),
        "Hab": (long: "Habakkuk", short: "Hab"),
        "Zeph": (long: "Zephaniah", short: "Zep"),
        "Hag": (long: "Haggai", short: "Hag"),
        "Zech": (long: "Zechariah", short: "Zec"),
        "Mal": (long: "Malachi", short: "Mal"),
        "1Esd": (long: "1 Esdras", short: "1 Esd"),
        "2Esd": (long: "2 Esdras", short: "2 Esd"),
        "Tob": (long: "Tobit", short: "Tob"),
        "Jdt": (long: "Judith", short: "Jdt"),
        "AddEsth": (long: "Additions to Esther", short: "Add Est"),
        "Wis": (long: "Wisdom of Solomon", short: "Wis"),
        "Sir": (long: "Sirach", short: "Sir"),
        "Bar": (long: "Baruch", short: "Bar"),
        "PrAzar": (long: "Prayer of Azariah", short: "Pr Azar"),
        "Sus": (long: "Susanna", short: "Sus"),
        "Bel": (long: "Bel and the Dragon", short: "Bel"),
        "PrMan": (long: "Prayer of Manasseh", short: "Pr Man"),
        "1Macc": (long: "1 Maccabees", short: "1 Macc"),
        "2Macc": (long: "2 Maccabees", short: "2 Macc"),
        "Matt": (long: "Matthew", short: "Mat"),
        "Mark": (long: "Mark", short: "Mar"),
        "Luke": (long: "Luke", short: "Luk"),
        "John": (long: "John", short: "Joh"),
        "Acts": (long: "Acts", short: "Act"),
        "Rom": (long: "Romans", short: "Rom"),
        "1Cor": (long: "1 Corinthians", short: "1 Cor"),
        "2Cor": (long: "2 Corinthians", short: "2 Cor"),
        "Gal": (long: "Galatians", short: "Gal"),
        "Eph": (long: "Ephesians", short: "Eph"),
        "Phil": (long: "Philippians", short: "Phili"),
        "Col": (long: "Colossians", short: "Col"),
        "1Thess": (long: "1 Thessalonians", short: "1 Th"),
        "2Thess": (long: "2 Thessalonians", short: "2 Th"),
        "1Tim": (long: "1 Timothy", short: "1 Tim"),
        "2Tim": (long: "2 Timothy", short: "2 Tim"),
        "Titus": (long: "Titus", short: "Tit"),
        "Phlm": (long: "Philemon", short: "Phile"),
        "Heb": (long: "Hebrews", short: "Heb"),
        "Jas": (long: "James", short: "Jam"),
        "1Pet": (long: "1 Peter", short: "1 Pe"),
        "2Pet": (long: "2 Peter", short: "2 Pe"),
        "1John": (long: "1 John", short: "1 Jo"),
        "2John": (long: "2 John", short: "2 Jo"),
        "3John": (long: "3 John", short: "3 Jo"),
        "Jude": (long: "Jude", short: "Jude"),
        "Rev": (long: "Revelation of John", short: "Rev"),
    ]

    /// `SystemKJVA` book table in versification order.
    static let bookTable: [JSwordKJVABookData] = [
        JSwordKJVABookData(osisId: "Gen", bibleBookOrdinal: 2, chapterVerseCounts: [31, 25, 24, 26, 32, 22, 24, 22, 29, 32, 32, 20, 18, 24, 21, 16, 27, 33, 38, 18, 34, 24, 20, 67, 34, 35, 46, 22, 35, 43, 55, 32, 20, 31, 29, 43, 36, 30, 23, 23, 57, 38, 34, 34, 28, 34, 31, 22, 33, 26]),
        JSwordKJVABookData(osisId: "Exod", bibleBookOrdinal: 3, chapterVerseCounts: [22, 25, 22, 31, 23, 30, 25, 32, 35, 29, 10, 51, 22, 31, 27, 36, 16, 27, 25, 26, 36, 31, 33, 18, 40, 37, 21, 43, 46, 38, 18, 35, 23, 35, 35, 38, 29, 31, 43, 38]),
        JSwordKJVABookData(osisId: "Lev", bibleBookOrdinal: 4, chapterVerseCounts: [17, 16, 17, 35, 19, 30, 38, 36, 24, 20, 47, 8, 59, 57, 33, 34, 16, 30, 37, 27, 24, 33, 44, 23, 55, 46, 34]),
        JSwordKJVABookData(osisId: "Num", bibleBookOrdinal: 5, chapterVerseCounts: [54, 34, 51, 49, 31, 27, 89, 26, 23, 36, 35, 16, 33, 45, 41, 50, 13, 32, 22, 29, 35, 41, 30, 25, 18, 65, 23, 31, 40, 16, 54, 42, 56, 29, 34, 13]),
        JSwordKJVABookData(osisId: "Deut", bibleBookOrdinal: 6, chapterVerseCounts: [46, 37, 29, 49, 33, 25, 26, 20, 29, 22, 32, 32, 18, 29, 23, 22, 20, 22, 21, 20, 23, 30, 25, 22, 19, 19, 26, 68, 29, 20, 30, 52, 29, 12]),
        JSwordKJVABookData(osisId: "Josh", bibleBookOrdinal: 7, chapterVerseCounts: [18, 24, 17, 24, 15, 27, 26, 35, 27, 43, 23, 24, 33, 15, 63, 10, 18, 28, 51, 9, 45, 34, 16, 33]),
        JSwordKJVABookData(osisId: "Judg", bibleBookOrdinal: 8, chapterVerseCounts: [36, 23, 31, 24, 31, 40, 25, 35, 57, 18, 40, 15, 25, 20, 20, 31, 13, 31, 30, 48, 25]),
        JSwordKJVABookData(osisId: "Ruth", bibleBookOrdinal: 9, chapterVerseCounts: [22, 23, 18, 22]),
        JSwordKJVABookData(osisId: "1Sam", bibleBookOrdinal: 10, chapterVerseCounts: [28, 36, 21, 22, 12, 21, 17, 22, 27, 27, 15, 25, 23, 52, 35, 23, 58, 30, 24, 42, 15, 23, 29, 22, 44, 25, 12, 25, 11, 31, 13]),
        JSwordKJVABookData(osisId: "2Sam", bibleBookOrdinal: 11, chapterVerseCounts: [27, 32, 39, 12, 25, 23, 29, 18, 13, 19, 27, 31, 39, 33, 37, 23, 29, 33, 43, 26, 22, 51, 39, 25]),
        JSwordKJVABookData(osisId: "1Kgs", bibleBookOrdinal: 12, chapterVerseCounts: [53, 46, 28, 34, 18, 38, 51, 66, 28, 29, 43, 33, 34, 31, 34, 34, 24, 46, 21, 43, 29, 53]),
        JSwordKJVABookData(osisId: "2Kgs", bibleBookOrdinal: 13, chapterVerseCounts: [18, 25, 27, 44, 27, 33, 20, 29, 37, 36, 21, 21, 25, 29, 38, 20, 41, 37, 37, 21, 26, 20, 37, 20, 30]),
        JSwordKJVABookData(osisId: "1Chr", bibleBookOrdinal: 14, chapterVerseCounts: [54, 55, 24, 43, 26, 81, 40, 40, 44, 14, 47, 40, 14, 17, 29, 43, 27, 17, 19, 8, 30, 19, 32, 31, 31, 32, 34, 21, 30]),
        JSwordKJVABookData(osisId: "2Chr", bibleBookOrdinal: 15, chapterVerseCounts: [17, 18, 17, 22, 14, 42, 22, 18, 31, 19, 23, 16, 22, 15, 19, 14, 19, 34, 11, 37, 20, 12, 21, 27, 28, 23, 9, 27, 36, 27, 21, 33, 25, 33, 27, 23]),
        JSwordKJVABookData(osisId: "Ezra", bibleBookOrdinal: 16, chapterVerseCounts: [11, 70, 13, 24, 17, 22, 28, 36, 15, 44]),
        JSwordKJVABookData(osisId: "Neh", bibleBookOrdinal: 17, chapterVerseCounts: [11, 20, 32, 23, 19, 19, 73, 18, 38, 39, 36, 47, 31]),
        JSwordKJVABookData(osisId: "Esth", bibleBookOrdinal: 18, chapterVerseCounts: [22, 23, 15, 17, 14, 14, 10, 17, 32, 3]),
        JSwordKJVABookData(osisId: "Job", bibleBookOrdinal: 19, chapterVerseCounts: [22, 13, 26, 21, 27, 30, 21, 22, 35, 22, 20, 25, 28, 22, 35, 22, 16, 21, 29, 29, 34, 30, 17, 25, 6, 14, 23, 28, 25, 31, 40, 22, 33, 37, 16, 33, 24, 41, 30, 24, 34, 17]),
        JSwordKJVABookData(osisId: "Ps", bibleBookOrdinal: 20, chapterVerseCounts: [6, 12, 8, 8, 12, 10, 17, 9, 20, 18, 7, 8, 6, 7, 5, 11, 15, 50, 14, 9, 13, 31, 6, 10, 22, 12, 14, 9, 11, 12, 24, 11, 22, 22, 28, 12, 40, 22, 13, 17, 13, 11, 5, 26, 17, 11, 9, 14, 20, 23, 19, 9, 6, 7, 23, 13, 11, 11, 17, 12, 8, 12, 11, 10, 13, 20, 7, 35, 36, 5, 24, 20, 28, 23, 10, 12, 20, 72, 13, 19, 16, 8, 18, 12, 13, 17, 7, 18, 52, 17, 16, 15, 5, 23, 11, 13, 12, 9, 9, 5, 8, 28, 22, 35, 45, 48, 43, 13, 31, 7, 10, 10, 9, 8, 18, 19, 2, 29, 176, 7, 8, 9, 4, 8, 5, 6, 5, 6, 8, 8, 3, 18, 3, 3, 21, 26, 9, 8, 24, 13, 10, 7, 12, 15, 21, 10, 20, 14, 9, 6]),
        JSwordKJVABookData(osisId: "Prov", bibleBookOrdinal: 21, chapterVerseCounts: [33, 22, 35, 27, 23, 35, 27, 36, 18, 32, 31, 28, 25, 35, 33, 33, 28, 24, 29, 30, 31, 29, 35, 34, 28, 28, 27, 28, 27, 33, 31]),
        JSwordKJVABookData(osisId: "Eccl", bibleBookOrdinal: 22, chapterVerseCounts: [18, 26, 22, 16, 20, 12, 29, 17, 18, 20, 10, 14]),
        JSwordKJVABookData(osisId: "Song", bibleBookOrdinal: 23, chapterVerseCounts: [17, 17, 11, 16, 16, 13, 13, 14]),
        JSwordKJVABookData(osisId: "Isa", bibleBookOrdinal: 24, chapterVerseCounts: [31, 22, 26, 6, 30, 13, 25, 22, 21, 34, 16, 6, 22, 32, 9, 14, 14, 7, 25, 6, 17, 25, 18, 23, 12, 21, 13, 29, 24, 33, 9, 20, 24, 17, 10, 22, 38, 22, 8, 31, 29, 25, 28, 28, 25, 13, 15, 22, 26, 11, 23, 15, 12, 17, 13, 12, 21, 14, 21, 22, 11, 12, 19, 12, 25, 24]),
        JSwordKJVABookData(osisId: "Jer", bibleBookOrdinal: 25, chapterVerseCounts: [19, 37, 25, 31, 31, 30, 34, 22, 26, 25, 23, 17, 27, 22, 21, 21, 27, 23, 15, 18, 14, 30, 40, 10, 38, 24, 22, 17, 32, 24, 40, 44, 26, 22, 19, 32, 21, 28, 18, 16, 18, 22, 13, 30, 5, 28, 7, 47, 39, 46, 64, 34]),
        JSwordKJVABookData(osisId: "Lam", bibleBookOrdinal: 26, chapterVerseCounts: [22, 22, 66, 22, 22]),
        JSwordKJVABookData(osisId: "Ezek", bibleBookOrdinal: 27, chapterVerseCounts: [28, 10, 27, 17, 17, 14, 27, 18, 11, 22, 25, 28, 23, 23, 8, 63, 24, 32, 14, 49, 32, 31, 49, 27, 17, 21, 36, 26, 21, 26, 18, 32, 33, 31, 15, 38, 28, 23, 29, 49, 26, 20, 27, 31, 25, 24, 23, 35]),
        JSwordKJVABookData(osisId: "Dan", bibleBookOrdinal: 28, chapterVerseCounts: [21, 49, 30, 37, 31, 28, 28, 27, 27, 21, 45, 13]),
        JSwordKJVABookData(osisId: "Hos", bibleBookOrdinal: 29, chapterVerseCounts: [11, 23, 5, 19, 15, 11, 16, 14, 17, 15, 12, 14, 16, 9]),
        JSwordKJVABookData(osisId: "Joel", bibleBookOrdinal: 30, chapterVerseCounts: [20, 32, 21]),
        JSwordKJVABookData(osisId: "Amos", bibleBookOrdinal: 31, chapterVerseCounts: [15, 16, 15, 13, 27, 14, 17, 14, 15]),
        JSwordKJVABookData(osisId: "Obad", bibleBookOrdinal: 32, chapterVerseCounts: [21]),
        JSwordKJVABookData(osisId: "Jonah", bibleBookOrdinal: 33, chapterVerseCounts: [17, 10, 10, 11]),
        JSwordKJVABookData(osisId: "Mic", bibleBookOrdinal: 34, chapterVerseCounts: [16, 13, 12, 13, 15, 16, 20]),
        JSwordKJVABookData(osisId: "Nah", bibleBookOrdinal: 35, chapterVerseCounts: [15, 13, 19]),
        JSwordKJVABookData(osisId: "Hab", bibleBookOrdinal: 36, chapterVerseCounts: [17, 20, 19]),
        JSwordKJVABookData(osisId: "Zeph", bibleBookOrdinal: 37, chapterVerseCounts: [18, 15, 20]),
        JSwordKJVABookData(osisId: "Hag", bibleBookOrdinal: 38, chapterVerseCounts: [15, 23]),
        JSwordKJVABookData(osisId: "Zech", bibleBookOrdinal: 39, chapterVerseCounts: [21, 13, 10, 14, 11, 15, 14, 23, 17, 12, 17, 14, 9, 21]),
        JSwordKJVABookData(osisId: "Mal", bibleBookOrdinal: 40, chapterVerseCounts: [14, 17, 18, 6]),
        JSwordKJVABookData(osisId: "1Esd", bibleBookOrdinal: 84, chapterVerseCounts: [58, 30, 24, 63, 73, 34, 15, 96, 55]),
        JSwordKJVABookData(osisId: "2Esd", bibleBookOrdinal: 85, chapterVerseCounts: [40, 48, 36, 52, 56, 59, 70, 63, 47, 59, 46, 51, 58, 48, 63, 78]),
        JSwordKJVABookData(osisId: "Tob", bibleBookOrdinal: 69, chapterVerseCounts: [22, 14, 17, 21, 22, 17, 18, 21, 6, 12, 19, 22, 18, 15]),
        JSwordKJVABookData(osisId: "Jdt", bibleBookOrdinal: 70, chapterVerseCounts: [16, 28, 10, 15, 24, 21, 32, 36, 14, 23, 23, 20, 20, 19, 13, 25]),
        JSwordKJVABookData(osisId: "AddEsth", bibleBookOrdinal: 71, chapterVerseCounts: [1, 1, 1, 1, 1, 1, 1, 1, 1, 13, 12, 6, 18, 19, 16, 24]),
        JSwordKJVABookData(osisId: "Wis", bibleBookOrdinal: 72, chapterVerseCounts: [16, 24, 19, 20, 23, 25, 30, 21, 18, 21, 26, 27, 19, 31, 19, 29, 21, 25, 22]),
        JSwordKJVABookData(osisId: "Sir", bibleBookOrdinal: 73, chapterVerseCounts: [30, 18, 31, 31, 15, 37, 36, 19, 18, 31, 34, 18, 26, 27, 20, 30, 32, 33, 30, 32, 28, 27, 28, 34, 26, 29, 30, 26, 28, 25, 31, 24, 31, 26, 20, 26, 31, 34, 35, 30, 24, 25, 33, 22, 26, 20, 25, 25, 16, 29, 30]),
        JSwordKJVABookData(osisId: "Bar", bibleBookOrdinal: 74, chapterVerseCounts: [22, 35, 37, 37, 9, 73]),
        JSwordKJVABookData(osisId: "PrAzar", bibleBookOrdinal: 76, chapterVerseCounts: [68]),
        JSwordKJVABookData(osisId: "Sus", bibleBookOrdinal: 77, chapterVerseCounts: [64]),
        JSwordKJVABookData(osisId: "Bel", bibleBookOrdinal: 78, chapterVerseCounts: [42]),
        JSwordKJVABookData(osisId: "PrMan", bibleBookOrdinal: 83, chapterVerseCounts: [1]),
        JSwordKJVABookData(osisId: "1Macc", bibleBookOrdinal: 79, chapterVerseCounts: [64, 70, 60, 61, 68, 63, 50, 32, 73, 89, 74, 53, 53, 49, 41, 24]),
        JSwordKJVABookData(osisId: "2Macc", bibleBookOrdinal: 80, chapterVerseCounts: [36, 32, 40, 50, 27, 31, 42, 36, 29, 38, 38, 45, 26, 46, 39]),
        JSwordKJVABookData(osisId: "Matt", bibleBookOrdinal: 42, chapterVerseCounts: [25, 23, 17, 25, 48, 34, 29, 34, 38, 42, 30, 50, 58, 36, 39, 28, 27, 35, 30, 34, 46, 46, 39, 51, 46, 75, 66, 20]),
        JSwordKJVABookData(osisId: "Mark", bibleBookOrdinal: 43, chapterVerseCounts: [45, 28, 35, 41, 43, 56, 37, 38, 50, 52, 33, 44, 37, 72, 47, 20]),
        JSwordKJVABookData(osisId: "Luke", bibleBookOrdinal: 44, chapterVerseCounts: [80, 52, 38, 44, 39, 49, 50, 56, 62, 42, 54, 59, 35, 35, 32, 31, 37, 43, 48, 47, 38, 71, 56, 53]),
        JSwordKJVABookData(osisId: "John", bibleBookOrdinal: 45, chapterVerseCounts: [51, 25, 36, 54, 47, 71, 53, 59, 41, 42, 57, 50, 38, 31, 27, 33, 26, 40, 42, 31, 25]),
        JSwordKJVABookData(osisId: "Acts", bibleBookOrdinal: 46, chapterVerseCounts: [26, 47, 26, 37, 42, 15, 60, 40, 43, 48, 30, 25, 52, 28, 41, 40, 34, 28, 41, 38, 40, 30, 35, 27, 27, 32, 44, 31]),
        JSwordKJVABookData(osisId: "Rom", bibleBookOrdinal: 47, chapterVerseCounts: [32, 29, 31, 25, 21, 23, 25, 39, 33, 21, 36, 21, 14, 23, 33, 27]),
        JSwordKJVABookData(osisId: "1Cor", bibleBookOrdinal: 48, chapterVerseCounts: [31, 16, 23, 21, 13, 20, 40, 13, 27, 33, 34, 31, 13, 40, 58, 24]),
        JSwordKJVABookData(osisId: "2Cor", bibleBookOrdinal: 49, chapterVerseCounts: [24, 17, 18, 18, 21, 18, 16, 24, 15, 18, 33, 21, 14]),
        JSwordKJVABookData(osisId: "Gal", bibleBookOrdinal: 50, chapterVerseCounts: [24, 21, 29, 31, 26, 18]),
        JSwordKJVABookData(osisId: "Eph", bibleBookOrdinal: 51, chapterVerseCounts: [23, 22, 21, 32, 33, 24]),
        JSwordKJVABookData(osisId: "Phil", bibleBookOrdinal: 52, chapterVerseCounts: [30, 30, 21, 23]),
        JSwordKJVABookData(osisId: "Col", bibleBookOrdinal: 53, chapterVerseCounts: [29, 23, 25, 18]),
        JSwordKJVABookData(osisId: "1Thess", bibleBookOrdinal: 54, chapterVerseCounts: [10, 20, 13, 18, 28]),
        JSwordKJVABookData(osisId: "2Thess", bibleBookOrdinal: 55, chapterVerseCounts: [12, 17, 18]),
        JSwordKJVABookData(osisId: "1Tim", bibleBookOrdinal: 56, chapterVerseCounts: [20, 15, 16, 16, 25, 21]),
        JSwordKJVABookData(osisId: "2Tim", bibleBookOrdinal: 57, chapterVerseCounts: [18, 26, 17, 22]),
        JSwordKJVABookData(osisId: "Titus", bibleBookOrdinal: 58, chapterVerseCounts: [16, 15, 15]),
        JSwordKJVABookData(osisId: "Phlm", bibleBookOrdinal: 59, chapterVerseCounts: [25]),
        JSwordKJVABookData(osisId: "Heb", bibleBookOrdinal: 60, chapterVerseCounts: [14, 18, 19, 16, 14, 20, 28, 13, 28, 39, 40, 29, 25]),
        JSwordKJVABookData(osisId: "Jas", bibleBookOrdinal: 61, chapterVerseCounts: [27, 26, 18, 17, 20]),
        JSwordKJVABookData(osisId: "1Pet", bibleBookOrdinal: 62, chapterVerseCounts: [25, 25, 22, 19, 14]),
        JSwordKJVABookData(osisId: "2Pet", bibleBookOrdinal: 63, chapterVerseCounts: [21, 22, 18]),
        JSwordKJVABookData(osisId: "1John", bibleBookOrdinal: 64, chapterVerseCounts: [10, 29, 24, 21, 21]),
        JSwordKJVABookData(osisId: "2John", bibleBookOrdinal: 65, chapterVerseCounts: [13]),
        JSwordKJVABookData(osisId: "3John", bibleBookOrdinal: 66, chapterVerseCounts: [14]),
        JSwordKJVABookData(osisId: "Jude", bibleBookOrdinal: 67, chapterVerseCounts: [25]),
        JSwordKJVABookData(osisId: "Rev", bibleBookOrdinal: 68, chapterVerseCounts: [20, 29, 22, 11, 14, 17, 17, 13, 21, 11, 19, 17, 18, 20, 8, 21, 18, 24, 21, 15, 27, 21]),
    ]
}
