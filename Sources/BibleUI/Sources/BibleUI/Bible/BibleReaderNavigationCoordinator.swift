// BibleReaderNavigationCoordinator.swift -- Reader navigation and visible-position state machine

import Foundation
import BibleCore

/**
 Minimal book metadata required by reader navigation.

 The controller converts SWORD `BookInfo` values into this DTO so the navigation coordinator can
 own book-order and chapter-boundary rules without depending on SWORD module instances. This keeps
 Android/JSword-compatible versification lookups in the controller while letting navigation state
 transitions be tested independently.
 */
struct BibleReaderNavigationBook: Equatable {
    /// User-facing book name stored by the reader controller.
    let name: String

    /// OSIS identifier used in Vue scroll keys and history persistence.
    let osisId: String

    /// One-based chapter count for wrapping next/previous navigation.
    let chapterCount: Int
}

/**
 Current visible Bible position for a reader pane.

 The value is copied into and out of `BibleReaderController` through closures so the coordinator can
 plan mutations without retaining an observable controller. Ordinary locations are one-based;
 chapter/book introductions use verse zero (and chapter zero for a book introduction) only after an
 explicit ordinal proof from the caller's active source.
 */
struct BibleReaderNavigationPosition: Equatable {
    /// User-facing book name.
    let book: String

    /// One-based chapter, or zero for a verified book introduction.
    let chapter: Int

    /// One-based verse, or zero for a verified book/chapter introduction.
    let verse: Int
}

/**
 Verse identity resolved from a module-local ordinal.

 The controller supplies this value after converting through the active SWORD/JSword-compatible
 versification. The coordinator only needs the resulting chapter and verse, plus the OSIS id when a
 test or host wants to assert the source identity.
 */
struct BibleReaderNavigationVerseReference: Equatable {
    /// One-based chapter resolved from the ordinal.
    let chapter: Int

    /// One-based verse resolved from the ordinal.
    let verse: Int

    /// OSIS book identifier associated with the resolved verse.
    let osisBookId: String

    /// Exact source-module ordinal captured with the resolved verse.
    let ordinal: Int
}

/**
 Scroll target sent to the Vue reader after a chapter document is loaded.

 Chapter-top restoration and verse-anchor restoration are intentionally distinct because Android
 preserves chapter-top context separately from verse one. Treating both as ordinal `1` causes
 reloads and restored positions to jump to a verse anchor when they should land on the top marker.
 */
enum BibleReaderScrollRestoreTarget: Equatable {
    /// Restore to the document's top marker.
    case chapterTop

    /// Restore to an exact module-local verse ordinal.
    case ordinal(Int)
}

/**
 Controller-owned dependencies used by the navigation coordinator.

 The coordinator owns navigation rules and PageManager writes; the reader controller still owns
 observed state, SWORD/JSword-compatible lookup functions, history storage, bridge reloads, and
 Android synthetic document detection. Closures make those dependencies explicit and prevent the
 coordinator from retaining a controller.
 */
struct BibleReaderNavigationContext {
    /// Reads the current controller-visible position.
    let currentPosition: () -> BibleReaderNavigationPosition

    /// Writes a new controller-visible position.
    let setCurrentPosition: (BibleReaderNavigationPosition) -> Void

    /// Returns the active pane PageManager, if the pane is backed by durable workspace state.
    let pageManager: () -> PageManager?

    /// Returns the active module's ordered book list.
    let bookList: () -> [BibleReaderNavigationBook]

    /// Indicates whether the pane is showing Android's synthetic Multi document.
    let isShowingAndroidMultiDocument: () -> Bool

    /// Indicates whether the Vue reader client can receive reload events.
    let clientReady: () -> Bool

    /// Resolves chapter count for a user-facing book name.
    let chapterCount: (String) -> Int

    /// Resolves the next book in active module order.
    let nextBook: (String) -> String?

    /// Resolves the previous book in active module order.
    let previousBook: (String) -> String?

    /// Converts a scroll key OSIS identifier into the active module's user-facing book name.
    let bookNameForOsisId: (String) -> String?

