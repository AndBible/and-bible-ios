// BibleReaderPersistedBibleReference.swift — Fail-closed detached Bible labels

import Foundation
import BibleCore

/**
 Projects an explicitly canonical persisted Bible identity for UI surfaces without a live reader.

 Attached `BibleReaderController` state remains authoritative because it has the selected source's
 book catalog and addressability checks. This projection accepts only PageManagers marked with the
 stable JSword `BibleBook.ordinal()` encoding whose stored versification proves the complete
 chapter/verse address; legacy, unknown, incomplete, and impossible locations remain unlabeled.
 */
struct BibleReaderPersistedBibleReference: Equatable, Sendable {
    let osisBookID: String
    let chapter: Int
    let verse: Int

    /** Resolves one canonical and versification-addressable persisted location. */
    init?(pageManager: PageManager) {
        guard let osisBookID = pageManager.canonicalBibleOSISBookID,
              let chapter = pageManager.bibleChapterNo,
              let verse = pageManager.bibleVerseNo,
              let versification = pageManager.bibleVersification,
              !versification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              JSwordVersificationAddress.isValid(
                osisBookID: osisBookID,
                chapter: chapter,
                verse: verse,
                versification: versification
              ) else { return nil }
        self.osisBookID = osisBookID
        self.chapter = chapter
        self.verse = verse
    }

    /// Compact label used by the bottom window strip.
    var compactChapterName: String {
        "\(osisBookID) \(chapter)"
    }

    /// Localized chapter label used by detached pane-menu summaries.
    var localizedChapterName: String {
        "\(localizedBookName) \(chapter)"
    }

    /// Exact OSIS verse reference used by agent window-state output.
    var osisVerseReference: String {
        "\(osisBookID).\(chapter).\(verse)"
    }

    /// Localized verse label used by agent window-state output.
    var localizedVerseName: String {
        "\(localizedBookName) \(chapter):\(verse)"
    }

    private var localizedBookName: String {
        JSwordKJVAVersification.localizedLongBookName(osisId: osisBookID) ?? osisBookID
    }
}
