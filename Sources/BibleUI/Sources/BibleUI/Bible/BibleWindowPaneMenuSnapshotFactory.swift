// BibleWindowPaneMenuSnapshotFactory.swift -- Shared Android window-menu state projection

import BibleCore

/**
 Builds the single Android window-popup snapshot used by pane buttons and restore-strip buttons.

 Android routes both entry points through `SplitBibleArea.showPopupMenu(window, view)`. Keeping the
 projection here prevents the bottom strip from recreating visibility, window ordering, document
 labels, or display-setting state independently from the pane menu.

 Inputs: one persisted window, the live window manager/controller registry, resolved window text
 settings, and installation-level AI availability

 Output: a pure `BibleWindowPaneMenuSnapshot` consumed by the shared menu model and renderer

 Side effects: none; controller and persistence state are read only

 Failure modes: missing controller state falls back to the persisted `PageManager`; missing labels
 remain nil so Android's formatted menu rows retain their empty-field behavior
 */
@MainActor
enum BibleWindowPaneMenuSnapshotFactory {
    /**
     Projects one live or restored window into the shared Android popup contract.

     - Parameters:
       - window: Window whose popup is being opened.
       - windowManager: Owner of window ordering, effective pinning, visibility, and controllers.
       - displaySettings: Fully resolved window-scoped text settings.
       - isAIConfigured: Whether Android's AI action row may be exposed.
       - recentTextSettings: Android-compatible recently changed text-setting types.
     - Returns: Complete menu snapshot for `BibleWindowPaneMenuModel`.
     - Side effects: None.
     - Failure modes: A controller that has not registered yet uses persisted page identity and
       conservative runtime capabilities.
     */
    static func snapshot(
        for window: BibleCore.Window,
        windowManager: WindowManager,
        displaySettings: TextDisplaySettings,
        isAIConfigured: Bool,
        referenceStore: BibleWindowMenuReferenceStore,
        recentTextSettings: [AndroidTextDisplaySettingType]
    ) -> BibleWindowPaneMenuSnapshot {
        let controller = windowManager.controllers[window.id] as? BibleReaderController
        let capabilities = BibleWindowPaneMenuCapabilities(window: window, controller: controller)
        let isVisible = window.layoutState != "minimized"
        let currentReference = controller?.windowMenuReference()
        let speakReference: BibleWindowMenuReference? = {
            guard isVisible,
                  controller?.speakService?.isSpeaking == true,
                  let position = controller?.speakService?.currentPosition else {
                return nil
            }
            return BibleWindowMenuReference.speechPosition(position)
        }()
        return BibleWindowPaneMenuSnapshot(
            windowID: window.id,
            isLinksWindow: window.isLinksWindow,
            isPinned: windowManager.isEffectivelyPinned(window),
            isSynchronized: window.isSynchronized,
            syncGroup: window.syncGroup,
            isVisible: isVisible,
            isMaximized: windowManager.isMaximized,
            canMinimize: window.layoutState != "minimized" && windowManager.visibleWindows.count > 1,
            canClose: windowManager.allWindows.count > 1,
            canSync: capabilities.canSyncWindow,
            canCopyLink: currentReference != nil,
            canAddWholePageBookmark: isVisible
                && controller?.createWindowMenuWholePageBookmarkEligibility == true,
            canExportHTML: isVisible && controller?.isWindowMenuHTMLExportAvailable == true,
            canExportStudyPad: isVisible && controller?.windowMenuStudyPadLabelID != nil,
            canExportStudyPadCSV: isVisible && controller?.windowMenuStudyPadLabelID != nil,
            copiedReferenceName: referenceStore.reference?.displayName,
            speakReferenceName: speakReference?.displayName,
            recentTextSettings: recentTextSettings,
            resolvedTextDisplaySettings: displaySettings,
            isBibleShown: controller?.currentCategory == .bible,
            isMyNotesShown: controller?.showingMyNotes == true,
            moduleHasRedLetterWords: controller?.hasRedLetterWords == true,
            autoPinEnabled: windowManager.activeWorkspace?.workspaceSettings?.autoPin
                ?? WorkspaceSettings.defaultAutoPin,
            moduleHasStrongs: controller?.hasStrongs ?? false,
            sectionTitlesEnabled: displaySettings.showSectionTitles ?? true,
            verseNumbersEnabled: displaySettings.showVerseNumbers ?? true,
            isAIConfigured: isAIConfigured,
            allWindowsInPersistedOrder: summaries(
                windowManager.windowsInPersistedOrder,
                windowManager: windowManager
            ),
            visibleWindows: summaries(windowManager.visibleWindows, windowManager: windowManager)
        )
    }

