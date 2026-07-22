// ESwordReader.swift -- Android-compatible e-Sword Bible SQLite reader

import Foundation

/**
 Reads e-Sword `.bblx` and `.bbli` Bible modules using Android's one-row `Details` schema.

 Both families store verse coordinates and text in `Bible(Book, Chapter, Verse, Scripture)`.
 Android converts RTF-like `.bblx` Scripture to OSIS-like text while passing `.bbli` plain text
 through unchanged. Discovery is intentionally nonrecursive, matching Android's `listFiles` scan.
 Initialization reads only first-row metadata; Bible schema failures remain lazy until access, and
 every operation owns an independent read-only connection and statement lifecycle.
 */
public final class ESwordReader: SQLiteDocumentReading {
    /// Pinned OpenJDK character classifications used by Kotlin's RTF parser operations.
    private static let javaCharacterTables: Lucene29CharacterTables = {
        do {
            return try Lucene29CharacterTables.loaded()
        } catch {
            preconditionFailure("Missing pinned OpenJDK character tables: \(error)")
        }
    }()

    /**
     OpenJDK 17 BMP `DECIMAL_DIGIT_NUMBER` blocks used by `Character.digit(char, radix)`.

     Every Java `char` digit block contains the values zero through nine consecutively. Keeping the
     starts pinned alongside the bundled OpenJDK category oracle prevents the host Foundation
     Unicode version from changing either hexadecimal escapes or signed RTF parameters.
     */
    private static let javaDecimalDigitBlockStarts: [UInt16] = [
        0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6,
        0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6, 0x0E50, 0x0ED0,
        0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80,
        0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900,
        0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10,
    ]

    /** e-Sword filename suffix that controls Scripture transformation. */
    public enum FileType: String, CaseIterable, Equatable, Sendable {
        /// Legacy `.bblx` Bible whose Scripture uses e-Sword RTF control words.
        case bblx

        /// `.bbli` Bible whose Scripture is already plain text.
        case bbli

        /** Resolves a supported e-Sword type from a case-insensitive filename extension. */
        static func resolve(fileName: String) -> Self? {
            let lowercased = fileName.lowercased()
            return allCases.first { lowercased.hasSuffix(".\($0.rawValue)") }
        }
    }

    /// Open validated e-Sword database.
    private let database: SQLiteDocumentDatabase

    /// Filename-selected e-Sword text family.
    public let fileType: FileType

    /// Validated immutable metadata suitable for later backend catalog integration.
    public let metadata: SQLiteDocumentMetadata

    /// e-Sword readers always expose Bible content.
    public var category: DocumentCategory { .bible }

    /**
     Opens one e-Sword Bible database and reads Android's first metadata row.

     - Parameter fileURL: Readable `.bblx` or `.bbli` file URL.
     - Side effects: Opens and closes one read-only SQLite handle to validate metadata.
     - Throws: `SQLiteDocumentReaderError` for unsupported filenames, invalid SQLite, or an
       absent/unreadable first `Details` row. Bible table and column failures remain lazy.
     */
    public init(fileURL: URL) throws {
        guard let fileType = FileType.resolve(fileName: fileURL.lastPathComponent) else {
            throw SQLiteDocumentReaderError.unsupportedFileName(
                format: .eSword,
                fileName: fileURL.lastPathComponent
            )
        }

        let database = try SQLiteDocumentDatabase(url: fileURL)
        let details = try database.firstDetailsRow(format: .eSword)

        self.database = database
        self.fileType = fileType
        self.metadata = Self.metadata(details: details, databaseURL: database.url)
    }

    /**
     Offers a failable path initializer for parity with the older SQLite readers.

     - Parameter filePath: Filesystem path to an e-Sword Bible database.
     - Side effects: Opens a read-only SQLite handle on success.
     - Failure modes: Returns `nil` for every structured initialization error; catalog code should
       use `init(fileURL:)` when diagnostics are needed.
     */
    public convenience init?(filePath: String) {
        try? self.init(fileURL: URL(fileURLWithPath: filePath))
    }

