// MySwordReader.swift -- Android-compatible MySword SQLite database reader

import Foundation

/**
 Reads MySword Bible, commentary, dictionary, and OTHER modules using Android's SQLite loader.

 Android discovers every recursive `.mybible` candidate. The case-sensitive token before that
 extension selects a known schema; every other token remains installed as JSword `OTHER` with no
 content backend. `Details` supplies first-row metadata, and category-specific content schema remains
 lazy until access. Each operation owns an independent read-only connection and statement lifecycle.
 */
public final class MySwordReader: SQLiteDocumentReading {
    /** Filename token that selects an Android MySword schema or the visible OTHER fallback. */
    public enum FileType: String, CaseIterable, Equatable, Sendable {
        /// `*.bbl.mybible` Bible module.
        case bible = "bbl"

        /// `*.cmt.mybible` commentary module.
        case commentary = "cmt"

        /// `*.dct.mybible` dictionary module.
        case dictionary = "dct"

        /// Any unrecognized case-sensitive token; Android registers it as `BookCategory.OTHER`.
        case other = "other"

        /// High-level document category corresponding to this filename token.
        var category: DocumentCategory {
            switch self {
            case .bible: return .bible
            case .commentary: return .commentary
            case .dictionary: return .dictionary
            case .other: return .generalBook
            }
        }

        /** Resolves Android's category token or OTHER beneath a case-insensitive outer suffix. */
        static func resolve(fileName: String) -> Self? {
            guard fileName.lowercased().hasSuffix(".mybible") else { return nil }
            let stem = (fileName as NSString).deletingPathExtension
            return Self(rawValue: (stem as NSString).pathExtension) ?? .other
        }
    }

    /// Open validated MySword database.
    private let database: SQLiteDocumentDatabase

    /// Detected module family derived from the compound filename suffix.
    public let fileType: FileType

    /// Validated immutable metadata suitable for later backend catalog integration.
    public let metadata: SQLiteDocumentMetadata

    /// Filename-selected MySword content category.
    public var category: DocumentCategory { metadata.category }

    /// User-visible module description retained for existing callers.
    public var moduleDescription: String { metadata.description }

    /// Module language retained for existing callers.
    public var language: String { metadata.language }

    /**
     Opens one Android-visible MySword database and reads its first metadata row.

     - Parameter fileURL: Readable file ending in `.mybible`. Android matches the outer suffix
       case-insensitively, requires exact lowercase known category tokens, and maps every other token
       to an installed OTHER book.
     - Side effects: Opens and closes one read-only SQLite handle to validate metadata.
     - Throws: `SQLiteDocumentReaderError` for a missing outer suffix, invalid SQLite, or an
       absent/unreadable first `Details` row. Content schema failures remain lazy.
     */
    public init(fileURL: URL) throws {
        guard let fileType = FileType.resolve(fileName: fileURL.lastPathComponent) else {
            throw SQLiteDocumentReaderError.unsupportedFileName(
                format: .mySword,
                fileName: fileURL.lastPathComponent
            )
        }

        let database = try SQLiteDocumentDatabase(url: fileURL)
        let details = try database.firstDetailsRow(format: .mySword)

        self.database = database
        self.fileType = fileType
        self.metadata = Self.metadata(
            details: details,
            databaseURL: database.url,
            fileType: fileType
        )
    }

    /**
     Preserves the original failable path initializer for current callers.

     - Parameter filePath: Filesystem path to an Android-named MySword database.
     - Side effects: Opens a read-only SQLite handle on success.
     - Failure modes: Returns `nil` for every structured initialization error; catalog code should
       use `init(fileURL:)` when diagnostics are needed.
     */
    public convenience init?(filePath: String) {
        try? self.init(fileURL: URL(fileURLWithPath: filePath))
    }

    /**
     Recursively discovers every filename Android passes to the MySword loader.

     - Parameter directoryURL: MySword module directory.
     - Returns: Readable regular descendants ending in `.mybible`, including generic and
       uppercase-category candidates that Android installs as OTHER books.
     - Side effects: Traverses the filesystem but does not open candidate databases.
     - Failure modes: Missing or unreadable directories return an empty array.
     */
    public static func discover(in directoryURL: URL) -> [URL] {
        SQLiteDocumentDiscovery.recursiveFiles(in: directoryURL) {
            $0.lowercased().hasSuffix(".mybible")
        }
    }