    /**
     Builds Android's durable reference URL for the current non-special Bible/commentary page.

     - Parameter controller: Registered reader controller for the target window.
     - Returns: A `read.andbible.org` URL or nil when Android would hide Copy reference.
     - Side effects: None.
     - Failure modes: Missing/special/non-verse content or missing module identity returns nil.
     */
    static func copyLinkURL(for controller: BibleReaderController?) -> String? {
        controller?.windowMenuReference()?.urlString
    }

    /** Builds stable window summaries for Android Move-to and Copy-settings submenus. */
    private static func summaries(
        _ windows: [BibleCore.Window],
        windowManager: WindowManager
    ) -> [BibleWindowPaneMenuWindowSummary] {
        windows.enumerated().map { index, candidate in
            let controller = windowManager.controllers[candidate.id] as? BibleReaderController
            return BibleWindowPaneMenuWindowSummary(
                id: candidate.id,
                position: index,
                documentAbbreviation: documentAbbreviation(for: candidate, controller: controller),
                referenceName: referenceName(for: candidate, controller: controller),
                isPinned: windowManager.isEffectivelyPinned(candidate)
            )
        }
    }

    /** Resolves Android's abbreviated document field from live state, then persisted state. */
    static func documentAbbreviation(
        for window: BibleCore.Window,
        controller: BibleReaderController?
    ) -> String? {
        if let controller {
            return controller.activeModuleName(for: controller.currentCategory)
        }
        guard let pageManager = window.pageManager else { return nil }
        switch pageManager.currentCategoryName {
        case DocumentCategory.bible.pageManagerKey:
            return pageManager.bibleDocument
        case DocumentCategory.commentary.pageManagerKey:
            return pageManager.commentaryDocument
        case DocumentCategory.dictionary.pageManagerKey:
            return pageManager.dictionaryDocument
        case DocumentCategory.generalBook.pageManagerKey:
            return pageManager.generalBookDocument
        case DocumentCategory.map.pageManagerKey:
            return pageManager.mapDocument
        case DocumentCategory.epub.pageManagerKey:
            return pageManager.epubIdentifier
        default:
            return pageManager.bibleDocument
        }
    }

    /** Resolves Android's key/reference field from live state, then persisted state. */
    static func referenceName(
        for window: BibleCore.Window,
        controller: BibleReaderController?
    ) -> String? {
        if let controller {
            switch controller.currentCategory {
            case .bible, .commentary:
                return "\(controller.currentBook) \(controller.currentChapter)"
            case .dictionary:
                return controller.currentDictionaryKey
            case .generalBook:
                return controller.currentGeneralBookKey
            case .map:
                return controller.currentMapKey
            case .epub:
                return controller.currentEpubTitle ?? controller.currentEpubHref
            case .dailyDevotion:
                return nil
            }
        }
        guard let pageManager = window.pageManager else { return nil }
        switch pageManager.currentCategoryName {
        case DocumentCategory.bible.pageManagerKey, DocumentCategory.commentary.pageManagerKey:
            if let book = pageManager.bibleBibleBook, let chapter = pageManager.bibleChapterNo {
                return "\(book):\(chapter)"
            }
            return nil
        case DocumentCategory.dictionary.pageManagerKey:
            return pageManager.dictionaryKey
        case DocumentCategory.generalBook.pageManagerKey:
            return pageManager.generalBookKey
        case DocumentCategory.map.pageManagerKey:
            return pageManager.mapKey
        case DocumentCategory.epub.pageManagerKey:
            return pageManager.epubHref
        default:
            return nil
        }
    }
}
