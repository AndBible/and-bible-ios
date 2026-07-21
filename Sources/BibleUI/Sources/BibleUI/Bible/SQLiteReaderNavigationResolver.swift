// SQLiteReaderNavigationResolver.swift -- Exact KJVA navigation for SQLite modules

import BibleCore
import SwordKit

/**
 Exact KJVA verse coordinate used by SQLite rendering, speech, copy, and commentary navigation.

 Construction is available only through `SQLiteReaderNavigationResolver`, which proves the
 coordinate exists in JSword's intro-inclusive KJVA ordinal domain.
 */
struct SQLiteReaderVerseCoordinate: Equatable, Sendable {
    /// Canonical OSIS book identifier.
    let osisBookId: String

    /// One-based KJVA chapter.
    let chapter: Int

    /// One-based KJVA verse.
    let verse: Int

    /// Exact JSword intro-inclusive KJVA ordinal.
    let ordinal: Int

    /// Dot-delimited OSIS key used by document and speech state.
    var osisKey: String {
        "\(osisBookId).\(chapter).\(verse)"
    }
}

/**
 Resolves SQLite module navigation without coordinate normalization or placeholder fallbacks.

 Android-compatible MyBible, MySword, and e-Sword Bible/commentary keys are addressed in KJVA.
 Centralizing validation keeps rendering, speech, copy, and commentary synchronization on the same
 exact ordinal contract.
 */
enum SQLiteReaderNavigationResolver {
    /**
     Validates one exact KJVA coordinate and attaches its canonical ordinal.

     - Parameters:
       - osisBookId: Canonical OSIS book identifier.
       - chapter: One-based chapter.
       - verse: One-based verse.
     - Returns: Validated coordinate, or nil when any component is outside KJVA.
     - Side effects: None.
     - Failure modes: Invalid books, chapters, verses, and intro verse zero return nil.
     */
    static func coordinate(
        osisBookId: String,
        chapter: Int,
        verse: Int
    ) -> SQLiteReaderVerseCoordinate? {
        guard let ordinal = JSwordKJVAVersification.verseOrdinal(
            osisId: osisBookId,
            chapter: chapter,
            verse: verse
        ) else {
            return nil
        }
        return SQLiteReaderVerseCoordinate(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    /**
     Parses an exact SQLite commentary key in OSIS or Android display form.

     - Parameter key: Either `Gen.1.1` or `Gen 1:1`; mixed separators are accepted only when they
       produce exactly three non-empty components.
     - Returns: Validated KJVA coordinate, or nil without snapping malformed/out-of-canon input.
     - Side effects: None.
     - Failure modes: Whitespace-only, extra-component, non-numeric, and invalid KJVA keys fail.
     */
    static func commentaryCoordinate(for key: String) -> SQLiteReaderVerseCoordinate? {
        let dotted = key.replacingOccurrences(of: " ", with: ".")
            .replacingOccurrences(of: ":", with: ".")
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let chapter = Int(parts[1]),
              let verse = Int(parts[2]) else {
            return nil
        }
        return coordinate(
            osisBookId: String(parts[0]),
            chapter: chapter,
            verse: verse
        )
    }

    /**
     Returns the last real KJVA-addressable verse exposed by one SQLite Bible chapter.

     - Parameters:
       - module: Immutable active SQLite Bible handle.
       - osisBookId: Canonical OSIS book identifier.
       - chapter: One-based chapter selected by the passage chooser.
     - Returns: Highest real verse number, or nil when the chapter is unreadable/empty or all rows
       are outside KJVA.
     - Side effects: Executes one chapter query on an operation-owned SQLite connection.
     - Failure modes: Reader errors and invalid source coordinates return nil without static-canon
       or SWORD fallback.
     */
    static func verseCount(
        module: BibleReaderSQLiteModuleHandle,
        osisBookId: String,
        chapter: Int
    ) -> Int? {
        guard let rows = try? module.chapterContent(osisId: osisBookId, chapter: chapter) else {
            return nil
        }
        return rows.compactMap { row in
            coordinate(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: row.verse
            )?.verse
        }.max()
    }
}
