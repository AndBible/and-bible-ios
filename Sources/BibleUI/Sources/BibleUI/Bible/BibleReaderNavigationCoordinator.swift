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
 plan mutations without retaining an observable controller. All numbers are one-based and already
 validated by the caller's active module/compatibility lookup.
 */
struct BibleReaderNavigationPosition: Equatable {
    /// User-facing book name.
    let book: String

    /// One-based chapter number.
    let chapter: Int

    /// One-based verse number.
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

    /// Records an Android-style history checkpoint after explicit navigation.
    let recordHistory: (_ book: String, _ chapter: Int, _ verse: Int) -> Void

    /// Persists mutated workspace/page state.
    let persistState: () -> Void

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
       chapter top to preserve Android's top-of-chapter behavior.
     */
    func restoreSavedPosition(
        _ position: BibleReaderNavigationPosition,
        ordinalForVerse: (_ book: String, _ chapter: Int, _ verse: Int) -> Int?
    ) {
        originalNavigationOrdinalRange = nil
        shouldRestoreScroll = false
        if position.verse > 1,
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
       - verse: Optional one-based verse; omitted navigation lands at the chapter top.
       - context: Controller-owned lookup, persistence, history, and reload callbacks.
     - Side effects: Mutates controller position through `context`, writes PageManager Bible fields,
       records history, persists workspace state, and reloads content when the Vue client is ready.
     - Failure modes: If no PageManager is available, controller state and history still update but
       no durable page-position write occurs; if the explicit verse has no ordinal, highlighting is
       skipped while navigation still lands on the requested verse number.
     */
    func navigateTo(book: String, chapter: Int, verse: Int? = nil, context: BibleReaderNavigationContext) {
        let resolvedVerse = max(1, verse ?? 1)
        let position = BibleReaderNavigationPosition(book: book, chapter: chapter, verse: resolvedVerse)
        context.setCurrentPosition(position)

        if let explicitVerse = verse,
           let ordinal = context.ordinalForVerse(book, chapter, max(1, explicitVerse)) {
            originalNavigationOrdinalRange = [ordinal, ordinal]
        } else {
            originalNavigationOrdinalRange = nil
        }

        if resolvedVerse > 1,
           let ordinal = context.ordinalForVerse(book, chapter, resolvedVerse) {
            lastScrollTarget = .ordinal(ordinal)
            shouldRestoreScroll = true
        } else {
            lastScrollTarget = .chapterTop
            shouldRestoreScroll = false
        }

        context.recordHistory(book, chapter, resolvedVerse)
        if let pageManager = context.pageManager() {
            write(position: position, to: pageManager, bookList: context.bookList())
            context.persistState()
        }

        guard context.clientReady() else { return }
        context.loadCurrentContent()
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
        if keyParts.count >= 2 {
            updateVisiblePositionFromKey(
                osisId: String(keyParts[0]),
                chapterText: String(keyParts[1]),
                ordinal: ordinal,
                context: context
            )
        } else if let reference = context.verseReference(previousPosition.book, ordinal) {
            var position = previousPosition
            position = BibleReaderNavigationPosition(
                book: position.book,
                chapter: reference.chapter,
                verse: reference.verse
            )
            context.setCurrentPosition(position)
            if let pageManager = context.pageManager() {
                write(position: position, to: pageManager, bookList: context.bookList())
                persistVisibleVerseState(immediate: false, persistState: context.persistState)
            }
        }

        return context.currentPosition() != previousPosition
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
       target ordinal as the next content restore anchor, and schedules visible-position persistence.
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
        context.setCurrentPosition(position)
        lastScrollTarget = .ordinal(ordinal)
        shouldRestoreScroll = true

        if let pageManager = context.pageManager() {
            write(position: position, to: pageManager, bookList: context.bookList())
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
        shouldRestoreScroll = false
        return restoreTarget
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
     - Failure modes: Non-numeric chapter strings are ignored to preserve the previous position.
     */
    private func updateVisiblePositionFromKey(
        osisId: String,
        chapterText: String,
        ordinal: Int,
        context: BibleReaderNavigationContext
    ) {
        var position = context.currentPosition()
        guard let chapter = Int(chapterText) else {
            return
        }

        if chapter != position.chapter {
            position = BibleReaderNavigationPosition(
                book: context.bookNameForOsisId(osisId) ?? position.book,
                chapter: chapter,
                verse: position.verse
            )
            if let pageManager = context.pageManager() {
                position = positionByResolvingVerse(
                    from: position,
                    ordinal: ordinal,
                    context: context
                )
                write(position: position, to: pageManager, bookList: context.bookList())
                persistVisibleVerseState(immediate: true, persistState: context.persistState)
            }
            context.setCurrentPosition(position)
        } else if let name = context.bookNameForOsisId(osisId), name != position.book {
            position = BibleReaderNavigationPosition(book: name, chapter: position.chapter, verse: position.verse)
            if let pageManager = context.pageManager() {
                position = positionByResolvingVerse(
                    from: position,
                    ordinal: ordinal,
                    context: context
                )
                write(position: position, to: pageManager, bookList: context.bookList())
                persistVisibleVerseState(immediate: true, persistState: context.persistState)
            }
            context.setCurrentPosition(position)
        } else if let pageManager = context.pageManager() {
            position = positionByResolvingVerse(from: position, ordinal: ordinal, context: context)
            context.setCurrentPosition(position)
            pageManager.bibleVerseNo = position.verse
            persistVisibleVerseState(immediate: false, persistState: context.persistState)
        }
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
