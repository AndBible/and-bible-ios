// BibleReaderWindowSynchronizationSource.swift -- Reader participation in window synchronization

import BibleCore

/**
 Adapts a pane controller to BibleCore's immediate sync-group source contract.

 The immutable payload includes its source versification and survives WindowManager debounce.
 My Notes publishes its authoritative fake-document KJVA position; ordinary Bible and accepted
 commentary pages publish their exact source-document coordinates. Targets perform strict mapping.
 */
extension BibleReaderController: WindowSynchronizationSource {
    /// Bible, accepted commentary, and accepted My Notes state expose authoritative sync identities.
    public var canProvideWindowSynchronizationPosition: Bool {
        if showingMyNotes { return activeMyNotesIntent != nil }
        switch currentCategory {
        case .bible, .commentary:
            return !isShowingAndroidMultiDocument && !isShowingAndroidMemorizeDocument
        default:
            return false
        }
    }

    /**
     Resolves this pane's current authoritative typed verse identity.

     - Returns: The accepted KJVA My Notes coordinate, captured commentary source coordinate, or
       active Bible coordinate together with its owning versification; `nil` when unavailable.
     - Side Effects: May temporarily move and restore the active SWORD module cursor.
     - Failure Modes: Non-verse pages and unresolved Bible positions return `nil`. Accepted notes
       and commentary positions do not require reconstructing an ordinal through the active Bible.
     */
    public func currentWindowSynchronizationPosition() -> WindowSynchronizationPosition? {
        if showingMyNotes, let intent = activeMyNotesIntent {
            let position = intent.kjvaPosition
            return WindowSynchronizationPosition(
                sourceVersification: JSwordKJVAVersification.name,
                osisBookId: position.osisBookID,
                chapter: position.chapter,
                verse: position.verse,
                sourceOrdinal: position.ordinal,
                sourceKey: position.key
            )
        }
        if currentCategory == .commentary,
           let target = commentaryNavigationAvailability.current {
            return WindowSynchronizationPosition(
                sourceVersification: target.sourceVersification,
                osisBookId: target.osisBookID,
                chapter: target.chapter,
                verse: target.verse,
                sourceOrdinal: target.sourceOrdinal,
                sourceKey: target.sourceKey
            )
        }
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
            sourceVersification: activeSourceVersificationName(),
            osisBookId: osisBookId,
            chapter: currentChapter,
            verse: currentVerse,
            sourceOrdinal: ordinal,
            sourceKey: "\(osisBookId).\(currentChapter).\(currentVerse)"
        )
    }
}
