// SQLiteBibleChapterDocumentBuilder.swift -- Android SQLite Bible chapter OSIS projection

import Foundation
import BibleCore
import SwordKit

/**
 Builds one reader chapter from a validated Android SQLite Bible module.

 MyBible, MySword, and e-Sword Bible keys use KJVA coordinates on Android. The builder therefore
 assigns the same JSword intro-inclusive KJVA ordinals used by bookmarks, reading progress, speech,
 and window synchronization instead of inventing per-chapter ordinals. Missing source rows remain
 missing; the builder never generates placeholder verses.
 */
struct SQLiteBibleChapterDocumentBuilder {
    /** One copied SQLite verse row used by the source-independent projector. */
    struct CapturedVerse: Sendable {
        let verse: Int
        let text: String
    }

    /** Complete immutable chapter read returned by one operation-owned SQLite connection. */
    struct CapturedChapter: Sendable {
        let osisBookId: String
        let chapter: Int
        let verses: [CapturedVerse]
        let isPlainESword: Bool
    }

    /// Readable database-backed Bible selected by the pane.
    let module: BibleReaderSQLiteModuleHandle

    /**
     Reads and wraps every present source verse in one chapter.

     - Parameters:
       - osisBookId: Canonical OSIS book identifier.
       - chapter: One-based chapter number.
     - Returns: Reader OSIS and the highest addressable verse, or `nil` for absent/invalid content.
     - Side effects: Executes read-only SQLite queries through the retained module.
     - Failure modes: Database failures and invalid KJVA coordinates return `nil`; no partial
       document is emitted. Duplicate source keys collapse to one exact verse.
     */
    func loadChapter(
        osisBookId: String,
        chapter: Int
    ) -> BibleChapterDocumentBuilder.LoadedChapterContent? {
        guard let capture = captureChapter(osisBookId: osisBookId, chapter: chapter) else {
            return nil
        }
        return Self.projectChapter(capture)
    }

    /** Reads exact SQLite source rows and copies the module-specific markup classification. */
    func captureChapter(osisBookId: String, chapter: Int) -> CapturedChapter? {
        guard chapter > 0,
              let rows = try? module.chapterContent(osisId: osisBookId, chapter: chapter),
              !rows.isEmpty else {
            return nil
        }

        return CapturedChapter(
            osisBookId: osisBookId,
            chapter: chapter,
            verses: rows.map { CapturedVerse(verse: $0.verse, text: $0.text) },
            isPlainESword: SQLiteReaderMarkupProjection.isPlainESword(module)
        )
    }

    /** Projects copied rows into OSIS without retaining or reading the SQLite module handle. */
    static func projectChapter(
        _ capture: CapturedChapter
    ) -> BibleChapterDocumentBuilder.LoadedChapterContent? {
        let osisBookId = capture.osisBookId
        let chapter = capture.chapter

        var firstTextByVerse: [Int: String] = [:]
        for row in capture.verses where row.verse > 0 {
            if firstTextByVerse[row.verse] == nil {
                firstTextByVerse[row.verse] = row.text
            }
        }
        let verses = firstTextByVerse.keys.sorted()
        guard let highestVerse = verses.last else { return nil }

        var xml = "<div><chapter osisID=\"\(osisBookId).\(chapter)\" sID=\"chapter-\(osisBookId)-\(chapter)\" />"
        for verse in verses {
            guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: verse
            ), let text = firstTextByVerse[verse] else {
                return nil
            }
            xml += "<verse osisID=\"\(coordinate.osisKey)\" verseOrdinal=\"\(coordinate.ordinal)\">"
            let projectedText = SQLiteReaderMarkupProjection.bibleVerseXML(
                text.trimmingCharacters(in: .whitespacesAndNewlines),
                isPlainESword: capture.isPlainESword
            )
            xml += SQLiteDocumentXMLCompatibility.validatedFragmentOrEscapedText(projectedText)
            xml += " </verse>"
        }
        xml += "</div>"
        return BibleChapterDocumentBuilder.LoadedChapterContent(
            xml: xml,
            verseCount: highestVerse,
            addChapter: false
        )
    }
}