    /// Resolves an exact verse ordinal in the active module's versification.
    let ordinalForVerse: (_ book: String, _ chapter: Int, _ verse: Int) -> Int?

    /// Resolves a module-local ordinal into a chapter/verse identity.
    let verseReference: (_ book: String, _ ordinal: Int) -> BibleReaderNavigationVerseReference?

    /// Admits and stages the Android-style location being left before navigation mutates state.
    let recordHistory: (_ book: String, _ chapter: Int, _ verse: Int) -> Bool

    /// Persists mutated workspace/page state.
    let persistState: () -> Void

    /// Scrolls to a target already retained by the current Vue document generation.
    let scrollToLoadedPosition: (_ position: BibleReaderNavigationPosition, _ highlight: Bool) -> Bool

    /// Reloads visible content through the reader controller.
    let loadCurrentContent: () -> Void
}

/**
 Owns Bible reader navigation state transitions for one pane.

 Android keeps current Bible page state, visible scroll callbacks, explicit navigation anchors, and
 next/previous chapter wrapping tied to one current-page manager workflow. This coordinator mirrors
 that shape on iOS: it updates `PageManager` Bible fields, records explicit navigation history,
 tracks the next render's highlight/restore target, and debounces intra-chapter visible-verse saves.

 - Important: Callers are expected to use this from the main actor/thread with the owning
   `BibleReaderController`. The class is intentionally not thread-safe because it mutates
   controller-adjacent state and schedules main-queue persistence work.
 */
final class BibleReaderNavigationCoordinator {
    /// Optional ordinal range rendered as the explicit navigation target on the next content load.
    private(set) var originalNavigationOrdinalRange: [Int]? = nil

    /// Last visible scroll target, preserving chapter-top context separately from verse ordinals.
    private var lastScrollTarget: BibleReaderScrollRestoreTarget = .chapterTop

    /// Whether the next content load should prefer `lastScrollTarget`.
    private var shouldRestoreScroll = false

    /// Pending debounced persistence work for noisy intra-chapter visible-verse callbacks.
    private var pendingVisibleVersePersistWorkItem: DispatchWorkItem?

    /**
     Restores the initial Bible scroll target from durable PageManager state.

     - Parameters:
       - position: Restored Bible book/chapter/verse.
       - ordinalForVerse: Active-module lookup used to convert the restored verse into an anchor.
     - Side effects: Clears explicit navigation highlighting and replaces the stored scroll target.
     - Failure modes: If the verse has no ordinal or is verse one, restoration falls back to the
       chapter top to preserve Android's top-of-chapter behavior. Verse zero restores only when the
       caller's active source resolves its exact introduction ordinal.
     */
    func restoreSavedPosition(
        _ position: BibleReaderNavigationPosition,
        ordinalForVerse: (_ book: String, _ chapter: Int, _ verse: Int) -> Int?
    ) {
        originalNavigationOrdinalRange = nil
        shouldRestoreScroll = false
        if position.verse == 0,
           let ordinal = ordinalForVerse(position.book, position.chapter, 0) {
            lastScrollTarget = .ordinal(ordinal)
            shouldRestoreScroll = true
        } else if position.verse > 1,
           let ordinal = ordinalForVerse(position.book, position.chapter, position.verse) {
            lastScrollTarget = .ordinal(ordinal)
        } else {
            lastScrollTarget = .chapterTop
        }
    }

    /**
     Marks the next content load as a same-position reload that should preserve the last scroll target.

     Display-setting changes rebuild the currently visible document without changing the Bible
     reference. Android preserves the active scroll context for that rebuild, so iOS keeps the
     existing target and only flips the one-shot restore flag.

     - Side effects: Updates coordinator state consumed by `consumeContentRestoreTarget`.
     - Failure modes: None; if no visible verse has ever been captured, the stored target remains
       chapter top.
     */
    func prepareForContentReload() {
        shouldRestoreScroll = true
    }