    /**
     Returns deterministic keys from the selected Android MySword content table.

     Commentary rows expose their start verse because range coverage is evaluated during lookup.

     - Returns: Typed keys ordered by coordinate or dictionary word.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     */
    public func keys() throws -> [SQLiteDocumentKey] {
        switch fileType {
        case .bible:
            return try database.rows(
                "SELECT Book, Chapter, Verse FROM Bible ORDER BY Book, Chapter, Verse"
            ) { statement in
                .verse(
                    book: try database.integer(statement, column: 0),
                    chapter: try database.integer(statement, column: 1),
                    verse: try database.integer(statement, column: 2)
                )
            }
        case .commentary:
            return try database.rows(
                """
                SELECT DISTINCT Book, Chapter, FromVerse
                FROM Commentary
                ORDER BY Book, Chapter, FromVerse
                """
            ) { statement in
                .verse(
                    book: try database.integer(statement, column: 0),
                    chapter: try database.integer(statement, column: 1),
                    verse: try database.integer(statement, column: 2)
                )
            }
        case .dictionary:
            return try database.rows("SELECT Word FROM Dictionary") { statement in
                .dictionary(try database.text(statement, column: 0))
            }
        case .other:
            return []
        }
    }

    /**
     Streams distinct MySword Bible chapters with constant transient row memory.

     - Parameter body: Consumer receiving source book and chapter values in numeric order.
     - Side effects: Executes one read-only `Bible` query on an operation-owned connection.
     - Throws: Shared query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func forEachBibleChapter(_ body: (Int, Int) throws -> Bool) throws {
        guard fileType == .bible else { return }
        do {
            try database.consumeRows(
                """
                SELECT DISTINCT Book, Chapter
                FROM Bible
                ORDER BY Book, Chapter
                """,
                transform: { statement in
                    (
                        try database.integer(statement, column: 0),
                        try database.integer(statement, column: 1)
                    )
                },
                consume: {
                    guard try body($0.0, $0.1) else {
                        throw SQLiteDocumentChapterIterationStop.requested
                    }
                }
            )
        } catch SQLiteDocumentChapterIterationStop.requested {
            return
        }
    }

    /**
     Streams books satisfying Android's `DocumentBibleBooks` 1:1-or-1:2 containment probe.

     Commentary predicates mirror `MySwordBook.indexOfCommentary`; dictionary and OTHER books have
     no Bible navigation entries.

     - Parameter body: Consumer receiving each matching one-based MySword book number.
     - Side effects: Executes at most one read-only query and may emit duplicate book numbers.
     - Throws: Shared query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func forEachNavigationBookNumber(_ body: (Int) throws -> Void) throws {
        switch fileType {
        case .bible:
            try database.consumeRows(
                "SELECT Book FROM Bible WHERE Chapter = 1 AND (Verse = 1 OR Verse = 2)",
                transform: { try database.integer($0, column: 0) },
                consume: body
            )
        case .commentary:
            try database.consumeRows(
                """
                SELECT Book FROM Commentary WHERE
                    (Chapter = 1 AND FromVerse <= 1 AND ToVerse >= 1) OR
                    (Chapter = 1 AND FromVerse = 1 AND (ToVerse IS NULL OR ToVerse = 0)) OR
                    (Chapter = 1 AND FromVerse <= 2 AND ToVerse >= 2) OR
                    (Chapter = 1 AND FromVerse = 2 AND (ToVerse IS NULL OR ToVerse = 0))
                """,
                transform: { try database.integer($0, column: 0) },
                consume: body
            )
        case .dictionary, .other:
            return
        }
    }

    /**
     Resolves one key using Android's MySword content columns and range predicates.

     All returned text passes through Android's MySword tag transformer, including dictionary and
     commentary data. Missing or category-incompatible keys return `nil`.

     - Parameter key: Typed verse or dictionary key.
     - Returns: Resolved transformed content, or `nil` when no matching row exists.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     */
    public func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        let rawText: String?
        switch (fileType, key) {
        case (.bible, .verse(let book, let chapter, let verse)):
            rawText = try database.firstText(
                "SELECT Scripture FROM Bible WHERE Book = ? AND Chapter = ? AND Verse = ?",
                bindings: [.coordinate(book), .coordinate(chapter), .coordinate(verse)]
            )
        case (.commentary, .verse(let book, let chapter, let verse)):
            rawText = try commentaryText(book: book, chapter: chapter, verse: verse)
        case (.dictionary, .dictionary(let word)):
            rawText = try database.firstText(
                "SELECT Data FROM Dictionary WHERE Word = ?",
                bindings: [.text(word)]
            )
        default:
            rawText = nil
        }
        return rawText.map {
            SQLiteDocumentContent(key: key, text: Self.transformMySwordTags($0))
        }
    }

    /**
     Returns one MySword Bible verse through the original nonthrowing API.

     - Parameters:
       - book: One-based MySword book number.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Android-transformed Scripture content, or `nil` when absent/error.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to `nil` for legacy compatibility.
     */
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        guard fileType == .bible else { return nil }
        return (try? content(for: .verse(book: book, chapter: chapter, verse: verse)))?.text
    }

    /**
     Returns a full MySword Bible chapter through the original tuple API.

     - Parameters:
       - book: One-based MySword book number.
       - chapter: One-based chapter number.
     - Returns: Verse/text tuples ordered by verse.
     - Side effects: Reads the open SQLite database.
     - Failure modes: Wrong categories or SQLite failures return an empty array.
     */
    public func getChapter(book: Int, chapter: Int) -> [(verse: Int, text: String)] {
        (try? chapterContent(book: book, chapter: chapter)) ?? []
    }

    /**
     Reads a MySword Bible chapter in one query without duplicate-coordinate rescans.

     - Parameters:
       - book: One-based source book number bound as Android text.
       - chapter: One-based chapter number bound as Android text.
     - Returns: First database row per distinct verse, transformed and sorted by verse number.
     - Side effects: Executes one read-only query on an operation-owned connection.
     - Throws: Shared query, cancellation, coercion, or CursorWindow errors.
     */
    public func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        guard fileType == .bible else { return [] }
        var firstTextByVerse: [Int: String] = [:]
        try database.consumeRows(
            "SELECT Verse, Scripture FROM Bible WHERE Book = ? AND Chapter = ?",
            bindings: [.coordinate(book), .coordinate(chapter)],
            transform: { statement in
                (
                    verse: try database.integer(statement, column: 0),
                    text: try database.text(statement, column: 1)
                )
            },
            consume: { row in
                guard firstTextByVerse[row.verse] == nil else { return }
                firstTextByVerse[row.verse] = Self.transformMySwordTags(row.text)
            }
        )
        return firstTextByVerse.keys.sorted().map { verse in
            (verse, firstTextByVerse[verse] ?? "")
        }
    }

    /**
     Returns MySword commentary covering one verse through the original API.

     - Parameters:
       - book: One-based MySword book number.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Android-joined and tag-transformed commentary, or `nil` when absent/error.
     - Side effects: Reads the open SQLite database.
     - Failure modes: Wrong categories or SQLite failures return `nil`.
     */
    public func getCommentary(book: Int, chapter: Int, verse: Int) -> String? {
        guard fileType == .commentary else { return nil }
        return (try? content(for: .verse(book: book, chapter: chapter, verse: verse)))?.text
    }

    /**
     Returns a MySword dictionary definition by exact `Dictionary.Word` value.

     - Parameter key: Exact dictionary word.
     - Returns: Android tag-transformed `Dictionary.Data`, or `nil` when absent/error.
     - Side effects: Reads the open SQLite database.
     - Failure modes: Wrong categories or SQLite failures return `nil`.
     */
    public func getDictionaryEntry(key: String) -> String? {
        guard fileType == .dictionary else { return nil }
        return (try? content(for: .dictionary(key)))?.text
    }

    /**
     Returns all exact MySword dictionary words in deterministic order.

     - Returns: `Dictionary.Word` values, or an empty array for other categories/SQLite failure.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to an empty array.
     */
    public func dictionaryKeys() -> [String] {
        guard fileType == .dictionary, let keys = try? keys() else { return [] }
        return keys.compactMap { key in
            guard case .dictionary(let word) = key else { return nil }
            return word
        }
    }

    /** Projects Android's one-row `Details` metadata and filename-derived identity. */
    private static func metadata(
        details: [String: String],
        databaseURL: URL,
        fileType: FileType
    ) -> SQLiteDocumentMetadata {
        let baseName = databaseURL.deletingPathExtension().lastPathComponent
        let initials = "MySword-" + SQLiteDocumentIdentity.sanitizedModuleName(baseName)
        let description = details["description"] ?? ""
        let abbreviation = details["abbreviation"] ?? initials
        let strong = Int(details["strong"] ?? "0") == 1
        return SQLiteDocumentMetadata(
            sourceURL: databaseURL,
            format: .mySword,
            initials: initials,
            abbreviation: abbreviation,
            title: details["title"] ?? "",
            description: description,
            language: details["language"] ?? "eng",
            version: "0.0",
            category: fileType.category,
            direction: .ltr,
            hasStrongs: fileType == .bible && strong,
            isStrongsDictionary: fileType == .dictionary && strong,
            hasWordsOfChrist: false
        )
    }

    /** Reads all MySword commentary rows Android considers to cover one verse. */
    private func commentaryText(book: Int, chapter: Int, verse: Int) throws -> String? {
        let fromVerse = chapter == 1 && verse == 1 ? 0 : verse
        var result = ""
        var hasRow = false
        try database.consumeRows(
            """
            SELECT Data FROM Commentary
            WHERE Book = ? AND (
                (Chapter = ? AND FromVerse <= ? AND ToVerse >= ?) OR
                (Chapter = ? AND FromVerse = ? AND (ToVerse IS NULL OR ToVerse = 0))
            )
            """,
            bindings: [
                .coordinate(book),
                .coordinate(chapter),
                .coordinate(verse),
                .coordinate(fromVerse),
                .coordinate(chapter),
                .coordinate(verse),
            ],
            transform: { try database.text($0, column: 0) },
            consume: { text in
                if hasRow { result += ", " }
                result += "<div>\(text)</div>"
                hasRow = true
            }
        )
        return result
    }

    /**
     Applies Android's MySword pseudo-tag conversions to raw module text.

     The ordered replacements preserve Strong's lemmas, morphology, paired closing tags, and
     Android's known self-closing marker set. Unknown text remains unchanged.

     - Parameter text: Raw `Scripture` or `Data` column text.
     - Returns: Android-compatible OSIS-like text.
     - Side effects: None.
     - Failure modes: None; regex patterns are fixed compile-time constants.
     */
    private static func transformMySwordTags(_ text: String) -> String {
        var result = replacingMatches(
            in: text,
            pattern: #"([A-Za-z0-9_]+)<W([GH])([0-9]+)><WT([a-zA-Z0-9\-]+)( l="([^"]+)")?>"#
        ) { groups in
            let word = groups[1] ?? ""
            let language = groups[2] ?? ""
            let number = groups[3] ?? ""
            let morphology = groups[4] ?? ""
            return "<w lemma=\"strong:\(language)\(number)\" morph=\"strongMorph:\(morphology)\">\(word)</w>"
        }
        result = replacingMatches(
            in: result,
            pattern: #"([A-Za-z0-9_]+)<W([GH][0-9]+)>(<W([GH][0-9]+)>)?(<W([GH][0-9]+)>)?"#
        ) { groups in
            let lemmas = [groups[2], groups[4], groups[6]]
                .compactMap { $0 }
                .map { "strong:\($0)" }
                .joined(separator: " ")
            return "<w lemma=\"\(lemmas)\">\(groups[1] ?? "")</w>"
        }
        result = replacingMatches(
            in: result,
            pattern: #"<WT([a-zA-Z0-9\-]+)( l="([^"]+)")?>"#
        ) { groups in
            let morphology = groups[1] ?? ""
            return "<w morph=\"strongMorph:\(morphology)\">\(morphology)</w>"
        }
        result = replacingMatches(in: result, pattern: #"<(Ts|Fi|Fo|q|e|t|x|h|g)>"#) { groups in
            "</\((groups[1] ?? "").uppercased())>"
        }
        return replacingMatches(
            in: result,
            pattern: #"<(CM|CL|PF[0-9]|Pl[0-9]|Cl|D|wh|wg|wt|br)>"#
        ) { groups in
            "<\(groups[1] ?? "")/>"
        }
    }

    /** Replaces regex matches from the end so capture ranges remain stable during mutation. */
    private static func replacingMatches(
        in input: String,
        pattern: String,
        replacement: ([String?]) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
        let source = input as NSString
        let matches = expression.matches(
            in: input,
            range: NSRange(location: 0, length: source.length)
        )
        var output = input
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String? in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : source.substring(with: range)
            }
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement(groups))
        }
        return output
    }
}
