// BibleReaderWindowSynchronizationSource.swift -- Reader participation in window synchronization

import BibleCore

/**
 Adapts a pane controller to BibleCore's immediate sync-group source contract.

 The payload remains source-local. `BibleReaderView`'s existing synchronization callback resolves it
 with `synchronizedVerseReference(ordinal:)`, and each target calls `scrollToSynchronizedVerse` to
 perform target-versification conversion and arm feedback suppression.
 */
extension BibleReaderController: WindowSynchronizationSource {
    /// Only Bible and commentary pages expose the verse key Android's `WindowSync` can copy.
    public var canProvideWindowSynchronizationPosition: Bool {
        switch currentCategory {
        case .bible, .commentary:
            return !isShowingAndroidMultiDocument && !isShowingAndroidMemorizeDocument
        default:
            return false
        }
    }

    /**
     Resolves this pane's current verse using its active Bible module.

     - Returns: A source-local ordinal plus OSIS key, or `nil` when the current page/reference cannot
       supply a sound verse key.
     - Side Effects: May temporarily move and restore the active SWORD module cursor.
     - Failure Modes: Non-verse pages, invalid chapter/verse state, unsupported books, and module
       lookup failures return `nil`; no raw ordinal is sent directly to a target pane.
     */
    public func currentWindowSynchronizationPosition() -> WindowSynchronizationPosition? {
        guard canProvideWindowSynchronizationPosition,
              currentChapter > 0,
              currentVerse >= 0 else {
            return nil
        }

        let osisBookId = bookList.first(where: { $0.name == currentBook })?.osisId
            ?? (activeModule == nil ? BibleReaderBookCatalog.osisBookId(for: currentBook) : "")
        guard !osisBookId.isEmpty else { return nil }

        let ordinal: Int?
        if let activeModule {
            ordinal = activeModule.verseOrdinal(
                osisBookId: osisBookId,
                chapter: currentChapter,
                verse: currentVerse
            )
        } else if currentVerse > 0 {
            ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: osisBookId,
                chapter: currentChapter,
                verse: currentVerse
            )
        } else {
            ordinal = nil
        }

        guard let ordinal, ordinal > 0 else { return nil }
        return WindowSynchronizationPosition(
            ordinal: ordinal,
            key: "\(osisBookId).\(currentChapter).\(currentVerse)"
        )
    }
}