    /**
     Navigates to an explicit Bible location and persists the resulting PageManager state.

     - Parameters:
       - book: User-facing book name to make visible.
       - chapter: One-based chapter number.
       - verse: Optional one-based verse; omitted navigation lands at the chapter top. Zero is
         accepted only with `verifiedIntroductionOrdinal`.
       - verifiedIntroductionOrdinal: Exact active-source ordinal proving the requested zero verse.
       - context: Controller-owned lookup, persistence, history, and reload callbacks.
     - Returns: `true` after history admission and the requested location mutate reader state;
       `false` before mutation when history admission fails or an introduction proof is absent or stale.
     - Side effects: Mutates controller position through `context`, writes PageManager Bible fields,
       records the prior location, persists workspace state, and either scrolls retained content or reloads when
       the Vue client is ready.
     - Failure modes: Rejected history admission or an invalid introduction proof returns before
       reader state, PageManager, persistence, scroll, or reload mutation. If no PageManager is
       available after admission, controller state and history still update without a durable page
       position write. If an explicit verse has no ordinal, highlighting is skipped while navigation
       still lands on the requested verse number.
     */
    @discardableResult
    func navigateTo(
        book: String,
        chapter: Int,
        verse: Int? = nil,
        verifiedIntroductionOrdinal: Int? = nil,
        context: BibleReaderNavigationContext
    ) -> Bool {
        let introductionOrdinal: Int?
        if let verifiedIntroductionOrdinal {
            guard verse == 0,
                  chapter >= 0,
                  context.ordinalForVerse(book, chapter, 0) == verifiedIntroductionOrdinal else {
                return false
            }
            introductionOrdinal = verifiedIntroductionOrdinal
        } else {
            introductionOrdinal = nil
        }

        let previousPosition = context.currentPosition()
        guard context.recordHistory(
            previousPosition.book,
            previousPosition.chapter,
            previousPosition.verse
        ) else { return false }

        let resolvedVerse = introductionOrdinal == nil ? max(1, verse ?? 1) : 0
        let position = BibleReaderNavigationPosition(book: book, chapter: chapter, verse: resolvedVerse)
        context.setCurrentPosition(position)

        if let ordinal = introductionOrdinal {
            originalNavigationOrdinalRange = [ordinal, ordinal]
        } else if let explicitVerse = verse,
                  let ordinal = context.ordinalForVerse(book, chapter, max(1, explicitVerse)) {
            originalNavigationOrdinalRange = [ordinal, ordinal]
        } else {
            originalNavigationOrdinalRange = nil
        }

        if let ordinal = introductionOrdinal {
            lastScrollTarget = .ordinal(ordinal)
            shouldRestoreScroll = true
        } else if resolvedVerse > 1,
                  let ordinal = context.ordinalForVerse(book, chapter, resolvedVerse) {
            lastScrollTarget = .ordinal(ordinal)
            shouldRestoreScroll = true
        } else {
            lastScrollTarget = .chapterTop
            shouldRestoreScroll = false
        }

        if let pageManager = context.pageManager() {
            write(position: position, to: pageManager, bookList: context.bookList())
        }
        context.persistState()

        guard context.clientReady() else { return true }
        if context.scrollToLoadedPosition(position, verse != nil) {
            originalNavigationOrdinalRange = nil
            shouldRestoreScroll = false
            return true
        }
        context.loadCurrentContent()
        return true
    }

    /**
     Navigates to the next Bible chapter, wrapping into the next book when available.

     - Parameter context: Controller-owned state and lookup callbacks.
     - Side effects: Delegates to `navigateTo` when a next chapter exists.
     - Failure modes: Does nothing at the final chapter or while Android synthetic Multi content is
       visible, matching the existing reader controls.
     */
    func navigateNext(context: BibleReaderNavigationContext) {
        guard !context.isShowingAndroidMultiDocument() else { return }
        let position = context.currentPosition()
        let maxChapter = context.chapterCount(position.book)
        if position.chapter < maxChapter {
            navigateTo(book: position.book, chapter: position.chapter + 1, context: context)
        } else if let nextBook = context.nextBook(position.book) {
            navigateTo(book: nextBook, chapter: 1, context: context)
        }
    }

