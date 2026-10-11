// PageManager+Cloning.swift -- Independent reader-state cloning

extension PageManager {
    /**
     Replaces this page manager's reader state with an independent value copy of another pane.

     Android clones `CurrentPageManager.entity` and restores every category-specific page before
     inserting the new row. This method mirrors that boundary while retaining this page manager's
     own identifier and window relationship.

     - Parameter source: Page manager whose complete persisted reader state should be copied.
     - Side Effects: Replaces all category documents and positions, the exact active category,
       window-scoped display overrides, legacy EPUB migration state, and serialized JavaScript
       state on the receiver.
     - Failure Modes: None. An unmarked or unknown-encoding source Bible position resets to
       Android's Genesis 1:1 default instead of copying an ambiguous module-list integer.
     - Important: `TextDisplaySettings` and its collections use value semantics, so later mutation
       of either pane cannot mutate the other pane through shared reader state.
     */
    func copyPersistedReaderState(from source: PageManager) {
        bibleDocument = source.bibleDocument
        let biblePosition = source.biblePositionForAndroid
        bibleVersification = biblePosition.versification
        bibleBibleBook = biblePosition.bookOrdinal
        bibleChapterNo = biblePosition.chapter
        bibleVerseNo = biblePosition.verse
        bibleBookEncoding = Self.jswordBibleBookEncoding

        commentaryDocument = source.commentaryDocument
        commentaryAnchorOrdinal = source.commentaryAnchorOrdinal

        dictionaryDocument = source.dictionaryDocument
        dictionaryKey = source.dictionaryKey

        generalBookDocument = source.generalBookDocument
        generalBookKey = source.generalBookKey

        mapDocument = source.mapDocument
        mapKey = source.mapKey

        epubIdentifier = source.epubIdentifier
        epubHref = source.epubHref

        currentCategoryName = source.currentCategoryName
        textDisplaySettings = source.textDisplaySettings
        jsState = source.jsState
    }
}
