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

    /**
     Reconstructs one chapter from exact source-filtered OSIS entries.

     - Parameters:
       - osisBookId: Canonical OSIS book identifier in the module's active versification.
       - chapter: One-based chapter number to capture.
     - Returns: Well-formed reader XML, emitted verse count, and chapter-marker state; returns `nil`
       when the exact chapter is unavailable, every positive verse is empty, source bounds cannot be
       resolved, or the native cursor cannot be restored.
     - Side effects: Reads optional book/chapter introductions, captures one bounded positive-verse
       range through SWORD's option/source/encoding filters, and parses each copied OSIS fragment.
     - Failure modes: Native positioning/filter/restoration errors fail the complete chapter closed
       rather than publishing content from a stale or mismatched cursor. Individually irreparable
       OSIS entries are omitted by the pinned JSword repair ladder.
     - Important: Positive verses are captured under one `SwordRuntime` lease so another SWORD
       caller cannot interleave cursor movement between entry metadata and source content.
     */
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

        guard let firstEntry = inspectedSourceEntry(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: 1
        ), firstEntry.verseKey.verseMax > 0,
        let lastEntry = inspectedSourceEntry(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: firstEntry.verseKey.verseMax
        ) else {
            chapterBuilderLogger.warning("SWORD: No content at \(osisBookId) \(chapter):1")
            return nil
        }

        let sourceRange: SwordVerseSourceRange
        do {
            sourceRange = try module.inspectVerseSourceRangeRestoringPrevious(
                startOrdinal: firstEntry.verseKey.index,
                endOrdinal: lastEntry.verseKey.index
            )
        } catch {
            chapterBuilderLogger.error(
                "SWORD: Could not capture \(osisBookId) \(chapter) with cursor integrity: \(String(describing: error))"
            )
            return nil
        }

        for sourceEntry in sourceRange.entries {
            let reference = sourceEntry.reference
            guard reference.osisBookId == osisBookId,
                  reference.chapter == chapter,
                  let text = sourceEntry.osisFragment,
                  !text.isEmpty else { continue }
            if !hasChapterMarker {
                appendPreservedOsisContent(chapterMarkerXML(osisBookId: osisBookId, chapter: chapter), to: &xmlParts)
                hasChapterMarker = true
            }

            let verseEntry = VerseEntry(
                verse: reference.verse,
                ordinal: reference.ordinal,
                xml: text
            )
            verseCount += 1
            currentVerseChunk.append(verseEntry)
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
        guard let sourceEntry = inspectedSourceEntry(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse
        ), !sourceEntry.osisFragment.isEmpty else { return nil }
        let repaired = SwordJSwordOSISSourceCompatibility.repairedSourceXML(
            sourceEntry.osisFragment,
            moduleInitials: module.info.name
        )
        guard !repaired.isEmpty else { return nil }
        return "<div>\(repaired)</div>"
    }

    /**
     Resolves one exact verse and its source-neutral OSIS without leaking native cursor movement.

     - Parameters:
       - osisBookId: Expected canonical OSIS book identifier.
       - chapter: Expected chapter, including zero for a book introduction.
       - verse: Expected verse, including zero for introduction material.
     - Returns: Exact copied VerseKey metadata and filtered OSIS, or `nil` when SWORD snaps to a
       different key or cannot restore the caller's cursor.
     - Side effects: Temporarily positions and source-filters the module under `SwordRuntime`.
     - Failure modes: Logs restoration failures and rejects snapped/missing coordinates; empty
       source content remains a successful exact inspection for the caller to classify.
     */
    private func inspectedSourceEntry(
        osisBookId: String,
        chapter: Int,
        verse: Int
    ) -> (verseKey: VerseKeyChildren, osisFragment: String)? {
        do {
            let inspection = try module.inspectVerseKeyOSISSourceRestoringPrevious(
                "=\(osisBookId).\(chapter).\(verse)"
            )
            guard let key = inspection.verseKey,
                  key.osisBookName == osisBookId,
                  key.chapter == chapter,
                  key.verse == verse else { return nil }
            return (key, inspection.osisFragment)
        } catch {
            chapterBuilderLogger.error(
                "SWORD: Could not inspect \(osisBookId).\(chapter).\(verse) with cursor integrity: \(String(describing: error))"
            )
            return nil
        }
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
