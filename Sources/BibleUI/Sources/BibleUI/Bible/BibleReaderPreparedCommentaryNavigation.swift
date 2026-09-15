// BibleReaderPreparedCommentaryNavigation.swift -- Immutable accepted commentary navigation

import Foundation
import SwordKit

/** Commentary block key paired with its source-Bible coordinate during source capture. */
struct BibleReaderCommentaryNavigationTarget: Equatable, Sendable {
    let key: String
    let osisBookID: String
    let chapter: Int
    let verse: Int
    let sourceOrdinal: Int

    init(
        key: String,
        sourceReference: SwordVersification.Reference,
        sourceOrdinal: Int
    ) {
        self.key = key
        self.sourceOrdinal = sourceOrdinal
        osisBookID = sourceReference.osisBookId
        chapter = sourceReference.chapter
        verse = sourceReference.verse
    }

    var navigationReference: BibleReaderNavigationVerseReference {
        BibleReaderNavigationVerseReference(
            chapter: chapter,
            verse: verse,
            osisBookId: osisBookID,
            ordinal: sourceOrdinal
        )
    }

    var sourceKey: String {
        "\(osisBookID).\(chapter).\(verse)"
    }
}

/** Rendered-document source target plus toolbar navigation captured with accepted commentary. */
struct BibleReaderCommentaryNavigationAvailability: Equatable, Sendable {
    static let empty = BibleReaderCommentaryNavigationAvailability(
        current: nil,
        previous: nil,
        next: nil
    )

    /// Exact source target for the one document Vue accepted and can report as visible.
    let current: BibleReaderCommentaryNavigationTarget?
    /// Previous block target used only by explicit reader navigation.
    let previous: BibleReaderCommentaryNavigationTarget?
    /// Next block target used only by explicit reader navigation.
    let next: BibleReaderCommentaryNavigationTarget?

    /** Returns the source target only when the accepted rendered document owns the exact key. */
    func target(matchingRenderedKey key: String) -> BibleReaderCommentaryNavigationTarget? {
        guard let current,
              SwordJavaStringIdentity.equals(current.key, key) else { return nil }
        return current
    }

    /** Returns the rendered document's source target for one exact source ordinal. */
    func target(matchingSourceOrdinal ordinal: Int) -> BibleReaderCommentaryNavigationTarget? {
        guard let current, current.sourceOrdinal == ordinal else { return nil }
        return current
    }
}
