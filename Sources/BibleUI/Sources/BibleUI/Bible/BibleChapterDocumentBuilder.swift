import Foundation
import SwordKit
import os.log

private let chapterBuilderLogger = Logger(subsystem: "org.andbible", category: "BibleChapterDocumentBuilder")

/**
 Reconstructs one Bible chapter OSIS payload from a SWORD verse-key module.

 Android filters every raw key through JSword `OSISFilter`, applies `SwordBook.addOSIS`, and then
 aggregates the repaired entries for a rendered chapter range. iOS does not expose that range API,
 so this builder owns the equivalent sequence: apply the pinned repair ladder per entry, project
 verse/pre-verse ownership, stitch in verse-0 intro material when enabled, and insert a real
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

    /**
     Stores one exact native verse before chapter-level OSIS reconstruction.

     Entries are immutable, ordered by the caller, and retain source XML without trimming so the
     shared projector can preserve Android-significant edge whitespace. Construction performs no
     I/O and cannot fail; `buildVerseChunkXML` owns structural repair and wrapper emission.
     */
    struct VerseEntry {
        /// One-based source verse number used by the synthetic OSIS wrapper.
        let verse: Int

        /// Active-versification ordinal emitted for Android-compatible reader navigation.
        let ordinal: Int

        /// Exact native OSIS entry supplied to the shared structural projection boundary.
        let xml: String

        /**
         Creates one immutable captured verse for reconstruction and focused contract tests.

         - Parameters:
           - verse: One-based source verse number.
           - ordinal: Active-versification ordinal used by reader navigation.
           - xml: Exact native OSIS fragment, including meaningful edge whitespace.
         - Side effects: None.
         - Failure modes: Inputs are retained verbatim; the later projection boundary handles
           malformed XML without throwing.
         */
        init(verse: Int, ordinal: Int, xml: String) {
            self.verse = verse
            self.ordinal = ordinal
            self.xml = xml
        }
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
                guard let ordinal = ordinal(osisBookId: osisBookId, chapter: chapter, verse: parsedVerse) else {
                    chapterBuilderLogger.warning("SWORD: Could not resolve ordinal for \(osisBookId) \(chapter):\(parsedVerse)")
                    return nil
                }
                let verseEntry = VerseEntry(
                    verse: parsedVerse,
                    ordinal: ordinal,
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

    /**
     Resolves the verse ordinal used in reader OSIS output.

     Android receives verse ordinals from JSword's active `Versification`; SWORD exposes the same
     concept through `VerseKey.getIndex()`. The fallback exists only for placeholder/unavailable
     module paths and preserves historical rendering when the bridge cannot resolve a real
     `VerseKey`.

     - Parameters:
       - osisBookId: OSIS book identifier for the verse being rendered.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: The active module's versification ordinal, or `nil` if the exact verse cannot be
       resolved through the module.
     - Side effects: May temporarily move the SWORD module cursor through `SwordModule`; the module
       restores its previous key before returning.
     */
    private func ordinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
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

    /**
     Loads and repairs one exact verse-zero introduction through JSword's source filter boundary.

     - Parameters:
       - osisBookId: Exact OSIS book identifier used to position and validate the native cursor.
       - chapter: Chapter component of the requested introduction key.
       - verse: Verse component, normally zero for book/chapter pre-verse material.
     - Returns: One structurally valid wrapper around repaired source children, or nil when the key
       is absent, its raw entry is empty, or every pinned repair stage rejects the entry.
     - Side effects: Moves the shared native module cursor to the requested exact key and parses one
       bounded source fragment in memory.
     - Failure modes: Never substitutes stripped/rendered text; invalid or irreparable source is
       omitted so it cannot invalidate the complete Vue chapter template.
     */
    private func rawEntryFragment(osisBookId: String, chapter: Int, verse: Int) -> String? {
        module.setKey("=\(osisBookId).\(chapter).\(verse)")
        guard let key = module.currentVerseKeyChildren(),
              key.osisBookName == osisBookId,
              key.chapter == chapter,
              key.verse == verse else {
            return nil
        }

        let raw = module.rawEntry()
        guard !raw.isEmpty else { return nil }
        let repaired = SwordJSwordOSISSourceCompatibility.repairedSourceXML(
            raw,
            moduleInitials: module.info.name
        )
        guard !repaired.isEmpty else { return nil }
        return "<div>\(repaired)</div>"
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
        appendOsisContent(
            Self.buildVerseChunkXML(
                osisBookId: osisBookId,
                chapter: chapter,
                verses: verseChunk,
                moduleInitials: module.info.name
            ),
            to: &xmlParts
        )
        verseChunk.removeAll(keepingCapacity: true)
    }

    /**
     Builds one structurally projected run of native SWORD verse entries.

     - Parameters:
       - osisBookId: Canonical OSIS book identifier shared by the chunk.
       - chapter: One-based chapter number shared by the chunk.
       - verses: Ordered exact raw entries with their source verse/ordinal identities.
       - moduleInitials: Exact installed initials controlling pinned module-specific source repair.
     - Returns: One wrapper containing chapter-level preambles and synthetic verse elements.
     - Side effects: Parses each bounded verse fragment in memory.
     - Failure modes: Every raw entry first follows pinned JSword's structural repair ladder;
       irreparable entries are omitted rather than emitting malformed Vue templates. No caller
       pre-trim may discard Java-significant NBSP before that compatibility boundary.
     */
    static func buildVerseChunkXML(
        osisBookId: String,
        chapter: Int,
        verses: [VerseEntry],
        moduleInitials: String? = nil
    ) -> String {
        var xml = "<div>"
        for verse in verses {
            let repairedSource = SwordJSwordOSISSourceCompatibility.repairedSourceXML(
                verse.xml,
                moduleInitials: moduleInitials
            )
            guard !repairedSource.isEmpty else { continue }
            let projection = SwordVerseOSISProjection.project(
                repairedSource,
                verseOrdinal: verse.ordinal
            )
            xml += projection.preVerseXML
            if projection.isAlreadyWrapped {
                xml += projection.verseBodyXML
                continue
            }
            xml += "<verse osisID=\"\(osisBookId).\(chapter).\(verse.verse)\" verseOrdinal=\"\(verse.ordinal)\">"
            xml += "\(projection.verseBodyXML) "
            xml += "</verse>"
        }
        xml += "</div>"
        return xml
    }
}