    /**
     Discovers only immediate e-Sword module-directory children, matching Android `listFiles`.

     - Parameter directoryURL: e-Sword module directory.
     - Returns: Readable direct child files ending in `.bblx` or `.bbli`, case-insensitively.
     - Side effects: Lists one directory but does not open candidate databases.
     - Failure modes: Missing or unreadable directories return an empty array.
     */
    public static func discover(in directoryURL: URL) -> [URL] {
        SQLiteDocumentDiscovery.directFiles(in: directoryURL) {
            FileType.resolve(fileName: $0) != nil
        }
    }

    /**
     Returns every e-Sword verse key in deterministic source-coordinate order.

     - Returns: Numeric book/chapter/verse keys using e-Sword's Android book-number map.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure, or
       `.cursorWindowRowTooLarge` if Android cannot expose one source row.
     */
    public func keys() throws -> [SQLiteDocumentKey] {
        try database.rows(
            "SELECT Book, Chapter, Verse FROM Bible ORDER BY Book, Chapter, Verse"
        ) { statement in
            .verse(
                book: try database.integer(statement, column: 0),
                chapter: try database.integer(statement, column: 1),
                verse: try database.integer(statement, column: 2)
            )
        }
    }

    /**
     Streams distinct e-Sword Bible chapters with constant transient row memory.

     - Parameter body: Consumer receiving source book and chapter values in numeric order.
     - Side effects: Executes one read-only `Bible` query on an operation-owned connection.
     - Throws: Shared query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func forEachBibleChapter(_ body: (Int, Int) throws -> Bool) throws {
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

     - Parameter body: Consumer receiving each matching e-Sword source book number.
     - Side effects: Executes one read-only query and may emit duplicate book numbers.
     - Throws: Shared query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func forEachNavigationBookNumber(_ body: (Int) throws -> Void) throws {
        try database.consumeRows(
            "SELECT Book FROM Bible WHERE Chapter = 1 AND (Verse = 1 OR Verse = 2)",
            transform: { try database.integer($0, column: 0) },
            consume: body
        )
    }

    /**
     Resolves one e-Sword verse and applies filename-specific Android text handling.

     `.bblx` content is converted from RTF controls to OSIS-like text; `.bbli` content is returned
     byte-for-text unchanged after SQLite UTF-8 decoding.

     - Parameter key: Numeric verse key; dictionary keys are category-incompatible.
     - Returns: Resolved content, including empty content for a present SQL `NULL`, or `nil` when
       the verse is absent or the key is incompatible.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     */
    public func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        guard case .verse(let book, let chapter, let verse) = key,
              let row = try database.firstTextRow(
                "SELECT Scripture FROM Bible WHERE Book = ? AND Chapter = ? AND Verse = ?",
                bindings: [.coordinate(book), .coordinate(chapter), .coordinate(verse)]
              ) else { return nil }
        let scripture = row.value ?? ""
        let text = fileType == .bblx ? Self.convertRTFToOSIS(scripture) : scripture
        return SQLiteDocumentContent(key: key, text: text)
    }

    /**
     Returns one e-Sword verse through a nonthrowing convenience API.

     - Parameters:
       - book: One-based e-Sword book number.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Converted `.bblx` or unchanged `.bbli` Scripture, or `nil` when absent/error.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to `nil`.
     */
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        (try? content(for: .verse(book: book, chapter: chapter, verse: verse)))?.text
    }

    /**
     Returns a full e-Sword Bible chapter through the tuple API shared by SQLite readers.

     - Parameters:
       - book: One-based e-Sword book number.
       - chapter: One-based chapter number.
     - Returns: Verse/text tuples ordered by verse with format-specific conversion applied.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite failures return an empty array.
     */
    public func getChapter(book: Int, chapter: Int) -> [(verse: Int, text: String)] {
        (try? chapterContent(book: book, chapter: chapter)) ?? []
    }

    /**
     Reads an e-Sword chapter in one query without duplicate-coordinate rescans.

     - Parameters:
       - book: One-based e-Sword book number bound as Android text.
       - chapter: One-based chapter number bound as Android text.
     - Returns: First database row per distinct verse, ordered by verse with format conversion.
     - Side effects: Executes one read-only query on an operation-owned connection.
     - Throws: Shared query, cancellation, coercion, or CursorWindow errors.
     */
    public func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        var firstTextByVerse: [Int: String] = [:]
        try database.consumeRows(
            "SELECT Verse, Scripture FROM Bible WHERE Book = ? AND Chapter = ?",
            bindings: [.coordinate(book), .coordinate(chapter)],
            transform: { statement in
                (
                    verse: try database.integer(statement, column: 0),
                    text: try database.optionalText(statement, column: 1) ?? ""
                )
            },
            consume: { row in
                guard firstTextByVerse[row.verse] == nil else { return }
                firstTextByVerse[row.verse] = fileType == .bblx
                    ? Self.convertRTFToOSIS(row.text)
                    : row.text
            }
        )
        return firstTextByVerse.keys.sorted().map { verse in
            (verse, firstTextByVerse[verse] ?? "")
        }
    }

    /** Projects Android's one-row e-Sword metadata and filename-derived identity. */
    private static func metadata(
        details: [String: String],
        databaseURL: URL
    ) -> SQLiteDocumentMetadata {
        let baseName = databaseURL.deletingPathExtension().lastPathComponent
        let initials = "ESword-" + SQLiteDocumentIdentity.sanitizedESwordModuleName(baseName)
        let description = details["description"] ?? details["title"] ?? ""
        let abbreviation = details["abbreviation"] ?? initials
        let strongValue = details["strong"] ?? details["strongs"] ?? "0"
        return SQLiteDocumentMetadata(
            sourceURL: databaseURL,
            format: .eSword,
            initials: initials,
            abbreviation: abbreviation,
            title: description.isEmpty ? abbreviation : description,
            description: description,
            language: "en",
            version: "0.0",
            category: .bible,
            direction: .ltr,
            hasStrongs: Int(strongValue) != 0,
            isStrongsDictionary: false,
            hasWordsOfChrist: false
        )
    }

    /**
     Converts e-Sword RTF content to the OSIS-like text emitted by Android's `convertRtfToOsis`.

     The parser handles bold, italic, superscript, line/paragraph breaks, escaped braces and
     backslashes, JVM hexadecimal digits, signed UTF-16 `\\u` escapes, Unicode control-word
     character classes, and skipped destination groups. Text stays semantic until the final XML
     serialization boundary, where forbidden XML 1.0 scalars are replaced and entities escaped.
     Android returns non-RTF input and malformed generated nesting raw; iOS preserves a valid fragment
     byte-for-text and otherwise escapes it as visible text so every returned OSIS fragment is valid.

     - Parameter rtf: Raw `.bblx` Scripture text. Plain text without an RTF-leading slash or brace
       follows the same safety-preserving fragment projection.
     - Returns: Trimmed OSIS-like text with formatting represented by `<hi>` and `<lb/>` elements.
     - Side effects: None.
     - Failure modes: Malformed/truncated controls are ignored; the function never throws.
     */
    public static func convertRTFToOSIS(_ rtf: String) -> String {
        guard !rtf.isEmpty else { return "" }
        guard rtf.hasPrefix("\\") || rtf.hasPrefix("{") else {
            return SQLiteDocumentXMLCompatibility.validatedFragmentOrEscapedText(rtf)
        }

        let input = Array(rtf.utf16)
        var outputParts: [String] = []
        var pendingText: [UInt16] = []
        pendingText.reserveCapacity(input.count)
        var index = 0
        var braceDepth = 0
        var skipsGroup = false
        var skippedGroupDepth = 0
        var bold = false
        var italic = false
        var superscript = false

        /** Flushes semantic text through the shared XML 1.0 serializer. */
        func flushText() {
            guard !pendingText.isEmpty else { return }
            outputParts.append(SQLiteDocumentXMLCompatibility.escapedText(
                String(decoding: pendingText, as: UTF16.self)
            ))
            pendingText.removeAll(keepingCapacity: true)
        }

        /** Appends one semantic decoded UTF-16 code unit without serializing it prematurely. */
        func appendText(_ character: UInt16) {
            pendingText.append(character)
        }

        /** Appends trusted converter-generated markup after flushing semantic text. */
        func appendMarkup(_ value: String) {
            flushText()
            outputParts.append(value)
        }

        /** Closes Android's active formatting flags in its exact terminal order. */
        func closeFormattingTags() {
            if superscript {
                appendMarkup("</hi>")
                superscript = false
            }
            if bold {
                appendMarkup("</hi>")
                bold = false
            }
            if italic {
                appendMarkup("</hi>")
                italic = false
            }
        }

        while index < input.count {
            let character = input[index]
            switch character {
            case 0x7B: // {
                braceDepth += 1
                if index + 1 < input.count,
                   input[index + 1] == 0x5C,
                   Self.isSkippedRTFGroup(input, at: index + 1) {
                    skipsGroup = true
                    skippedGroupDepth = braceDepth
                }
                index += 1

            case 0x7D: // }
                if skipsGroup && braceDepth == skippedGroupDepth {
                    skipsGroup = false
                }
                braceDepth -= 1
                index += 1

            case _ where skipsGroup:
                index += 1

            case 0x5C: // backslash
                index += 1
                guard index < input.count else { break }
                switch input[index] {
                case 0x5C: // escaped backslash
                    appendText(0x5C)
                    index += 1
                case 0x7B, 0x7D: // escaped braces
                    appendText(input[index])
                    index += 1
                case 0x0A, 0x0D: // escaped newline
                    index += 1
                case 0x27: // hex escape apostrophe
                    index += 1
                    if index + 1 < input.count {
                        if let value = Self.hexCodeUnit(input[index], input[index + 1]) {
                            appendText(value)
                        }
                        index += 2
                    }
                case 0x75: // u
                    if index + 1 < input.count,
                       Self.isRTFParameterDigit(input[index + 1]) || input[index + 1] == 0x2D {
                        index += 1
                        let numberStart = index
                        if input[index] == 0x2D { index += 1 }
                        while index < input.count, Self.isRTFParameterDigit(input[index]) { index += 1 }
                        if let number = Self.integer(input[numberStart..<index]) {
                            let codeUnit = number < 0 ? number + 65_536 : number
                            appendText(UInt16(truncatingIfNeeded: codeUnit))
                        }
                        if index < input.count,
                           input[index] != 0x5C,
                           input[index] != 0x7B,
                           input[index] != 0x7D {
                            index += 1
                        }
                    } else {
                        while index < input.count, Self.isRTFControlLetter(input[index]) { index += 1 }
                        if index < input.count,
                           input[index] == 0x2D || Self.isRTFParameterDigit(input[index]) {
                            if input[index] == 0x2D { index += 1 }
                            while index < input.count, Self.isRTFParameterDigit(input[index]) { index += 1 }
                        }
                        if index < input.count, input[index] == 0x20 { index += 1 }
                    }
                default:
                    let wordStart = index
                    while index < input.count, Self.isRTFControlLetter(input[index]) { index += 1 }
                    let word = String(decoding: input[wordStart..<index], as: UTF16.self)
                    let parameterStart = index
                    if index < input.count,
                       input[index] == 0x2D || Self.isRTFParameterDigit(input[index]) {
                        if input[index] == 0x2D { index += 1 }
                        while index < input.count, Self.isRTFParameterDigit(input[index]) { index += 1 }
                    }
                    let parameter = parameterStart < index
                        ? Self.integer(input[parameterStart..<index])
                        : nil
                    if index < input.count, input[index] == 0x20 { index += 1 }

                    switch word {
                    case "b":
                        if parameter == 0 {
                            if bold {
                                appendMarkup("</hi>")
                                bold = false
                            }
                        } else if !bold {
                            appendMarkup("<hi type=\"bold\">")
                            bold = true
                        }
                    case "i":
                        if parameter == 0 {
                            if italic {
                                appendMarkup("</hi>")
                                italic = false
                            }
                        } else if !italic {
                            appendMarkup("<hi type=\"italic\">")
                            italic = true
                        }
                    case "super":
                        if !superscript {
                            appendMarkup("<hi type=\"super\">")
                            superscript = true
                        }
                    case "nosupersub":
                        if superscript {
                            appendMarkup("</hi>")
                            superscript = false
                        }
                    case "line", "par":
                        appendMarkup("<lb/>")
                    default:
                        break
                    }
                }

            default:
                appendText(character)
                index += 1
            }
        }

        closeFormattingTags()
        flushText()
        let output = outputParts.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SQLiteDocumentXMLCompatibility.validatedFragmentOrEscapedText(output)
    }

    /** Reports whether a brace group starts with an Android-skipped RTF destination. */
    private static func isSkippedRTFGroup(_ input: [UInt16], at index: Int) -> Bool {
        ["\\fonttbl", "\\colortbl", "\\stylesheet", "\\*\\"].contains {
            hasASCIIPrefix($0, in: input, at: index)
        }
    }

    /** Compares one ASCII control prefix against UTF-16 input without allocating a substring. */
    private static func hasASCIIPrefix(_ prefix: String, in input: [UInt16], at index: Int) -> Bool {
        let units = Array(prefix.utf16)
        guard index + units.count <= input.count else { return false }
        return input[index..<(index + units.count)].elementsEqual(units)
    }

    /** Decodes two JVM `Character.digit(radix: 16)` code units into one Latin-1 value. */
    private static func hexCodeUnit(_ high: UInt16, _ low: UInt16) -> UInt16? {
        guard let highValue = hexadecimalValue(high),
              let lowValue = hexadecimalValue(low) else { return nil }
        return highValue * 16 + lowValue
    }

    /** Mirrors Java `Character.digit(char, 16)` for BMP decimal and hexadecimal characters. */
    private static func hexadecimalValue(_ character: UInt16) -> UInt16? {
        if let value = javaDecimalDigitValue(character) { return value }
        switch character {
        case 0x41...0x46: return character - 0x41 + 10
        case 0x61...0x66: return character - 0x61 + 10
        case 0xFF21...0xFF26: return character - 0xFF21 + 10
        case 0xFF41...0xFF46: return character - 0xFF41 + 10
        default: return nil
        }
    }

    /** Parses Kotlin `String.toIntOrNull` parameters with signed 32-bit bounds. */
    private static func integer(_ units: ArraySlice<UInt16>) -> Int? {
        guard !units.isEmpty else { return nil }
        var index = units.startIndex
        let isNegative = units[index] == 0x2D
        if isNegative {
            index = units.index(after: index)
            guard index < units.endIndex else { return nil }
        }

        let magnitudeLimit: Int64 = isNegative ? 2_147_483_648 : 2_147_483_647
        var value: Int64 = 0
        while index < units.endIndex {
            guard let digit = javaDecimalDigitValue(units[index]) else { return nil }
            let digitValue = Int64(digit)
            guard value <= (magnitudeLimit - digitValue) / 10 else { return nil }
            value = value * 10 + digitValue
            index = units.index(after: index)
        }
        return isNegative ? -Int(value) : Int(value)
    }

    /** Reports whether a UTF-16 code unit is a Kotlin-compatible Unicode RTF control letter. */
    private static func isRTFControlLetter(_ character: UInt16) -> Bool {
        javaCharacterTables.isLetter(character)
    }

    /** Reports whether a UTF-16 code unit is a Kotlin-compatible Unicode decimal digit. */
    private static func isRTFParameterDigit(_ character: UInt16) -> Bool {
        javaCharacterTables.isDecimalDigit(character)
    }

    /** Returns OpenJDK's decimal value for one BMP Java `char`, or nil for non-digits. */
    private static func javaDecimalDigitValue(_ character: UInt16) -> UInt16? {
        guard javaCharacterTables.isDecimalDigit(character) else { return nil }
        for start in javaDecimalDigitBlockStarts where character >= start && character <= start + 9 {
            return character - start
        }
        return nil
    }
}
