// SQLiteReaderVerseRangeTextBuilder.swift -- Plain text for SQLite copy and share actions

/**
 Builds exact plain text for a KJVA verse range from one immutable SQLite Bible module.

 Share, copy, and other native visible-text actions must read the selected MyBible, MySword, or
 e-Sword source instead of falling through to SWORD. Rows outside the exact inclusive KJVA range
 are ignored, source order is retained, and markup is projected through the same format-aware text
 policy used by speech.
 */
struct SQLiteReaderVerseRangeTextBuilder {
    /// Immutable active SQLite Bible handle.
    let module: BibleReaderSQLiteModuleHandle

    /**
     Reads and joins real source verses intersecting an exact KJVA range.

     - Parameters:
       - osisBookId: Canonical OSIS book identifier for the active chapter.
       - chapter: One-based active chapter.
       - startOrdinal: First requested KJVA ordinal; reversed ranges are accepted.
       - endOrdinal: Last requested KJVA ordinal; reversed ranges are accepted.
     - Returns: Space-separated source text with markup removed, retaining the first source row for
       duplicate ordinals, or an empty string when no real row is addressable.
     - Side effects: Executes one chapter query on an operation-owned SQLite connection.
     - Failure modes: Reader errors, invalid coordinates, and empty source text produce an empty or
       partially filtered result without SWORD/placeholder fallback.
     */
    func text(
        osisBookId: String,
        chapter: Int,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> String {
        guard let rows = try? module.chapterContent(osisId: osisBookId, chapter: chapter) else {
            return ""
        }
        let bounds = min(startOrdinal, endOrdinal)...max(startOrdinal, endOrdinal)
        var seenOrdinals: Set<Int> = []
        return rows.compactMap { row -> String? in
            guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: row.verse
            ), bounds ~= coordinate.ordinal,
                  seenOrdinals.insert(coordinate.ordinal).inserted else {
                return nil
            }
            let text = SQLiteReaderMarkupProjection.plainText(row.text, module: module)
            return text.isEmpty ? nil : text
        }.joined(separator: " ")
    }
}
