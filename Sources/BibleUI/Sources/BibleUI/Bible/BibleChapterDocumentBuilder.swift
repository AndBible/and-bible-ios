import Foundation
import SwordKit
import os.log

private let chapterBuilderLogger = Logger(subsystem: "org.andbible", category: "BibleChapterDocumentBuilder")

/**
 Reconstructs one Bible chapter OSIS payload from a SWORD verse-key module.

 Android reads a whole OSIS fragment for a rendered chapter range. iOS does not currently expose the
 same low-level SWORD fragment API, so this builder centralizes the best available approximation:
 preserve verse-level raw OSIS, stitch in verse-0 intro material when enabled, and insert a real
 `<chapter>` marker when the source fragment does not already provide one.

 The raw OSIS stream is the authoritative source for headings. Some modules surface the same heading
 through both verse OSIS and heading entry attributes; merging both sources duplicates titles at
 chapter boundaries.
 */
struct BibleChapterDocumentBuilder {
    struct LoadedChapterContent {
        let xml: String
        let verseCount: Int
        let addChapter: Bool
    }

    private struct VerseEntry {
        let verse: Int
        let ordinal: Int
        let xml: String
    }

    let module: SwordModule
    let includeHeadings: Bool

    func loadChapter(osisBookId: String, chapter: Int) -> LoadedChapterContent? {
        var verseCount = 0
        var currentVerseChunk: [VerseEntry] = []
        var xmlParts: [String] = []
        var hasChapterMarker = false

        if includeHeadings, chapter == 1,
           let bookIntroXML = rawEntryFragment(osisBookId: osisBookId, chapter: 0, verse: 0) {
            appendPreservedOsisContent(bookIntroXML, to: &xmlParts)
            hasChapterMarker = hasChapterMarker || bookIntroXML.contains("<chapter")
        }

        if includeHeadings,
           let chapterIntroXML = rawEntryFragment(osisBookId: osisBookId, chapter: chapter, verse: 0) {
            appendPreservedOsisContent(chapterIntroXML, to: &xmlParts)
            hasChapterMarker = hasChapterMarker || chapterIntroXML.contains("<chapter")
        }

        let startKey = "\(osisBookId) \(chapter):1"
        module.setKey(startKey)

        guard let firstKey = module.currentVerseKeyChildren(),
              firstKey.osisBookName == osisBookId,
              firstKey.chapter == chapter else {
            chapterBuilderLogger.warning("SWORD: No content at \(startKey)")
            return nil
        }

        while true {
            guard let key = module.currentVerseKeyChildren(),
                  key.osisBookName == osisBookId else {
                break
            }

            if key.chapter != chapter {
                break
            }

            let parsedVerse = key.verse
            if parsedVerse <= 0 {
                if !module.next() { break }
                continue
            }

            if !hasChapterMarker {
                appendPreservedOsisContent(chapterMarkerXML(osisBookId: osisBookId, chapter: chapter), to: &xmlParts)
                hasChapterMarker = true
            }

            let text = module.rawEntry()
            if !text.isEmpty {
                let verseEntry = VerseEntry(
                    verse: parsedVerse,
                    ordinal: Self.ordinal(chapter: chapter, verse: parsedVerse),
                    xml: text
                )
                verseCount += 1
                currentVerseChunk.append(verseEntry)
            }

            if !module.next() {
                break
            }
        }

        appendCurrentVerseChunk(osisBookId: osisBookId, chapter: chapter, verseChunk: &currentVerseChunk, xmlParts: &xmlParts)

        if verseCount == 0 {
            chapterBuilderLogger.warning("SWORD: No verses found for \(osisBookId) \(chapter)")
            return nil
        }

        let xml = "<div>\(xmlParts.joined())</div>"
        chapterBuilderLogger.info("SWORD: Loaded \(verseCount) verses for \(osisBookId) \(chapter)")
        return LoadedChapterContent(
            xml: xml,
            verseCount: verseCount,
            addChapter: !hasChapterMarker
        )
    }

    static func ordinal(chapter: Int, verse: Int) -> Int {
        (chapter - 1) * 40 + max(1, verse)
    }

    private func normalizedOsisSegment(_ xml: String) -> String {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        return "<div>\(trimmed)</div>"
    }

    private func chapterMarkerXML(osisBookId: String, chapter: Int) -> String {
        normalizedOsisSegment(
            "<chapter osisID=\"\(osisBookId).\(chapter)\" sID=\"chapter-\(osisBookId)-\(chapter)\" />"
        )
    }

    private func rawEntryFragment(osisBookId: String, chapter: Int, verse: Int) -> String? {
        module.setKey("=\(osisBookId).\(chapter).\(verse)")
        guard let key = module.currentVerseKeyChildren(),
              key.osisBookName == osisBookId,
              key.chapter == chapter,
              key.verse == verse else {
            return nil
        }

        let raw = module.rawEntry().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return normalizedOsisSegment(raw)
    }

    private func osisFragmentBody(_ xml: String) -> String {
        let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let openEnd = trimmed.firstIndex(of: ">"),
              let closeStart = trimmed.range(of: "</div>", options: .backwards)?.lowerBound else {
            return trimmed
        }
        return String(trimmed[trimmed.index(after: openEnd)..<closeStart])
    }

    private func appendOsisContent(_ xml: String, to xmlParts: inout [String]) {
        xmlParts.append(osisFragmentBody(xml))
    }

    private func appendPreservedOsisContent(_ xml: String, to xmlParts: inout [String]) {
        xmlParts.append(xml.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func appendCurrentVerseChunk(osisBookId: String,
                                         chapter: Int,
                                         verseChunk: inout [VerseEntry],
                                         xmlParts: inout [String]) {
        guard !verseChunk.isEmpty else { return }
        appendOsisContent(buildVerseChunkXML(osisBookId: osisBookId, chapter: chapter, verses: verseChunk), to: &xmlParts)
        verseChunk.removeAll(keepingCapacity: true)
    }

    private func buildVerseChunkXML(osisBookId: String, chapter: Int, verses: [VerseEntry]) -> String {
        var xml = "<div>"
        for verse in verses {
            let cleanText = verse.xml.trimmingCharacters(in: .whitespacesAndNewlines)
            xml += "<verse osisID=\"\(osisBookId).\(chapter).\(verse.verse)\" verseOrdinal=\"\(verse.ordinal)\">"
            xml += "\(cleanText) "
            xml += "</verse>"
        }
        xml += "</div>"
        return xml
    }
}