    /**
     Navigates to the previous Bible chapter, wrapping into the previous book when available.

     - Parameter context: Controller-owned state and lookup callbacks.
     - Side effects: Delegates to `navigateTo` when a previous chapter exists.
     - Failure modes: Does nothing at the first chapter or while Android synthetic Multi content is
       visible, matching the existing reader controls.
     */
    func navigatePrevious(context: BibleReaderNavigationContext) {
        guard !context.isShowingAndroidMultiDocument() else { return }
        let position = context.currentPosition()
        if position.chapter > 1 {
            navigateTo(book: position.book, chapter: position.chapter - 1, context: context)
        } else if let previousBook = context.previousBook(position.book) {
            navigateTo(book: previousBook, chapter: context.chapterCount(previousBook), context: context)
        }
    }

    /**
     Reports whether a next chapter is available for host controls.

     - Parameter context: Controller-owned state and lookup callbacks.
     - Returns: `true` when navigation can move forward from the current Bible position.
     - Side effects: None.
     - Failure modes: Returns `false` for Android synthetic Multi content so Bible-only controls do
       not advertise unavailable chapter movement.
     */
    func hasNext(context: BibleReaderNavigationContext) -> Bool {
        guard !context.isShowingAndroidMultiDocument() else { return false }
        let position = context.currentPosition()
        return position.chapter < context.chapterCount(position.book) || context.nextBook(position.book) != nil
    }

    /**
     Reports whether a previous chapter is available for host controls.

     - Parameter context: Controller-owned state and lookup callbacks.
     - Returns: `true` when navigation can move backward from the current Bible position.
     - Side effects: None.
     - Failure modes: Returns `false` for Android synthetic Multi content so Bible-only controls do
       not advertise unavailable chapter movement.
     */
    func hasPrevious(context: BibleReaderNavigationContext) -> Bool {
        guard !context.isShowingAndroidMultiDocument() else { return false }
        let position = context.currentPosition()
        return position.chapter > 1 || context.previousBook(position.book) != nil
    }

    /**
     Applies visible-verse telemetry reported by the Vue reader.

     - Parameters:
       - ordinal: Module-local verse ordinal near the viewport focus.
       - key: Vue document key, usually `OSIS.chapter` or `OSIS.chapter.verse`.
       - atChapterTop: Whether the viewport is at the chapter-top marker.
       - context: Controller-owned lookup, state, and persistence callbacks.
     - Returns: `true` when the visible Bible book/chapter/verse changed.
     - Side effects: Mutates controller position, writes PageManager Bible fields, updates the last
       scroll restore target, and persists immediately for chapter/book changes or debounced for
       same-chapter verse movement.
     - Failure modes: Invalid keys fall back to ordinal resolution in the current book; unresolved
       ordinals leave visible position unchanged.
     */
    @discardableResult
    func updateVisiblePosition(
        ordinal: Int,
        key: String,
        atChapterTop: Bool,
        context: BibleReaderNavigationContext
    ) -> Bool {
        let previousPosition = context.currentPosition()
        lastScrollTarget = atChapterTop ? .chapterTop : .ordinal(ordinal)

        let keyParts = key.split(separator: ".", omittingEmptySubsequences: true)
        if keyParts.count >= 2, Int(keyParts[1]) != nil {
            updateVisiblePositionFromKey(
                osisId: String(keyParts[0]),
                chapterText: String(keyParts[1]),
                ordinal: ordinal,
                context: context
            )
        } else if let reference = context.verseReference(previousPosition.book, ordinal) {
            let position = BibleReaderNavigationPosition(
                book: previousPosition.book,
                chapter: reference.chapter,
                verse: reference.verse
            )
            let pageManager = context.pageManager()
            _ = applyVisibleBiblePosition(
                position,
                pageManager: pageManager,
                context: context
            )
            if pageManager != nil {
                persistVisibleVerseState(immediate: false, persistState: context.persistState)
            }
        }

        return context.currentPosition() != previousPosition
    }

