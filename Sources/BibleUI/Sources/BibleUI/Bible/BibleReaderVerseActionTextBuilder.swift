// BibleReaderVerseActionTextBuilder.swift -- Exact installed-source share and copy text

import Foundation

/** Builds Android-compatible share/copy text from an explicit installed Bible identity. */
struct BibleReaderVerseActionTextBuilder {
    /// Snapshot of Android's global installed-book registry for this operation.
    let moduleResolver: BibleReaderInstalledModuleResolver

    /**
     Reads and labels one exact inclusive source range.

     - Parameters:
       - bookInitials: Bridge- or bookmark-owned installed Bible identity.
       - startOrdinal: First source-domain concrete verse ordinal.
       - endOrdinal: Last source-domain concrete verse ordinal.
     - Returns: Canonical plain text plus source-owned reference and module initials, or nil.
     - Side effects: SWORD performs one bounded cursor-restoring read; SQLite performs bounded,
       operation-owned chapter reads.
     - Failure modes: Missing/wrong-category sources, invalid or oversized ranges, non-verse
       endpoints, empty content, and backend read/metadata failures fail closed.
     */
    func build(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> String? {
        guard !bookInitials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let source = moduleResolver.scripture(named: bookInitials),
              let start = source.verseReference(ordinal: startOrdinal),
              let end = source.verseReference(ordinal: endOrdinal),
              start.ordinal <= end.ordinal,
              let passage = try? source.passage(
                  startOrdinal: start.ordinal,
                  endOrdinal: end.ordinal
              ),
              !passage.plainText.isEmpty,
              let reference = try? source.displayName(start: start, end: end),
              !reference.isEmpty else {
            return nil
        }
        return "\(passage.plainText)\n— \(reference) (\(source.info.name))"
    }
}