    /**
     Applies a visible source-Bible reference already captured outside the main scroll callback.

     Commentary documents report document-local anchor ordinals, so resolving those ordinals through
     the active Bible module can both block the main thread and select the wrong Bible verse. This
     entry point accepts the source-qualified reference captured with the commentary document and
     applies the same PageManager/debounce policy as ordinary visible Bible telemetry, without
     history, reload, or another SWORD/SQLite lookup.

     - Parameters:
       - reference: Exact source-Bible book, chapter, verse, and ordinal captured off-main.
       - context: Controller-owned state and persistence callbacks.
     - Returns: `true` only when the visible Bible position changed.
     - Side effects: Updates controller and PageManager Bible position, retains the source ordinal
       for a later Bible restore, and persists immediately across book/chapter boundaries or
       debounced within one chapter.
     - Failure modes: An OSIS book absent from the active book catalog leaves state unchanged.
     */
    @discardableResult
    func updateVisiblePosition(
        reference: BibleReaderNavigationVerseReference,
        context: BibleReaderNavigationContext
    ) -> Bool {
        let previousPosition = context.currentPosition()
        guard let book = context.bookNameForOsisId(reference.osisBookId) else { return false }
        let position = BibleReaderNavigationPosition(
            book: book,
            chapter: reference.chapter,
            verse: reference.verse
        )
        lastScrollTarget = .ordinal(reference.ordinal)
        let pageManager = context.pageManager()
        let changes = applyVisibleBiblePosition(
            position,
            pageManager: pageManager,
            context: context
        )
        if pageManager != nil,
           changes.positionChanged || changes.pageManagerChanged {
            persistVisibleVerseState(
                immediate: position.book != previousPosition.book
                    || position.chapter != previousPosition.chapter,
                persistState: context.persistState
            )
        }
        return changes.positionChanged
    }

    /**
     Applies a synchronized target verse that has already been converted into this pane's ordinal
     space.

     - Parameters:
       - book: Target pane book name.
       - chapter: Target chapter.
       - verse: Target verse.
       - ordinal: Target-local ordinal for the verse.
       - context: Controller-owned state and persistence callbacks.
     - Side effects: Updates controller position, writes PageManager Bible fields, records the
       target ordinal as the next content restore anchor, clears any superseded explicit-navigation
       highlight, and schedules visible-position persistence.
     - Failure modes: If no PageManager is available, native position and restore target still update
       while durable persistence is skipped.
     */
    func applySynchronizedVersePosition(
        book: String,
        chapter: Int,
        verse: Int,
        ordinal: Int,
        context: BibleReaderNavigationContext
    ) {
        let position = BibleReaderNavigationPosition(book: book, chapter: chapter, verse: verse)
        originalNavigationOrdinalRange = nil
        lastScrollTarget = .ordinal(ordinal)
        shouldRestoreScroll = true

        let pageManager = context.pageManager()
        _ = applyVisibleBiblePosition(
            position,
            pageManager: pageManager,
            context: context
        )
        if pageManager != nil {
            persistVisibleVerseState(immediate: false, persistState: context.persistState)
        }
    }

    /**
     Returns and consumes the scroll target for a newly loaded chapter document.

     - Parameters:
       - currentPosition: Current Bible position after the document has been built.
       - ordinalForVerse: Active-module lookup for the current verse.
     - Returns: The exact ordinal or chapter-top marker to pass to Vue `setup_content`.
     - Side effects: Clears the one-shot `shouldRestoreScroll` flag.
     - Failure modes: If no ordinal can be resolved for the current verse, returns `.chapterTop`.
     */
    func consumeContentRestoreTarget(
        currentPosition: BibleReaderNavigationPosition,
        ordinalForVerse: (_ book: String, _ chapter: Int, _ verse: Int) -> Int?
    ) -> BibleReaderScrollRestoreTarget {
        let restoreTarget = contentRestoreTarget(
            currentPosition: currentPosition,
            ordinalForVerse: ordinalForVerse
        )
        shouldRestoreScroll = false
        return restoreTarget
    }

    /**
     Peeks at the setup target without consuming it before bridge acceptance.

     Asynchronous document preparation can fail or be superseded after source capture. Keeping this
     read non-mutating lets a retry preserve the same explicit highlight or visible-scroll target.

     - Parameters:
       - currentPosition: Current Bible position represented by the prepared document.
       - ordinalForVerse: Active-source lookup for the current verse.
     - Returns: The exact ordinal or chapter-top marker to pass to Vue `setup_content`.
     - Side effects: None.
     - Failure modes: If no ordinal can be resolved for the current verse, returns `.chapterTop`.
     */
    func contentRestoreTarget(
        currentPosition: BibleReaderNavigationPosition,
        ordinalForVerse: (_ book: String, _ chapter: Int, _ verse: Int) -> Int?
    ) -> BibleReaderScrollRestoreTarget {
        let restoreTarget: BibleReaderScrollRestoreTarget
        if shouldRestoreScroll {
            restoreTarget = lastScrollTarget
        } else if currentPosition.verse > 1,
                  let ordinal = ordinalForVerse(
                    currentPosition.book,
                    currentPosition.chapter,
                    currentPosition.verse
                  ) {
            restoreTarget = .ordinal(ordinal)
        } else {
            restoreTarget = .chapterTop
        }
        return restoreTarget
    }

    /**
     Commits a setup target only after the bridge accepts its replacement document.

     - Parameter originalOrdinalRange: Explicit navigation range represented by the accepted setup.
     - Side effects: Clears one-shot scroll restoration and clears the original range when it still
       matches the accepted setup.
     - Failure modes: A superseding original range is preserved for its newer request.
     */
    func commitAcceptedContentRestore(originalOrdinalRange: [Int]?) {
        shouldRestoreScroll = false
        if self.originalNavigationOrdinalRange == originalOrdinalRange {
            self.originalNavigationOrdinalRange = nil
        }
    }

    /**
     Persists visible-verse state immediately or after a short debounce.

     - Parameters:
       - immediate: Whether persistence should happen synchronously.
       - persistState: Controller callback that saves mutated workspace state.
     - Side effects: Cancels any older debounced work item and may enqueue a main-queue save.
     - Failure modes: If the caller's persistence closure is a no-op because the controller has gone
       away, queued work harmlessly does nothing.
     */
    func persistVisibleVerseState(immediate: Bool, persistState: @escaping () -> Void) {
        pendingVisibleVersePersistWorkItem?.cancel()
        pendingVisibleVersePersistWorkItem = nil

        if immediate {
            persistState()
            return
        }

        let workItem = DispatchWorkItem(block: persistState)
        pendingVisibleVersePersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    /**
     Applies a parsed Vue key to the visible position.

     - Parameters:
       - osisId: OSIS book id from the Vue key.
       - chapterText: Chapter component from the Vue key.
       - ordinal: Visible ordinal reported with the key.
       - context: Controller-owned lookup, state, and persistence callbacks.
     - Side effects: Mutates controller position and PageManager fields when the key identifies a
       changed book/chapter or when the same-chapter ordinal resolves to a different verse.
     - Failure modes: Non-numeric chapter strings are handled by the caller's typed ordinal
       fallback because intro-inclusive document keys can be ranges such as `Matt.0-Matt.1`.
     */
    private func updateVisiblePositionFromKey(
        osisId: String,
        chapterText: String,
        ordinal: Int,
        context: BibleReaderNavigationContext
    ) {
        let previousPosition = context.currentPosition()
        guard let chapter = Int(chapterText) else {
            return
        }

        var position = previousPosition
        let isImmediateTransition: Bool
        if chapter != previousPosition.chapter {
            position = BibleReaderNavigationPosition(
                book: context.bookNameForOsisId(osisId) ?? previousPosition.book,
                chapter: chapter,
                verse: previousPosition.verse
            )
            isImmediateTransition = true
        } else if let name = context.bookNameForOsisId(osisId), name != previousPosition.book {
            position = BibleReaderNavigationPosition(
                book: name,
                chapter: previousPosition.chapter,
                verse: previousPosition.verse
            )
            isImmediateTransition = true
        } else {
            isImmediateTransition = false
        }

        guard let pageManager = context.pageManager() else {
            if isImmediateTransition {
                context.setCurrentPosition(position)
            }
            return
        }

        position = positionByResolvingVerse(from: position, ordinal: ordinal, context: context)
        _ = applyVisibleBiblePosition(
            position,
            pageManager: pageManager,
            context: context
        )
        persistVisibleVerseState(
            immediate: isImmediateTransition,
            persistState: context.persistState
        )
    }

    /**
     Resolves a visible ordinal into a position update.

     - Parameters:
       - position: Current candidate position.
       - ordinal: Visible ordinal reported by Vue.
       - context: Controller-owned ordinal resolver.
     - Returns: A position with the resolved verse when available, otherwise the original position.
     - Side effects: None.
     - Failure modes: Unresolved ordinals preserve the candidate position unchanged.
     */
    private func positionByResolvingVerse(
        from position: BibleReaderNavigationPosition,
        ordinal: Int,
        context: BibleReaderNavigationContext
    ) -> BibleReaderNavigationPosition {
        guard let reference = context.verseReference(position.book, ordinal) else {
            return position
        }
        return BibleReaderNavigationPosition(
            book: position.book,
            chapter: position.chapter,
            verse: reference.verse
        )
    }

    /**
     Applies one resolved Bible position without assigning fields that already match.

     - Parameters:
       - position: Resolved visible Bible position.
       - pageManager: Durable page state for the active window, when one exists.
       - context: Controller-owned observed position and active book catalog.
     - Returns: Independent flags for controller-coordinate and PageManager mutation.
     - Side effects: Publishes the controller position before mutating only the PageManager fields
       whose values differ, so immediate persistence observes one coherent target.
     - Failure modes: A missing PageManager still permits the controller position to advance but
       produces no durable mutation flag. An unresolved book index preserves the retained index while
       chapter and verse repairs remain available.
     */
    private func applyVisibleBiblePosition(
        _ position: BibleReaderNavigationPosition,
        pageManager: PageManager?,
        context: BibleReaderNavigationContext
    ) -> (positionChanged: Bool, pageManagerChanged: Bool) {
        let positionChanged = context.currentPosition() != position
        if positionChanged {
            context.setCurrentPosition(position)
        }

        guard let pageManager else {
            return (positionChanged, false)
        }
        let resolvedBookIndex = context.bookList().firstIndex { $0.name == position.book }
        var pageManagerChanged = false
        if let resolvedBookIndex,
           pageManager.bibleBibleBook != resolvedBookIndex {
            pageManager.bibleBibleBook = resolvedBookIndex
            pageManagerChanged = true
        }
        if pageManager.bibleChapterNo != position.chapter {
            pageManager.bibleChapterNo = position.chapter
            pageManagerChanged = true
        }
        if pageManager.bibleVerseNo != position.verse {
            pageManager.bibleVerseNo = position.verse
            pageManagerChanged = true
        }
        return (positionChanged, pageManagerChanged)
    }

    /**
     Writes a Bible position to a PageManager.

     - Parameters:
       - position: Current visible Bible position.
       - pageManager: Durable page state for the owning window.
       - bookList: Active module book order used to persist Android-style book index.
     - Side effects: Mutates `bibleBibleBook`, `bibleChapterNo`, and `bibleVerseNo`.
     - Failure modes: If the book is absent from `bookList`, the book index is written as `nil`
       while chapter and verse still persist.
     */
    private func write(
        position: BibleReaderNavigationPosition,
        to pageManager: PageManager,
        bookList: [BibleReaderNavigationBook]
    ) {
        pageManager.bibleBibleBook = bookList.firstIndex { $0.name == position.book }
        pageManager.bibleChapterNo = position.chapter
        pageManager.bibleVerseNo = position.verse
    }
}
