// BibleReaderController.swift — Handles bridge delegate for BibleReaderView

import Foundation
import BibleView
import BibleCore
import SwordKit
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "org.andbible", category: "BibleReaderController")

/**
 Coordinates BibleView bridge events, SWORD content loading, and native presentation callbacks.

 The controller owns the active module/category state for one window pane, translates native state
 into the JSON payloads consumed by the Vue.js reader, and routes bridge callbacks back into native
 sheets, compare flows, search, bookmarks, and history persistence.

 Data dependencies:
 - `BibleBridge` transports events between native code and the Vue.js reader
 - SWORD managers and modules provide Bible, commentary, dictionary, general-book, map, and EPUB
   content sources
 - optional services such as bookmarks, TTS, workspace storage, and settings are injected by the
   owning view

 Side effects:
 - mutates active reading state, emits bridge events, persists workspace/page state, and invokes
   native callback closures in response to user interaction and bridge events
 */
@Observable
public final class BibleReaderController: NSObject, BibleBridgeDelegate {
    private enum ScrollRestoreTarget {
        case chapterTop
        case ordinal(Int)
    }

    let bridge: BibleBridge
    var bookmarkService: BookmarkService?
    var myDocumentStore: MyDocumentStore?
    private(set) var currentBook: String = "Genesis"
    private(set) var currentChapter: Int = 1
    private(set) var currentVerse: Int = 1
    private var clientReady = false
    /**
     Ordinals for synchronized scroll requests that this pane initiated from another source pane.

     `scrollToOrdinal(_:)` records the target ordinal after successfully emitting to Vue. The next
     matching `didScrollToOrdinal` callback is then treated as secondary-window feedback: the pane
     state is updated, but the callback does not focus the pane or rebroadcast to `WindowManager`.

     Side effects:
     - values are inserted by sync-origin native scroll requests and removed by matching or stale
       scroll callbacks

     Failure modes:
     - a nonmatching callback clears stale pending values and is treated as user-origin scroll
     */
    private var pendingSynchronizedScrollOrdinals: Set<Int> = []

    /// Whether the WebView is currently showing the My Notes document (vs Bible text).
    private(set) var showingMyNotes = false
    /// Monotonic marker used by lightweight UI-test exports when My Notes state or documents rebuild.
    private(set) var myNotesMutationRevision = 0
    /// Prevents a launch-seeded UI-test append from firing more than once in the same reader session.
    private var didApplyUITestMyNotesAppendText = false

    /// Whether the WebView is currently showing a StudyPad document.
    private(set) var showingStudyPad = false
    /// Monotonic marker used by lightweight UI-test exports when StudyPad state mutates.
    private(set) var studyPadMutationRevision = 0
    /// Prevents a launch-seeded UI-test StudyPad note from firing more than once per reader session.
    private var didApplyUITestStudyPadCreatedNoteText = false
    /// The label ID of the currently active StudyPad.
    private(set) var activeStudyPadLabelId: UUID?
    /// The name of the currently active StudyPad label (for the header).
    private(set) var activeStudyPadLabelName: String?
    /// Whether the WebView is in editing mode (Quill editor active).
    private(set) var editingInWebView = false
    /// Whether the Vue reader client currently reports an open modal for this pane.
    private(set) var webModalIsOpen = false

    /// SWORD module manager and active Bible module
    private(set) var swordManager: SwordManager?
    private(set) var activeModule: SwordModule?
    private(set) var activeModuleName: String = "KJV"
    /// All installed Bible modules (for module switching)
    private(set) var installedBibleModules: [ModuleInfo] = []

    /**
     Dynamic book list from the active module's versification.
     Populated when a Bible module is loaded. Empty means either no module is active or the active
     module could not expose a safe module-specific book list.
     */
    private(set) var moduleBookList: [BookInfo] = []

    /// The active book list: uses the module's versification, or the 66-book default only with no module.
    var bookList: [BookInfo] {
        if !moduleBookList.isEmpty {
            return moduleBookList
        }
        return activeModule == nil ? Self.defaultBooks : []
    }

    /// Commentary module support
    private(set) var installedCommentaryModules: [ModuleInfo] = []
    private(set) var activeCommentaryModule: SwordModule?
    private(set) var activeCommentaryModuleName: String?
    private(set) var currentCategory: DocumentCategory = .bible

    /// Dictionary/Lexicon module support
    private(set) var installedDictionaryModules: [ModuleInfo] = []
    private(set) var activeDictionaryModule: SwordModule?
    private(set) var activeDictionaryModuleName: String?
    private(set) var currentDictionaryKey: String?

    /// General Book module support
    private(set) var installedGeneralBookModules: [ModuleInfo] = []
    private(set) var activeGeneralBookModule: SwordModule?
    private(set) var activeGeneralBookModuleName: String?
    private(set) var currentGeneralBookKey: String?

    /// Map module support
    private(set) var installedMapModules: [ModuleInfo] = []
    private(set) var activeMapModule: SwordModule?
    private(set) var activeMapModuleName: String?
    private(set) var currentMapKey: String?

    /// EPUB support
    private(set) var activeEpubReader: EpubReader?
    private(set) var activeEpubIdentifier: String?
    private(set) var activeEpubTitle: String?
    private(set) var currentEpubHref: String?
    private(set) var currentEpubTitle: String?

    /// Stable summary of the last content payload emitted to the reader WebView.
    static let emptyRenderedContentState = BibleReaderRenderedContentState.empty.encodedValue
    private static let issueTrackerURLString = "https://github.com/AndBible/and-bible/issues"
    private(set) var renderedContentState: String = BibleReaderController.emptyRenderedContentState
    /// Transient document that should be replayed once the Vue client has finished bootstrapping.
    private var pendingClientReadyTransientMultiDocument: TransientMultiDocumentRequest?
    /// Current My Documents page rendered through the local store rather than a SWORD module.
    private var activeMyDocumentBookInitials: String?
    /// Current My Documents page key rendered through the local store rather than a SWORD module.
    private var activeMyDocumentPageKey: String?

    /// Infinite scroll: tracks the range of chapters/books currently loaded in the WebView.
    private var minLoadedChapter: Int = 0
    private var maxLoadedChapter: Int = 0
    private var minLoadedBook: String = "Genesis"
    private var maxLoadedBook: String = "Genesis"

    /// Last rendered reading position, preserving chapter-top context separately from verse ordinals.
    private var lastScrollTarget: ScrollRestoreTarget = .chapterTop
    /// Whether the next loadCurrentChapter should restore scroll position (true = settings reload).
    private var shouldRestoreScroll = false
    /// Coalesces intra-chapter scroll persistence so visible-verse updates do not save SwiftData on every tick.
    private var pendingVisibleVersePersistWorkItem: DispatchWorkItem?
    /// Optional verse range that should render as the explicit navigation target on the next load.
    private var originalNavigationOrdinalRange: [Int]? = nil

    /**
     Captures a transient Vue `MultiDocument` load until the web client can receive it.

     Link-result panes may be created before their `BibleWebView` has sent `setClientReady`. The
     request stores the serialized document and rendered-content labels so the initial client-ready
     replay shows the same link result instead of briefly loading the cloned Bible location.
     */
    private struct TransientMultiDocumentRequest {
        /// Serialized Vue `MultiDocument` payload to emit.
        let documentJSON: String

        /// Rendered-content book token for accessibility and tab display.
        let renderedBook: String

        /// Rendered-content key token for accessibility and tab display.
        let renderedKey: String

        /// Rendered-content category token.
        let renderedCategory: DocumentCategory

        /// Optional rendered module token.
        let renderedModuleName: String?
    }

    /**
     Legacy ordinal fallback used only when no SWORD verse-key module can resolve the reference.

     Real Bible, commentary, cross-reference, bookmark, and memorization paths should use
     `verseOrdinal(...)` so ordinals come from the active SWORD/JSword-style versification. This
     fallback preserves placeholder rendering for startup and no-module states where there is no
     module cursor to query.
     */
    private func compatibilityOrdinal(chapter: Int, verse: Int) -> Int {
        BibleChapterDocumentBuilder.ordinal(chapter: chapter, verse: verse)
    }

    /**
     Resolves a verse ordinal through the active module's SWORD versification.

     - Parameters:
       - osisBookId: OSIS book identifier for the verse.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: The SWORD/JSword-style ordinal when available, the legacy placeholder ordinal when
       no module is present, or `nil` when the active module rejects the reference.
     - Side effects: May temporarily move the active SWORD module cursor; `SwordModule` restores it
       before returning.
     */
    private func verseOrdinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        if let activeModule {
            return activeModule.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
        }
        return compatibilityOrdinal(chapter: chapter, verse: verse)
    }

    /**
     Resolves a persisted ordinal back to a verse reference for a book.

     Android resolves these values through JSword's versification when building bookmark,
     memorization, and note payloads. iOS mirrors that by asking the active SWORD module to position
     a `VerseKey` by index, falling back to the historical placeholder calculation only when there
     is no active module available.

     - Parameters:
       - book: User-facing book name used to derive the OSIS identifier.
       - ordinal: Persisted verse ordinal.
     - Returns: A verse reference in the requested book, or `nil` for invalid ordinals.
     - Side effects: May temporarily move the active SWORD module cursor; `SwordModule` restores it
       before returning.
     */
    private func verseReference(book: String, ordinal: Int) -> VerseKeyReference? {
        guard ordinal > 0 else { return nil }
        let osisBookId = osisBookId(for: book)
        if let activeModule {
            return activeModule.verseReference(osisBookId: osisBookId, ordinal: ordinal)
        }

        let chapter = max(1, ((ordinal - 1) / 40) + 1)
        let verse = ordinal - ((chapter - 1) * 40)
        guard verse > 0 else { return nil }
        return VerseKeyReference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    /**
     Resolves a Bible bookmark ordinal for bookmark-list display and navigation.

     `BookmarkListView` does not own a SWORD manager. The active reader supplies this closure so the
     list uses the same SWORD/JSword-style versification semantics as rendered Bible content while
     keeping the view independent from module lifecycle concerns.

     - Parameters:
       - book: User-facing book name stored with the bookmark.
       - ordinal: Persisted verse ordinal.
     - Returns: A chapter/verse DTO for the bookmark list, or `nil` if the ordinal is invalid.
     - Side effects: May temporarily move the active SWORD module cursor; the module restores it
       before returning.
     */
    func bookmarkListVerseReference(book: String, ordinal: Int) -> BookmarkListVerseReference? {
        guard let reference = verseReference(book: book, ordinal: ordinal) else { return nil }
        return BookmarkListVerseReference(chapter: reference.chapter, verse: reference.verse)
    }

    /**
     Resolves the ordinal range for a chapter in the active module's versification.

     - Parameters:
       - book: User-facing book name.
       - chapter: One-based chapter number.
       - verseCount: Optional known last verse count; when omitted, the method asks the active
         module, or uses the static compatibility table only when there is no active module.
     - Returns: Start/end ordinals and the verse count used to compute the end, or `nil` when an
       active module cannot resolve the chapter exactly.
     - Side effects: May query the active SWORD module for verse counts and ordinals.
     */
    private func chapterOrdinalRange(book: String, chapter: Int, verseCount: Int? = nil) -> (start: Int, end: Int, verseCount: Int)? {
        let osisBookId = osisBookId(for: book)
        let resolvedVerseCount: Int
        if let verseCount {
            resolvedVerseCount = verseCount
        } else if let activeModule {
            guard let moduleVerseCount = activeModule.verseCount(osisBookId: osisBookId, chapter: chapter) else {
                return nil
            }
            resolvedVerseCount = moduleVerseCount
        } else {
            resolvedVerseCount = Self.verseCount(for: book, chapter: chapter)
        }
        guard let ordinalStart = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: 1),
              let ordinalEnd = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: resolvedVerseCount) else {
            return nil
        }
        return (ordinalStart, ordinalEnd, resolvedVerseCount)
    }

    /// Ordinal range for the current chapter using the active module's SWORD versification.
    private func currentChapterOrdinalRange() -> (start: Int, end: Int, verseCount: Int)? {
        chapterOrdinalRange(book: currentBook, chapter: currentChapter)
    }

    /// Snapshot factory that owns compact UI-test state assembly while the controller supplies state.
    private func accessibilitySnapshotFactory() -> BibleReaderAccessibilitySnapshotFactory {
        BibleReaderAccessibilitySnapshotFactory(
            bookmarkService: bookmarkService,
            currentBook: currentBook,
            currentChapter: currentChapter,
            showingMyNotes: showingMyNotes,
            showingStudyPad: showingStudyPad,
            editingInWebView: editingInWebView,
            myNotesMutationRevision: myNotesMutationRevision,
            studyPadMutationRevision: studyPadMutationRevision,
            activeStudyPadLabelId: activeStudyPadLabelId,
            activeStudyPadLabelName: activeStudyPadLabelName,
            chapterOrdinalRange: { [self] in
                currentChapterOrdinalRange()
            },
            verseReference: { [self] book, ordinal in
                verseReference(book: book, ordinal: ordinal)
            }
        )
    }

    /// Notes with non-empty payloads that belong to the currently visible chapter.
    private func currentChapterMyNotesBookmarks() -> [BibleBookmark] {
        accessibilitySnapshotFactory().currentChapterMyNotesBookmarks()
    }

    /// Typed My Notes state used to produce compact UI-test accessibility exports.
    var myNotesAccessibilitySnapshot: MyNotesAccessibilitySnapshot {
        accessibilitySnapshotFactory().myNotesAccessibilitySnapshot()
    }

    /// Compact My Notes state used by UI tests after opening the real visible My Notes document.
    var myNotesAccessibilityState: String {
        myNotesAccessibilitySnapshot.encodedValue
    }

    /// Typed StudyPad state used to produce compact UI-test accessibility exports.
    var studyPadAccessibilitySnapshot: StudyPadAccessibilitySnapshot {
        accessibilitySnapshotFactory().studyPadAccessibilitySnapshot()
    }

    /// Compact StudyPad state used by UI tests after opening the real visible StudyPad document.
    var studyPadAccessibilityState: String {
        studyPadAccessibilitySnapshot.encodedValue
    }

    /// Records the latest content identity that native requested the reader WebView to display.
    private func setRenderedContentState(
        category: DocumentCategory,
        moduleName: String?,
        book: String,
        chapter: Int? = nil,
        key: String? = nil
    ) {
        if category != .generalBook || moduleName != activeMyDocumentBookInitials {
            activeMyDocumentBookInitials = nil
            activeMyDocumentPageKey = nil
        }
        renderedContentState = BibleReaderRenderedContentState(
            category: category,
            moduleName: moduleName,
            book: book,
            chapter: chapter,
            key: key
        ).encodedValue
    }

    /// Whether the current module has Strong's numbers (matching Android CurrentPageManager.hasStrongs).
    var hasStrongs: Bool {
        switch currentCategory {
        case .bible:
            return activeModule?.info.features.contains(.strongsNumbers) == true
        case .commentary:
            return activeCommentaryModule?.info.features.contains(.strongsNumbers) == true
        default:
            return false
        }
    }

    /// Resolved text display settings used for Vue.js config
    var displaySettings: TextDisplaySettings = .appDefaults
    /// Night mode toggle
    var nightMode: Bool = false
    /// Document IDs hidden in compare view (toggled via toggleCompareDocument bridge method)
    var hiddenCompareDocuments: Set<String> = []

    /// Latest asynchronous compare request used to ignore stale background payloads.
    private var compareDocumentRequestID = UUID()
    /// TTS service
    var speakService: SpeakService?
    /// Speech-specific collaborator that builds TTS payloads and owns word-highlight state.
    private let speechCoordinator = BibleReaderSpeechCoordinator()
    /// Workspace store for history recording
    var workspaceStore: WorkspaceStore?
    /// The current window (for history recording)
    var activeWindow: Window?

    /**
     Creates one controller for a single `BibleView` bridge instance.

     - Parameters:
       - bridge: Bridge used to emit events to the Vue.js reader and receive callbacks.
       - bookmarkService: Optional bookmark/studypad service used for annotation features.
       - initializesSword: Whether to initialize SWORD immediately. Pane controllers that will
         copy an existing controller's shared module state pass `false` to avoid creating a
         transient extra `SwordManager`.

     Side effects:
     - assigns itself as the bridge delegate
     - initializes SWORD state and installed-module caches when `initializesSword` is `true`

     Failure modes:
     - if SWORD initialization is requested and `SwordManager` creation fails, the controller
       remains usable for placeholder/fallback rendering with empty installed-module caches.
     */
    public init(
        bridge: BibleBridge,
        bookmarkService: BookmarkService? = nil,
        initializesSword: Bool = true
    ) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        super.init()
        bridge.delegate = self
        if initializesSword {
            initializeSwordIfNeeded()
        }
    }

    init(bridge: BibleBridge, bookmarkService: BookmarkService? = nil, swordManagerOverride: SwordManager) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        super.init()
        bridge.delegate = self
        configureSwordManager(swordManagerOverride)
    }

    /**
     Callback for pane-owned routing of transient dictionary-style documents.

     The controller builds already-serialized Vue `MultiDocument` payloads for Strong's,
     morphology, and word-lookup dictionary results. The owning pane decides whether those payloads
     render in the current pane or in the Android-style links target window.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload.
       - renderedBook: Accessibility/test-state book token for the transient document.
       - renderedKey: Accessibility/test-state key token for the transient document.
     - Returns: The closure returns no value; the owner reports completion by rendering in the
       selected target controller.
     - Side effects: None in the controller until the owning closure calls back into a target
       controller to render the payload.
     - Failure modes: If no owner installs the closure, `openDefinitionDocument(...)` falls back
       to rendering in the current controller.
     */
    var onOpenDefinitionDocumentInLinksWindow: ((String, String, String) -> Void)?

    /// Callback for opening search with a Strong's number (from "Find all occurrences" links).
    var onShowStrongsSearch: ((String) -> Void)?

    /**
     Legacy callback for native cross-reference sheets.

     Multi-reference Bible links intentionally bypass this callback and render Vue
     `MultiDocument` payloads so iOS follows Android's shared document pipeline.
     */
    var onShowCrossReferences: (([CrossReference]) -> Void)?

    /**
     Callback for opening a transient multi-reference Vue document in the Android-style links window.

     The string parameter is a serialized `MultiDocument` payload. The owning pane decides whether
     to route it into a dedicated links window or render it in the current controller.
     */
    var onOpenMultiReferenceDocumentInLinksWindow: ((String) -> Void)?

    /// Callback for presenting native AI regeneration for a validated My Documents page.
    var onRegenerateMyDocumentPage: ((MyDocumentAIPageActionContext) -> Void)?

    /// Callback for presenting native label assignment UI (bookmarkId).
    var onAssignLabels: ((UUID) -> Void)?

    /// Callback for presenting native reading-progress UI with Android tab index semantics.
    var onShowReadingProgress: ((Int) -> Void)?

    /// Callback for presenting native reading-progress settings UI.
    var onShowReadingProgressSettings: (() -> Void)?

    /// Callback for presenting native chapter-read history UI.
    var onShowChapterReadHistory: ((ChapterReadHistoryTarget) -> Void)?

    /// Settings store for reading preferred dictionary setting and local bridge-backed state.
    var settingsStore: SettingsStore? {
        didSet {
            memorizationProgressStore = settingsStore.map(MemorizationProgressStore.init(settingsStore:))
            readingProgressStore = settingsStore.map(ReadingProgressStore.init(settingsStore:))
        }
    }

    /// Local iOS memorization state backing Android-style memorization bridge methods.
    var memorizationProgressStore: MemorizationProgressStore?

    /// Local iOS reading-progress state backing Android-style chapter-read bridge methods.
    var readingProgressStore: ReadingProgressStore?

    /// Callback to persist SwiftData changes (called after PageManager updates).
    var onPersistState: (() -> Void)?

    /// Persists the current page-manager state either immediately or after a short debounce for scroll updates.
    private func persistVisibleVerseState(immediate: Bool) {
        pendingVisibleVersePersistWorkItem?.cancel()
        pendingVisibleVersePersistWorkItem = nil

        guard let onPersistState else { return }

        if immediate {
            onPersistState()
            return
        }

        let workItem = DispatchWorkItem(block: onPersistState)
        pendingVisibleVersePersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    /// Update display settings and re-emit config to Vue.js.
    public func updateDisplaySettings(_ settings: TextDisplaySettings, nightMode: Bool) {
        self.displaySettings = settings
        self.nightMode = nightMode
        applySwordOptions()
        applyNightModeBackground()
        guard clientReady else { return }
        bridge.emit(event: "set_config", data: buildConfigJSON())
        // Reload to re-render with new options; restore scroll position for same-chapter reload
        shouldRestoreScroll = true
        loadCurrentContent()
    }

    /// Inject CSS to set the page background for night/day mode using display settings colors.
    private func applyNightModeBackground() {
        let s = displaySettings
        let d = TextDisplaySettings.appDefaults
        let bgInt = nightMode
            ? (s.nightBackground ?? d.nightBackground ?? -16777216)
            : (s.dayBackground ?? d.dayBackground ?? -1)
        let fgInt = nightMode
            ? (s.nightTextColor ?? d.nightTextColor ?? -1)
            : (s.dayTextColor ?? d.dayTextColor ?? -16777216)
        let bg = Self.cssColor(fromArgbInt: bgInt)
        let fg = Self.cssColor(fromArgbInt: fgInt)
        bridge.webView?.evaluateJavaScript("""
        document.documentElement.style.backgroundColor = '\(bg)';
        document.body.style.backgroundColor = '\(bg)';
        document.body.style.color = '\(fg)';
        var content = document.getElementById('content');
        if (content) {
            content.style.paddingTop = '8px';
            content.style.paddingBottom = '16px';
        }
        // Inject CSS overrides for margins and TTS highlighting
        if (!document.getElementById('ios-margin-fix')) {
            var s = document.createElement('style');
            s.id = 'ios-margin-fix';
            s.textContent = '#content { padding-left: 16px !important; padding-right: 16px !important; max-width: none !important; } .speaking-verse { background-color: rgba(100, 149, 237, 0.12); border-radius: 4px; transition: background-color 0.3s ease; } #speaking-word { background-color: rgba(100, 149, 237, 0.45); border-radius: 3px; padding: 1px 0; }';
            document.head.appendChild(s);
        }
        """)
    }

    /// Convert a signed ARGB integer (Android/Vue.js convention) to a CSS hex color string.
    private static func cssColor(fromArgbInt value: Int) -> String {
        let uint = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        let r = (uint >> 16) & 0xFF
        let g = (uint >> 8) & 0xFF
        let b = uint & 0xFF
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    /**
     Speak the current chapter using TTS with word-level highlighting.

     SWORD's `stripText()` is affected by global options — when Strong's Numbers
     or Morphology are enabled, it includes tokens like "H7225" in the plain text
     output. This corrupts TTS and causes `AVSpeechSynthesizer` to finish the
     utterance prematurely, triggering auto-advance to the next chapter.
     To prevent this, Strong's and Morphology are temporarily disabled during
     text extraction and restored immediately after.
     */
    public func speakCurrentChapter() {
        guard let service = speakService, let context = makeSpeechContext() else { return }
        speechCoordinator.speakCurrentChapter(service: service, context: context)
    }

    /**
     Speak a specific verse range using TTS.

     See `speakCurrentChapter()` for details on why Strong's/Morphology options
     are temporarily disabled during text extraction.
     */
    private func speakVerseRange(startOrdinal: Int, endOrdinal: Int) {
        guard let service = speakService, let context = makeSpeechContext() else { return }
        speechCoordinator.speakVerseRange(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            service: service,
            context: context
        )
    }

    /**
     Speak a specific verse range repeatedly for Android memorization-loop parity.
     */
    private func speakMemorizationLoopRange(startOrdinal: Int, endOrdinal: Int) {
        guard let service = speakService, let context = makeSpeechContext() else { return }
        speechCoordinator.speakMemorizationLoopRange(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            service: service,
            context: context
        )
    }

    /**
     Builds the speech collaborator context from the controller's current reader state.

     The context captures only the dependencies required for speech extraction and highlight
     emission. Closures capture the controller or bridge weakly so `SpeakService` callbacks do not
     retain the reader controller after the pane is dismissed.
     */
    private func makeSpeechContext() -> BibleReaderSpeechContext? {
        guard let module = activeModule else { return nil }
        return BibleReaderSpeechContext(
            module: module,
            swordManager: swordManager,
            currentBook: currentBook,
            currentChapter: currentChapter,
            activeModuleName: activeModuleName,
            displaySettings: displaySettings,
            osisBookId: { [weak self] bookName in
                self?.osisBookId(for: bookName) ?? BibleReaderController.osisBookId(for: bookName)
            },
            parseVerseKey: { [weak self] key in
                self?.parseVerseKey(key)
            },
            verseOrdinal: { [weak self] osisBookId, chapter, verse in
                self?.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
            },
            evaluateJavaScript: { [weak bridge] js in
                bridge?.webView?.evaluateJavaScript(js)
            }
        )
    }

    /// Switch to a different installed Bible module.
    public func switchModule(to moduleName: String) {
        guard let mgr = swordManager,
              let mod = mgr.module(named: moduleName) else {
            logger.warning("Cannot switch to module \(moduleName) — not found")
            return
        }
        activeModule = mod
        activeModuleName = moduleName
        refreshBookList()
        logger.info("Switched to module: \(moduleName) (\(self.moduleBookList.count) books)")

        // Persist module selection to PageManager
        if let pm = activeWindow?.pageManager {
            pm.bibleDocument = moduleName
            onPersistState?()
        }

        // Reload the current chapter with the new module
        guard clientReady else { return }
        loadCurrentContent()
    }

    /// Switch to a different installed commentary module.
    public func switchCommentaryModule(to moduleName: String) {
        guard let mgr = swordManager,
              let mod = mgr.module(named: moduleName) else {
            logger.warning("Cannot switch to commentary module \(moduleName) — not found")
            return
        }
        activeCommentaryModule = mod
        activeCommentaryModuleName = moduleName
        logger.info("Switched to commentary module: \(moduleName)")

        // Persist to PageManager
        if let pm = activeWindow?.pageManager {
            pm.commentaryDocument = moduleName
            onPersistState?()
        }

        // Reload if currently viewing commentary
        guard clientReady, currentCategory == .commentary else { return }
        loadCurrentContent()
    }

    /// Switch the active dictionary module.
    public func switchDictionaryModule(to moduleName: String) {
        guard let mgr = swordManager,
              let mod = mgr.module(named: moduleName) else {
            logger.warning("Cannot switch to dictionary module \(moduleName) — not found")
            return
        }
        activeDictionaryModule = mod
        activeDictionaryModuleName = moduleName
        currentDictionaryKey = nil
        logger.info("Switched to dictionary module: \(moduleName)")

        if let pm = activeWindow?.pageManager {
            pm.dictionaryDocument = moduleName
            pm.dictionaryKey = nil
            onPersistState?()
        }
    }

    /// Switch the active general book module.
    public func switchGeneralBookModule(to moduleName: String) {
        guard let mgr = swordManager,
              let mod = mgr.module(named: moduleName) else {
            logger.warning("Cannot switch to general book module \(moduleName) — not found")
            return
        }
        activeGeneralBookModule = mod
        activeGeneralBookModuleName = moduleName
        currentGeneralBookKey = nil
        logger.info("Switched to general book module: \(moduleName)")

        if let pm = activeWindow?.pageManager {
            pm.generalBookDocument = moduleName
            pm.generalBookKey = nil
            onPersistState?()
        }
    }

    /// Switch the active map module.
    public func switchMapModule(to moduleName: String) {
        guard let mgr = swordManager,
              let mod = mgr.module(named: moduleName) else {
            logger.warning("Cannot switch to map module \(moduleName) — not found")
            return
        }
        activeMapModule = mod
        activeMapModuleName = moduleName
        currentMapKey = nil
        logger.info("Switched to map module: \(moduleName)")

        if let pm = activeWindow?.pageManager {
            pm.mapDocument = moduleName
            pm.mapKey = nil
            onPersistState?()
        }
    }

    /// Switch between document categories (Bible, Commentary, Dictionary, General Book, Map).
    public func switchCategory(to category: DocumentCategory) {
        let oldCategory = currentCategory
        currentCategory = category

        // Persist to PageManager
        if let pm = activeWindow?.pageManager {
            pm.currentCategoryName = category.pageManagerKey
            onPersistState?()
        }

        // Reload content if the category actually changed
        guard clientReady, category != oldCategory else { return }
        loadCurrentContent()
    }

    /// Load the appropriate content for the current category.
    public func loadCurrentContent() {
        switch currentCategory {
        case .commentary:
            loadCommentaryForCurrentVerse()
        case .dictionary:
            loadDictionaryEntry()
        case .generalBook:
            loadGeneralBookEntry()
        case .map:
            loadMapEntry()
        case .epub:
            loadEpubEntry()
        default:
            loadCurrentChapter()
        }
    }

    /**
     Displays a transient Vue `MultiDocument` made from Bible reference fragments.

     - Parameter documentJSON: Serialized multi-document payload produced by
       `buildBibleMultiReferenceDocumentJSON(refs:)`.
     - Side effects: clears the current Vue document, emits labels, emits the supplied document and
       setup payload, resets selection state, updates the rendered-content accessibility token, and
       reapplies the reader background. It intentionally does not persist PageManager category or
       location state because Android treats multi-reference documents as link results, not the
       owning Bible position.
     - Failure modes: assumes the payload is already valid JSON; invalid payloads are forwarded to
       the Vue bridge after the transient reader state is prepared, so caller-owned builders should
       validate or serialize before invoking this method.
     */
    func loadMultiReferenceDocument(_ documentJSON: String) {
        loadTransientMultiDocument(documentJSON, renderedBook: "Multi", renderedKey: "multi")
    }

    /**
     Displays an Android-style compare `MultiDocument` for the active passage.

     - Parameters:
       - startVerse: Optional first verse in the compare range. `nil` compares from verse 1.
       - endVerse: Optional final verse in the compare range. `nil` compares through the chapter's
         module-reported final verse.
     - Side effects: reads installed Bible modules from SWORD, clears and replaces the current Vue
       document with a transient compare document after the payload is built off the main queue,
       emits label/config state, clears any selection, updates rendered-content test state, and
       reapplies the reader background.
     - Failure modes: returns without changing the reader when no SWORD manager is available, no
       installed Bible module can render the requested range, or the compare payload cannot be
       serialized.
     */
    func loadCompareDocument(startVerse: Int? = nil, endVerse: Int? = nil) {
        guard let request = makeBibleCompareDocumentRequest(startVerse: startVerse, endVerse: endVerse) else {
            return
        }
        let requestID = UUID()
        compareDocumentRequestID = requestID

        DispatchQueue.global(qos: .userInitiated).async {
            let documentJSON = Self.buildBibleCompareDocumentJSON(request)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.compareDocumentRequestID == requestID,
                      let documentJSON else {
                    return
                }
                self.loadTransientMultiDocument(documentJSON, renderedBook: "Compare", renderedKey: "compare")
            }
        }
    }

    /**
     Emits one already-serialized transient Vue `MultiDocument`.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload to add to the Vue document list.
       - renderedBook: Accessibility/test-state book token for the transient document.
       - renderedKey: Accessibility/test-state key token for the transient document.
       - renderedCategory: Category token to expose through rendered-content state.
       - renderedModuleName: Optional module token to expose through rendered-content state; defaults
         to the active Bible module for existing Bible-backed transient documents.
     - Side effects: clears the current Vue document, emits labels, emits the supplied document and
       setup payload, resets selection/editing flags, updates rendered-content accessibility state,
       emits active-window state, clears the web selection, and reapplies the reader background.
     - Failure modes: assumes `documentJSON` is valid JSON; invalid payloads are still forwarded
       after transient reader state is prepared.
     */
    private func loadTransientMultiDocument(
        _ documentJSON: String,
        renderedBook: String,
        renderedKey: String,
        renderedCategory: DocumentCategory = .bible,
        renderedModuleName: String? = nil
    ) {
        let request = TransientMultiDocumentRequest(
            documentJSON: documentJSON,
            renderedBook: renderedBook,
            renderedKey: renderedKey,
            renderedCategory: renderedCategory,
            renderedModuleName: renderedModuleName
        )
        if clientReady {
            pendingClientReadyTransientMultiDocument = nil
        } else {
            pendingClientReadyTransientMultiDocument = request
        }
        emitTransientMultiDocument(request)
    }

    /**
     Emits a transient Vue `MultiDocument` request to the current bridge.

     - Parameter request: Stored transient document request with payload and native display labels.
     - Side effects: Clears the current Vue document, emits labels and document/setup events,
       resets transient selection/editing state, updates rendered-content state, emits active-window
       state, clears web selection, and reapplies the reader background.
     - Failure modes: Invalid JSON is forwarded unchanged to the bridge, matching the existing
       transient document contract.
     */
    private func emitTransientMultiDocument(_ request: TransientMultiDocumentRequest) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""
        currentCategory = .bible

        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()
        bridge.emit(event: "add_documents", data: request.documentJSON)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
        setRenderedContentState(
            category: request.renderedCategory,
            moduleName: request.renderedModuleName ?? activeModuleName,
            book: request.renderedBook,
            key: request.renderedKey
        )
        emitActiveState()

        bridge.clearSelection()
        applyNightModeBackground()
    }

    /**
     Loads commentary for the currently selected Bible verse.

     Android's `CurrentCommentaryPage` is a single-key page backed by JSword `BookData(book, key)`;
     it does not walk the current chapter when the user switches to a commentary. iOS mirrors that
     contract by resolving the selected verse once, reading exactly that SWORD key, and emitting a
     verse-level document key and ordinal range. Missing commentary entries are still represented as
     the selected verse so tabs, highlights, and restored state stay tied to the same passage.

     Side effects:
     - clears the current Vue document, emits labels and a commentary document, updates rendered
       content state, emits active-window state, clears selection, and reapplies the reader
       background.

     Failure modes:
     - when no commentary module is selected or the selected module has no exact entry for the
       current verse, emits a deterministic no-content commentary document for the selected verse.
     */
    private func loadCommentaryForCurrentVerse() {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        let osisBookId = osisBookId(for: currentBook)
        let chapter = currentChapter
        let verse = max(1, currentVerse)
        let verseKey = "\(osisBookId).\(chapter).\(verse)"
        let verseTitle = "\(currentBook) \(chapter):\(verse)"
        guard let selectedOrdinal = activeCommentaryModule?.verseOrdinal(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse
        ) ?? verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse) else {
            logger.error("Failed to resolve commentary ordinal for \(osisBookId, privacy: .public).\(chapter).\(verse)")
            return
        }
        let selectedOrdinalRange = [selectedOrdinal, selectedOrdinal]
        let selectedVerseBookmarks = bookmarkService?.bookmarks(
            for: selectedOrdinal,
            endOrdinal: selectedOrdinal,
            book: currentBook
        ) ?? []

        guard let module = activeCommentaryModule else {
            // No commentary module selected — show a message
            bridge.emit(event: "clear_document")
            let xml = buildCommentaryVerseXML(
                osisBookId: osisBookId,
                bookName: currentBook,
                chapter: chapter,
                verse: verse,
                ordinal: selectedOrdinal,
                bodyXML: "<p>No commentary module is installed. Download one from the module browser.</p>",
                title: "No Commentary"
            )
            guard let document = buildDocumentJSON(
                osisBookId: osisBookId,
                bookName: currentBook,
                chapter: chapter,
                verseCount: 1,
                isNT: isNewTestament(currentBook),
                xml: xml,
                bookmarks: [],
                bookCategory: "COMMENTARY",
                bookInitials: "none",
                addChapter: false,
                documentKey: verseKey,
                keyName: verseTitle,
                ordinalRangeOverride: selectedOrdinalRange
            ) else { return }
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: """
            {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
            """)
            setRenderedContentState(
                category: .commentary,
                moduleName: activeCommentaryModuleName,
                book: currentBook,
                chapter: chapter,
                key: verseKey
            )
            applyNightModeBackground()
            return
        }

        let isNT = isNewTestament(currentBook)
        let moduleName = activeCommentaryModuleName ?? "Commentary"
        let inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious("=\(verseKey)")
        let rawText = inspection.verseKey.flatMap { key -> String? in
            guard key.osisBookName == osisBookId,
                  key.chapter == chapter,
                  key.verse == verse else {
                return nil
            }
            let trimmed = inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let bodyXML = rawText.map(Self.commentaryVerseBodyXML(from:))
            ?? "<p>No commentary available for this verse in \(moduleName).</p>"
        let xml = buildCommentaryVerseXML(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: chapter,
            verse: verse,
            ordinal: selectedOrdinal,
            bodyXML: bodyXML,
            title: verseTitle
        )

        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()

        guard let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: chapter,
            verseCount: 1,
            isNT: isNT,
            xml: xml,
            bookmarks: selectedVerseBookmarks,
            bookCategory: "COMMENTARY",
            bookInitials: moduleName,
            addChapter: false,
            documentKey: verseKey,
            keyName: verseTitle,
            ordinalRangeOverride: selectedOrdinalRange
        ) else { return }
        bridge.emit(event: "add_documents", data: document)

        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
        setRenderedContentState(
            category: .commentary,
            moduleName: moduleName,
            book: currentBook,
            chapter: chapter,
            key: verseKey
        )
        emitActiveState()

        bridge.clearSelection()
        applyNightModeBackground()
    }

    /**
     Builds a verse-scoped commentary OSIS fragment for the Vue reader.

     - Parameters:
       - osisBookId: OSIS book identifier for the selected Bible verse.
       - bookName: Display book name for titles.
       - chapter: Selected chapter.
       - verse: Selected verse.
       - ordinal: JSword/SWORD ordinal for the selected verse.
       - bodyXML: Commentary body XML or no-content message already prepared for the verse body.
       - title: Title to display above the commentary content.
     - Returns: A small OSIS fragment with one verse wrapper and paragraph milestones.
     - Side effects: None.
     - Failure modes: None; callers supply XML that the reader already accepts.
     */
    private func buildCommentaryVerseXML(
        osisBookId: String,
        bookName: String,
        chapter: Int,
        verse: Int,
        ordinal: Int,
        bodyXML: String,
        title: String
    ) -> String {
        let osisRef = "\(osisBookId).\(chapter).\(verse)"
        let body = bodyXML.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <div><title type="x-gen">\(title)</title><div sID="p1" type="paragraph"/><verse osisID="\(osisRef)" verseOrdinal="\(ordinal)">\(body) </verse><div eID="p1" type="paragraph"/></div>
        """
    }

    /**
     Mirrors JSword's single-key commentary unwrap behavior.

     Android removes the outer `<verse>` element returned by `BookData(book, key)` for a
     single-key commentary, then renders that verse's children. SWORD raw entries may already be
     verse-wrapped, while no-content messages are not; this helper strips exactly one whole outer
     verse wrapper and otherwise preserves the raw body unchanged.

     - Parameter rawEntry: Raw SWORD OSIS entry for one exact commentary verse key.
     - Returns: The verse body XML to embed in the reader's own verse wrapper.
     - Side effects: None.
     - Failure modes: If the raw entry is not a single outer `<verse>`, returns it unchanged.
     */
    private static func commentaryVerseBodyXML(from rawEntry: String) -> String {
        let trimmed = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(
            pattern: #"^<verse\b[^>]*>([\s\S]*)</verse>$"#,
            options: []
        ) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges == 2,
              let bodyRange = Range(match.range(at: 1), in: trimmed) else {
            return trimmed
        }
        return String(trimmed[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dictionary/GenBook/Map Content Loading

    /**
     Clears transient reader state before replacing the visible document with auxiliary content.

     Dictionary, general-book, and map loads should leave My Notes, StudyPad, editing, and selection
     state the same way the previous inline implementations did. Keeping this reset in the
     controller preserves ownership of reader state while allowing the auxiliary loader to share the
     document-emission workflow.
     */
    private func resetAuxiliaryContentState() {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""
    }

    /**
     Creates the auxiliary content loader for the current bridge and payload factory.

     - Returns: A loader configured with bridge emission, document JSON, rendered-state, and
       background callbacks for this controller instance.
     - Side effects: None during construction. The returned loader mutates state only through the
       explicit closures supplied here.
     - Failure modes: None during construction.
     */
    private func auxiliaryContentLoader() -> BibleReaderAuxiliaryContentLoader {
        BibleReaderAuxiliaryContentLoader(
            bridge: bridge,
            documentPayloadFactory: documentPayloadFactory(),
            resetReaderState: { [self] in
                resetAuxiliaryContentState()
            },
            setRenderedContentState: { [self] category, moduleName, book, key in
                setRenderedContentState(
                    category: category,
                    moduleName: moduleName,
                    book: book,
                    key: key
                )
            },
            applyNightModeBackground: { [self] in
                applyNightModeBackground()
            }
        )
    }

    /**
     Load a dictionary entry and display it in the WebView.
     Uses renderText() since dictionary entries are typically HTML-formatted definitions.
     */
    public func loadDictionaryEntry(key: String? = nil) {
        auxiliaryContentLoader().loadModuleEntry(
            BibleReaderAuxiliaryModuleEntryRequest(
                category: .dictionary,
                module: activeDictionaryModule,
                moduleName: activeDictionaryModuleName,
                requestedKey: key,
                currentKey: currentDictionaryKey,
                osisBookId: "Dict",
                fallbackBookName: "Dictionary",
                bookCategory: DocumentCategory.dictionary.rawValue,
                noModuleTitle: "No Dictionary",
                noModuleMessage: "No dictionary module is selected. Download one from the module browser.",
                noSelectionMessage: "Select an entry from the key browser to view its definition.",
                noContentNoun: "definition",
                persistResolvedKey: { [self] entryKey in
                    currentDictionaryKey = entryKey
                    if let pm = activeWindow?.pageManager {
                        pm.dictionaryKey = entryKey
                        onPersistState?()
                    }
                }
            )
        )
    }

    /// Load a general book entry and display it in the WebView.
    public func loadGeneralBookEntry(key: String? = nil) {
        auxiliaryContentLoader().loadModuleEntry(
            BibleReaderAuxiliaryModuleEntryRequest(
                category: .generalBook,
                module: activeGeneralBookModule,
                moduleName: activeGeneralBookModuleName,
                requestedKey: key,
                currentKey: currentGeneralBookKey,
                osisBookId: "GenBook",
                fallbackBookName: "General Book",
                bookCategory: DocumentCategory.generalBook.rawValue,
                noModuleTitle: "No General Book",
                noModuleMessage: "No general book module is selected. Download one from the module browser.",
                noSelectionMessage: "Select an entry from the key browser to view its content.",
                noContentNoun: "content",
                persistResolvedKey: { [self] entryKey in
                    currentGeneralBookKey = entryKey
                    if let pm = activeWindow?.pageManager {
                        pm.generalBookKey = entryKey
                        onPersistState?()
                    }
                }
            )
        )
    }

    /// Load a map entry and display it in the WebView.
    public func loadMapEntry(key: String? = nil) {
        auxiliaryContentLoader().loadModuleEntry(
            BibleReaderAuxiliaryModuleEntryRequest(
                category: .map,
                module: activeMapModule,
                moduleName: activeMapModuleName,
                requestedKey: key,
                currentKey: currentMapKey,
                osisBookId: "Map",
                fallbackBookName: "Map",
                bookCategory: DocumentCategory.map.rawValue,
                noModuleTitle: "No Map",
                noModuleMessage: "No map module is selected. Download one from the module browser.",
                noSelectionMessage: "Select an entry from the key browser to view the map.",
                noContentNoun: "content",
                persistResolvedKey: { [self] entryKey in
                    currentMapKey = entryKey
                    if let pm = activeWindow?.pageManager {
                        pm.mapKey = entryKey
                        onPersistState?()
                    }
                }
            )
        )
    }

    // MARK: - EPUB Support

    /// Switch to an EPUB by identifier.
    public func switchEpub(identifier: String) {
        guard let reader = EpubReader(identifier: identifier) else {
            logger.warning("Failed to open EPUB: \(identifier)")
            return
        }
        activeEpubReader = reader
        activeEpubIdentifier = identifier
        activeEpubTitle = reader.title
        currentEpubHref = nil
        currentEpubTitle = nil

        if let pm = activeWindow?.pageManager {
            pm.epubIdentifier = identifier
            pm.epubHref = nil
            onPersistState?()
        }
    }

    /// Load EPUB content for a given section href (or current section).
    public func loadEpubEntry(href: String? = nil) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        guard let reader = activeEpubReader else {
            bridge.emit(event: "clear_document")
            let xml = "<div><title type=\"x-gen\">No EPUB</title><div type=\"paragraph\"><p>No EPUB is selected. Import one from the Import &amp; Export screen, then open it from the EPUB Library.</p></div></div>"
            guard let document = buildDocumentJSON(
                osisBookId: "Epub", bookName: "EPUB", chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: "none"
            ) else { return }
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .epub,
                moduleName: activeEpubTitle,
                book: "EPUB",
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        let entryHref = href ?? currentEpubHref
        guard let entryHref else {
            // No section selected — show prompt
            bridge.emit(event: "clear_document")
            let title = activeEpubTitle ?? "EPUB"
            let xml = "<div><title type=\"x-gen\">\(title)</title><div type=\"paragraph\"><p>Select a section from the Table of Contents to begin reading.</p></div></div>"
            guard let document = buildDocumentJSON(
                osisBookId: "Epub", bookName: title, chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: title
            ) else { return }
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .epub,
                moduleName: title,
                book: title,
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        // Strip fragment from href for content lookup
        let parts = entryHref.components(separatedBy: "#")
        let baseHref = parts.first ?? entryHref
        let fragment = parts.count > 1 ? parts[1] : nil

        // If same base file is already loaded, just scroll to fragment (avoid re-rendering large content)
        if baseHref == currentEpubHref, fragment != nil {
            let jumpToId = "\"\(fragment!)\""
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":\(jumpToId),\"topOffset\":0,\"bottomOffset\":0}")
            return
        }

        currentEpubHref = baseHref
        let htmlContent = reader.getContent(href: baseHref) ?? ""
        // Look up section title — try TOC first, then content table, then derive from filename
        let sectionTitle = reader.getTitle(href: baseHref)
            ?? (baseHref as NSString).deletingPathExtension.components(separatedBy: "_").last
            ?? baseHref
        currentEpubTitle = sectionTitle
        let epubTitle = activeEpubTitle ?? "EPUB"

        // Persist state
        if let pm = activeWindow?.pageManager {
            pm.epubHref = baseHref
            onPersistState?()
        }

        // Build document JSON with isNativeHtml flag (using JSONSerialization for proper escaping)
        let document = buildEpubDocumentJSON(
            bookName: sectionTitle,
            bookInitials: epubTitle,
            content: htmlContent
        )

        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: document)

        // If href has a fragment, jump to it
        let jumpToId = fragment.map { "\"\($0)\"" } ?? "null"
        bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":\(jumpToId),\"topOffset\":0,\"bottomOffset\":0}")
        setRenderedContentState(
            category: .epub,
            moduleName: epubTitle,
            book: sectionTitle,
            key: baseHref
        )
        applyNightModeBackground()
    }

    /**
     Build document JSON for EPUB content with isNativeHtml: true.

     The controller remains the orchestration boundary for selecting the active EPUB section, while
     `BibleReaderDocumentPayloadFactory` owns the Vue document schema and serialization details.

     - Parameters:
       - bookName: Visible EPUB section title.
       - bookInitials: Parent EPUB title used as document initials.
       - content: Rewritten EPUB XHTML/HTML loaded from the EPUB index.
     - Returns: Serialized Vue document JSON, or `{}` when serialization fails.
     - Side effects: None directly; failures are logged by the payload factory.
     - Failure modes: Returns `{}` if the payload cannot be serialized, preserving the legacy
       controller behavior for malformed native HTML payloads.
     */
    private func buildEpubDocumentJSON(bookName: String, bookInitials: String, content: String) -> String {
        documentPayloadFactory().epubDocumentJSON(
            bookName: bookName,
            bookInitials: bookInitials,
            content: content
        )
    }

    /// Return the active module name for a given category.
    public func activeModuleName(for category: DocumentCategory) -> String? {
        switch category {
        case .bible: return activeModuleName
        case .commentary: return activeCommentaryModuleName
        case .dictionary: return activeDictionaryModuleName
        case .generalBook: return activeGeneralBookModuleName
        case .map: return activeMapModuleName
        case .epub: return activeEpubTitle
        default: return nil
        }
    }

    /// Return installed modules for a given category.
    public func installedModules(for category: DocumentCategory) -> [ModuleInfo] {
        switch category {
        case .bible: return installedBibleModules
        case .commentary: return installedCommentaryModules
        case .dictionary: return installedDictionaryModules
        case .generalBook: return installedGeneralBookModules
        case .map: return installedMapModules
        default: return []
        }
    }

    /**
     Refresh the list of installed Bible modules (call after install/uninstall).
     Recreates the SwordManager so newly installed modules are detected.
     */
    public func refreshInstalledModules() {
        guard let newMgr = SwordManager() else { return }
        configureSwordManager(newMgr)
    }

    /**
     Ensures this controller has a SWORD manager and installed-module cache.

     Controllers normally initialize SWORD during construction. Pane controllers may defer that
     initialization so they can copy an existing controller's module state without constructing a
     transient extra `SwordManager`; this method is the explicit fallback when shared state cannot
     be copied.

     Side effects:
     - creates and configures `SwordManager` when this controller does not already have one
     - refreshes installed-module caches and active module handles through `configureSwordManager`

     Failure modes:
     - if `SwordManager` creation fails, leaves the existing controller state unchanged.
     */
    public func initializeSwordIfNeeded() {
        guard swordManager == nil else { return }
        initializeSword()
    }

    /// Initialize SWORD and find the first available Bible module.
    private func initializeSword() {
        guard let mgr = SwordManager() else {
            logger.warning("Failed to create SwordManager — using placeholder text")
            return
        }
        configureSwordManager(mgr)
    }

    private func configureSwordManager(_ mgr: SwordManager) {
        swordManager = mgr

        // Enable headings and verse-level rendering
        mgr.setGlobalOption(.headings, enabled: true)
        mgr.setGlobalOption(.redLetterWords, enabled: true)
        applySwordOptions()

        let modules = mgr.installedModules()
        logger.info("SWORD found \(modules.count) installed modules")
        for mod in modules {
            let hasStrongs = mod.features.contains(.strongsNumbers)
            logger.info("  Module: \(mod.name) (\(mod.description)) [\(mod.category.rawValue)] strongs=\(hasStrongs)")
        }

        installedBibleModules = modules.filter { $0.category == .bible }
        installedCommentaryModules = modules.filter { $0.category == .commentary }
        installedDictionaryModules = modules.filter { $0.category == .dictionary }
        installedGeneralBookModules = modules.filter { $0.category == .generalBook }
        installedMapModules = modules.filter { $0.category == .map }

        if let mod = mgr.module(named: activeModuleName) {
            activeModule = mod
        } else if let kjv = mgr.module(named: "KJV") {
            activeModule = kjv
            activeModuleName = kjv.info.name
            logger.info("Using Bible module: \(kjv.info.name)")
        } else if let firstBible = installedBibleModules.first {
            activeModule = mgr.module(named: firstBible.name)
            activeModuleName = firstBible.name
            logger.info("Using Bible module: \(firstBible.name)")
        } else {
            activeModule = nil
            logger.warning("No Bible modules installed — using placeholder text")
        }

        if let name = activeCommentaryModuleName, let mod = mgr.module(named: name) {
            activeCommentaryModule = mod
        } else if let firstComm = installedCommentaryModules.first {
            activeCommentaryModule = mgr.module(named: firstComm.name)
            activeCommentaryModuleName = firstComm.name
        } else {
            activeCommentaryModule = nil
        }

        if let name = activeDictionaryModuleName, let mod = mgr.module(named: name) {
            activeDictionaryModule = mod
        } else {
            activeDictionaryModule = nil
        }

        if let name = activeGeneralBookModuleName, let mod = mgr.module(named: name) {
            activeGeneralBookModule = mod
        } else {
            activeGeneralBookModule = nil
        }

        if let name = activeMapModuleName, let mod = mgr.module(named: name) {
            activeMapModule = mod
        } else {
            activeMapModule = nil
        }

        refreshBookList()
    }

    /**
     Copies module state from an existing controller while keeping pane cursor state independent.

     - Parameter other: Controller whose shared `SwordManager` and installed-module caches should
       seed this controller.
     - Returns: `true` when shared state was copied; `false` when `other` has no manager yet.
     - Side Effects: Reuses `other`'s `SwordManager`, copies installed-module caches, resolves this
       controller's own active module handles from that manager, and reapplies SWORD options.
     - Failure Modes: Returns `false` without mutation when the source controller has no
       `SwordManager`.
     - Important: This avoids constructing multiple C++ `SWMgr` instances during pane creation.
     */
    @discardableResult
    public func copyModuleState(from other: BibleReaderController) -> Bool {
        guard let mgr = other.swordManager else { return false }
        self.swordManager = mgr
        self.installedBibleModules = other.installedBibleModules
        self.installedCommentaryModules = other.installedCommentaryModules
        self.installedDictionaryModules = other.installedDictionaryModules
        self.installedGeneralBookModules = other.installedGeneralBookModules
        self.installedMapModules = other.installedMapModules
        self.moduleBookList = other.moduleBookList

        // Get own module handles from the shared manager (for independent cursor state)
        if let mod = mgr.module(named: other.activeModuleName) {
            self.activeModule = mod
            self.activeModuleName = other.activeModuleName
        }
        if let commName = other.activeCommentaryModuleName,
           let commMod = mgr.module(named: commName) {
            self.activeCommentaryModule = commMod
            self.activeCommentaryModuleName = commName
        }
        if let dictName = other.activeDictionaryModuleName,
           let dictMod = mgr.module(named: dictName) {
            self.activeDictionaryModule = dictMod
            self.activeDictionaryModuleName = dictName
        }
        if let gbName = other.activeGeneralBookModuleName,
           let gbMod = mgr.module(named: gbName) {
            self.activeGeneralBookModule = gbMod
            self.activeGeneralBookModuleName = gbName
        }
        if let mapName = other.activeMapModuleName,
           let mapMod = mgr.module(named: mapName) {
            self.activeMapModule = mapMod
            self.activeMapModuleName = mapName
        }

        // Apply global options to match
        mgr.setGlobalOption(.headings, enabled: true)
        mgr.setGlobalOption(.redLetterWords, enabled: true)
        applySwordOptions()
        return true
    }

    /**
     Restore saved module and position from PageManager.
     Must be called after `activeWindow` is set.
     */
    public func restoreSavedPosition() {
        guard let pm = activeWindow?.pageManager else { return }

        // Restore saved Bible module
        if let saved = pm.bibleDocument,
           let mgr = swordManager,
           let mod = mgr.module(named: saved) {
            activeModule = mod
            activeModuleName = saved
            refreshBookList()
            logger.info("Restored saved Bible module: \(saved)")
        }

        // Restore saved commentary module
        if let savedComm = pm.commentaryDocument,
           let mgr = swordManager,
           let mod = mgr.module(named: savedComm) {
            activeCommentaryModule = mod
            activeCommentaryModuleName = savedComm
            logger.info("Restored saved commentary module: \(savedComm)")
        } else if let firstComm = installedCommentaryModules.first,
                  let mgr = swordManager {
            activeCommentaryModule = mgr.module(named: firstComm.name)
            activeCommentaryModuleName = firstComm.name
        }

        // Restore dictionary module
        if let savedDict = pm.dictionaryDocument,
           let mgr = swordManager,
           let mod = mgr.module(named: savedDict) {
            activeDictionaryModule = mod
            activeDictionaryModuleName = savedDict
            currentDictionaryKey = pm.dictionaryKey
            logger.info("Restored saved dictionary module: \(savedDict)")
        }

        // Restore general book module
        if let savedGB = pm.generalBookDocument,
           let mgr = swordManager,
           let mod = mgr.module(named: savedGB) {
            activeGeneralBookModule = mod
            activeGeneralBookModuleName = savedGB
            currentGeneralBookKey = pm.generalBookKey
            logger.info("Restored saved general book module: \(savedGB)")
        }

        // Restore map module
        if let savedMap = pm.mapDocument,
           let mgr = swordManager,
           let mod = mgr.module(named: savedMap) {
            activeMapModule = mod
            activeMapModuleName = savedMap
            currentMapKey = pm.mapKey
            logger.info("Restored saved map module: \(savedMap)")
        }

        // Restore EPUB
        if let savedEpub = pm.epubIdentifier,
           let reader = EpubReader(identifier: savedEpub) {
            activeEpubReader = reader
            activeEpubIdentifier = savedEpub
            activeEpubTitle = reader.title
            currentEpubHref = pm.epubHref
            currentEpubTitle = pm.epubHref.flatMap { reader.getTitle(href: $0) }
            logger.info("Restored saved EPUB: \(savedEpub)")
        }

        // Restore category
        let categoryName = pm.currentCategoryName
        switch categoryName {
        case "commentary": currentCategory = .commentary
        case "dictionary": currentCategory = .dictionary
        case "general_book": currentCategory = .generalBook
        case "map": currentCategory = .map
        case "epub": currentCategory = .epub
        default: currentCategory = .bible
        }

        // Restore saved book and chapter
        if let bookIndex = pm.bibleBibleBook,
           bookIndex >= 0, bookIndex < bookList.count {
            currentBook = bookList[bookIndex].name
        }
        if let chapter = pm.bibleChapterNo, chapter > 0 {
            currentChapter = chapter
        }
        if let verse = pm.bibleVerseNo, verse > 0 {
            currentVerse = verse
        } else {
            currentVerse = 1
        }
        originalNavigationOrdinalRange = nil
        if currentVerse > 1,
           let ordinal = ordinal(forChapter: currentChapter, verse: currentVerse) {
            lastScrollTarget = .ordinal(ordinal)
        } else {
            lastScrollTarget = .chapterTop
        }
        logger.info("Restored position: \(self.currentBook) \(self.currentChapter):\(self.currentVerse)")
    }

    /// Apply SWORD global options based on current display settings.
    private func applySwordOptions() {
        guard let mgr = swordManager else { return }
        let s = displaySettings
        let d = TextDisplaySettings.appDefaults
        let strongsOn = (s.strongsMode ?? d.strongsMode ?? 0) > 0
        let xrefsOn = s.showXrefs ?? d.showXrefs ?? false
        let footnotesOn = s.showFootNotes ?? d.showFootNotes ?? false
        mgr.setGlobalOption(.strongsNumbers, enabled: strongsOn)
        mgr.setGlobalOption(.morphology, enabled: s.showMorphology ?? d.showMorphology ?? false)
        mgr.setGlobalOption(.footnotes, enabled: footnotesOn)
        mgr.setGlobalOption(.crossReferences, enabled: xrefsOn)
    }

    // MARK: - Public Navigation API

    /// Navigate to a specific book and chapter. Sends content to the WebView.
    public func navigateTo(book: String, chapter: Int, verse: Int? = nil) {
        currentBook = book
        currentChapter = chapter
        let resolvedVerse = max(1, verse ?? 1)
        currentVerse = resolvedVerse
        if let explicitVerse = verse {
            if let ordinal = ordinal(forChapter: chapter, verse: max(1, explicitVerse)) {
                originalNavigationOrdinalRange = [ordinal, ordinal]
            } else {
                originalNavigationOrdinalRange = nil
            }
        } else {
            originalNavigationOrdinalRange = nil
        }
        if resolvedVerse > 1,
           let ordinal = ordinal(forChapter: chapter, verse: resolvedVerse) {
            lastScrollTarget = .ordinal(ordinal)
            shouldRestoreScroll = true
        } else {
            lastScrollTarget = .chapterTop
            shouldRestoreScroll = false
        }

        // Record history
        if let store = workspaceStore, let window = activeWindow {
            let osisId = osisBookId(for: book)
            store.addHistoryItem(to: window, document: activeModuleName, key: "\(osisId).\(chapter).\(resolvedVerse)")
        }

        // Persist position to PageManager
        if let pm = activeWindow?.pageManager {
            pm.bibleBibleBook = bookList.firstIndex(where: { $0.name == book })
            pm.bibleChapterNo = chapter
            pm.bibleVerseNo = resolvedVerse
            onPersistState?()
        }

        guard clientReady else { return }
        loadCurrentContent()
    }

    /// Navigate to the next chapter, wrapping to the next book if needed.
    public func navigateNext() {
        let maxChapter = chapterCount(for: currentBook)
        if currentChapter < maxChapter {
            navigateTo(book: currentBook, chapter: currentChapter + 1)
        } else if let nextBook = nextBook(after: currentBook) {
            navigateTo(book: nextBook, chapter: 1)
        }
        // At Revelation's last chapter, do nothing
    }

    /// Navigate to the previous chapter, wrapping to the previous book if needed.
    public func navigatePrevious() {
        if currentChapter > 1 {
            navigateTo(book: currentBook, chapter: currentChapter - 1)
        } else if let prevBook = previousBook(before: currentBook) {
            navigateTo(book: prevBook, chapter: chapterCount(for: prevBook))
        }
        // At Genesis 1, do nothing
    }

    /// Scroll down by one viewport page (Android parity: PAGE swipe mode).
    public func scrollPageDown() {
        guard clientReady else { return }
        bridge.emit(event: "scroll_down")
    }

    /// Scroll up by one viewport page (Android parity: PAGE swipe mode).
    public func scrollPageUp() {
        guard clientReady else { return }
        bridge.emit(event: "scroll_up")
    }

    /// Whether there's a next chapter available.
    public var hasNext: Bool {
        let maxChapter = chapterCount(for: currentBook)
        return currentChapter < maxChapter || nextBook(after: currentBook) != nil
    }

    /// Whether there's a previous chapter available.
    public var hasPrevious: Bool {
        return currentChapter > 1 || previousBook(before: currentBook) != nil
    }

    // MARK: - BibleBridgeDelegate — State

    /**
     Handles the initial "client ready" callback from the Vue.js reader.

     - Parameter bridge: Bridge whose web client has finished bootstrapping.

     Side effects:
     - marks the client ready, reloads recent labels and active-language metadata, emits config,
       and replays the current native document state into the web view
     */
    public func bridgeDidSetClientReady(_ bridge: BibleBridge) {
        logger.info("Client ready, sending initial content")
        clientReady = true
        loadRecentLabels()
        applyNightModeBackground()
        updateActiveLanguages()
        bridge.emit(event: "set_config", data: buildConfigJSON())
        reloadVisibleDocumentAfterClientReady()
    }

    /**
     Replays the native controller's current document after the web client bootstraps.

     WKWebView can be recreated by SwiftUI while the pane controller survives. In that case the new
     JavaScript client has no document/config state even though native state still says the pane is
     showing a pending link-result document, My Notes, StudyPad, or the current Bible/category
     document. Rehydrating from the controller state keeps the WebView content and native
     accessibility/export state aligned.
     */
    private func reloadVisibleDocumentAfterClientReady() {
        if let pendingClientReadyTransientMultiDocument {
            self.pendingClientReadyTransientMultiDocument = nil
            emitTransientMultiDocument(pendingClientReadyTransientMultiDocument)
            return
        }

        if showingMyNotes {
            loadMyNotesDocument()
            return
        }

        if showingStudyPad, let activeStudyPadLabelId {
            loadStudyPadDocument(labelId: activeStudyPadLabelId)
            return
        }

        loadCurrentContent()
    }

    /**
     Persists serialized Vue.js UI state onto the active page manager.

     - Parameters:
       - bridge: Bridge reporting the updated state blob.
       - state: Opaque state string produced by the web client.

     Side effects:
     - updates `activeWindow?.pageManager?.jsState`
     - updates transient Strong's rendered-content module labels when Vue tab state changes
     - invokes `onPersistState` so the owning view can save SwiftData changes
     */
    public func bridge(_ bridge: BibleBridge, saveState state: String) {
        activeWindow?.pageManager?.jsState = state
        updateDefinitionRenderedModuleIfNeeded(from: state)
        onPersistState?()
    }

    /**
     Applies Strong's tab-selection state to native rendered-content labels.

     Vue owns the per-dictionary tabs inside `StrongsDocument`, while Swift owns the bottom window
     tabs. When Vue reports a new selected dictionary, this updates only the native display token so
     the bottom tab follows the active dictionary module without treating the link result as a
     durable PageManager category switch.

     - Parameter state: Serialized Vue state from `android.saveState(...)`.
     - Returns: No direct return value; `renderedContentState` is updated when the state applies.
     - Side effects: May update `renderedContentState`.
     - Failure modes: Non-Strong's rendered content, invalid JSON, or missing selected dictionary
       fields leave the current rendered-content state unchanged.
     */
    private func updateDefinitionRenderedModuleIfNeeded(from state: String) {
        let currentTokens = renderedContentStateTokens()
        guard currentTokens["category"] == DocumentCategory.dictionary.pageManagerKey,
              let moduleName = selectedDefinitionModuleName(from: state) else {
            return
        }

        setRenderedContentState(
            category: .dictionary,
            moduleName: moduleName,
            book: currentTokens["book"] ?? "Dictionary",
            key: currentTokens["key"]
        )
    }

    /**
     Parses the current rendered-content token string into key/value fields.

     - Returns: Dictionary containing fields such as `category`, `module`, `book`, `chapter`, and
       `key`.
     - Side effects: None.
     */
    private func renderedContentStateTokens() -> [String: String] {
        BibleReaderRenderedContentState.tokens(from: renderedContentState)
    }

    /**
     Extracts the selected dictionary module from serialized Strong's Vue state.

     - Parameter state: JSON string produced by `StrongsDocument.saveState()`.
     - Returns: Selected Strong's dictionary initials, selected morphology dictionary initials, or
       `nil` when neither is present.
     - Side effects: None.
     */
    private func selectedDefinitionModuleName(from state: String) -> String? {
        guard let data = state.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return nonEmptyString(root["selectedStrongsDict"])
            ?? nonEmptyString(root["selectedMorphDict"])
    }

    /**
     Records Vue modal visibility for the pane owned by this controller.

     - Parameters:
       - bridge: Bridge reporting modal visibility.
       - isOpen: Whether a modal is currently shown inside the web client.

     Side effects:
     - updates `webModalIsOpen`, which native swipe and keyboard handlers use to avoid navigating
       the reader while the Vue modal stack owns interaction

     Failure modes:
     - accepts duplicate reports idempotently; malformed bridge messages are rejected before this
       delegate method is called
     */
    public func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool) {
        webModalIsOpen = isOpen
    }

    /**
     Receives web-client focus changes for text inputs.

     - Parameters:
       - bridge: Bridge reporting the focus transition.
       - focused: Whether a text input is currently focused in the web client.

     - Note: iOS currently does not need this signal, so the callback is intentionally a no-op.
     */
    public func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool) {}

    /**
     Handles keyboard navigation events forwarded from the web client.

     - Parameters:
       - bridge: Bridge reporting the key-down event.
       - key: Logical key identifier from the Vue.js reader.

     Side effects:
     - navigates to the previous or next chapter for left/right arrow keys
     - requests Vue modal dismissal for escape keys when a modal is open

     Failure modes:
     - ignores navigation keys while a Vue modal is open so host navigation does not steal focus
     - ignores keys other than `ArrowLeft`, `ArrowRight`, `Escape`, and `Esc`
     */
    public func bridge(_ bridge: BibleBridge, onKeyDown key: String) {
        guard !webModalIsOpen else {
            if key == "Escape" || key == "Esc" {
                closeWebModalIfNeeded()
            }
            return
        }

        switch key {
        case "ArrowLeft":
            navigatePrevious()
        case "ArrowRight":
            navigateNext()
        default:
            break
        }
    }

    /**
     Requests that the Vue reader close any non-blocking modal before native host navigation runs.

     - Returns: `true` when a close request was emitted because the last reported Vue modal state
       was open; `false` when no modal was reported open.

     Side effects:
     - emits `close_modals` into this controller's bridge without mutating `webModalIsOpen`; the
       next `reportModalState` callback remains the authoritative state transition

     Failure modes:
     - returns `false` and emits nothing when no modal is reported open
     - blocking Vue modals intentionally ignore the event and must report their own eventual state

     - Note: This is pane scoped because each `BibleReaderController` owns exactly one web bridge.
     */
    @discardableResult
    func closeWebModalIfNeeded() -> Bool {
        guard webModalIsOpen else { return false }
        bridge.emit(event: "close_modals")
        return true
    }

    // MARK: - BibleBridgeDelegate — Navigation & Scroll

    /**
     Tracks visible-verse changes reported by the web client during scrolling.

     - Parameters:
       - bridge: Bridge reporting the scroll position change.
       - ordinal: Approximate verse ordinal currently near the viewport focus.
       - key: Verse/document key string such as `Gen.1.5` used to infer chapter changes.

     Side effects:
     - marks the pane as interacted-with only for user-origin scrolls
     - updates scroll-restoration state and persists chapter/book changes to the page manager
     - notifies the window manager for synchronized scrolling only when the callback did not
       acknowledge a sync-origin programmatic scroll
     */
    public func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool) {
        let acknowledgedSynchronizedScroll = consumePendingSynchronizedScroll(ordinal: ordinal)
        if !acknowledgedSynchronizedScroll {
            // Focus-on-interaction: scrolling in a pane makes it the active window
            onInteraction?()
        }
        // Track scroll position for restoration.
        lastScrollTarget = atChapterTop ? .chapterTop : .ordinal(ordinal)

        // Update toolbar header when scrolling into a different chapter/book (infinite scroll)
        if !key.isEmpty, let dotIdx = key.lastIndex(of: ".") {
            let chapterStr = String(key[key.index(after: dotIdx)...])
            let osisId = String(key[key.startIndex..<dotIdx])
            if let chapter = Int(chapterStr), chapter != currentChapter {
                currentChapter = chapter
                if let name = bookName(forOsisId: osisId), name != currentBook {
                    currentBook = name
                }
                // Persist updated position to PageManager
                if let pm = activeWindow?.pageManager {
                    pm.bibleChapterNo = chapter
                    if let bookIdx = bookList.firstIndex(where: { $0.name == currentBook }) {
                        pm.bibleBibleBook = bookIdx
                    }
                    if let verse = verseReference(book: currentBook, ordinal: ordinal)?.verse {
                        currentVerse = verse
                        pm.bibleVerseNo = verse
                    }
                    persistVisibleVerseState(immediate: true)
                }
            } else if let name = bookName(forOsisId: osisId), name != currentBook {
                currentBook = name
                if let pm = activeWindow?.pageManager {
                    if let bookIdx = bookList.firstIndex(where: { $0.name == currentBook }) {
                        pm.bibleBibleBook = bookIdx
                    }
                    if let verse = verseReference(book: currentBook, ordinal: ordinal)?.verse {
                        currentVerse = verse
                        pm.bibleVerseNo = verse
                    }
                    persistVisibleVerseState(immediate: true)
                }
            } else if let pm = activeWindow?.pageManager {
                if let verse = verseReference(book: currentBook, ordinal: ordinal)?.verse {
                    currentVerse = verse
                    pm.bibleVerseNo = verse
                }
                persistVisibleVerseState(immediate: false)
            }
        }

        // Notify WindowManager for synchronized scrolling
        if !acknowledgedSynchronizedScroll, let window = activeWindow {
            windowManagerRef?.notifyVerseChanged(sourceWindow: window, ordinal: ordinal, key: key)
        }
    }

    /**
     Scrolls this pane's WebView to a verse ordinal as a synchronized secondary-window update.

     - Parameter ordinal: SWORD/JSword ordinal to bring near the viewport top.

     Side effects:
     - emits `scroll_to_verse` to the Vue reader
     - records `ordinal` as a pending synchronized scroll acknowledgement only when the bridge
       dispatches the emit

     Failure modes:
     - if the web view is not attached, `BibleBridge` logs the failed JavaScript evaluation and no
       pending acknowledgement is recorded
     - if no scroll callback is produced, the pending ordinal remains until a future nonmatching
       callback clears it
     */
    public func scrollToOrdinal(_ ordinal: Int) {
        if bridge.emit(event: "scroll_to_verse", data: "{\"ordinal\":\(ordinal),\"now\":false}") {
            pendingSynchronizedScrollOrdinals.insert(ordinal)
        }
    }

    /**
     Consumes a pending synchronized-scroll acknowledgement for a web-visible ordinal callback.

     - Parameter ordinal: Ordinal reported by the web client after a scroll position change.
     - Returns: `true` when `ordinal` matches a pending synchronized scroll request; otherwise
       `false`.

     Side effects:
     - removes the matched pending ordinal
     - clears all pending ordinals when a nonmatching callback arrives, treating those requests as
       stale so later user scrolls are not suppressed

     Failure modes:
     - returns `false` when no sync-origin scroll is pending or when the callback ordinal does not
       match the pending synchronized scroll target
     */
    private func consumePendingSynchronizedScroll(ordinal: Int) -> Bool {
        guard !pendingSynchronizedScrollOrdinals.isEmpty else { return false }
        guard pendingSynchronizedScrollOrdinals.contains(ordinal) else {
            pendingSynchronizedScrollOrdinals.removeAll()
            return false
        }
        pendingSynchronizedScrollOrdinals.remove(ordinal)
        return true
    }

    /**
     Supplies an earlier chapter document for infinite scroll prepend requests.

     - Parameter callId: Bridge response identifier for the pending JS callback.

     Side effects:
     - updates the loaded chapter/book range when a prepend succeeds
     - sends either a document JSON payload or `null` back through the bridge

     Failure modes:
     - returns `null` when the current category is not Bible content, when no previous chapter/book
       exists, or when the adjacent chapter fails to load from SWORD
     */
    public func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int) {
        guard currentCategory == .bible else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        let newChapter = minLoadedChapter - 1
        if newChapter < 1 {
            // Cross-book: try loading the last chapter of the previous book
            if let prevBook = previousBook(before: minLoadedBook) {
                let lastChap = chapterCount(for: prevBook)
                if let document = loadChapterJSON(book: prevBook, chapter: lastChap) {
                    minLoadedBook = prevBook
                    minLoadedChapter = lastChap
                    bridge.sendResponse(callId: callId, value: document)
                } else {
                    bridge.sendResponse(callId: callId, value: "null")
                }
            } else {
                bridge.sendResponse(callId: callId, value: "null")
            }
            return
        }
        minLoadedChapter = newChapter
        if let document = loadChapterJSON(book: minLoadedBook, chapter: newChapter) {
            bridge.sendResponse(callId: callId, value: document)
        } else {
            minLoadedChapter = newChapter + 1 // revert
            bridge.sendResponse(callId: callId, value: "null")
        }
    }

    /**
     Supplies a later chapter document for infinite scroll append requests.

     - Parameter callId: Bridge response identifier for the pending JS callback.

     Side effects:
     - updates the loaded chapter/book range when an append succeeds
     - sends either a document JSON payload or `null` back through the bridge

     Failure modes:
     - returns `null` when the current category is not Bible content, when no next chapter/book
       exists, or when the adjacent chapter fails to load from SWORD
     */
    public func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int) {
        guard currentCategory == .bible else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        let lastChapter = chapterCount(for: maxLoadedBook)
        let newChapter = maxLoadedChapter + 1
        if newChapter > lastChapter {
            // Cross-book: try loading chapter 1 of the next book
            if let nextBk = nextBook(after: maxLoadedBook) {
                if let document = loadChapterJSON(book: nextBk, chapter: 1) {
                    maxLoadedBook = nextBk
                    maxLoadedChapter = 1
                    bridge.sendResponse(callId: callId, value: document)
                } else {
                    bridge.sendResponse(callId: callId, value: "null")
                }
            } else {
                bridge.sendResponse(callId: callId, value: "null")
            }
            return
        }
        maxLoadedChapter = newChapter
        if let document = loadChapterJSON(book: maxLoadedBook, chapter: newChapter) {
            bridge.sendResponse(callId: callId, value: document)
        } else {
            maxLoadedChapter = newChapter - 1 // revert
            bridge.sendResponse(callId: callId, value: "null")
        }
    }

    // MARK: - BibleBridgeDelegate — Bookmarks

    /// Shared bookmark creation/update path used by JS bridge and native selection actions.
    private func addOrUpdateBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool,
        wholeVerse: Bool,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) {
        guard let coordinator = bookmarkActionCoordinator() else {
            logger.warning("addBookmark: bookmarkService is nil")
            return
        }
        applyBookmarkActionResult(
            coordinator.addOrUpdateBibleBookmark(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                addNote: addNote,
                wholeVerse: wholeVerse,
                startOffset: startOffset,
                endOffset: endOffset,
                workspaceSettings: activeWindow?.workspace?.workspaceSettings
            ),
            bridge: bridge
        )
    }

    /**
     Creates or updates a Bible bookmark requested from the web client.

     - Parameters:
       - bookInitials: Module initials associated with the bookmark.
       - startOrdinal: Start verse ordinal from the web selection.
       - endOrdinal: End verse ordinal from the web selection.
       - addNote: Whether the bookmark sheet should open directly to note editing.

     Side effects:
     - delegates to the shared Bible-bookmark creation path, emits bookmark updates, and may open
       the bookmark modal in the web client
     */
    public func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {
        addOrUpdateBibleBookmark(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote,
            wholeVerse: true,
            startOffset: nil,
            endOffset: nil
        )
    }

    /**
     Creates a generic bookmark for non-Bible content from a web-client request.

     - Parameters:
       - bookInitials: Module initials that own the referenced content.
       - osisRef: Key/reference string for the bookmarked content.
       - startOrdinal: Start ordinal attached to the selection.
       - endOrdinal: End ordinal attached to the selection.
       - addNote: Whether the bookmark modal should open with note editing active.

     Side effects:
     - inserts the generic bookmark, emits it back to Vue.js, and opens the bookmark modal

     Failure modes:
     - returns without side effects when bookmark services are unavailable
     */
    public func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {
        logger.info("Add generic bookmark: \(bookInitials) ref=\(osisRef)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.addGenericBookmark(
                bookInitials: bookInitials,
                osisRef: osisRef,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                addNote: addNote,
                workspaceSettings: activeWindow?.workspace?.workspaceSettings
            ),
            bridge: bridge
        )
    }

    /// Creates a Bible paragraph-break bookmark requested from the web client.
    public func bridge(_ bridge: BibleBridge, addParagraphBreakBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        logger.info("Add paragraph break bookmark: \(bookInitials)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.addParagraphBreakBibleBookmark(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            ),
            bridge: bridge
        )
    }

    /// Creates a generic paragraph-break bookmark requested from the web client.
    public func bridge(_ bridge: BibleBridge, addGenericParagraphBreakBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int) {
        logger.info("Add generic paragraph break bookmark: \(bookInitials) ref=\(osisRef)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.addGenericParagraphBreakBookmark(
                bookInitials: bookInitials,
                osisRef: osisRef,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            ),
            bridge: bridge
        )
    }

    /**
     Deletes a Bible bookmark requested from the web client.

     - Parameter bookmarkId: UUID string of the bookmark to remove.

     Side effects:
     - removes the bookmark from persistence and emits a delete event to Vue.js

     Failure modes:
     - returns without side effects when the bookmark service is unavailable or the identifier is invalid
     */
    public func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String) {
        logger.info("Remove bookmark: \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(coordinator.removeBookmark(bookmarkId), bridge: bridge)
    }

    /**
     Deletes a generic bookmark requested from the web client.

     - Parameter bookmarkId: UUID string of the generic bookmark to remove.

     Side effects:
     - removes the bookmark from persistence

     Failure modes:
     - returns without side effects when the bookmark service is unavailable or the identifier is invalid
     */
    public func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String) {
        logger.info("Remove generic bookmark: \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(coordinator.removeGenericBookmark(bookmarkId), bridge: bridge)
    }

    /**
     Persists note text for an existing Bible bookmark and notifies the web client.

     - Parameters:
       - bookmarkId: UUID string of the bookmark whose note changed.
       - note: Optional note text to persist.

     Side effects:
     - saves bookmark notes through the bookmark service and emits an updated note payload to Vue.js

     Failure modes:
     - returns without side effects when the bookmark service is unavailable or the identifier is invalid
     */
    public func bridge(_ bridge: BibleBridge, saveBookmarkNote bookmarkId: String, note: String?) {
        logger.info("Save bookmark note: \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.saveBookmarkNote(bookmarkId: bookmarkId, note: note),
            bridge: bridge
        )
    }

    private func applyUITestMyNotesAppendTextIfNeeded() {
        guard !didApplyUITestMyNotesAppendText,
              let appendText = UITestRuntimeConfiguration.myNotesAppendText,
              appendUITestTextToFirstVisibleMyNotesNote(appendText) else {
            return
        }
        didApplyUITestMyNotesAppendText = true
    }

    @discardableResult
    private func appendUITestTextToFirstVisibleMyNotesNote(_ text: String) -> Bool {
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
              showingMyNotes,
              !text.isEmpty,
              let bookmark = currentChapterMyNotesBookmarks().first
        else {
            return false
        }

        let currentNote = bookmark.notes?.notes ?? ""
        return saveBookmarkNoteAndNotify(bookmarkId: bookmark.id, note: currentNote + text)
    }

    private func applyUITestStudyPadCreatedNoteTextIfNeeded() {
        guard !didApplyUITestStudyPadCreatedNoteText,
              let noteText = UITestRuntimeConfiguration.studyPadCreatedNoteText,
              updateNewestVisibleStudyPadTextEntry(noteText) else {
            return
        }
        didApplyUITestStudyPadCreatedNoteText = true
    }

    @discardableResult
    private func updateNewestVisibleStudyPadTextEntry(_ text: String) -> Bool {
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
              showingStudyPad,
              !text.isEmpty,
              let service = bookmarkService,
              let labelId = activeStudyPadLabelId,
              let entry = service.studyPadEntries(labelId: labelId).max(by: { lhs, rhs in
                  if lhs.orderNumber != rhs.orderNumber {
                      return lhs.orderNumber < rhs.orderNumber
                  }
                  return lhs.id.uuidString < rhs.id.uuidString
              })
        else {
            return false
        }

        service.updateStudyPadTextEntryText(id: entry.id, text: text)
        studyPadMutationRevision += 1
        let updatedEntry = service.studyPadEntry(id: entry.id) ?? entry
        bridge.emit(
            event: "add_or_update_study_pad",
            data: StudyPadUpdatePayload(
                studyPadTextEntry: buildStudyPadEntryJSON(updatedEntry),
                bookmarkToLabelsOrdered: [],
                genericBookmarkToLabelsOrdered: [],
                studyPadItemsOrdered: []
            )
        )
        return true
    }

    /**
     Persists a bookmark note update from the web reader and emits the JavaScript bridge mutation event
     from the stored row state.

     - Parameters:
       - bookmarkId: Identifier for either a Bible bookmark or generic bookmark note row.
       - note: Raw note text supplied by the web editor. Whitespace-only text is delegated to the
         bookmark service, which treats it as a delete to match Android bridge behavior.
     - Returns: `true` when the service is available and the bridge payload could be serialized,
       otherwise `false`.

     Side effects:
     - mutates bookmark note persistence through `BookmarkService`
     - increments `myNotesMutationRevision`
     - emits `bookmark_note_modified` to the embedded BibleView runtime

     Failure modes:
     - returns `false` without persistence when no bookmark service is configured
     - returns `false` after persistence when JSON serialization unexpectedly fails
     */
    @discardableResult
    private func saveBookmarkNoteAndNotify(bookmarkId: UUID, note: String?) -> Bool {
        guard let coordinator = bookmarkActionCoordinator() else { return false }
        let result = coordinator.saveBookmarkNote(bookmarkId: bookmarkId.uuidString, note: note)
        applyBookmarkActionResult(result, bridge: bridge)
        return result.incrementsMyNotesRevision || !result.events.isEmpty
    }

    /**
     Requests native label-assignment UI for a bookmark from the owning SwiftUI view.

     - Parameter bookmarkId: UUID string of the bookmark to edit.

     Side effects:
     - invokes `onAssignLabels` with the parsed bookmark identifier

     Failure modes:
     - returns without side effects when the identifier is invalid
     */
    public func bridge(_ bridge: BibleBridge, assignLabels bookmarkId: String) {
        logger.info("Assign labels requested for: \(bookmarkId)")
        guard let uuid = UUID(uuidString: bookmarkId) else { return }
        onAssignLabels?(uuid)
    }

    /// Refresh bookmark data in Vue.js after label changes (called after LabelAssignmentView dismisses).
    public func refreshBookmarkInVueJS(bookmarkId: UUID) {
        guard let service = bookmarkService,
              let bookmark = service.bibleBookmark(id: bookmarkId) else { return }
        bridge.emit(event: "add_or_update_bookmarks", data: [buildBookmarkJSON(bookmark)])
        sendLabelsToVueJS()
        // Re-send config to update favouriteLabels in Vue.js appSettings
        bridge.emit(event: "set_config", data: buildConfigJSON())
    }

    /**
     Toggles one label assignment on a bookmark and re-emits the updated bookmark state.
     */
    public func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String) {
        logger.info("Toggle label \(labelId) on bookmark \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.toggleBookmarkLabel(bookmarkId: bookmarkId, labelId: labelId),
            bridge: bridge
        )
    }

    /**
     Removes one label assignment from a bookmark and re-emits the updated bookmark state.
     */
    public func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {
        logger.info("Remove label \(labelId) from bookmark \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.removeBookmarkLabel(bookmarkId: bookmarkId, labelId: labelId),
            bridge: bridge
        )
    }

    /**
     Sets the primary label used to style a bookmark in Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {
        logger.info("Set primary label \(labelId) on bookmark \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.setPrimaryLabel(bookmarkId: bookmarkId, labelId: labelId),
            bridge: bridge
        )
    }

    /**
     Updates whether a bookmark should highlight whole verses or a text-range selection.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {
        logger.info("Set whole verse \(value) for bookmark \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.setBookmarkWholeVerse(bookmarkId: bookmarkId, value: value),
            bridge: bridge
        )
    }

    /**
     Updates the custom icon attached to a bookmark.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {
        logger.info("Set custom icon for bookmark \(bookmarkId)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.setBookmarkCustomIcon(bookmarkId: bookmarkId, value: value),
            bridge: bridge
        )
    }

    // MARK: - BibleBridgeDelegate — StudyPad

    /**
     Creates a new StudyPad text entry relative to an existing bookmark or note row.

     - Parameters:
       - labelId: Label whose StudyPad journal is being edited.
       - entryType: Type of row referenced by `afterEntryId` (`bookmark`, `generic-bookmark`, `journal`, or `none`).
       - afterEntryId: Identifier of the row after which the new entry should be inserted.

     Side effects:
     - mutates StudyPad persistence and emits reorder/update events back to Vue.js

     Failure modes:
     - returns without side effects when identifiers are invalid or StudyPad creation fails
     */
    public func bridge(_ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String, afterEntryId: String) {
        logger.info("Create StudyPad entry type=\(entryType) after \(afterEntryId) in label \(labelId)")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(
            coordinator.createNewStudyPadEntry(
                labelId: labelId,
                entryType: entryType,
                afterEntryId: afterEntryId
            ),
            bridge: bridge
        )
        applyUITestStudyPadCreatedNoteTextIfNeeded()
    }

    /**
     Deletes one StudyPad text entry and emits the resulting reordered state.
     */
    public func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String) {
        logger.info("Delete StudyPad entry: \(studyPadId)")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(coordinator.deleteStudyPadEntry(studyPadId), bridge: bridge)
    }

    /**
     Updates StudyPad entry metadata such as indent level or order number from a Vue.js payload.
     */
    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String) {
        logger.info("Update StudyPad text entry metadata")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(coordinator.updateStudyPadTextEntry(data: data), bridge: bridge)
    }

    /**
     Persists edited text for one StudyPad text entry.
     */
    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {
        logger.info("Update StudyPad entry text: \(id)")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(
            coordinator.updateStudyPadTextEntryText(id: id, text: text),
            bridge: bridge
        )
    }

    /**
     Persists reordered StudyPad rows and bookmark associations for one label.
     */
    public func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String) {
        logger.info("Update order numbers for label \(labelId)")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(
            coordinator.updateOrderNumber(labelId: labelId, data: data),
            bridge: bridge
        )
    }

    /**
     Updates one `BibleBookmarkToLabel` association from a JSON payload emitted by Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String) {
        logger.info("Update BibleBookmarkToLabel")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(coordinator.updateBookmarkToLabel(data: data), bridge: bridge)
    }

    /**
     Updates one `GenericBookmarkToLabel` association from a JSON payload emitted by Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String) {
        logger.info("Update GenericBookmarkToLabel")
        guard let coordinator = studyPadActionCoordinator() else { return }
        applyStudyPadActionResult(coordinator.updateGenericBookmarkToLabel(data: data), bridge: bridge)
    }

    /**
     Persists an optional bookmark edit action configured in the web client.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String) {
        logger.info("Set edit action on bookmark \(bookmarkId): \(value)")
        guard let coordinator = bookmarkActionCoordinator() else { return }
        applyBookmarkActionResult(
            coordinator.setBookmarkEditAction(bookmarkId: bookmarkId, value: value),
            bridge: bridge
        )
    }

    /**
     Tracks whether the embedded web client is currently editing content.
     */
    public func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {
        logger.info("WebView editing mode: \(enabled)")
        editingInWebView = enabled
        if enabled {
            applyUITestMyNotesAppendTextIfNeeded()
            applyUITestStudyPadCreatedNoteTextIfNeeded()
        }
    }

    /**
     Persists the current insertion cursor position for a StudyPad label.
     */
    public func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int) {
        logger.info("StudyPad cursor: label=\(labelId) order=\(orderNumber)")
        guard let uuid = UUID(uuidString: labelId) else { return }
        if activeWindow?.workspace?.workspaceSettings == nil {
            activeWindow?.workspace?.workspaceSettings = WorkspaceSettings()
        }
        activeWindow?.workspace?.workspaceSettings?.studyPadCursors[uuid] = orderNumber
        onPersistState?()
        // Re-emit config so Vue.js gets the updated cursor position
        bridge.emit(event: "set_config", data: buildConfigJSON())
    }

    // MARK: - BibleBridgeDelegate — Selection

    /**
     Records the latest text selection reported by the web client and enables native action mode UI.
     */
    public func bridge(_ bridge: BibleBridge, selectionChanged text: String) {
        hasActiveSelection = true
        selectedText = text
        bridge.emit(event: "set_action_mode", data: "true")
    }

    /**
     Clears native selection state when the web client deselects text.
     */
    public func bridgeSelectionCleared(_ bridge: BibleBridge) {
        hasActiveSelection = false
        selectedText = ""
        bridge.emit(event: "set_action_mode", data: "false")
    }

    // MARK: - Selection Actions

    /**
     Query detailed selection info from Vue.js (`bibleView.querySelection()`), with
     fallback to the bridge's DOM-based query when unavailable.
     */
    @MainActor
    private func querySelectionDetails() async -> (
        text: String,
        startOrdinal: Int?,
        endOrdinal: Int?,
        startOffset: Int?,
        endOffset: Int?
    )? {
        if let webView = bridge.webView {
            let js = """
            (function() {
                try {
                    if (typeof bibleView === 'undefined' || !bibleView.querySelection) return null;
                    var sel = bibleView.querySelection();
                    if (sel == null) return null;
                    return (typeof sel === 'string') ? sel : JSON.stringify(sel);
                } catch (e) {
                    return null;
                }
            })()
            """

            do {
                let result = try await webView.evaluateJavaScript(js)
                if let jsonStr = result as? String,
                   let data = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    /// Coerces JSON bridge values into optional `Int` values while treating `NSNull` as missing.
                    func asInt(_ value: Any?) -> Int? {
                        if value is NSNull { return nil }
                        if let intValue = value as? Int { return intValue }
                        if let number = value as? NSNumber { return number.intValue }
                        return nil
                    }

                    let text = dict["text"] as? String ?? ""
                    let startOrdinal = asInt(dict["startOrdinal"])
                    let endOrdinal = asInt(dict["endOrdinal"])
                    let startOffset = asInt(dict["startOffset"])
                    let endOffset = asInt(dict["endOffset"])

                    if !text.isEmpty || startOrdinal != nil || endOrdinal != nil {
                        return (text, startOrdinal, endOrdinal, startOffset, endOffset)
                    }
                }
            } catch {
                logger.debug("querySelectionDetails JS error: \(error.localizedDescription)")
            }
        }

        if let fallback = await bridge.querySelection() {
            return (fallback.text, fallback.startOrdinal, fallback.endOrdinal, nil, nil)
        }
        return nil
    }

    /**
     Bookmark the current selection.
     `wholeVerse=false` matches Android "Selection", `wholeVerse=true` matches "Verses".
     */
    func bookmarkSelection(wholeVerse: Bool = false) {
        Task { @MainActor in
            guard let sel = await querySelectionDetails() else { return }
            let startOrd = sel.startOrdinal ?? verseOrdinal(
                osisBookId: osisBookId(for: currentBook),
                chapter: currentChapter,
                verse: 1
            )
            guard let startOrd else {
                logger.error("Failed to resolve selection bookmark start ordinal for \(self.currentBook, privacy: .public) \(self.currentChapter)")
                return
            }
            let endOrd = sel.endOrdinal ?? startOrd

            let selectionStartOffset = wholeVerse ? nil : sel.startOffset
            let selectionEndOffset = wholeVerse ? nil : sel.endOffset

            addOrUpdateBibleBookmark(
                bookInitials: activeModuleName,
                startOrdinal: startOrd,
                endOrdinal: endOrd,
                addNote: false,
                wholeVerse: wholeVerse,
                startOffset: selectionStartOffset,
                endOffset: selectionEndOffset
            )
            bridge.clearSelection()
        }
    }

    /// Copy the selected text to the clipboard.
    func copySelection() {
        guard !selectedText.isEmpty else { return }
        let reference = "\(currentBook) \(currentChapter)"
        let copyText = "\(selectedText)\n\u{2014} \(reference) (\(activeModuleName))"
        #if os(iOS)
        UIPasteboard.general.string = copyText
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        #endif
        bridge.clearSelection()
    }

    /// Share the selected text.
    func shareSelection() {
        guard !selectedText.isEmpty else { return }
        let reference = "\(currentBook) \(currentChapter)"
        let shareText = "\(selectedText)\n\u{2014} \(reference) (\(activeModuleName))"
        onShareVerseText?(shareText)
        bridge.clearSelection()
    }

    /// Speak the selected text.
    func speakSelection() {
        Task { @MainActor in
            guard let sel = await bridge.querySelection(), !sel.text.isEmpty else { return }
            guard let service = speakService else { return }
            service.currentTitle = "\(currentBook) \(currentChapter)"
            service.currentSubtitle = activeModuleName
            let lang = activeModule?.info.language ?? "en"
            let speechLang = lang.hasPrefix("en") ? "en-US" : lang
            service.speak(text: sel.text, language: speechLang)
            bridge.clearSelection()
        }
    }

    /// Compare translations for the selected verse(s) through the Vue document pipeline.
    func compareSelection() {
        Task { @MainActor in
            var startVerse: Int? = nil
            var endVerse: Int? = nil
            if let sel = await bridge.querySelection() {
                startVerse = sel.startOrdinal.flatMap { ordinalToVerse($0) }
                endVerse = sel.endOrdinal.flatMap { ordinalToVerse($0) }
            }
            loadCompareDocument(startVerse: startVerse, endVerse: endVerse)
            bridge.clearSelection()
        }
    }

    /// Open a web search for the currently selected text.
    func webSearchSelection() {
        guard !selectedText.isEmpty else { return }
        guard let encoded = selectedText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /**
     Looks up the current text selection in configured plain dictionary modules.

     This mirrors Android's `disabled_word_lookup_dictionaries` behavior: plain dictionaries are
     enabled unless they are explicitly disabled, and successful lookups render as transient
     document content instead of an iOS-only sheet.

     - Parameters: None; the method reads the controller's current `selectedText`.
     - Returns: No direct return value; a successful lookup emits a Vue document payload through
       the current pane or configured links-window target.
     - Side effects: May show a localized "not found" toast, route a dictionary document payload,
       and clear the active WebView selection after a successful lookup.
     - Failure modes: Empty selections, empty normalized queries, or missing dictionary payloads
       exit without navigation and show the existing not-found toast where user-facing feedback is
       required.
     */
    func lookupSelectionInDictionaries() {
        guard !selectedText.isEmpty else { return }
        let query = normalizeWordLookupQuery(selectedText)
        guard !query.isEmpty else {
            onShowToast?(String(
                localized: "word_not_found_in_dictionaries",
                defaultValue: "Word not found in any dictionary"
            ))
            return
        }
        guard let multiDocJSON = buildWordLookupMultiDocJSON(query: query) else {
            onShowToast?(String(
                localized: "word_not_found_in_dictionaries",
                defaultValue: "Word not found in any dictionary"
            ))
            return
        }
        openDefinitionDocument(
            multiDocJSON,
            renderedBook: "Dictionary",
            renderedKey: "dictionary"
        )
        bridge.clearSelection()
    }

    // MARK: - BibleBridgeDelegate — Content Actions

    /// Callback for presenting action sheets (set by BibleReaderView)
    var onShareVerseText: ((String) -> Void)?

    /**
     Callback for presenting Downloads with an optional Android-compatible search seed.

     The optional string mirrors Android `DownloadActivity`'s `"search"` extra: `nil` opens
     Downloads normally, while a non-empty module initials value pre-populates the browser search.
     */
    var onRequestOpenDownloads: ((String?) -> Void)?
    var onOpenExternalURL: ((URL) -> Void)?

    /// Whether there's an active text selection in the WebView.
    private(set) var hasActiveSelection = false
    /// The currently selected text.
    private(set) var selectedText: String = ""
    /// Whether any plain word-lookup dictionaries are currently available.
    var hasWordLookupDictionaries: Bool { !findWordLookupDictionaryModules().isEmpty }

    /**
     Builds a shareable verse string for the current module and forwards it to native sharing UI.
     */
    public func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        let text = getVerseText(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
        guard !text.isEmpty else { return }
        let reference = "\(currentBook) \(currentChapter)"
        let shareText = "\(text)\n— \(reference) (\(activeModuleName))"
        onShareVerseText?(shareText)
    }

    /**
     Shares a Bible bookmark identified by the web client's `shareBookmarkVerse(bookmark.id)` call.
     */
    public func bridge(_ bridge: BibleBridge, shareBookmarkVerse bookmarkId: String) {
        guard let service = bookmarkService,
              let uuid = UUID(uuidString: bookmarkId),
              let bookmark = service.bibleBookmark(id: uuid) else {
            logger.warning("shareBookmarkVerse: bookmark not found for id=\(bookmarkId)")
            return
        }
        self.bridge(
            bridge,
            shareVerse: activeModuleName,
            startOrdinal: bookmark.ordinalStart,
            endOrdinal: bookmark.ordinalEnd
        )
    }

    /**
     Copies a verse selection and its reference to the platform pasteboard.
     */
    public func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        let text = getVerseText(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
        guard !text.isEmpty else { return }
        let reference = "\(currentBook) \(currentChapter)"
        let copyText = "\(text)\n— \(reference) (\(activeModuleName))"
        #if os(iOS)
        UIPasteboard.general.string = copyText
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        #endif
    }

    /**
     Returns the Android-compatible raw My Documents page payload for the supplied document/page key.
     */
    public func bridge(_ bridge: BibleBridge, getMyDocumentPageRawContent callId: Int, bookInitials: String, pageKey: String) {
        guard let payload = myDocumentStore?.rawContentPayload(bookInitials: bookInitials, pageKey: pageKey) else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }

        bridge.sendResponse(callId: callId, value: payload)
    }

    /**
     Renders one locally stored My Documents page into the WebView document stream.

     - Returns: `true` when the page exists and a document payload was emitted.
     */
    @discardableResult
    public func loadMyDocumentPage(bookInitials: String, pageKey: String) -> Bool {
        guard let store = myDocumentStore,
              let document = store.document(initials: bookInitials),
              let page = store.page(bookInitials: bookInitials, pageKey: pageKey) else {
            return false
        }

        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""
        currentCategory = .generalBook
        activeMyDocumentBookInitials = bookInitials
        activeMyDocumentPageKey = pageKey
        setRenderedContentState(
            category: .generalBook,
            moduleName: document.initials,
            book: document.name,
            key: page.pageKey
        )

        let documentJSON = buildMyDocumentDocumentJSON(document: document, page: page)
        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: documentJSON)
        bridge.emit(
            event: "setup_content",
            data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}"
        )
        bridge.clearSelection()
        applyNightModeBackground()
        return true
    }

    /**
     Builds the Vue.js `OsisDocument` payload for one stored My Documents page.
     */
    private func buildMyDocumentDocumentJSON(document: MyDocument, page: MyDocumentPage) -> String {
        let content = page.pageContent?.content ?? ""
        let xml = renderedMyDocumentXML(content: content, contentType: page.contentType)
        let promptId: Any = page.sourcePromptId?.uuidString ?? NSNull()

        let osisFragment: [String: Any] = [
            "xml": xml,
            "key": page.pageKey,
            "keyName": page.title,
            "v11n": "KJVA",
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookInitials": document.initials,
            "bookAbbreviation": document.initials,
            "osisRef": page.pageKey,
            "isNewTestament": false,
            "features": [String: Any](),
            "hasStrongs": false,
            "ordinalRange": [0, 0],
            "language": page.languageCode ?? Locale.current.languageCode ?? "en",
            "direction": "ltr",
        ]

        let renderedDocument: [String: Any] = [
            "id": "my-document-\(page.id.uuidString)",
            "type": "osis",
            "osisFragment": osisFragment,
            "bookInitials": document.initials,
            "bookCategory": DocumentCategory.generalBook.rawValue,
            "bookAbbreviation": document.initials,
            "bookName": document.name,
            "key": page.pageKey,
            "v11n": "KJVA",
            "osisRef": page.pageKey,
            "annotateRef": page.pageKey,
            "genericBookmarks": [Any](),
            "ordinalRange": [0, 0],
            "isNativeHtml": false,
            "highlightedOrdinalRange": NSNull(),
            "isMyDocument": true,
            "isAiDocument": document.initials == "AIDocuments",
            "myDocumentPageId": page.id.uuidString,
            "sourcePromptId": promptId,
            "sourcePromptName": NSNull(),
            "sourceModelName": NSNull(),
            "aiDocMarkers": [Any](),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: renderedDocument, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize My Documents page JSON for \(document.initials, privacy: .public)")
            return "{}"
        }

        return json
    }

    /**
     Converts stored raw My Documents content into the OSIS-template fragment consumed by Vue.js.
     */
    private func renderedMyDocumentXML(content: String, contentType: MyDocumentContentType) -> String {
        switch contentType {
        case .markdown:
            return "<div class=\"mydoc-markdown\"><markdown>\(escapeXML(content))</markdown></div>"
        case .html:
            return "<div class=\"mydoc-html\"><html>\(escapeXML(content))</html></div>"
        case .osis:
            return content
        }
    }

    /**
     Copies the stored raw My Documents page content to the platform pasteboard.
     */
    public func bridge(_ bridge: BibleBridge, copyMyDocumentContent bookInitials: String, pageKey: String) {
        guard let payload = myDocumentStore?.rawContentPayload(bookInitials: bookInitials, pageKey: pageKey) else {
            return
        }

        #if os(iOS)
        UIPasteboard.general.string = payload.content
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload.content, forType: .string)
        #endif
    }

    /**
     Shares the stored raw My Documents page content through native sharing UI.
     */
    public func bridge(_ bridge: BibleBridge, shareMyDocumentContent bookInitials: String, pageKey: String) {
        guard let payload = myDocumentStore?.rawContentPayload(bookInitials: bookInitials, pageKey: pageKey) else {
            return
        }

        let shareText: String
        if payload.title.isEmpty {
            shareText = payload.content
        } else {
            shareText = "\(payload.title)\n\n\(payload.content)"
        }
        onShareVerseText?(shareText)
    }

    /**
     Persists raw My Documents editor content without rebuilding the document immediately.
     */
    public func bridge(_ bridge: BibleBridge, saveMyDocumentPageContent bookInitials: String, pageId: String, content: String, title: String?) {
        guard let pageUUID = UUID(uuidString: pageId) else {
            logger.warning("saveMyDocumentPageContent: malformed page id=\(pageId, privacy: .public)")
            return
        }

        guard myDocumentStore?.savePageContent(
            bookInitials: bookInitials,
            pageId: pageUUID,
            content: content,
            title: title
        ) == true else {
            logger.warning("saveMyDocumentPageContent: page not found or save failed for document=\(bookInitials, privacy: .public)")
            return
        }
    }

    /**
     Reloads the currently visible My Documents page when it belongs to the supplied document.
     */
    public func bridge(_ bridge: BibleBridge, reloadMyDocumentPage bookInitials: String) {
        guard activeMyDocumentBookInitials == bookInitials,
              let pageKey = activeMyDocumentPageKey else {
            return
        }

        loadMyDocumentPage(bookInitials: bookInitials, pageKey: pageKey)
    }

    /**
     Hands off regeneration for one AI-generated My Documents page.

     The shared AI regeneration dialog is tracked separately, so this bridge
     method validates source prompt metadata and forwards the context to the
     owning native surface.
     */
    public func bridge(_ bridge: BibleBridge, regenerateMyDocumentPage pageId: String) {
        guard let pageUUID = UUID(uuidString: pageId) else {
            logger.warning("regenerateMyDocumentPage: malformed page id=\(pageId, privacy: .public)")
            return
        }

        guard let context = myDocumentStore?.aiPageActionContext(pageId: pageUUID) else {
            logger.warning("regenerateMyDocumentPage: source prompt metadata missing for page id=\(pageId, privacy: .public)")
            return
        }

        onRegenerateMyDocumentPage?(context)
    }

    /**
     Deletes one AI-generated My Documents page and refreshes reader content.

     Non-AI/user-authored pages are refused because Android only exposes this
     action for sourcePromptId-backed pages.
     */
    public func bridge(_ bridge: BibleBridge, deleteMyDocumentPage pageId: String) {
        guard let pageUUID = UUID(uuidString: pageId) else {
            logger.warning("deleteMyDocumentPage: malformed page id=\(pageId, privacy: .public)")
            return
        }

        guard let store = myDocumentStore else {
            logger.warning("deleteMyDocumentPage: My Documents store unavailable")
            return
        }

        switch store.deleteAIPage(pageId: pageUUID) {
        case .deleted(let context):
            refreshMyDocumentAfterDeletingPage(context)
        case .notAIPage:
            logger.warning("deleteMyDocumentPage: refusing non-AI page id=\(pageId, privacy: .public)")
        case .pageNotFound:
            logger.warning("deleteMyDocumentPage: page not found id=\(pageId, privacy: .public)")
        case .saveFailed:
            logger.warning("deleteMyDocumentPage: save failed for page id=\(pageId, privacy: .public)")
        }
    }

    /**
     Keeps the visible WebView in sync after an AI My Documents page deletion.
     */
    private func refreshMyDocumentAfterDeletingPage(_ context: MyDocumentAIPageActionContext) {
        guard activeMyDocumentBookInitials == context.bookInitials else {
            return
        }

        if activeMyDocumentPageKey == context.pageKey {
            activeMyDocumentBookInitials = nil
            activeMyDocumentPageKey = nil
            currentCategory = .bible
            if let pageManager = activeWindow?.pageManager {
                pageManager.currentCategoryName = DocumentCategory.bible.pageManagerKey
            }
            onPersistState?()
            loadCurrentChapter()
            return
        }

        if let pageKey = activeMyDocumentPageKey {
            loadMyDocumentPage(bookInitials: context.bookInitials, pageKey: pageKey)
        }
    }

    /**
     Opens the Android-style compare document for the selected verse range.
     */
    public func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        logger.info("Compare verses requested: \(startOrdinal)-\(endOrdinal)")
        let startVerse = ordinalToVerse(startOrdinal)
        let endVerse = ordinalToVerse(endOrdinal)
        loadCompareDocument(startVerse: startVerse, endVerse: endVerse)
    }

    /**
     Starts TTS playback for the selected verse range.
     */
    public func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {
        speakVerseRange(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Starts repeated TTS playback for the selected memorization range.
     */
    public func bridge(_ bridge: BibleBridge, speakMemorizationLoop bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {
        speakMemorizationLoopRange(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Adds the selected verse range as a memorization target and opens the bundled Memorize document.
     */
    public func bridge(_ bridge: BibleBridge, memorize bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationProgressStore?.addMemorizationTargetIfNeeded(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
        loadMemorizeDocument(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Marks the selected verse range as memorized in local iOS memorization state.
     */
    public func bridge(_ bridge: BibleBridge, markAsMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationProgressStore?.markAsMemorized(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /**
     Adds the selected verse range to local iOS memorization targets.
     */
    public func bridge(_ bridge: BibleBridge, addMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationProgressStore?.addMemorizationTarget(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /**
     Removes the selected verse range from local iOS memorization targets.
     */
    public func bridge(_ bridge: BibleBridge, removeMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationProgressStore?.removeMemorizationTarget(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /**
     Removes the selected verse range from local iOS memorized ranges.
     */
    public func bridge(_ bridge: BibleBridge, unmarkMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationProgressStore?.unmarkMemorized(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /**
     Records one chapter-read history row in local iOS reading-progress state.
     */
    public func bridge(_ bridge: BibleBridge, recordChapterRead bookInitials: String, startOrdinal: Int, chapter: Int, source: String) {
        guard let store = readingProgressStore,
              let target = readingProgressBridgeTarget(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                chapter: chapter
              ) else {
            return
        }
        let count = store.recordChapterRead(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            kjvBookOrdinal: target.kjvBookOrdinal,
            chapter: chapter,
            source: ReadingProgressSource(bridgeValue: source)
        )
        emitChapterReadStatus(chapter: chapter, count: count)
    }

    /**
     Opens native chapter-read history for the active Bible chapter identity.
     */
    public func bridge(_ bridge: BibleBridge, openChapterReadHistory bookInitials: String, startOrdinal: Int, chapter: Int) {
        guard readingProgressStore != nil,
              let target = readingProgressBridgeTarget(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                chapter: chapter
              ) else {
            return
        }
        onShowChapterReadHistory?(
            ChapterReadHistoryTarget(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                kjvBookOrdinal: target.kjvBookOrdinal,
                bookName: target.bookName,
                chapter: chapter
            )
        )
    }

    /**
     Opens native reading-progress UI using Android's numeric tab positions.
     */
    public func bridge(_ bridge: BibleBridge, openReadingProgress tab: Int) {
        onShowReadingProgress?(tab)
    }

    /**
     Opens native reading-progress settings UI.
     */
    public func bridgeDidRequestOpenReadingProgressSettings(_ bridge: BibleBridge) {
        onShowReadingProgressSettings?()
    }

    /**
     Persists Android-compatible reading-progress settings and notifies the embedded client.
     */
    public func bridge(_ bridge: BibleBridge, setReadingProgressSettings json: String) {
        guard readingProgressStore?.applySettingsBundle(json: json) == true else {
            return
        }
        emitReadingProgressSettings()
        bridge.emit(event: "set_config", data: buildConfigJSON())
    }

    /**
     Clears chapter-read status for the active reading-progress cycle.
     */
    public func bridge(_ bridge: BibleBridge, unmarkChapterRead bookInitials: String, startOrdinal: Int, chapter: Int) {
        guard let store = readingProgressStore,
              let target = readingProgressBridgeTarget(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                chapter: chapter
              ) else {
            return
        }
        let count = store.clearChapterReadStatus(kjvBookOrdinal: target.kjvBookOrdinal, chapter: chapter)
        emitChapterReadStatus(chapter: chapter, count: count)
    }

    // MARK: - BibleBridgeDelegate — Navigation Actions

    /**
     Handles Android-style manual next-chapter navigation from bibleview-js.

     Used when the shared renderer disables infinite scroll and shows chapter navigation buttons
     instead of appending the next chapter into the current WebView document.
     */
    public func bridgeDidRequestGoToNextChapter(_ bridge: BibleBridge) {
        navigateNext()
    }

    /**
     Handles Android-style manual previous-chapter navigation from bibleview-js.

     Used when the shared renderer disables infinite scroll and shows chapter navigation buttons
     instead of prepending the previous chapter into the current WebView document.
     */
    public func bridgeDidRequestGoToPreviousChapter(_ bridge: BibleBridge) {
        navigatePrevious()
    }

    /**
     Opens a label-backed StudyPad journal document in the current pane.
     */
    public func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String) {
        logger.info("Open StudyPad for label: \(labelId)")
        guard let uuid = UUID(uuidString: labelId) else { return }
        let bmUuid = UUID(uuidString: bookmarkId)
        loadStudyPadDocument(labelId: uuid, bookmarkId: bmUuid)
    }

    /**
     Opens the chapter-level My Notes document in the current pane.
     */
    public func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int) {
        loadMyNotesDocument(jumpToOrdinal: ordinal)
    }

    /**
     Load the My Notes document for the current chapter into the WebView.
     Shows all bookmarks for the chapter in a personal-commentary style view.
     */
    public func loadMyNotesDocument(jumpToOrdinal: Int? = nil) {
        guard clientReady else { return }
        showingMyNotes = true
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        let osisBookId = osisBookId(for: currentBook)
        guard let range = currentChapterOrdinalRange() else {
            logger.error("Failed to resolve My Notes chapter range for \(self.currentBook, privacy: .public) \(self.currentChapter)")
            return
        }
        let verseCount = range.verseCount

        // Get bookmarks with notes for this chapter
        let bookmarks = currentChapterMyNotesBookmarks()

        let verseRange = "\(currentBook) \(currentChapter):1-\(verseCount)"
        let docId = "\(osisBookId).\(currentChapter).1-\(osisBookId).\(currentChapter).\(verseCount)"

        let document = MyNotesDocumentPayload(
            id: docId,
            type: "notes",
            bookmarks: bookmarks.map { buildBookmarkJSONForMyNotes($0) },
            verseRange: verseRange,
            ordinalRange: [range.start, range.end]
        )

        // Send to Vue.js using the same sequence as loadCurrentChapter
        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(
            event: "setup_content",
            data: ReaderSetupContentPayload(jumpToOrdinal: jumpToOrdinal)
        )

        setRenderedContentState(
            category: .bible,
            moduleName: "My Notes",
            book: "My Notes",
            chapter: currentChapter,
            key: docId
        )

        myNotesMutationRevision += 1
    }

    /**
     Opens the bundled Memorize document for the selected verse range.

     The document is backed by the same local `MemorizationProgressStore` state that the bridge
     mutation methods update. The current frontend renders the practice modes from `texts`; the
     extra metadata keeps the payload aligned with Android's document shape for future client-side
     target/memorized controls.
     */
    private func loadMemorizeDocument(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        guard clientReady,
              let document = buildMemorizeDocumentJSON(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
              ) else {
            return
        }

        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
        setRenderedContentState(
            category: .bible,
            moduleName: activeModuleName,
            book: "Memorize",
            chapter: currentChapter,
            key: "memorize:\(bookInitials):\(startOrdinal)-\(endOrdinal)"
        )
        bridge.clearSelection()
        applyNightModeBackground()
    }

    /// Return from My Notes to the Bible text view.
    public func returnFromMyNotes() {
        guard showingMyNotes else { return }
        loadCurrentChapter()
        myNotesMutationRevision += 1
    }

    /// Load a StudyPad document for a label into the WebView.
    public func loadStudyPadDocument(labelId: UUID, bookmarkId: UUID? = nil) {
        guard clientReady, let service = bookmarkService else { return }
        guard let label = service.label(id: labelId) else {
            logger.warning("loadStudyPadDocument: label not found for \(labelId)")
            return
        }
        guard let labelData = buildLabelData(label) else {
            logger.warning("loadStudyPadDocument: label deleted before serialization for \(labelId)")
            return
        }

        showingMyNotes = false
        showingStudyPad = true
        activeStudyPadLabelId = labelId
        activeStudyPadLabelName = label.name
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        // Fetch all data for this StudyPad
        let bibleBookmarks = service.bibleBookmarks(withLabel: labelId)
        let genericBookmarks = service.genericBookmarks(withLabel: labelId)
        let bibleBtls = service.bibleBookmarkToLabels(labelId: labelId)
        let genericBtls = service.genericBookmarkToLabels(labelId: labelId)
        let entries = service.studyPadEntries(labelId: labelId)

        let document = StudyPadDocumentPayload(
            id: "journal_\(labelId.uuidString)",
            type: "journal",
            label: labelData,
            bookmarks: bibleBookmarks.map { buildBookmarkJSONForStudyPad($0) },
            genericBookmarks: genericBookmarks.map { buildGenericBookmarkJSONForStudyPad($0) },
            bookmarkToLabels: bibleBtls.compactMap { buildBibleBookmarkToLabelJSON($0) },
            genericBookmarkToLabels: genericBtls.compactMap { buildGenericBookmarkToLabelJSON($0) },
            journalTextEntries: entries.map { buildStudyPadEntryJSON($0) }
        )

        // Send to Vue.js
        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()
        bridge.emit(event: "add_documents", data: document)

        // Setup content with optional jump target
        bridge.emit(
            event: "setup_content",
            data: ReaderSetupContentPayload(jumpToId: bookmarkId?.uuidString)
        )

        setRenderedContentState(
            category: .bible,
            moduleName: "StudyPad",
            book: label.name,
            key: "journal_\(labelId.uuidString)"
        )

        applyNightModeBackground()
    }

    /// Return from StudyPad to the Bible text view.
    public func returnFromStudyPad() {
        guard showingStudyPad else { return }
        loadCurrentChapter()
    }

    /**
     Routes an external-style link emitted by the web client to the appropriate native handler.

     - Parameter link: Link string using one of the supported pseudo-schemes or a standard URL.

     Side effects:
     - may open transient document content, cross-reference sheets, search, EPUB navigation, or
       delegate real URLs to the host platform

     Failure modes:
     - unrecognized schemes fall through to the platform URL-opening path
     */
    public func bridge(_ bridge: BibleBridge, openExternalLink link: String) {
        // Handle Strong's/morphology links: ab-w://?strong=H1234&robinson=...
        if link.hasPrefix("ab-w://") {
            handleStrongsLink(link)
            return
        }
        // Handle document-independent Strong's links: strongs://G2316, strongs://H430.
        if link.hasPrefix("strongs://") {
            handleStandaloneStrongsLink(link)
            return
        }
        // Handle document-independent morphology links: morphology://robinson/V-PAI-3S.
        if link.hasPrefix("morphology://") {
            handleStandaloneMorphologyLink(link)
            return
        }
        // Handle "Find all occurrences" links from FeaturesLink.vue
        if link.hasPrefix("ab-find-all://") {
            handleFindAllLink(link)
            return
        }
        // Handle error-report links surfaced in web-rendered error overlays.
        if link.hasPrefix("ab-error://") {
            handleErrorReportLink()
            return
        }
        // Handle EPUB internal reference links when surfaced as raw anchors.
        if link.hasPrefix("epub-ref://") {
            handleEpubRefLink(link)
            return
        }
        // Handle Downloads links surfaced in web-rendered help/error content.
        if link.hasPrefix("download://") {
            onRequestOpenDownloads?(Self.downloadSearchText(from: link))
            return
        }
        // Handle My Notes links surfaced in bookmark metadata.
        if link.hasPrefix("my-notes://") {
            handleMyNotesLink(link)
            return
        }
        // Handle StudyPad links surfaced in bookmark metadata.
        if link.hasPrefix("journal://") {
            handleJournalLink(link)
            return
        }
        // Handle cross-reference links: osis://?osis=Matt.1.1&v11n=KJV
        if link.hasPrefix("osis://") {
            handleOsisLink(link)
            return
        }
        // Handle multi cross-reference links: multi://?osis=Matt.1.1&osis=Mark.2.3
        if link.hasPrefix("multi://") {
            handleMultiLink(link)
            return
        }
        // Handle sword:// links (e.g. sword://Bible/John.17.11 from Calvin's commentary)
        if link.hasPrefix("sword://") {
            handleSwordLink(link)
            return
        }
        // Handle MyBible cross-reference links: "B:bookInt chapter:verse"
        if link.hasPrefix("B:") {
            handleMyBibleLink(link)
            return
        }
        // Handle MyBible Strong's links: "S:G2424" or "S:H1234"
        if link.hasPrefix("S:") {
            let strongRef = String(link.dropFirst(2))
            handleStrongsLink("ab-w://?strong=\(strongRef)")
            return
        }
        // Handle MySword Bible links: "#bBookInt.Chapter.Verse"
        if link.hasPrefix("#b") {
            handleMySwordBibleLink(link)
            return
        }
        // Handle MySword Strong's links: "#sG2424" or "#dH1234"
        if link.hasPrefix("#s") || link.hasPrefix("#d") {
            let strongRef = String(link.dropFirst(2))
            handleStrongsLink("ab-w://?strong=\(strongRef)")
            return
        }
        guard let url = URL(string: link) else { return }
        openPlatformURL(url)
    }

    /**
     Extracts the module-initials search seed from an Android-compatible Downloads pseudo-link.

     - Parameter link: A `download://` link emitted by rendered document content, optionally with
       an `initials` query item such as `download://?initials=KJV`.
     - Returns: The decoded, trimmed `initials` value when present and non-empty; otherwise `nil`.

     The method is deterministic and performs no I/O. Malformed or non-download links return
     `nil`, which keeps the caller on the standard unfiltered Downloads presentation path.
     */
    static func downloadSearchText(from link: String) -> String? {
        guard link.hasPrefix("download://"),
              let components = URLComponents(string: link),
              let value = components.queryItems?.first(where: { $0.name == "initials" })?.value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func handleErrorReportLink() {
        guard let url = URL(string: Self.issueTrackerURLString) else { return }
        openPlatformURL(url)
    }

    private func openPlatformURL(_ url: URL) {
        if let onOpenExternalURL {
            onOpenExternalURL(url)
            return
        }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /**
     Parses Strong's and morphology link payloads from `ab-w://` URLs.

     Android routes these links through normal document/window handling. iOS follows that route by
     building the shared Vue `MultiDocument` payload with `contentType: "strongs"` and then handing
     it to the pane-owned definition document router.

     - Parameter link: `ab-w://` URL containing one or more `strong` or `robinson` query items.
     - Returns: No direct return value; valid links route a transient Strong's document payload.
     - Side effects: May emit an `add_documents` event in the current pane or configured links
       target window. Preserves saved Strong's tab state when recursive Strong's links are opened
       from an existing Strong's document.
     - Failure modes: Malformed URLs, links without recognized query items, or payload-build
       failures are ignored, matching the existing bridge-link behavior.
     */
    private func handleStrongsLink(_ link: String) {
        logger.info("handleStrongsLink: \(link)")
        guard let components = URLComponents(string: link) else {
            logger.warning("handleStrongsLink: failed to parse URL")
            return
        }
        let items = components.queryItems ?? []

        var strongs: [String] = []
        var robinson: [String] = []

        for item in items {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name {
            case "strong":
                strongs.append(value)
            case "robinson":
                robinson.append(value)
            default:
                break
            }
        }

        logger.info("handleStrongsLink: strongs=\(strongs), robinson=\(robinson)")
        if strongs.isEmpty && robinson.isEmpty { return }

        let multiDocJSON = buildStrongsMultiDocJSON(
            strongs: strongs,
            robinson: robinson,
            stateJSON: currentStrongsDocumentStateJSON()
        )
        guard let multiDocJSON else { return }

        openDefinitionDocument(
            multiDocJSON,
            renderedBook: "Strongs",
            renderedKey: "strongs"
        )
    }

    /**
     Renders a Strong's or dictionary result through the shared document pipeline.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload already shaped for Vue.
       - renderedBook: Accessibility/test-state book token for the transient result.
       - renderedKey: Accessibility/test-state key token for the transient result.
     - Returns: No direct return value; the embedded document client receives an `add_documents`
       event.
     - Side effects: Replaces the current web document with the supplied payload and exposes the
       resolved dictionary module/key through rendered-content state for tab labels. This does not
       persist PageManager category or key state because Android treats Strong's and dictionary
       results as link-result documents.
     - Failure modes: Invalid JSON is forwarded unchanged to the Vue bridge, matching the existing
       transient document contract.
     */
    func loadDefinitionDocument(_ documentJSON: String, renderedBook: String, renderedKey: String) {
        let tabState = definitionDocumentTabState(
            from: documentJSON,
            fallbackBook: renderedBook,
            fallbackKey: renderedKey
        )
        loadTransientMultiDocument(
            documentJSON,
            renderedBook: tabState.book,
            renderedKey: tabState.key,
            renderedCategory: .dictionary,
            renderedModuleName: tabState.moduleName
        )
    }

    /**
     Routes a definition-style transient document through the pane owner when possible.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload already shaped for Vue.
       - renderedBook: Accessibility/test-state book token for the transient result.
       - renderedKey: Accessibility/test-state key token for the transient result.
     - Returns: No direct return value; rendering is delegated to the current or links-window
       controller.
     - Side effects: May hand off to the owning pane so it can use the configured Android-style
       links window. If no owner is attached, the current controller renders the document directly.
     - Failure modes: A missing links-window owner is treated as a direct render fallback; JSON
       validation remains owned by the downstream Vue document pipeline.
     */
    private func openDefinitionDocument(_ documentJSON: String, renderedBook: String, renderedKey: String) {
        if let openInLinksWindow = onOpenDefinitionDocumentInLinksWindow {
            openInLinksWindow(documentJSON, renderedBook, renderedKey)
        } else {
            loadDefinitionDocument(documentJSON, renderedBook: renderedBook, renderedKey: renderedKey)
        }
    }

    /// Display identity extracted from a transient definition document for native tab chrome.
    private struct DefinitionDocumentTabState {
        /// Module initials or abbreviation shown as the primary tab label.
        let moduleName: String

        /// Compact lookup key shown as the secondary tab label.
        let key: String

        /// Book token recorded in rendered-content state for UI tests and tab display.
        let book: String
    }

    /**
     Extracts the visible dictionary module/key from a Vue definition document payload.

     Strong's documents can contain several dictionary fragments plus a saved selected-tab state.
     The bottom window tab should reflect the active dictionary fragment, not the source Bible pane
     that opened the link. Parsing the serialized payload keeps that display state aligned with the
     shared Vue route without persisting a durable `PageManager` category change.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload emitted to Vue.
       - fallbackBook: Book token to use when parsing fails.
       - fallbackKey: Key token to use when parsing fails.
     - Returns: Module and key labels suitable for rendered-content state.
     - Side effects: None.
     - Failure modes: Invalid JSON or missing fragment fields fall back to the caller-supplied
       labels so the document still renders.
     */
    private func definitionDocumentTabState(
        from documentJSON: String,
        fallbackBook: String,
        fallbackKey: String
    ) -> DefinitionDocumentTabState {
        let fallback = DefinitionDocumentTabState(
            moduleName: fallbackBook,
            key: fallbackKey,
            book: fallbackBook
        )
        guard let data = documentJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fragments = root["osisFragments"] as? [[String: Any]],
              let firstFragment = fragments.first else {
            return fallback
        }

        let selectedStrongsDict = (root["state"] as? [String: Any])?["selectedStrongsDict"] as? String
        let selectedFragment = selectedStrongsDict.flatMap { selected in
            fragments.first { ($0["bookInitials"] as? String) == selected }
        } ?? firstFragment

        let moduleName = nonEmptyString(selectedFragment["bookInitials"])
            ?? nonEmptyString(selectedFragment["bookAbbreviation"])
            ?? fallback.moduleName
        let key = definitionDocumentDisplayKey(from: selectedFragment) ?? fallback.key
        return DefinitionDocumentTabState(moduleName: moduleName, key: key, book: key)
    }

    /**
     Builds a compact dictionary key label from one serialized definition fragment.

     - Parameter fragment: JSON object for one `OsisFragment` inside a Vue `MultiDocument`.
     - Returns: A display key such as `H00776`, `G01234`, or the fragment key name.
     - Side effects: None.
     - Failure modes: Returns `nil` when the fragment has no usable key fields.
     */
    private func definitionDocumentDisplayKey(from fragment: [String: Any]) -> String? {
        if let features = fragment["features"] as? [String: Any],
           let keyName = nonEmptyString(features["keyName"]) {
            let type = nonEmptyString(features["type"])
            let prefix = type == "hebrew" ? "H" : type == "greek" ? "G" : ""
            return keyName.hasPrefix("H") || keyName.hasPrefix("G") ? keyName : "\(prefix)\(keyName)"
        }

        return nonEmptyString(fragment["keyName"])
    }

    /**
     Converts a loosely typed JSON field into a non-empty string.

     - Parameter value: JSON value from `JSONSerialization`.
     - Returns: Trimmed string when the value is a non-empty string, otherwise `nil`.
     - Side effects: None.
     */
    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /**
     Returns the last saved Strong's tab-selection state when the current transient document is Strong's.

     Vue emits tab state through `saveState`; preserving it across recursive Strong's links keeps
     the selected dictionary tab stable without reviving the removed sheet-local history stack.

     - Returns: Serialized Vue state for the active Strong's document, or `nil` when the current
       document is not a Strong's result or no state has been saved.
     - Side effects: None; this reads the current rendered-content token and active page-manager
       state.
     - Failure modes: Missing saved state produces `nil`, which lets Vue choose its default tab.
     */
    private func currentStrongsDocumentStateJSON() -> String? {
        guard renderedContentState.contains("key=strongs") else { return nil }
        return activeWindow?.pageManager?.jsState
    }

    private func handleStandaloneStrongsLink(_ link: String) {
        guard let components = URLComponents(string: link) else { return }
        let ref = components.host ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !ref.isEmpty else { return }
        handleStrongsLink("ab-w://?strong=\(ref)")
    }

    private func handleStandaloneMorphologyLink(_ link: String) {
        guard let components = URLComponents(string: link) else { return }
        let code = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !code.isEmpty else { return }
        handleStrongsLink("ab-w://?robinson=\(code)")
    }

    private func handleEpubRefLink(_ link: String) {
        guard let components = URLComponents(string: link),
              let items = components.queryItems,
              let book = items.first(where: { $0.name == "book" })?.value,
              let toKey = items.first(where: { $0.name == "toKey" })?.value,
              let toId = items.first(where: { $0.name == "toId" })?.value else { return }

        bridge(self.bridge, openEpubLink: book, toKey: toKey, toId: toId)
    }

    /**
     Build a MultiFragmentDocument JSON from Strong's numbers and Robinson codes.
     Returns nil if no definitions were found.
     */
    func buildStrongsMultiDocJSON(strongs: [String], robinson: [String], stateJSON: String? = nil) -> String? {
        logger.info("buildStrongsMultiDocJSON: strongs=\(strongs), robinson=\(robinson), swordManager=\(self.swordManager == nil ? "nil" : "alive")")
        var fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: OsisFeatures)] = []

        for num in strongs {
            let lexModules = findAllLexiconModules(for: num)
            logger.info("buildStrongsMultiDocJSON: num=\(num), lexModules=\(lexModules.map { $0.info.name })")
            let keyOptions = buildKeyOptions(for: num)
            logger.info("buildStrongsMultiDocJSON: keyOptions=\(keyOptions)")
            for mod in lexModules {
                if let lookup = lookupInModule(mod, keyOptions: keyOptions) {
                    // Determine features type for "Find all occurrences" link
                    let isHebrew = num.hasPrefix("H") || (!num.hasPrefix("G") && (Int(String(num.drop(while: { $0.isLetter || $0 == "0" }))) ?? 0) > 5624)
                    let featureType = isHebrew ? "hebrew" : "greek"
                    let keyName = Self.canonicalStrongsKeyName(requested: num, actualKey: lookup.actualKey, rawEntry: lookup.rawEntry)
                    let xml = buildDictionaryEntryXML(
                        rawEntry: lookup.rawEntry,
                        renderedText: lookup.renderedText,
                        strongsLinkPrefix: Self.strongsLinkPrefix(for: num)
                    )
                    let features = OsisFeatures(type: featureType, keyName: keyName)

                    fragments.append((
                        xml: xml,
                        key: "\(mod.info.name)--\(keyName)",
                        keyName: keyName,
                        bookInitials: mod.info.name,
                        bookAbbreviation: moduleDisplayLabel(mod),
                        features: features
                    ))
                }
            }
        }

        // Look up morphology codes in morphology dictionaries
        if !robinson.isEmpty {
            let morphModules = findMorphologyModules()
            for code in robinson {
                for mod in morphModules {
                    let morphKeys = [code, code.uppercased(), code.lowercased()]
                    if let lookup = lookupInModule(mod, keyOptions: morphKeys) {
                        let xml = buildDictionaryEntryXML(
                            rawEntry: lookup.rawEntry,
                            renderedText: lookup.renderedText,
                            fallbackTitle: "Morphology: \(code)"
                        )
                        fragments.append((
                            xml: xml,
                            key: "\(mod.info.name)--\(code)",
                            keyName: code,
                            bookInitials: mod.info.name,
                            bookAbbreviation: moduleDisplayLabel(mod),
                            features: OsisFeatures()
                        ))
                    }
                }
            }
        }

        if fragments.isEmpty, let firstStrongs = strongs.first {
            fragments.append(missingStrongsDictionaryFragment(for: firstStrongs))
        }

        if fragments.isEmpty {
            logger.info("handleStrongsLink: no definitions found")
            return nil
        }

        return buildMultiFragmentJSON(
            fragments: fragments,
            contentType: "strongs",
            stateJSON: stateJSON
        )
    }

    /**
     Builds the Android-style missing-document fallback shown when Strong's display is available
     but no matching Strong's dictionary module is installed.

     Android falls back to a synthetic dictionary document with a download link instead of leaving
     the user with an enabled Strong's UI and no actionable destination.
    */
    private func missingStrongsDictionaryFragment(
        for strongsNumber: String
    ) -> (xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: OsisFeatures) {
        let isHebrew = Self.isHebrewStrongsNumber(strongsNumber)
        let moduleName = isHebrew ? "StrongsHebrew" : "StrongsGreek"
        let featureType = isHebrew ? "hebrew" : "greek"
        let numericKey = Self.normalizeNumericKey(strongsNumber)
        let keyName = numericKey.count < 5
            ? String(repeating: "0", count: max(0, 5 - numericKey.count)) + numericKey
            : numericKey
        let message = escapeXML(
            Bundle.main.localizedString(
                forKey: "no_dictionary_installed",
                value: "No dictionary module installed. Download Strong's Hebrew/Greek from Downloads.",
                table: nil
            )
        )
        let downloadsLabel = escapeXML(
            Bundle.main.localizedString(
                forKey: "downloads",
                value: "Downloads",
                table: nil
            )
        )
        let xml = """
        <div>
        <title type="x-gen">\(message)</title>
        <p><a href="download://">\(downloadsLabel)</a></p>
        </div>
        """
        return (
            xml: xml,
            key: "\(moduleName)--\(keyName)--missing",
            keyName: keyName,
            bookInitials: moduleName,
            bookAbbreviation: moduleName,
            features: OsisFeatures(type: featureType, keyName: keyName)
        )
    }

    /// Handle "Find all occurrences" links: ab-find-all://?type=hebrew&name=H05775
    private func handleFindAllLink(_ link: String) {
        logger.info("handleFindAllLink: \(link)")
        guard let components = URLComponents(string: link) else { return }
        let items = components.queryItems ?? []
        let type = items.first(where: { $0.name == "type" })?.value
        var name = items.first(where: { $0.name == "name" })?.value ?? ""

        // Ensure name has H/G prefix
        if !name.isEmpty && name.first?.isLetter != true {
            if type == "hebrew" {
                name = "H\(name)"
            } else if type == "greek" {
                name = "G\(name)"
            }
        }

        if !name.isEmpty {
            onShowStrongsSearch?(name)
        }
    }

    private func handleMyNotesLink(_ link: String) {
        logger.info("handleMyNotesLink: \(link)")
        guard let components = URLComponents(string: link) else {
            loadMyNotesDocument()
            return
        }

        let items = components.queryItems ?? []
        let ordinal = items.first(where: { $0.name == "ordinal" })?.value.flatMap(Int.init)

        if let osisRef = items.first(where: { $0.name == "osis" })?.value,
           let ref = parseOsisReferences(osisRef).first {
            navigateTo(book: ref.book, chapter: ref.chapter, verse: ref.verse)
            loadMyNotesDocument(jumpToOrdinal: ordinal)
            return
        }

        loadMyNotesDocument(jumpToOrdinal: ordinal)
    }

    private func handleJournalLink(_ link: String) {
        logger.info("handleJournalLink: \(link)")
        guard let components = URLComponents(string: link),
              let items = components.queryItems,
              let labelId = items.first(where: { $0.name == "id" })?.value,
              let labelUUID = UUID(uuidString: labelId) else { return }

        let entryId = items.first(where: { $0.name == "bookmarkId" })?.value
            ?? items.first(where: { $0.name == "entryId" })?.value
        let bookmarkUUID = entryId.flatMap(UUID.init(uuidString:))
        loadStudyPadDocument(labelId: labelUUID, bookmarkId: bookmarkUUID)
    }

    /**
     Transform dictionary cross-references into clickable links.
     Handles:
     1. ThML `<ref target="StrongsHebrew/02421">text</ref>` tags
     2. Plain text "see HEBREW for 05774" / "see GREEK for 01234" from StrongsHebrew/Greek modules
     3. Plain text "from 05774" / "From H5774" patterns
     */
    static func linkifyRenderedDictionaryHTML(_ html: String, defaultPrefix: String? = nil) -> String {
        var result = html

        result = linkifyStructuredDictionaryRefs(in: result, defaultPrefix: defaultPrefix)

        // Handle bare <ref target="key">text</ref> for any remaining ref tags
        let bareRefPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="[^"]*?/?(\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        if let regex = bareRefPattern {
            let range = NSRange(result.startIndex..., in: result)
            let prefix = defaultPrefix.map { "\($0)" } ?? ""
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(prefix)$1\">$2</a>"
            )
        }

        // 2. Plain text: "see HEBREW for 05774" → link the number
        let seeHebrewPattern = try? NSRegularExpression(
            pattern: #"see HEBREW for (\d{4,5})"#,
            options: []
        )
        if let regex = seeHebrewPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "see HEBREW for <a href=\"ab-w://?strong=H$1\">$1</a>")
        }

        // 3. Plain text: "see GREEK for 01234" → link the number
        let seeGreekPattern = try? NSRegularExpression(
            pattern: #"see GREEK for (\d{4,5})"#,
            options: []
        )
        if let regex = seeGreekPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "see GREEK for <a href=\"ab-w://?strong=G$1\">$1</a>")
        }

        // 4. Plain text: "from 05774" or "From 05774" (common in StrongsHebrew entries)
        // Only match standalone numbers preceded by "from " to avoid false positives
        let fromPattern = try? NSRegularExpression(
            pattern: #"(?<=[Ff]rom )(\d{4,5})(?=[;,.\s]|$)"#,
            options: []
        )
        if let regex = fromPattern, let defaultPrefix {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(defaultPrefix)$1\">$1</a>"
            )
        }

        // 5. Remove <br/> tags immediately before <span class="sense"> — redundant when
        // .sense is CSS display:block, and causes double line spacing otherwise.
        let brBeforeSensePattern = try? NSRegularExpression(
            pattern: #"<br\s*/?>\s*(?=<span\s+class="sense")"#,
            options: []
        )
        if let regex = brBeforeSensePattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        return result
    }

    /// Transform raw dictionary XML references into clickable links while preserving TEI structure.
    static func linkifyRawDictionaryXML(_ xml: String, defaultPrefix: String? = nil) -> String {
        var result = xml

        result = linkifyStructuredDictionaryRefs(in: result, defaultPrefix: defaultPrefix)

        let bareRefPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="[^"]*?/?(\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        if let regex = bareRefPattern {
            let range = NSRange(result.startIndex..., in: result)
            let prefix = defaultPrefix.map { "\($0)" } ?? ""
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(prefix)$1\">$2</a>"
            )
        }

        let seeHebrewPattern = try? NSRegularExpression(
            pattern: #"see HEBREW for (\d{4,5})"#,
            options: []
        )
        if let regex = seeHebrewPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "see HEBREW for <a href=\"ab-w://?strong=H$1\">$1</a>"
            )
        }

        let seeGreekPattern = try? NSRegularExpression(
            pattern: #"see GREEK for (\d{4,5})"#,
            options: []
        )
        if let regex = seeGreekPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "see GREEK for <a href=\"ab-w://?strong=G$1\">$1</a>"
            )
        }

        let fromPattern = try? NSRegularExpression(
            pattern: #"(?<=[Ff]rom )(\d{4,5})(?=[;,.\s]|$)"#,
            options: []
        )
        if let regex = fromPattern, let defaultPrefix {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<a href=\"ab-w://?strong=\(defaultPrefix)$1\">$1</a>"
            )
        }

        return result
    }

    private static func linkifyStructuredDictionaryRefs(in source: String, defaultPrefix: String?) -> String {
        let refPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="(StrongsHebrew|StrongsGreek|StrongsRealGreek|BDB|OSHB|Thayer)[/:](\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        guard let regex = refPattern else { return source }

        let mutable = NSMutableString(string: source)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        guard !matches.isEmpty else { return source }

        let nsSource = source as NSString
        for match in matches.reversed() {
            let moduleName = nsSource.substring(with: match.range(at: 1))
            let digits = nsSource.substring(with: match.range(at: 2))
            let text = nsSource.substring(with: match.range(at: 3))
            let prefix = strongsLinkPrefix(forModuleName: moduleName) ?? defaultPrefix ?? ""
            let replacement = "<a href=\"ab-w://?strong=\(prefix)\(digits)\">\(text)</a>"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return mutable as String
    }

    /**
     Build a typed MultiFragmentDocument JSON string for rendering in Vue.js document views.

     - Parameters:
       - fragments: Dictionary fragments to project into Vue `OsisFragment` values.
       - contentType: Optional document content type such as `strongs`.
       - stateJSON: Optional saved Vue state JSON to attach to the document.
     - Returns: Serialized bridge JSON, or `nil` if typed encoding unexpectedly fails.
     - Side effects: none.
     - Failure modes: logs and returns `nil` when the payload cannot be encoded, allowing callers
       to avoid emitting an invalid Vue document shape.
     */
    private func buildMultiFragmentJSON(
        fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: OsisFeatures)],
        contentType: String? = nil,
        stateJSON: String? = nil
    ) -> String? {
        let id = "strongs-multi-\(UUID().uuidString)"
        let osisFragments = fragments.map { frag in
            OsisFragment(
                xml: frag.xml.replacingOccurrences(of: "\r", with: ""),
                key: frag.key,
                keyName: frag.keyName,
                v11n: "KJVA",
                bookCategory: DocumentCategory.dictionary.rawValue,
                bookInitials: frag.bookInitials,
                bookAbbreviation: frag.bookAbbreviation,
                osisRef: frag.keyName,
                isNewTestament: false,
                features: frag.features,
                hasStrongs: frag.features.type != nil,
                ordinalRange: [0, 0],
                language: "en",
                direction: "ltr"
            )
        }

        let payload = MultiFragmentDocumentPayload(
            id: id,
            type: "multi",
            osisFragments: osisFragments,
            compare: false,
            contentType: contentType,
            state: bridgeJSONValue(from: stateJSON)
        )
        guard let data = try? bridgeEncoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode multi-fragment bridge document")
            return nil
        }
        return json
    }

    /**
     Captures all main-reader state needed to build a compare payload away from the main queue.
     */
    private struct BibleCompareDocumentRequest {
        /// Modules to include in compare output, paired with their SWORD readers.
        let modules: [(info: ModuleInfo, module: SwordModule)]

        /// Active passage OSIS book id.
        let osisBookId: String

        /// User-facing active book name.
        let bookName: String

        /// One-based active chapter.
        let chapter: Int

        /// Whether the active book is in the New Testament.
        let isNewTestament: Bool

        /// Optional first selected verse.
        let startVerse: Int?

        /// Optional last selected verse.
        let endVerse: Int?
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for Compare.

     Android opens `FakeBookFactory.compareDocument` and renders a `MultiFragmentDocument` with
     `compare=true`, one fragment per installed Bible. iOS mirrors that shape so Vue owns the
     translation list, hide buttons, and restore affordance.

     - Parameters:
       - startVerse: Optional first verse requested by the selection or bridge action. `nil`
         starts at verse 1.
       - endVerse: Optional final verse requested by the selection or bridge action. `nil` uses the
         chapter's module-reported final verse.
     - Returns: Serialized compare `MultiDocument`, or `nil` when no installed Bible can render the
       requested range.
     - Side effects: reads installed SWORD Bible modules and temporarily moves each module cursor
       while extracting raw OSIS.
     - Failure modes: logs and returns `nil` when SWORD is unavailable, every module misses the
       requested range, or JSON serialization fails.
     */
    private func makeBibleCompareDocumentRequest(startVerse: Int?, endVerse: Int?) -> BibleCompareDocumentRequest? {
        guard let manager = swordManager else {
            logger.warning("Compare requested without an active SwordManager")
            return nil
        }

        let modules = installedCompareBibleModules(using: manager).compactMap { moduleInfo in
            manager.module(named: moduleInfo.name).map { (info: moduleInfo, module: $0) }
        }
        guard !modules.isEmpty else {
            logger.warning("Compare requested with no installed Bible modules")
            return nil
        }

        let bookName = currentBook
        let chapter = currentChapter
        let osisBookId = osisBookId(for: bookName)
        return BibleCompareDocumentRequest(
            modules: modules,
            osisBookId: osisBookId,
            bookName: bookName,
            chapter: chapter,
            isNewTestament: isNewTestament(bookName),
            startVerse: startVerse,
            endVerse: endVerse
        )
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for Compare.

     - Parameter request: Captured compare request containing module readers and passage metadata.
     - Returns: Serialized compare `MultiDocument`, or `nil` when no installed Bible can render the
       requested range.
     - Side effects: temporarily moves each module cursor while extracting raw OSIS.
     - Failure modes: logs and returns `nil` when every module misses the requested range or JSON
       serialization fails.
    */
    private static func buildBibleCompareDocumentJSON(_ request: BibleCompareDocumentRequest) -> String? {
        let fragments = request.modules.compactMap { modulePair -> [String: Any]? in
            buildBibleCompareFragment(
                module: modulePair.module,
                moduleInfo: modulePair.info,
                osisBookId: request.osisBookId,
                bookName: request.bookName,
                chapter: request.chapter,
                isNewTestament: request.isNewTestament,
                startVerse: request.startVerse,
                endVerse: request.endVerse
            )
        }

        guard !fragments.isEmpty else {
            logger.warning(
                "Compare requested but no module rendered \(request.osisBookId, privacy: .public) \(request.chapter)"
            )
            return nil
        }

        let document: [String: Any] = [
            "id": "compare-\(UUID().uuidString)",
            "type": "multi",
            "osisFragments": fragments,
            "compare": true,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize compare document JSON")
            return nil
        }
        return json
    }

    /**
     Resolves installed Bible modules eligible for Compare.

     - Parameter manager: Active SWORD manager used as a fallback when cached module metadata is
       empty.
     - Returns: Installed Bible module metadata in active-reader order.
     - Side effects: may read the SWORD module list when cached `installedBibleModules` is empty.
     - Failure modes: returns an empty array when no installed module is categorized as a Bible.
     */
    private func installedCompareBibleModules(using manager: SwordManager) -> [ModuleInfo] {
        let cached = installedBibleModules
        let modules = cached.isEmpty
            ? manager.installedModules().filter { $0.category == .bible }
            : cached

        guard let activeIndex = modules.firstIndex(where: { $0.name == activeModuleName }) else {
            return modules
        }
        var orderedModules = modules
        let activeModule = orderedModules.remove(at: activeIndex)
        orderedModules.insert(activeModule, at: 0)
        return orderedModules
    }

    /**
     Builds one compare fragment for one installed Bible module.

     - Parameters:
       - module: SWORD Bible module to read.
       - moduleInfo: Metadata for `module`, used for Vue labels and language/direction flags.
       - osisBookId: Active passage OSIS book identifier.
       - bookName: User-facing active book name.
       - chapter: One-based active chapter number.
       - startVerse: Optional one-based first verse to compare.
       - endVerse: Optional one-based final verse to compare.
     - Returns: Vue OSIS fragment dictionary, or `nil` when the module cannot resolve any verse in
       the requested range.
     - Side effects: temporarily moves the SWORD module cursor once per inspected verse and restores
       the previous cursor after each read.
     - Failure modes: returns `nil` if the first requested verse cannot be resolved in the target
       module's versification or if all raw entries in the range are empty.
     */
    private static func buildBibleCompareFragment(
        module: SwordModule,
        moduleInfo: ModuleInfo,
        osisBookId: String,
        bookName: String,
        chapter: Int,
        isNewTestament: Bool,
        startVerse: Int?,
        endVerse: Int?
    ) -> [String: Any]? {
        let normalizedStart = max(1, startVerse ?? 1)
        let firstInspection = module.inspectVerseKeyAndRawEntryRestoringPrevious(
            "=\(osisBookId).\(chapter).\(normalizedStart)"
        )
        guard let firstKey = firstInspection.verseKey,
              firstKey.osisBookName == osisBookId,
              firstKey.chapter == chapter,
              firstKey.verse == normalizedStart else {
            return nil
        }

        let chapterMaxVerse = max(normalizedStart, firstKey.verseMax)
        let normalizedEnd = min(max(normalizedStart, endVerse ?? chapterMaxVerse), chapterMaxVerse)
        var verseXML: [String] = []

        for verse in normalizedStart...normalizedEnd {
            guard let ordinal = module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse) else {
                return nil
            }
            let inspection: (actualKey: String, verseKey: VerseKeyChildren?, rawEntry: String)
            if verse == normalizedStart {
                inspection = firstInspection
            } else {
                inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious(
                    "=\(osisBookId).\(chapter).\(verse)"
                )
            }

            guard let key = inspection.verseKey,
                  key.osisBookName == osisBookId,
                  key.chapter == chapter,
                  key.verse == verse else {
                continue
            }

            let rawText = inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { continue }

            let osisRef = "\(osisBookId).\(chapter).\(verse)"
            verseXML.append(
                "<verse osisID=\"\(osisRef)\" verseOrdinal=\"\(ordinal)\">\(rawText) </verse>"
            )
        }

        guard !verseXML.isEmpty else { return nil }

        let osisRef = compareOsisRef(
            osisBookId: osisBookId,
            chapter: chapter,
            startVerse: normalizedStart,
            endVerse: normalizedEnd
        )
        let keyName = compareRangeTitle(
            bookName: bookName,
            chapter: chapter,
            startVerse: normalizedStart,
            endVerse: normalizedEnd
        )
        guard let ordinalStart = module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: normalizedStart),
              let ordinalEnd = module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: normalizedEnd) else {
            return nil
        }

        return [
            "xml": "<div>\(verseXML.joined())</div>",
            "key": "\(moduleInfo.name)--\(osisRef)",
            "keyName": keyName,
            "v11n": "KJVA",
            "bookCategory": DocumentCategory.bible.rawValue,
            "bookInitials": moduleInfo.name,
            "bookAbbreviation": moduleInfo.name,
            "osisRef": osisRef,
            "isNewTestament": isNewTestament,
            "features": [String: Any](),
            "hasStrongs": moduleInfo.features.contains(.strongsNumbers),
            "ordinalRange": [ordinalStart, ordinalEnd],
            "language": moduleInfo.language.isEmpty ? "en" : moduleInfo.language,
            "direction": moduleInfo.isRightToLeft ? "rtl" : "ltr",
        ]
    }

    /**
     Formats the OSIS reference carried by a compare fragment.

     - Parameters:
       - osisBookId: OSIS book identifier.
       - chapter: One-based chapter number.
       - startVerse: First verse in the rendered range.
       - endVerse: Last verse in the rendered range.
     - Returns: Single-verse OSIS ref or Android-style repeated-book range ref.
     - Side effects: none.
     - Failure modes: none; inputs are expected to be normalized by the caller.
     */
    private static func compareOsisRef(osisBookId: String, chapter: Int, startVerse: Int, endVerse: Int) -> String {
        if startVerse == endVerse {
            return "\(osisBookId).\(chapter).\(startVerse)"
        }
        return "\(osisBookId).\(chapter).\(startVerse)-\(osisBookId).\(chapter).\(endVerse)"
    }

    /**
     Formats the user-visible compare range title used by Vue `MultiDocument`.

     - Parameters:
       - bookName: User-facing book name.
       - chapter: One-based chapter number.
       - startVerse: First verse in the rendered range.
       - endVerse: Last verse in the rendered range.
     - Returns: Title such as `Genesis 1:1` or `Genesis 1:1-3`.
     - Side effects: none.
     - Failure modes: none; inputs are expected to be normalized by the caller.
     */
    private static func compareRangeTitle(bookName: String, chapter: Int, startVerse: Int, endVerse: Int) -> String {
        if startVerse == endVerse {
            return "\(bookName) \(chapter):\(startVerse)"
        }
        return "\(bookName) \(chapter):\(startVerse)-\(endVerse)"
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for multi-reference Bible links.

     - Parameter refs: Parsed OSIS references in the order supplied by `multi://` or a
       multi-reference `osis://` link. Empty input produces no document.
     - Returns: Serialized JSON for a transient multi-document, or `nil` if there are no references
       or JSON serialization fails.
     - Side effects: reads the active SWORD Bible module and moves its key cursor while extracting
       verse OSIS. Missing module content is represented by a fallback verse label so the link still
       opens a document instead of falling back to the native cross-reference sheet.
     - Note: The payload intentionally omits `contentType`; Vue routes non-Strong's `type: "multi"`
       documents to `MultiDocument`, matching Android's `FakeBookFactory.multiDocument` path.
     */
    private func buildBibleMultiReferenceDocumentJSON(refs: [OsisRef]) -> String? {
        guard !refs.isEmpty else { return nil }

        let moduleName = activeModuleName
        let fragments: [[String: Any]] = refs.compactMap { ref in
            let osisRef = "\(ref.osisId).\(ref.chapter).\(ref.verse)"
            let ordinal: Int
            if let activeModule {
                guard let moduleOrdinal = activeModule.verseOrdinal(
                    osisBookId: ref.osisId,
                    chapter: ref.chapter,
                    verse: ref.verse
                ) else {
                    return nil
                }
                ordinal = moduleOrdinal
            } else {
                ordinal = compatibilityOrdinal(chapter: ref.chapter, verse: ref.verse)
            }
            return [
                "xml": buildBibleMultiReferenceXML(ref: ref, module: activeModule, ordinal: ordinal),
                "key": "\(moduleName)--\(osisRef)",
                "keyName": ref.displayName,
                "v11n": "KJVA",
                "bookCategory": DocumentCategory.bible.rawValue,
                "bookInitials": moduleName,
                "bookAbbreviation": ref.osisId,
                "osisRef": osisRef,
                "isNewTestament": isNewTestament(ref.book),
                "features": [String: Any](),
                "hasStrongs": activeModule?.info.features.contains(.strongsNumbers) ?? false,
                "ordinalRange": [ordinal, ordinal],
                "language": "en",
                "direction": "ltr",
            ]
        }
        guard fragments.count == refs.count else { return nil }

        let document: [String: Any] = [
            "id": "multi-\(UUID().uuidString)",
            "type": "multi",
            "osisFragments": fragments,
            "compare": false,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize multi-reference document JSON")
            return nil
        }
        return json
    }

    /**
     Reads one Bible verse as an OSIS fragment suitable for Vue `MultiDocument`.

     - Parameters:
       - ref: Parsed Bible reference to render.
       - module: Active Bible module to read from. A missing module yields a fallback fragment.
     - Returns: A `<div>` containing one `<verse>` element with the caller-supplied module or
       placeholder ordinal.
     - Side effects: when `module` is present, temporarily moves its SWORD key cursor inside one
       serialized inspection call and restores the previous cursor before returning.
     - Failure modes: if the module cannot resolve the exact verse or returns empty raw OSIS, the
       fragment contains an escaped display label rather than throwing.
     */
    private func buildBibleMultiReferenceXML(ref: OsisRef, module: SwordModule?, ordinal: Int) -> String {
        let osisRef = "\(ref.osisId).\(ref.chapter).\(ref.verse)"
        let rawText: String

        if let module {
            let inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious("=\(osisRef)")
            if let key = inspection.verseKey,
               key.osisBookName == ref.osisId,
               key.chapter == ref.chapter,
               key.verse == ref.verse {
                rawText = inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawText = ""
            }
        } else {
            rawText = ""
        }

        let body = rawText.isEmpty ? escapeXML(ref.displayName) : rawText
        return "<div><verse osisID=\"\(osisRef)\" verseOrdinal=\"\(ordinal)\">\(body) </verse></div>"
    }

    /// Escape special XML characters in text content.
    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /**
     Build Strong's key variants using the same families Android tries for dictionary lookup.

     Android parity matters here because installed Strong's dictionaries do not all expose the same
     key shape. Some expect zero-padded numeric keys, some want a prefixed category key such as
     `G1234` / `H1234`, and some zLD modules require a trailing carriage return.
     */
    private func buildKeyOptions(for strongsNumber: String) -> [String] {
        Self.strongsLookupKeyOptions(for: strongsNumber)
    }

    /// Shared Strong's lookup key variants used by reader dictionary resolution and tests.
    static func strongsLookupKeyOptions(for strongsNumber: String) -> [String] {
        let original = strongsNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberOnly = String(original.drop(while: { $0.isLetter }))
        let stripped = numberOnly.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        let sanitizedBase = stripped.isEmpty ? numberOnly : stripped

        let categoryPrefix: String
        categoryPrefix = isHebrewStrongsNumber(original) ? "H" : "G"

        var keys: [String] = []

        func appendUnique(_ candidate: String) {
            guard !candidate.isEmpty, !keys.contains(candidate) else { return }
            keys.append(candidate)
        }

        var digitVariants: [String] = [numberOnly]
        var currentDigits = numberOnly
        while currentDigits.hasPrefix("0"), currentDigits.count > 1 {
            currentDigits.removeFirst()
            digitVariants.append(currentDigits)
        }

        appendUnique(original)
        for digits in digitVariants {
            appendUnique(digits)
            appendUnique(digits + "\r")
            appendUnique("\(categoryPrefix)\(digits)")
        }
        appendUnique(sanitizedBase)

        return keys
    }

    /// Mirrors Android's heuristic for inferring Hebrew-vs-Greek when the prefix is omitted.
    static func isHebrewStrongsNumber(_ strongsNumber: String) -> Bool {
        let normalized = strongsNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if normalized.hasPrefix("H") { return true }
        if normalized.hasPrefix("G") { return false }

        let digits = String(normalized.drop(while: { $0.isLetter || $0 == "0" }))
        return (Int(digits) ?? 0) > 5624
    }

    /**
     Try each key variant in a module and return the first valid renderText() result.
     After setKey(), SWORD positions to the nearest entry even if the exact key
     doesn't exist. We must verify currentKey() matches to avoid returning wrong entries.
     */
    private struct DictionaryLookupResult {
        let actualKey: String
        let rawEntry: String
        let renderedText: String
    }

    private func lookupInModule(_ module: SwordModule, keyOptions: [String]) -> DictionaryLookupResult? {
        logger.info("lookupInModule: \(module.info.name), keyOptions=\(keyOptions)")

        for key in keyOptions {
            // Atomic setKey + currentKey + renderText in one queue.sync block
            // to prevent SWORD state interleaving between calls.
            let inspection = module.setKeyAndInspect(key)
            let actualKey = inspection.actualKey
            let candidate = inspection.renderedText
            let trimmedKey = actualKey.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("lookupInModule: tried key='\(key)', actualKey='\(trimmedKey)', renderLen=\(candidate.count)")

            switch Self.dictionaryLookupCandidateRejectionReason(
                requested: key,
                actualKey: trimmedKey,
                rawEntry: inspection.rawEntry,
                renderedText: candidate
            ) {
            case .none:
                break
            case .actualKeyMismatch:
                logger.info("lookupInModule: key mismatch, skipping")
                continue
            case let .rawEntryMismatch(rawEntryKey):
                logger.info("lookupInModule: raw entry key mismatch (\(rawEntryKey)), skipping")
                continue
            case .emptyRenderedText:
                continue
            case .renderedEntryMismatch:
                logger.info("lookupInModule: rendered entry key mismatch, skipping")
                continue
            case .renderedTextMissingRequestedNumericKey:
                logger.info("lookupInModule: rendered text missing requested numeric key, skipping")
                continue
            }

            return DictionaryLookupResult(
                actualKey: trimmedKey,
                rawEntry: inspection.rawEntry.trimmingCharacters(in: .whitespacesAndNewlines),
                renderedText: candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return nil
    }

    private func buildDictionaryEntryXML(
        rawEntry: String,
        renderedText: String,
        fallbackTitle: String? = nil,
        strongsLinkPrefix: String? = nil
    ) -> String {
        let trimmedRawEntry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRawEntry.hasPrefix("<"), trimmedRawEntry.hasSuffix(">") {
            let linkifiedRawEntry = Self.linkifyRawDictionaryXML(
                trimmedRawEntry,
                defaultPrefix: strongsLinkPrefix
            )
            if let fallbackTitle, !trimmedRawEntry.localizedCaseInsensitiveContains("<title") {
                let escapedTitle = escapeXML(fallbackTitle)
                return "<div><title type=\"x-gen\">\(escapedTitle)</title>\(linkifiedRawEntry)</div>"
            }
            return "<div>\(linkifiedRawEntry)</div>"
        }

        let linkifiedHtml = Self.linkifyRenderedDictionaryHTML(
            renderedText,
            defaultPrefix: strongsLinkPrefix
        )
        let titlePrefix = fallbackTitle.map { "<title type=\"x-gen\">\(escapeXML($0))</title>" } ?? ""
        return "<div>\(titlePrefix)<div type=\"paragraph\">\(linkifiedHtml)</div></div>"
    }

    private static func strongsLinkPrefix(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let prefix = trimmed.first, prefix == "H" || prefix == "G" else {
            return nil
        }
        return String(prefix)
    }

    private static func strongsLinkPrefix(forModuleName moduleName: String) -> String? {
        switch moduleName {
        case "StrongsHebrew", "BDB", "OSHB":
            return "H"
        case "StrongsGreek", "StrongsRealGreek", "Thayer":
            return "G"
        default:
            return nil
        }
    }

    static func canonicalStrongsKeyName(requested: String, actualKey: String, rawEntry: String) -> String {
        let resolvedKey = dictionaryEntryKey(actualKey: actualKey, rawEntry: rawEntry) ?? requested
        let numericKey = Self.normalizeNumericKey(resolvedKey)
        guard !numericKey.isEmpty else {
            return Self.normalizeNumericKey(requested)
        }
        return numericKey.count < 5
            ? String(repeating: "0", count: 5 - numericKey.count) + numericKey
            : numericKey
    }

    static func dictionaryEntryKey(actualKey: String, rawEntry: String) -> String? {
        let trimmedActualKey = actualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedActualKey.isEmpty {
            return trimmedActualKey
        }

        let titlePattern = try? NSRegularExpression(pattern: #"<title>([^<]+)</title>"#, options: [])
        if let regex = titlePattern,
           let match = regex.firstMatch(in: rawEntry, range: NSRange(rawEntry.startIndex..., in: rawEntry)),
           let range = Range(match.range(at: 1), in: rawEntry) {
            return String(rawEntry[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let entryPattern = try? NSRegularExpression(
            pattern: #"<entryFree\b[^>]*\bn\s*=\s*"([^"]+)""#,
            options: []
        )
        if let regex = entryPattern,
           let match = regex.firstMatch(in: rawEntry, range: NSRange(rawEntry.startIndex..., in: rawEntry)),
           let range = Range(match.range(at: 1), in: rawEntry) {
            return String(rawEntry[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    static func rawDictionaryEntryMatchesRequestedKey(requested: String, rawEntry: String) -> Bool {
        guard let resolvedKey = dictionaryEntryKey(actualKey: "", rawEntry: rawEntry) else {
            return true
        }

        let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResolvedKey = resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRequested.caseInsensitiveCompare(trimmedResolvedKey) == .orderedSame {
            return true
        }

        let requestedNumeric = normalizeNumericKey(trimmedRequested)
        let resolvedNumeric = normalizeNumericKey(trimmedResolvedKey)
        return !requestedNumeric.isEmpty && requestedNumeric == resolvedNumeric
    }

    enum DictionaryLookupCandidateRejectionReason: Equatable {
        case actualKeyMismatch
        case rawEntryMismatch(String)
        case emptyRenderedText
        case renderedEntryMismatch
        case renderedTextMissingRequestedNumericKey
    }

    static func dictionaryLookupCandidateRejectionReason(
        requested: String,
        actualKey: String,
        rawEntry: String,
        renderedText: String
    ) -> DictionaryLookupCandidateRejectionReason? {
        let trimmedActualKey = actualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRenderedText = renderedText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Verify the key actually matched. SWORD dictionary modules silently
        // position to the nearest entry when the exact key doesn't exist.
        if !trimmedActualKey.isEmpty,
           !keysMatchNormalized(requested: requested, actual: trimmedActualKey) {
            return .actualKeyMismatch
        }

        if let rawEntryKey = dictionaryEntryKey(actualKey: "", rawEntry: rawEntry),
           !rawDictionaryEntryMatchesRequestedKey(requested: requested, rawEntry: rawEntry) {
            return .rawEntryMismatch(rawEntryKey)
        }

        if trimmedRenderedText.isEmpty || trimmedRenderedText.contains("@@@@") {
            return .emptyRenderedText
        }

        if !renderedDictionaryEntryMatchesRequestedKey(
            requested: requested,
            renderedText: trimmedRenderedText
        ) {
            return .renderedEntryMismatch
        }

        // For modules where currentKey() returns empty (some zLD modules like
        // BDBGlosses), verify the content references the requested Strong's number.
        // Without this check, these modules return whatever entry they're stuck on.
        if trimmedActualKey.isEmpty {
            let numericKey = normalizeNumericKey(requested)
            if !numericKey.isEmpty && !trimmedRenderedText.contains(numericKey) {
                return .renderedTextMissingRequestedNumericKey
            }
        }

        return nil
    }

    static func renderedDictionaryEntryKey(renderedText: String) -> String? {
        let withoutTags = renderedText.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let normalized = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        let pattern = try? NSRegularExpression(
            pattern: #"^([HG]?\d{1,5})\b"#,
            options: [.caseInsensitive]
        )
        guard let regex = pattern,
              let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized)
              ),
              let range = Range(match.range(at: 1), in: normalized) else {
            return nil
        }

        return String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func renderedDictionaryEntryMatchesRequestedKey(requested: String, renderedText: String) -> Bool {
        guard let resolvedKey = renderedDictionaryEntryKey(renderedText: renderedText) else {
            return true
        }

        let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedResolvedKey = resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRequested.caseInsensitiveCompare(trimmedResolvedKey) == .orderedSame {
            return true
        }

        let requestedNumeric = normalizeNumericKey(trimmedRequested)
        let resolvedNumeric = normalizeNumericKey(trimmedResolvedKey)
        return !requestedNumeric.isEmpty && requestedNumeric == resolvedNumeric
    }

    /**
     Compare two dictionary keys by normalizing: strip letter prefixes, leading zeros,
     and compare case-insensitively. Handles Strong's variants ("01121" == "1121" == "H1121")
     and non-numeric keys like Robinson morphology codes ("V-2AAI-3S").
     */
    static func keysMatchNormalized(requested: String, actual: String) -> Bool {
        let trimmedRequested = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedActual = actual.trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct case-insensitive match (handles morphology codes, etc.)
        if trimmedRequested.caseInsensitiveCompare(trimmedActual) == .orderedSame { return true }

        // Numeric normalization: strip letter prefix and leading zeros, then compare
        let reqNumeric = Self.normalizeNumericKey(trimmedRequested)
        let actNumeric = Self.normalizeNumericKey(trimmedActual)
        if !reqNumeric.isEmpty && reqNumeric == actNumeric { return true }

        return false
    }

    /**
     Strip optional letter prefix (H/G) and leading zeros from a key.
     "H07225" → "7225", "01121" → "1121", "7225" → "7225"
     */
    static func normalizeNumericKey(_ key: String) -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterLetters = String(trimmedKey.drop(while: { $0.isLetter }))
        let stripped = afterLetters.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        // Verify it's actually numeric
        guard !stripped.isEmpty, stripped.allSatisfy({ $0.isNumber }) else { return "" }
        return stripped
    }

    private func moduleDisplayLabel(_ module: SwordModule) -> String {
        if let abbreviation = module.configEntry("Abbreviation")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !abbreviation.isEmpty {
            return abbreviation
        }
        return module.info.name
    }

    /// Find ALL lexicon/dictionary modules that can look up the given Strong's number.
    private func findAllLexiconModules(for strongsNumber: String) -> [SwordModule] {
        guard let mgr = swordManager else {
            logger.error("findAllLexiconModules: swordManager is nil!")
            return []
        }

        let isHebrew: Bool
        if strongsNumber.hasPrefix("H") {
            isHebrew = true
        } else if strongsNumber.hasPrefix("G") {
            isHebrew = false
        } else {
            let numStr = strongsNumber.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
            isHebrew = (Int(numStr) ?? 0) > 5624
        }
        let feature: ModuleFeatures = isHebrew ? .hebrewDef : .greekDef

        let allModules = mgr.installedModules()
        logger.info("findAllLexiconModules: \(allModules.count) installed modules, isHebrew=\(isHebrew), categories: \(allModules.map { $0.name + ":" + String(describing: $0.category) }.joined(separator: ", "))")
        var result: [SwordModule] = []
        var seen = Set<String>()

        // 1. Explicit user selection (Android parity: when non-empty, use only selected modules)
        let selectionKey: AppPreferenceKey = isHebrew ? .strongsHebrewDictionary : .strongsGreekDictionary
        let selectedNames = settingsStore?.getStringSet(selectionKey) ?? []
        if !selectedNames.isEmpty {
            for name in selectedNames where seen.insert(name).inserted {
                if let mod = mgr.module(named: name),
                   StrongsDictionaryPolicy.isSupportedDictionaryModuleName(mod.info.name),
                   (mod.info.category == .dictionary || mod.info.category == .glossary),
                   mod.info.features.contains(feature) {
                    result.append(mod)
                }
            }
            // Fall back to runtime defaults when persisted values are stale/invalid.
            if !result.isEmpty {
                return result
            }
        }

        // 2. Runtime default: dictionary/glossary modules with matching feature
        for info in allModules where
            (info.category == .dictionary || info.category == .glossary) &&
                StrongsDictionaryPolicy.isSupportedDictionaryModuleName(info.name) &&
                info.features.contains(feature) {
            if seen.insert(info.name).inserted, let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        if !result.isEmpty {
            return result
        }

        // 3. Known lexicon module names fallback
        let lexiconNames = isHebrew
            ? ["StrongsHebrew", "OSHB", "BDB"]
            : ["StrongsGreek", "StrongsRealGreek", "Thayer", "ISBE"]
        for name in lexiconNames {
            if seen.insert(name).inserted, let mod = mgr.module(named: name) {
                result.append(mod)
            }
        }

        return result
    }

    /**
     Android currently excludes certain Strong's modules from the curated Strong's-dictionary flow
     because their content/lookup behavior is not good enough for parity use.

     We mirror that product decision here so iOS does not surface modules that Android intentionally
     hides, which would otherwise produce confusing tab labels and materially different entry content.
     */
    static func isSupportedStrongsDictionaryModuleName(_ name: String) -> Bool {
        StrongsDictionaryPolicy.isSupportedDictionaryModuleName(name)
    }

    /// Find modules that can decode morphology (Robinson, Packard, etc.).
    private func findMorphologyModules() -> [SwordModule] {
        guard let mgr = swordManager else { return [] }
        let allModules = mgr.installedModules()
        var result: [SwordModule] = []
        var seen = Set<String>()

        // 1. Explicit user selection (Android parity: when non-empty, use only selected modules)
        let selectedNames = settingsStore?.getStringSet(.robinsonGreekMorphology) ?? []
        if !selectedNames.isEmpty {
            for name in selectedNames where seen.insert(name).inserted {
                if let mod = mgr.module(named: name),
                   (mod.info.category == .dictionary || mod.info.category == .glossary),
                   mod.info.features.contains(.greekParse) {
                    result.append(mod)
                }
            }
            // Fall back to runtime defaults when persisted values are stale/invalid.
            if !result.isEmpty {
                return result
            }
        }

        // 2. Runtime default: dictionary/glossary modules with Greek morphology
        for info in allModules where
            (info.category == .dictionary || info.category == .glossary) &&
                info.features.contains(.greekParse) {
            if seen.insert(info.name).inserted, let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        if !result.isEmpty {
            return result
        }

        // 3. Known morphology module fallback
        for name in ["Robinson"] {
            if seen.insert(name).inserted, let mod = mgr.module(named: name) {
                result.append(mod)
            }
        }

        return result
    }

    /**
     Find plain dictionaries used by "Lookup in dictionaries".
     Mirrors Android `SwordDocumentFacade.wordLookupDictionaries`.
     */
    private func findWordLookupDictionaryModules() -> [SwordModule] {
        guard let mgr = swordManager else { return [] }
        let disabled = Set(settingsStore?.getStringSet(.disabledWordLookupDictionaries) ?? [])
        let allModules = mgr.installedModules()

        var result: [SwordModule] = []
        for info in allModules where
            info.category == .dictionary &&
                !info.features.contains(.greekDef) &&
                !info.features.contains(.hebrewDef) &&
                !info.features.contains(.greekParse) &&
                !disabled.contains(info.name) {
            if let module = mgr.module(named: info.name) {
                result.append(module)
            }
        }
        return result
    }

    /**
     Normalizes selected text before dictionary lookup by trimming whitespace and trailing punctuation.

     - Parameter text: Raw selected text from the web client.
     - Returns: Sanitized lookup key used against plain dictionary modules.
     */
    private func normalizeWordLookupQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.,;:!?"'()\[\]]+$"#, with: "", options: .regularExpression)
    }

    /**
     Builds a multi-fragment dictionary document for the current word-lookup query.

     - Parameter query: Normalized lookup key to resolve across enabled plain dictionaries.
     - Returns: Multi-document JSON for the lookup results, or `nil` when nothing matches.

     Failure modes:
     - returns `nil` when no enabled lookup dictionaries are installed or when none contain the key
     */
    private func buildWordLookupMultiDocJSON(query: String) -> String? {
        let modules = findWordLookupDictionaryModules()
        guard !modules.isEmpty else { return nil }

        // Try common case variants, while still requiring exact key match after normalization.
        let keyOptions = [query, query.lowercased(), query.capitalized]
        var fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: OsisFeatures)] = []

        for mod in modules {
            guard let html = lookupInModule(mod, keyOptions: keyOptions) else { continue }
            let escapedTitle = escapeXML(query)
            let xml = "<div><title type=\"x-gen\">\(escapedTitle)</title><div type=\"paragraph\">\(html)</div></div>"
            fragments.append((
                xml: xml,
                key: "\(mod.info.name)--\(query)",
                keyName: query,
                bookInitials: mod.info.name,
                bookAbbreviation: String(mod.info.name.prefix(10)),
                features: OsisFeatures()
            ))
        }

        guard !fragments.isEmpty else { return nil }
        return buildMultiFragmentJSON(fragments: fragments)
    }

    /// Handle a single cross-reference link: osis://?osis=Matt.1.1&v11n=KJV
    private func handleOsisLink(_ link: String) {
        logger.info("handleOsisLink: \(link)")
        guard let components = URLComponents(string: link) else { return }
        let items = components.queryItems ?? []
        guard let osisRef = items.first(where: { $0.name == "osis" })?.value else { return }

        let refs = parseOsisReferences(osisRef)
        if refs.count == 1, let ref = refs.first {
            // Single reference: if links window callback is available, use it
            if let openInLinks = onOpenInLinksWindow {
                openInLinks(ref.book, ref.chapter)
            } else {
                navigateTo(book: ref.book, chapter: ref.chapter)
            }
        } else if !refs.isEmpty {
            // Multiple references in one osis param (e.g. "Matt.1.1-Matt.1.3")
            openMultiReferenceDocument(refs: refs)
        }
    }

    /// Handle multi cross-reference links: multi://?osis=Matt.1.1&osis=Mark.2.3&...
    private func handleMultiLink(_ link: String) {
        logger.info("handleMultiLink: \(link)")
        guard let components = URLComponents(string: link) else { return }
        let items = components.queryItems ?? []
        let osisValues = items.filter { $0.name == "osis" }.compactMap(\.value)

        var allRefs: [OsisRef] = []
        for value in osisValues {
            allRefs.append(contentsOf: parseOsisReferences(value))
        }

        guard !allRefs.isEmpty else { return }

        if allRefs.count == 1, let ref = allRefs.first {
            navigateTo(book: ref.book, chapter: ref.chapter)
        } else {
            openMultiReferenceDocument(refs: allRefs)
        }
    }

    /**
     Opens parsed multi-reference results through the shared Vue document pipeline.

     - Parameter refs: Non-empty parsed references collected from one `osis://` range/list or a
       `multi://` Open All link.
     - Side effects: builds a transient multi-document from the active Bible module, then either
       hands it to the owner for links-window routing or renders it in this controller.
     - Failure modes: returns without side effects when JSON construction fails; single-reference
       navigation is handled by callers before this method is reached.
     */
    private func openMultiReferenceDocument(refs: [OsisRef]) {
        guard let documentJSON = buildBibleMultiReferenceDocumentJSON(refs: refs) else { return }

        if let openInLinksWindow = onOpenMultiReferenceDocumentInLinksWindow {
            openInLinksWindow(documentJSON)
        } else {
            loadMultiReferenceDocument(documentJSON)
        }
    }

    /**
     Handle sword:// links (e.g. sword://Bible/John.17.11 from Calvin's commentary).
     Format: sword://moduleName/OsisRef or sword://Bible/OsisRef
     */
    private func handleSwordLink(_ link: String) {
        logger.info("handleSwordLink: \(link)")
        // Strip "sword://" prefix
        var ref = String(link.dropFirst("sword://".count))
        // Strip leading/trailing slashes
        while ref.hasPrefix("/") { ref = String(ref.dropFirst()) }
        while ref.hasSuffix("/") { ref = String(ref.dropLast()) }

        guard !ref.isEmpty else { return }

        if let slashIdx = ref.firstIndex(of: "/") {
            let modulePart = String(ref[ref.startIndex..<slashIdx]).lowercased()
            let osisRef = String(ref[ref.index(after: slashIdx)...])
            // If module is "Bible" (generic), just navigate to the OSIS ref
            if modulePart == "bible" {
                _ = navigateToOsisRef(osisRef)
            } else {
                // Try to navigate with the OSIS ref regardless of module name
                // (we don't switch modules for now, just navigate to the reference)
                _ = navigateToOsisRef(osisRef)
            }
        } else {
            // No slash — treat the whole thing as an OSIS reference
            _ = navigateToOsisRef(ref)
        }
    }

    /**
     Handle MyBible cross-reference links: "B:bookInt chapter:verse"
     Example: "B:470 1:1" → Matthew 1:1
     */
    private func handleMyBibleLink(_ link: String) {
        logger.info("handleMyBibleLink: \(link)")
        // Format: "B:bookInt chapter:verse" (e.g. "B:470 1:1")
        let parts = link.split(separator: " ", maxSplits: 1)
        guard parts.count >= 2 else { return }

        // Extract book number from "B:470"
        let bookPart = String(parts[0])
        guard bookPart.hasPrefix("B:"),
              let bookInt = Int(bookPart.dropFirst(2)) else { return }

        // Look up OSIS ID from MyBible book number
        guard let osisId = Self.myBibleIntToOsisId[bookInt] else {
            logger.warning("Unknown MyBible book number: \(bookInt)")
            return
        }

        // Parse "chapter:verse"
        let chapVerse = String(parts[1]).components(separatedBy: ":")
        guard let chapter = Int(chapVerse[0]) else { return }
        let verse = chapVerse.count >= 2 ? Int(chapVerse[1]) : nil

        let osisRef = verse != nil ? "\(osisId).\(chapter).\(verse!)" : "\(osisId).\(chapter)"
        _ = navigateToOsisRef(osisRef)
    }

    /**
     Handle MySword Bible links: "#bBookInt.Chapter.Verse"
     Example: "#b40.1.1" → Matthew 1:1 (MySword uses sequential 1-66 numbering)
     */
    private func handleMySwordBibleLink(_ link: String) {
        logger.info("handleMySwordBibleLink: \(link)")
        // Format: "#bBookInt.Chapter.Verse" (e.g. "#b40.1.1")
        let rest = String(link.dropFirst(2)) // strip "#b"
        let parts = rest.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return }

        let bookInt = parts[0]
        let chapter = parts[1]
        let verse = parts.count >= 3 ? parts[2] : nil

        // MySword uses sequential 1-66 numbering (1=Gen, 40=Matt, 66=Rev)
        guard let osisId = Self.mySwordIntToOsisId[bookInt] else {
            logger.warning("Unknown MySword book number: \(bookInt)")
            return
        }

        let osisRef = verse != nil ? "\(osisId).\(chapter).\(verse!)" : "\(osisId).\(chapter)"
        _ = navigateToOsisRef(osisRef)
    }

    // MARK: - MySword/MyBible Book Number Mappings

    /**
     MySword sequential book numbering (1-66, Protestant canon).
     Matches Android's mySwordIntToBibleBook in MySwordBookMap.kt.
     */
    private static let mySwordIntToOsisId: [Int: String] = [
        1: "Gen", 2: "Exod", 3: "Lev", 4: "Num", 5: "Deut",
        6: "Josh", 7: "Judg", 8: "Ruth", 9: "1Sam", 10: "2Sam",
        11: "1Kgs", 12: "2Kgs", 13: "1Chr", 14: "2Chr",
        15: "Ezra", 16: "Neh", 17: "Esth", 18: "Job",
        19: "Ps", 20: "Prov", 21: "Eccl", 22: "Song",
        23: "Isa", 24: "Jer", 25: "Lam", 26: "Ezek", 27: "Dan",
        28: "Hos", 29: "Joel", 30: "Amos", 31: "Obad", 32: "Jonah",
        33: "Mic", 34: "Nah", 35: "Hab", 36: "Zeph",
        37: "Hag", 38: "Zech", 39: "Mal",
        40: "Matt", 41: "Mark", 42: "Luke", 43: "John",
        44: "Acts", 45: "Rom", 46: "1Cor", 47: "2Cor",
        48: "Gal", 49: "Eph", 50: "Phil", 51: "Col",
        52: "1Thess", 53: "2Thess", 54: "1Tim", 55: "2Tim",
        56: "Titus", 57: "Phlm", 58: "Heb",
        59: "Jas", 60: "1Pet", 61: "2Pet",
        62: "1John", 63: "2John", 64: "3John",
        65: "Jude", 66: "Rev",
    ]

    /**
     MyBible non-sequential book numbering.
     Matches Android's myBibleIntToBibleBook in MyBibleBookMap.kt.
     */
    private static let myBibleIntToOsisId: [Int: String] = [
        10: "Gen", 20: "Exod", 30: "Lev", 40: "Num", 50: "Deut",
        60: "Josh", 70: "Judg", 80: "Ruth",
        90: "1Sam", 100: "2Sam", 110: "1Kgs", 120: "2Kgs",
        130: "1Chr", 140: "2Chr",
        150: "Ezra", 160: "Neh", 190: "Esth",
        220: "Job", 230: "Ps", 240: "Prov", 250: "Eccl", 260: "Song",
        290: "Isa", 300: "Jer", 310: "Lam", 320: "Bar",
        330: "Ezek", 340: "Dan",
        350: "Hos", 360: "Joel", 370: "Amos", 380: "Obad",
        390: "Jonah", 400: "Mic", 410: "Nah", 420: "Hab",
        430: "Zeph", 440: "Hag", 450: "Zech", 460: "Mal",
        470: "Matt", 480: "Mark", 490: "Luke", 500: "John",
        510: "Acts", 520: "Rom", 530: "1Cor", 540: "2Cor",
        550: "Gal", 560: "Eph", 570: "Phil", 580: "Col",
        590: "1Thess", 600: "2Thess", 610: "1Tim", 620: "2Tim",
        630: "Titus", 640: "Phlm", 650: "Heb",
        660: "Jas", 670: "1Pet", 680: "2Pet",
        690: "1John", 700: "2John", 710: "3John",
        720: "Jude", 730: "Rev",
        // Deuterocanonical / Apocrypha (MyBible includes these)
        170: "Tob", 180: "Jdt", 270: "Wis", 280: "Sir",
        462: "1Macc", 464: "2Macc", 466: "3Macc", 467: "4Macc",
        468: "2Esd",
    ]

    /**
     Parses an OSIS reference string into structured verse references.

     Android resolves cross-reference passages through JSword `PassageKeyFactory`, which expands
     ranges and lists against the active document versification. For range/list inputs iOS now
     delegates to the active SWORD module's key parser and uses the previous string splitter only
     as a no-module fallback.

     - Parameter osisString: OSIS reference text such as `Matt.1.1`, `Gen.1.1-Gen.1.3`, or a
       comma-separated list.
     - Returns: Parsed references in module/parser order. Invalid or unknown keys are omitted.
     - Side effects: May temporarily move the active module cursor through `SwordModule`; that
       method restores the previous key before returning.
     */
    private func parseOsisReferences(_ osisString: String) -> [OsisRef] {
        let trimmed = osisString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let activeModule {
            let parsedKeys = trimmed.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .flatMap { activeModule.parseKeyList($0) }
            if !parsedKeys.isEmpty {
                return parsedKeys.compactMap { key in
                    guard let ref = parseOsisRef(key),
                          isValidResolvedReference(osisBookId: ref.osisId, chapter: ref.chapter, verse: ref.verse) else {
                        return nil
                    }
                    return ref
                }
            }
        }

        // Fallback for no-module startup paths and parser failures.
        let parts = trimmed.components(separatedBy: CharacterSet(charactersIn: ",-"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var refs: [OsisRef] = []
        for part in parts {
            if let ref = parseOsisRef(part),
               isValidResolvedReference(osisBookId: ref.osisId, chapter: ref.chapter, verse: ref.verse) {
                refs.append(ref)
            }
        }
        return refs
    }

    /// Parse a single OSIS ref like "Matt.1.1" → OsisRef(book: "Matthew", chapter: 1, verse: 1)
    private func parseOsisRef(_ osis: String) -> OsisRef? {
        // Format: BookId.Chapter.Verse or BookId.Chapter
        let components = osis.components(separatedBy: ".")
        guard components.count >= 2 else { return nil }

        let osisId = components[0]
        guard let chapter = Int(components[1]) else { return nil }
        let verse = components.count >= 3 ? Int(components[2]) : nil

        guard let bookName = bookName(forOsisId: osisId) else {
            logger.warning("Unknown OSIS book ID: \(osisId)")
            return nil
        }

        return OsisRef(book: bookName, chapter: chapter, verse: verse ?? 1, osisId: osisId)
    }

    /// Look up verse text for each reference from the active SWORD module.
    private func lookupCrossReferences(_ refs: [OsisRef]) -> [CrossReference] {
        guard let module = activeModule else {
            return refs.map { CrossReference(ref: $0, text: "") }
        }

        return refs.map { ref in
            let key = "\(ref.osisId) \(ref.chapter):\(ref.verse)"
            module.setKey(key)
            let text = module.stripText().trimmingCharacters(in: .whitespacesAndNewlines)
            return CrossReference(ref: ref, text: text)
        }
    }

    /**
     Requests that the owning SwiftUI view present the downloads/install UI.
     */
    public func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge) {
        onRequestOpenDownloads?(nil)
    }

    // MARK: - BibleBridgeDelegate — Dialogs

    /// Callback for presenting a reference chooser dialog (returns OSIS ref via completion).
    var onRefChooserDialog: ((@escaping (String?) -> Void) -> Void)?

    /**
     Opens the native reference chooser and returns the selected OSIS reference to Vue.js.

     - Parameter callId: Bridge response identifier for the pending chooser callback.

     Side effects:
     - invokes the native chooser callback and sends the resolved OSIS string or `null` back

     Failure modes:
     - returns `null` immediately when no native chooser handler is configured
     */
    public func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int) {
        // Show a reference picker and return the selected OSIS ref
        if let handler = onRefChooserDialog {
            handler { [weak bridge] osisRef in
                guard let bridge else { return }
                if let ref = osisRef {
                    bridge.sendResponse(callId: callId, value: "\"\(ref)\"")
                } else {
                    bridge.sendResponse(callId: callId, value: "null")
                }
            }
        } else {
            bridge.sendResponse(callId: callId, value: "null")
        }
    }

    /**
     Parses human-readable or OSIS-format references on behalf of the web client.

     - Parameters:
       - callId: Bridge response identifier for the pending parse request.
       - text: Raw reference text entered by the user.

     Side effects:
     - sends either a resolved OSIS reference string or `null` through the bridge response channel

     Failure modes:
     - returns `null` for empty input or any reference string the native parser cannot resolve
     */
    public func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String) {
        // Try to resolve human-readable reference to OSIS key
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }

        if let osisRef = resolveReferenceWithActiveModuleParser(trimmed) {
            let escaped = osisRef.replacingOccurrences(of: "\"", with: "\\\"")
            bridge.sendResponse(callId: callId, value: "\"\(escaped)\"")
            return
        }

        // If already OSIS format (e.g. "Gen.1.1"), validate and return
        if let osisRef = resolveOsisRef(trimmed) {
            let escaped = osisRef.replacingOccurrences(of: "\"", with: "\\\"")
            bridge.sendResponse(callId: callId, value: "\"\(escaped)\"")
            return
        }

        // Try parsing as human-readable (e.g. "Genesis 1:1", "Gen 1:1", "Matt 5:3-7")
        if let osisRef = resolveHumanRef(trimmed) {
            let escaped = osisRef.replacingOccurrences(of: "\"", with: "\\\"")
            bridge.sendResponse(callId: callId, value: "\"\(escaped)\"")
            return
        }

        // Fallback: return null if we can't parse
        bridge.sendResponse(callId: callId, value: "null")
    }

    /**
     Resolves reference text through the active SWORD parser and serializes it like JSword.

     Android's text editor calls `LinkControl.resolveRef`, which delegates to JSword
     `PassageKeyFactory` and returns `key.osisRef`. This helper mirrors that path for iOS by
     asking the active module to parse each comma-separated passage item, then joining normalized
     OSIS range strings with JSword's space delimiter.

     - Parameter text: Human-readable or OSIS passage text supplied by the web client.
     - Returns: JSword-style `osisRef` text, or `nil` when no active module can parse it.
     - Side effects: Temporarily moves the active SWORD module cursor through `parseKeyList` and
       verse-count checks; `SwordModule` restores the cursor around those calls.
     - Failure modes: Returns `nil` if any parsed key is not a valid verse reference in the active
       module's versification.
     */
    private func resolveReferenceWithActiveModuleParser(_ text: String) -> String? {
        guard let activeModule else { return nil }
        let explicitValidation = validateExplicitReferenceText(text, module: activeModule)
        if case .invalid = explicitValidation {
            return nil
        }

        let parsedKeys = activeModule.parseKeyList(text)
        guard !parsedKeys.isEmpty else { return nil }

        if case let .parsed(ranges) = explicitValidation,
           let osisRef = moduleParsedOsisRef(ranges: ranges, module: activeModule) {
            return osisRef
        }

        let refs = parsedKeys.compactMap { key -> OsisRef? in
            guard let ref = parseOsisRef(key),
                  isValidResolvedReference(
                    osisBookId: ref.osisId,
                    chapter: ref.chapter,
                    verse: ref.verse
                  ) else {
                return nil
            }
            return ref
        }
        guard refs.count == parsedKeys.count else { return nil }
        return moduleParsedOsisRef(refs, module: activeModule)
    }

    /**
     Validates and parses explicit numeric coordinates before trusting SWORD's parser output.

     JSword's `PassageKeyFactory` validates every constructed `VerseRange` through
     `Versification.validate(...)`. SWORD's `SWModule_parseKeyList` instead normalizes references
     such as `Gen.1.99` to a later valid verse. This helper preserves JSword semantics by checking
     user-supplied chapter/verse numbers that iOS can unambiguously identify. When the whole string
     is parsed, the resulting ranges also preserve list/range structure that SWORD may otherwise
     flatten into separate chapter keys.
     */
    private func validateExplicitReferenceText(
        _ text: String,
        module: SwordModule
    ) -> ExplicitReferenceValidation {
        let normalized = text.replacingOccurrences(
            of: #"\p{Pd}"#,
            with: "-",
            options: .regularExpression
        )
        var basis: ReferenceCoordinate?
        var ranges: [ReferenceRange] = []
        for segment in normalized.components(separatedBy: CharacterSet(charactersIn: ",;")) {
            let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSegment.isEmpty else { continue }
            let rangeParts = trimmedSegment.components(separatedBy: "-")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard rangeParts.count <= 2 else { return .invalid }
            guard let firstPart = rangeParts.first,
                  let start = parseReferenceCoordinate(firstPart, basis: basis) else {
                return .unknown
            }
            guard isValidReferenceCoordinate(start, module: module) else { return .invalid }

            var end = start
            if rangeParts.count > 1 {
                guard let parsedEnd = parseReferenceCoordinate(
                    rangeParts[1],
                    basis: start,
                    rangeEndUsesChapterWhenStartIsChapterOnly: start.verse == nil
                ),
                      isValidReferenceCoordinate(parsedEnd, module: module),
                      let startOrdinal = referenceOrdinal(start, module: module),
                      let endOrdinal = referenceOrdinal(parsedEnd, module: module),
                      endOrdinal >= startOrdinal else {
                    return .invalid
                }
                end = parsedEnd
            }

            ranges.append(ReferenceRange(start: start, end: end))
            basis = end
        }

        return ranges.isEmpty ? .unknown : .parsed(ranges)
    }

    /**
     Serializes one parser result segment into the compact OSIS form JSword would expose.

     `SWModule_parseKeyList` returns expanded verse keys. JSword's `Passage.getOsisRef()` reports
     a single verse as `Book.Chapter.Verse`, a same-chapter range as
     `Book.Chapter.Start-Book.Chapter.End`, and a whole chapter as `Book.Chapter`. This helper
     reconstructs those compact forms for the common verse-list and range cases accepted by the
     editor bridge.
     */
    private func moduleParsedOsisRef(_ refs: [OsisRef], module: SwordModule) -> String? {
        guard !refs.isEmpty else { return nil }

        let references = refs.compactMap { ref -> VerseKeyReference? in
            guard let ordinal = module.verseOrdinal(
                osisBookId: ref.osisId,
                chapter: ref.chapter,
                verse: ref.verse
            ) else {
                return nil
            }
            return module.verseReference(osisBookId: ref.osisId, ordinal: ordinal)
        }
        guard references.count == refs.count else { return nil }

        var ranges: [(start: VerseKeyReference, end: VerseKeyReference)] = []
        var rangeStart = references[0]
        var rangeEnd = references[0]

        for reference in references.dropFirst() {
            if reference.ordinal == rangeEnd.ordinal + 1 {
                rangeEnd = reference
            } else {
                ranges.append((rangeStart, rangeEnd))
                rangeStart = reference
                rangeEnd = reference
            }
        }
        ranges.append((rangeStart, rangeEnd))

        return ranges
            .map { moduleParsedOsisRange(start: $0.start, end: $0.end, module: module) }
            .joined(separator: " ")
    }

    /**
     Serializes parsed explicit ranges using the same contiguous-range normalization as JSword.

     JSword normalizes adjacent range/list entries before `getOsisRef()`. This converts
     chapter-level coordinates into their real verse endpoints, merges adjacent ranges by active
     module ordinal, and then delegates to the same range formatter used for SWORD-expanded keys.
     */
    private func moduleParsedOsisRef(ranges: [ReferenceRange], module: SwordModule) -> String? {
        let resolvedRanges = ranges.compactMap { range -> (start: VerseKeyReference, end: VerseKeyReference)? in
            guard let start = verseKeyReference(forStartOf: range.start, module: module),
                  let end = verseKeyReference(forEndOf: range.end, module: module) else {
                return nil
            }
            return (start, end)
        }
        guard resolvedRanges.count == ranges.count, !resolvedRanges.isEmpty else { return nil }

        var merged: [(start: VerseKeyReference, end: VerseKeyReference)] = []
        var current = resolvedRanges[0]
        for range in resolvedRanges.dropFirst() {
            if range.start.ordinal == current.end.ordinal + 1 {
                current.end = range.end
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)

        return merged
            .map { moduleParsedOsisRange(start: $0.start, end: $0.end, module: module) }
            .joined(separator: " ")
    }

    /**
     Formats one contiguous verse run using JSword `VerseRange.getOsisRef()` semantics.

     - Returns: A single verse, same-chapter range, whole-chapter reference, or multi-chapter range
       with whole-chapter endpoints compacted where the active module confirms the endpoint starts
       or ends a chapter.
     */
    private func moduleParsedOsisRange(
        start: VerseKeyReference,
        end: VerseKeyReference,
        module: SwordModule
    ) -> String {
        if start == end {
            return start.osisRef
        }

        if start.osisBookId == end.osisBookId,
           start.chapter == 1,
           start.verse == 1,
           let bookName = bookName(forOsisId: start.osisBookId),
           end.chapter == chapterCount(for: bookName),
           module.verseCount(osisBookId: end.osisBookId, chapter: end.chapter) == end.verse {
            return start.osisBookId
        }

        if start.osisBookId == end.osisBookId, start.chapter == end.chapter {
            if start.verse == 1,
               module.verseCount(osisBookId: start.osisBookId, chapter: start.chapter) == end.verse {
                return "\(start.osisBookId).\(start.chapter)"
            }
            return "\(start.osisRef)-\(end.osisRef)"
        }

        let startText = start.verse == 1
            ? "\(start.osisBookId).\(start.chapter)"
            : start.osisRef
        let endText = module.verseCount(osisBookId: end.osisBookId, chapter: end.chapter) == end.verse
            ? "\(end.osisBookId).\(end.chapter)"
            : end.osisRef
        return "\(startText)-\(endText)"
    }

    private func osisRefString(_ ref: OsisRef) -> String {
        "\(ref.osisId).\(ref.chapter).\(ref.verse)"
    }

    /**
     Parsed coordinate from user reference text.

     `verse == nil` represents a chapter-level coordinate. That distinction is required because
     JSword interprets `Gen 1-2` as a chapter range but `Gen 1:1-2` as a verse range.
     */
    private enum ExplicitReferenceValidation {
        case parsed([ReferenceRange])
        case unknown
        case invalid
    }

    private struct ReferenceRange {
        let start: ReferenceCoordinate
        let end: ReferenceCoordinate
    }

    private struct ReferenceCoordinate {
        let osisBookId: String
        let chapter: Int
        let verse: Int?
    }

    private func parseReferenceCoordinate(
        _ text: String,
        basis: ReferenceCoordinate?,
        rangeEndUsesChapterWhenStartIsChapterOnly: Bool = false
    ) -> ReferenceCoordinate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let osis = parseOsisCoordinate(trimmed) {
            return osis
        }

        if let human = parseHumanCoordinate(trimmed) {
            return human
        }

        if let chapterVerse = parseRelativeChapterVerseCoordinate(trimmed, basis: basis) {
            return chapterVerse
        }

        if let number = Int(trimmed), let basis {
            if rangeEndUsesChapterWhenStartIsChapterOnly || basis.verse == nil {
                return ReferenceCoordinate(osisBookId: basis.osisBookId, chapter: number, verse: nil)
            }
            return ReferenceCoordinate(osisBookId: basis.osisBookId, chapter: basis.chapter, verse: number)
        }

        return nil
    }

    private func parseOsisCoordinate(_ text: String) -> ReferenceCoordinate? {
        let parts = text.components(separatedBy: ".")
        guard parts.count == 2 || parts.count == 3,
              bookName(forOsisId: parts[0]) != nil,
              let chapter = Int(parts[1]) else {
            return nil
        }
        let verse = parts.count == 3 ? Int(parts[2]) : nil
        if parts.count == 3, verse == nil { return nil }
        return ReferenceCoordinate(osisBookId: parts[0], chapter: chapter, verse: verse)
    }

    private func parseHumanCoordinate(_ text: String) -> ReferenceCoordinate? {
        let aliases = referenceBookAliases()
            .sorted { $0.alias.count > $1.alias.count }
            .map { NSRegularExpression.escapedPattern(for: $0.alias) }
            .joined(separator: "|")
        guard !aliases.isEmpty,
              let regex = try? NSRegularExpression(
                pattern: #"(?i)^(\#(aliases))\s+(\d+)(?::(\d+))?$"#
              ),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let aliasRange = Range(match.range(at: 1), in: text),
              let chapterRange = Range(match.range(at: 2), in: text),
              let chapter = Int(text[chapterRange]) else {
            return nil
        }

        let alias = canonicalReferenceAlias(String(text[aliasRange]))
        guard let osisBookId = referenceBookAliasMap()[alias] else { return nil }
        let verse: Int?
        if match.range(at: 3).location != NSNotFound,
           let verseRange = Range(match.range(at: 3), in: text) {
            verse = Int(text[verseRange])
            if verse == nil { return nil }
        } else {
            verse = nil
        }

        return ReferenceCoordinate(osisBookId: osisBookId, chapter: chapter, verse: verse)
    }

    private func parseRelativeChapterVerseCoordinate(
        _ text: String,
        basis: ReferenceCoordinate?
    ) -> ReferenceCoordinate? {
        guard let basis else { return nil }
        let parts = text.components(separatedBy: ":")
        guard parts.count == 2,
              let chapter = Int(parts[0]),
              let verse = Int(parts[1]) else {
            return nil
        }
        return ReferenceCoordinate(osisBookId: basis.osisBookId, chapter: chapter, verse: verse)
    }

    private func isValidReferenceCoordinate(_ coordinate: ReferenceCoordinate, module: SwordModule) -> Bool {
        if let verse = coordinate.verse {
            return module.verseOrdinal(
                osisBookId: coordinate.osisBookId,
                chapter: coordinate.chapter,
                verse: verse
            ) != nil
        }
        return module.verseCount(osisBookId: coordinate.osisBookId, chapter: coordinate.chapter) != nil
    }

    private func referenceOrdinal(_ coordinate: ReferenceCoordinate, module: SwordModule) -> Int? {
        if let verse = coordinate.verse {
            return module.verseOrdinal(
                osisBookId: coordinate.osisBookId,
                chapter: coordinate.chapter,
                verse: verse
            )
        }
        return module.verseOrdinal(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: 1
        )
    }

    private func verseKeyReference(
        forStartOf coordinate: ReferenceCoordinate,
        module: SwordModule
    ) -> VerseKeyReference? {
        let verse = coordinate.verse ?? 1
        guard let ordinal = module.verseOrdinal(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse
        ) else {
            return nil
        }
        return VerseKeyReference(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    private func verseKeyReference(
        forEndOf coordinate: ReferenceCoordinate,
        module: SwordModule
    ) -> VerseKeyReference? {
        let verse: Int
        if let coordinateVerse = coordinate.verse {
            verse = coordinateVerse
        } else if let chapterVerseCount = module.verseCount(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter
        ) {
            verse = chapterVerseCount
        } else {
            return nil
        }

        guard let ordinal = module.verseOrdinal(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse
        ) else {
            return nil
        }
        return VerseKeyReference(
            osisBookId: coordinate.osisBookId,
            chapter: coordinate.chapter,
            verse: verse,
            ordinal: ordinal
        )
    }

    private func referenceBookAliasMap() -> [String: String] {
        var map: [String: String] = [:]
        for alias in referenceBookAliases() {
            map[alias.alias] = alias.osisBookId
        }
        return map
    }

    private func referenceBookAliases() -> [(alias: String, osisBookId: String)] {
        var aliases: [(alias: String, osisBookId: String)] = []
        let books = (bookList.isEmpty ? Self.defaultBooks : bookList)
        for book in books {
            appendReferenceAlias(book.name, osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias(book.abbreviation, osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias(book.osisId, osisBookId: book.osisId, to: &aliases)
            appendNumberedBookReferenceAliases(for: book, to: &aliases)
        }
        for (alias, osisBookId) in Self.commonReferenceAliasOsisIds {
            appendReferenceAlias(alias, osisBookId: osisBookId, to: &aliases)
        }
        return aliases
    }

    private static let commonReferenceAliasOsisIds: [String: String] = [
        "gen": "Gen", "ex": "Exod", "exo": "Exod", "lev": "Lev",
        "num": "Num", "deut": "Deut", "deu": "Deut", "dt": "Deut",
        "josh": "Josh", "judg": "Judg", "jdg": "Judg",
        "1 sam": "1Sam", "2 sam": "2Sam", "1 ki": "1Kgs", "2 ki": "2Kgs",
        "1 chr": "1Chr", "2 chr": "2Chr", "neh": "Neh", "est": "Esth",
        "ps": "Ps", "psa": "Ps", "prov": "Prov", "pro": "Prov",
        "eccl": "Eccl", "ecc": "Eccl", "song": "Song", "sos": "Song",
        "isa": "Isa", "jer": "Jer", "lam": "Lam", "ezek": "Ezek", "eze": "Ezek",
        "dan": "Dan", "hos": "Hos", "joe": "Joel", "amo": "Amos",
        "oba": "Obad", "jon": "Jonah", "mic": "Mic", "nah": "Nah",
        "hab": "Hab", "zeph": "Zeph", "zep": "Zeph",
        "hag": "Hag", "zech": "Zech", "zec": "Zech", "mal": "Mal",
        "matt": "Matt", "mat": "Matt", "mk": "Mark", "luk": "Luke", "lk": "Luke",
        "jn": "John", "joh": "John", "act": "Acts",
        "rom": "Rom", "1 cor": "1Cor", "2 cor": "2Cor",
        "gal": "Gal", "eph": "Eph", "phil": "Phil", "php": "Phil",
        "col": "Col", "1 thess": "1Thess", "2 thess": "2Thess",
        "1 th": "1Thess", "2 th": "2Thess",
        "1 tim": "1Tim", "2 tim": "2Tim", "tit": "Titus", "phm": "Phlm", "philem": "Phlm",
        "heb": "Heb", "jas": "Jas", "jam": "Jas",
        "1 pet": "1Pet", "2 pet": "2Pet", "1 pe": "1Pet", "2 pe": "2Pet",
        "1 jn": "1John", "2 jn": "2John", "3 jn": "3John",
        "1 john": "1John", "2 john": "2John", "3 john": "3John",
        "jude": "Jude", "jud": "Jude",
        "rev": "Rev", "reve": "Rev",
    ]

    private func appendNumberedBookReferenceAliases(
        for book: BookInfo,
        to aliases: inout [(alias: String, osisBookId: String)]
    ) {
        let numberedPrefixes: [(numeric: String, roman: String, word: String)] = [
            ("1", "I", "First"),
            ("2", "II", "Second"),
            ("3", "III", "Third"),
            ("4", "IV", "Fourth"),
        ]
        for prefix in numberedPrefixes where book.name.hasPrefix("\(prefix.numeric) ") {
            let baseName = String(book.name.dropFirst(2))
            appendReferenceAlias("\(prefix.roman) \(baseName)", osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias("\(prefix.word) \(baseName)", osisBookId: book.osisId, to: &aliases)
            appendReferenceAlias("\(prefix.numeric)\(baseName)", osisBookId: book.osisId, to: &aliases)
        }
    }

    private func appendReferenceAlias(
        _ alias: String,
        osisBookId: String,
        to aliases: inout [(alias: String, osisBookId: String)]
    ) {
        let canonical = canonicalReferenceAlias(alias)
        guard !canonical.isEmpty else { return }
        aliases.append((canonical, osisBookId))
    }

    private func canonicalReferenceAlias(_ alias: String) -> String {
        alias
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: #"[\s_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Try to validate/resolve an OSIS-format reference like "Gen.1.1"
    private func resolveOsisRef(_ text: String) -> String? {
        let parts = text.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        // Check if first part is a valid OSIS book ID
        guard bookName(forOsisId: parts[0]) != nil else { return nil }
        guard let chapter = Int(parts[1]) else { return nil }
        let verse = parts.count >= 3 ? Int(parts[2]) : nil
        guard isValidResolvedReference(osisBookId: parts[0], chapter: chapter, verse: verse) else {
            return nil
        }
        return text
    }

    /**
     Validates a resolved OSIS reference against the active module when one exists.

     Android delegates parsed references to JSword's `PassageKeyFactory`, which rejects invalid
     chapter and verse coordinates instead of accepting text that merely looks like OSIS. This
     helper gives iOS the same contract through SWORD's exact verse/versification APIs, with the
     static compatibility table used only when no module is available.
     */
    private func isValidResolvedReference(osisBookId: String, chapter: Int, verse: Int?) -> Bool {
        guard chapter > 0, let book = bookName(forOsisId: osisBookId) else { return false }
        if let activeModule {
            if let verse {
                return activeModule.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse) != nil
            }
            return activeModule.verseCount(osisBookId: osisBookId, chapter: chapter) != nil
        }

        guard chapter <= Self.chapterCount(for: book) else { return false }
        if let verse {
            return verse > 0 && verse <= Self.verseCount(for: book, chapter: chapter)
        }
        return true
    }

    /// Try to resolve a human-readable reference like "Genesis 1:1" or "Gen 1:1"
    private func resolveHumanRef(_ text: String) -> String? {
        // Pattern: BookName Chapter:Verse or BookName Chapter
        // Handle numbered books: "1 Sam 1:1", "2 Kings 3:4"
        let pattern = #"^(\d?\s*[A-Za-z]+(?:\s+[A-Za-z]+)*)\s+(\d+)(?::(\d+)(?:-(\d+))?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        guard let bookRange = Range(match.range(at: 1), in: text),
              let chapterRange = Range(match.range(at: 2), in: text) else { return nil }

        let bookText = String(text[bookRange]).trimmingCharacters(in: .whitespaces)
        guard let chapter = Int(text[chapterRange]) else { return nil }

        // Look up OSIS book ID
        guard let osisId = osisBookId(forHumanName: bookText) else { return nil }

        if match.range(at: 3).location != NSNotFound,
           let verseRange = Range(match.range(at: 3), in: text),
           let verse = Int(text[verseRange]) {
            let startRef = "\(osisId).\(chapter).\(verse)"
            guard resolveOsisRef(startRef) != nil else { return nil }
            if match.range(at: 4).location != NSNotFound,
               let endRange = Range(match.range(at: 4), in: text),
               let endVerse = Int(text[endRange]) {
                let endRef = "\(osisId).\(chapter).\(endVerse)"
                guard endVerse >= verse, resolveOsisRef(endRef) != nil else { return nil }
                return "\(startRef)-\(endRef)"
            }
            return startRef
        }
        let chapterRef = "\(osisId).\(chapter)"
        return resolveOsisRef(chapterRef)
    }

    /// Look up OSIS ID from a human-readable book name or abbreviation.
    private func osisBookId(forHumanName name: String) -> String? {
        let lower = name.lowercased()
        let books = bookList
        // Try exact match first
        if let info = books.first(where: { $0.name == name }) {
            return info.osisId
        }
        // Try case-insensitive match against full book names
        for info in books {
            if info.name.lowercased() == lower {
                return info.osisId
            }
        }
        // Try abbreviation matching (first 3+ characters)
        for info in books {
            if info.name.lowercased().hasPrefix(lower) || lower.hasPrefix(info.name.lowercased().prefix(3).description) {
                return info.osisId
            }
        }
        // Try common abbreviations
        let abbreviations: [String: String] = [
            "gen": "Gen", "ex": "Exod", "exo": "Exod", "lev": "Lev",
            "num": "Num", "deut": "Deut", "deu": "Deut", "dt": "Deut",
            "josh": "Josh", "judg": "Judg", "jdg": "Judg",
            "1 sam": "1Sam", "2 sam": "2Sam", "1 ki": "1Kgs", "2 ki": "2Kgs",
            "1 chr": "1Chr", "2 chr": "2Chr", "neh": "Neh", "est": "Esth",
            "ps": "Ps", "psa": "Ps", "prov": "Prov", "pro": "Prov",
            "eccl": "Eccl", "ecc": "Eccl", "song": "Song", "sos": "Song",
            "isa": "Isa", "jer": "Jer", "lam": "Lam", "ezek": "Ezek", "eze": "Ezek",
            "dan": "Dan", "hos": "Hos", "joe": "Joel", "amo": "Amos",
            "oba": "Obad", "jon": "Jonah", "mic": "Mic", "nah": "Nah",
            "hab": "Hab", "zeph": "Zeph", "zep": "Zeph",
            "hag": "Hag", "zech": "Zech", "zec": "Zech", "mal": "Mal",
            "matt": "Matt", "mat": "Matt", "mk": "Mark", "luk": "Luke", "lk": "Luke",
            "jn": "John", "joh": "John", "act": "Acts",
            "rom": "Rom", "1 cor": "1Cor", "2 cor": "2Cor",
            "gal": "Gal", "eph": "Eph", "phil": "Phil", "php": "Phil",
            "col": "Col", "1 thess": "1Thess", "2 thess": "2Thess", "1 th": "1Thess", "2 th": "2Thess",
            "1 tim": "1Tim", "2 tim": "2Tim", "tit": "Titus", "phm": "Phlm", "philem": "Phlm",
            "heb": "Heb", "jas": "Jas", "jam": "Jas",
            "1 pet": "1Pet", "2 pet": "2Pet", "1 pe": "1Pet", "2 pe": "2Pet",
            "1 jn": "1John", "2 jn": "2John", "3 jn": "3John",
            "1 john": "1John", "2 john": "2John", "3 john": "3John",
            "jude": "Jude", "jud": "Jude",
            "rev": "Rev", "reve": "Rev",
        ]
        if let osisId = abbreviations[lower] {
            return osisId
        }
        return nil
    }

    /**
     Navigate to a reference entered as human-readable text (e.g. "Genesis 1:1", "Gen 1", "Matt 5:3")
     or OSIS format (e.g. "Gen.1.1"). Returns true if navigation succeeded.
     */
    @discardableResult
    public func navigateToRef(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Try OSIS format first
        if let osisRef = resolveOsisRef(trimmed) {
            return navigateToOsisRef(osisRef)
        }

        // Try human-readable format
        if let osisRef = resolveHumanRef(trimmed) {
            return navigateToOsisRef(osisRef)
        }

        return false
    }

    /// Navigate to a resolved OSIS ref like "Gen.1.1" or "Gen.1"
    private func navigateToOsisRef(_ osisRef: String) -> Bool {
        let parts = osisRef.split(separator: ".")
        guard parts.count >= 2, let chapter = Int(parts[1]) else { return false }
        guard let name = bookName(forOsisId: String(parts[0])) else { return false }
        let verse = parts.count >= 3 ? Int(parts[2]) : nil
        navigateTo(book: name, chapter: chapter, verse: verse)
        return true
    }

    /**
     Receives help-dialog requests from the web client.

     - Note: iOS currently logs the request only; native help presentation is handled elsewhere.
     */
    public func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?) {
        logger.info("Help dialog: \(title ?? "Help")")
    }

    // MARK: - BibleBridgeDelegate — Toast & Sharing

    /// Callback for presenting toast messages (set by BibleReaderView).
    var onShowToast: ((String) -> Void)?
    /// Callback for sharing HTML content (set by BibleReaderView).
    var onShareHtml: ((String) -> Void)?
    /// Callback when user interacts with this pane (for focus-on-interaction).
    var onInteraction: (() -> Void)?
    /// Reference to the WindowManager for synchronized scrolling.
    weak var windowManagerRef: WindowManager?
    /// Callback to open content in a links window (book, chapter).
    var onOpenInLinksWindow: ((String, Int) -> Void)?

    /**
     Forwards a toast/banner message request to the owning SwiftUI view.
     */
    public func bridge(_ bridge: BibleBridge, showToast text: String) {
        onShowToast?(text)
    }

    /**
     Forwards HTML sharing content to the host view so platform share UI can be presented.
     */
    public func bridge(_ bridge: BibleBridge, shareHtml html: String) {
        onShareHtml?(html)
    }

    /**
     Toggles whether one compare document should be hidden in the current compare session.
     */
    public func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String) {
        var documents = currentHiddenCompareDocuments()
        if documents.contains(documentId) {
            documents.remove(documentId)
        } else {
            documents.insert(documentId)
        }
        persistHiddenCompareDocuments(documents)
        // Notify Vue.js of updated settings
        bridge.emit(event: "set_config", data: buildConfigJSON())
    }

    /**
     Resolves the hidden compare module set currently exposed to Vue.

     - Returns: Workspace-persisted hidden module initials when a workspace is active, otherwise the
       controller-local fallback used by tests and controllers not attached to a workspace.
     - Side effects: none.
     - Failure modes: none.
     */
    private func currentHiddenCompareDocuments() -> Set<String> {
        if let workspaceDocuments = activeWindow?.workspace?.workspaceSettings?.hideCompareDocuments {
            return workspaceDocuments
        }
        return hiddenCompareDocuments
    }

    /**
     Persists hidden compare module state to the active workspace when available.

     - Parameter documents: Module initials hidden from Vue compare output.
     - Side effects: updates the controller fallback cache, mutates active workspace settings, and
       invokes `onPersistState` so the owning pane can save SwiftData.
     - Failure modes: if no workspace is active, only the controller fallback cache is updated.
     */
    private func persistHiddenCompareDocuments(_ documents: Set<String>) {
        hiddenCompareDocuments = documents
        guard let workspace = activeWindow?.workspace else { return }

        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        settings.hideCompareDocuments = documents
        workspace.workspaceSettings = settings
        onPersistState?()
    }

    /// Callback for fullscreen toggle requests (from double-tap in WebView).
    public var onToggleFullScreen: (() -> Void)?

    /**
     Handles double-tap fullscreen requests originating in the embedded web client.

     Failure modes:
     - returns without side effects when the user has disabled double-tap fullscreen in preferences
     */
    public func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge) {
        // Match Android: double-tap fullscreen can be disabled by user preference.
        guard appPreferenceBool(.doubleTapToFullscreen) else { return }
        onToggleFullScreen?()
    }

    // MARK: - EPUB Link Navigation

    /**
     Navigates EPUB links emitted by the web client either to another spine entry or an in-page anchor.
     */
    public func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String) {
        guard activeEpubReader != nil else { return }
        if !toKey.isEmpty {
            // Navigate to section (loadEpubEntry handles fragment scrolling)
            let href = toId.isEmpty ? toKey : "\(toKey)#\(toId)"
            loadEpubEntry(href: href)
        } else if !toId.isEmpty {
            // Same-page fragment navigation
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":\"\(toId)\",\"topOffset\":0,\"bottomOffset\":0}")
        }
    }

    /// Update active languages in the WebView based on installed SWORD modules.
    public func updateActiveLanguages() {
        guard let manager = swordManager else { return }
        let languages = Array(Set(manager.installedModules().map { $0.language })).sorted()
        bridge.updateActiveLanguages(languages.isEmpty ? ["en"] : languages)
    }

    /**
     Convert an ordinal back to a verse number within the current chapter.
     */
    private func ordinalToVerse(_ ordinal: Int) -> Int? {
        guard let reference = verseReference(book: currentBook, ordinal: ordinal),
              reference.chapter == currentChapter else {
            return nil
        }
        return reference.verse
    }

    /// Get plain text for a verse range using SWORD stripText.
    private func getVerseText(startOrdinal: Int, endOrdinal: Int) -> String {
        guard let module = activeModule else { return "" }
        let osisBookId = osisBookId(for: currentBook)
        let chapter = currentChapter

        module.setKey("\(osisBookId) \(chapter):1")
        var text = ""

        while true {
            let key = module.currentKey()
            guard let (_, parsedChapter, parsedVerse) = parseVerseKey(key) else { break }
            if parsedChapter != chapter { break }

            guard let ordinal = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: parsedVerse) else {
                break
            }
            if ordinal >= startOrdinal && ordinal <= endOrdinal {
                let verseText = module.stripText()
                if !verseText.isEmpty {
                    text += verseText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                }
            }
            if ordinal > endOrdinal { break }
            if !module.next() { break }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildMemorizeDocumentJSON(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> String? {
        let textItems = memorizeTextItems(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
        guard !textItems.isEmpty else { return nil }

        let document: [String: Any] = [
            "id": "memorize-\(bookInitials)-\(startOrdinal)-\(endOrdinal)",
            "type": "memorize",
            "title": memorizeReferenceTitle(startOrdinal: startOrdinal, endOrdinal: endOrdinal),
            "texts": textItems,
            "state": [
                "memorize": [
                    "mode": "blur",
                    "modeConfig": [String: Any](),
                ] as [String: Any],
            ] as [String: Any],
            "bookInitials": bookInitials,
            "v11n": "KJVA",
            "osisRef": memorizeOsisRef(startOrdinal: startOrdinal, endOrdinal: endOrdinal),
            "startOrdinal": startOrdinal,
            "endOrdinal": endOrdinal,
            "memorizedOrdinals": memorizationProgressStore?.memorizedOrdinals(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            ) ?? [],
            "targetOrdinals": memorizationProgressStore?.targetOrdinals(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            ) ?? [],
            "readingProgressSettings": readingProgressSettingsPayload(),
        ]

        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize Memorize document JSON")
            return nil
        }
        return json
    }

    private func memorizeTextItems(startOrdinal: Int, endOrdinal: Int) -> [[String: String]] {
        guard let startVerse = ordinalToVerse(startOrdinal),
              let endVerse = ordinalToVerse(endOrdinal),
              startVerse <= endVerse else {
            return []
        }

        let osisBookId = osisBookId(for: currentBook)
        let chapter = currentChapter

        guard let module = activeModule else {
            let verseCount = Self.verseCount(for: currentBook, chapter: chapter)
            let boundedEndVerse = min(endVerse, verseCount)
            guard startVerse <= boundedEndVerse else { return [] }
            return (startVerse...boundedEndVerse).map { verse in
                [
                    "key": "\(osisBookId).\(chapter).\(verse)",
                    "text": Self.placeholderVerseText(book: currentBook, chapter: chapter, verse: verse),
                ]
            }
        }

        module.setKey("\(osisBookId) \(chapter):1")
        var items: [[String: String]] = []

        while true {
            let key = module.currentKey()
            guard let (_, parsedChapter, parsedVerse) = parseVerseKey(key) else { break }
            if parsedChapter != chapter { break }

            if parsedVerse >= startVerse && parsedVerse <= endVerse {
                let verseText = module.stripText().trimmingCharacters(in: .whitespacesAndNewlines)
                if !verseText.isEmpty {
                    items.append([
                        "key": "\(osisBookId).\(chapter).\(parsedVerse)",
                        "text": verseText,
                    ])
                }
            }
            if parsedVerse > endVerse { break }
            if !module.next() { break }
        }

        return items
    }

    private func memorizeReferenceTitle(startOrdinal: Int, endOrdinal: Int) -> String {
        guard let startVerse = ordinalToVerse(startOrdinal),
              let endVerse = ordinalToVerse(endOrdinal) else {
            return "\(currentBook) \(currentChapter)"
        }
        let verseSuffix = startVerse == endVerse ? "\(startVerse)" : "\(startVerse)-\(endVerse)"
        return "\(currentBook) \(currentChapter):\(verseSuffix)"
    }

    private func memorizeOsisRef(startOrdinal: Int, endOrdinal: Int) -> String {
        let osisBookId = osisBookId(for: currentBook)
        guard let startVerse = ordinalToVerse(startOrdinal),
              let endVerse = ordinalToVerse(endOrdinal) else {
            return "\(osisBookId).\(currentChapter)"
        }
        let startRef = "\(osisBookId).\(currentChapter).\(startVerse)"
        let endRef = "\(osisBookId).\(currentChapter).\(endVerse)"
        return startVerse == endVerse ? startRef : "\(startRef)-\(endRef)"
    }

    // MARK: - Content Loading

    /**
     Loads the currently selected Bible chapter into the embedded Vue.js reader.

     Side effects:
     - clears selection and special-document state, loads SWORD or placeholder content, emits labels
       and document JSON to the bridge, restores scroll position when needed, and reapplies active
       window/background styling
     */
    private func loadCurrentChapter() {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""
        let osisBookId = osisBookId(for: currentBook)
        let isNT = isNewTestament(currentBook)

        // Try loading from SWORD module first
        let loadedChapter = loadChapterFromSword(
            osisBookId: osisBookId,
            chapter: currentChapter
        )
        let xml: String
        let verseCount: Int
        let addChapter: Bool
        if let loadedChapter {
            xml = loadedChapter.xml
            verseCount = loadedChapter.verseCount
            addChapter = loadedChapter.addChapter
        } else if activeModule == nil {
            let fallbackChapter = loadPlaceholderChapter(osisBookId: osisBookId, bookName: currentBook)
            xml = fallbackChapter.0
            verseCount = fallbackChapter.1
            addChapter = true
        } else {
            logger.error("Failed to load SWORD chapter for \(osisBookId, privacy: .public).\(self.currentChapter)")
            return
        }

        // Query bookmarks for this chapter
        let chapterBookmarks = bookmarksForCurrentChapter(verseCount: verseCount)

        // Clear and load new document
        bridge.emit(event: "clear_document")

        // Send bookmark labels before the document (Vue.js needs labels to render bookmark highlights)
        sendLabelsToVueJS()

        guard let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: currentChapter,
            verseCount: verseCount,
            isNT: isNT,
            xml: xml,
            bookmarks: chapterBookmarks,
            addChapter: addChapter,
            originalOrdinalRange: originalNavigationOrdinalRange
        ) else { return }
        bridge.emit(event: "add_documents", data: document)

        // Track loaded chapter/book range for infinite scroll
        minLoadedChapter = currentChapter
        maxLoadedChapter = currentChapter
        minLoadedBook = currentBook
        maxLoadedBook = currentBook

        // Restore either the exact verse anchor or the chapter-top reading context.
        let restoreTarget: ScrollRestoreTarget
        if shouldRestoreScroll {
            restoreTarget = lastScrollTarget
        } else if currentVerse > 1,
                  let ordinal = ordinal(forChapter: currentChapter, verse: currentVerse) {
            restoreTarget = .ordinal(ordinal)
        } else {
            restoreTarget = .chapterTop
        }
        shouldRestoreScroll = false
        let jumpOrdinal: String
        let jumpToId: String
        switch restoreTarget {
        case .chapterTop:
            jumpOrdinal = "null"
            jumpToId = "\"top\""
        case .ordinal(let ordinal):
            jumpOrdinal = String(ordinal)
            jumpToId = "null"
        }
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":\(jumpOrdinal),"jumpToAnchor":null,"jumpToId":\(jumpToId),"topOffset":0,"bottomOffset":0}
        """)
        setRenderedContentState(
            category: .bible,
            moduleName: activeModuleName,
            book: currentBook,
            chapter: currentChapter,
            key: "\(osisBookId).\(currentChapter)"
        )
        emitActiveState()

        // Clear any accidental text selection and re-apply background
        bridge.clearSelection()
        applyNightModeBackground()

    }

    /**
     Load chapter text from the active SWORD module.
     Returns (xml, verseCount) or nil if no module is available.
     */
    private func loadChapterFromSword(osisBookId: String, chapter: Int) -> BibleChapterDocumentBuilder.LoadedChapterContent? {
        guard let module = activeModule else { return nil }
        let builder = BibleChapterDocumentBuilder(
            module: module,
            includeHeadings: shouldIncludeSwordHeadings()
        )
        return builder.loadChapter(osisBookId: osisBookId, chapter: chapter)
    }

    /**
     Load a specific chapter from the active SWORD module and return its document JSON string.
     Used by infinite scroll to load adjacent chapters without navigating.
     */
    private func loadChapterJSON(book: String, chapter: Int) -> String? {
        guard let module = activeModule else { return nil }

        let osisBookId = osisBookId(for: book)
        let isNT = isNewTestament(book)
        let restoreKey = "\(self.osisBookId(for: currentBook)) \(currentChapter):1"
        defer {
            module.setKey(restoreKey)
        }

        guard let loadedChapter = loadChapterFromSword(
            osisBookId: osisBookId,
            chapter: chapter
        ) else {
            return nil
        }

        // Query bookmarks for this chapter's ordinal range
        guard let range = chapterOrdinalRange(book: book, chapter: chapter, verseCount: loadedChapter.verseCount) else {
            logger.error("Failed to resolve SWORD chapter range for \(osisBookId, privacy: .public).\(chapter)")
            return nil
        }
        let chapterBookmarks = bookmarkService?.bookmarks(for: range.start, endOrdinal: range.end, book: book) ?? []

        guard let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: book,
            chapter: chapter,
            verseCount: loadedChapter.verseCount,
            isNT: isNT,
            xml: loadedChapter.xml,
            bookmarks: chapterBookmarks,
            addChapter: loadedChapter.addChapter,
            originalOrdinalRange: nil
        ) else { return nil }

        return document
    }

    /// Parse a SWORD verse key like "Genesis 1:1" into (book, chapter, verse).
    private func parseVerseKey(_ key: String) -> (String, Int, Int)? {
        // SWORD returns keys like "Genesis 1:1" or "I Samuel 2:3"
        // Split from the right to handle multi-word book names
        guard let colonIdx = key.lastIndex(of: ":") else { return nil }
        let verseStr = String(key[key.index(after: colonIdx)...])
        let beforeColon = String(key[..<colonIdx])

        guard let spaceIdx = beforeColon.lastIndex(of: " ") else { return nil }
        let chapterStr = String(beforeColon[beforeColon.index(after: spaceIdx)...])
        let bookPart = String(beforeColon[..<spaceIdx])

        guard let chapter = Int(chapterStr), let verse = Int(verseStr) else { return nil }
        return (bookPart, chapter, verse)
    }

    private func shouldIncludeSwordHeadings() -> Bool {
        displaySettings.showSectionTitles ?? TextDisplaySettings.appDefaults.showSectionTitles ?? true
    }

    private func ordinal(forChapter chapter: Int, verse: Int) -> Int? {
        verseOrdinal(osisBookId: osisBookId(for: currentBook), chapter: chapter, verse: verse)
    }

    private func buildSwordChapterXML(osisBookId: String, bookName: String, chapter: Int, verses: [(Int, String)]) -> String {
        var xml = "<div>"
        xml += "<title type=\"x-gen\">\(bookName) \(chapter)</title>"
        xml += "<div sID=\"p1\" type=\"paragraph\"/>"

        for (verseNum, text) in verses {
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ordinal = ordinal(forChapter: chapter, verse: verseNum) else { continue }
            xml += "<verse osisID=\"\(osisBookId).\(chapter).\(verseNum)\" verseOrdinal=\"\(ordinal)\">"
            xml += "\(cleanText) "
            xml += "</verse>"
        }
        xml += "<div eID=\"p1\" type=\"paragraph\"/>"
        xml += "</div>"
        return xml
    }

    /**
     Transform SWORD rendered Strong's numbers into OSIS `<w>` elements.
     SWORD renderText outputs Strong's as:
       `<small><em>&lt;<a href="passagestudy.jsp?showStrong=07225#cv">07225</a>&gt;</em></small>`
     Vue.js W.vue expects `<w lemma="strong:H07225"></w>` for proper rendering.
     */
    private static func transformStrongsNumbers(_ text: String, isOT: Bool) -> String {
        let prefix = isOT ? "H" : "G"

        // Match the full SWORD Strong's HTML pattern
        let pattern = #"<small><em>&lt;<a href="passagestudy\.jsp\?showStrong=(\d+)#cv">\d+</a>&gt;</em></small>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var result = text
        // Process matches in reverse order to preserve string indices
        for match in matches.reversed() {
            let fullRange = match.range
            let numRange = match.range(at: 1)
            let number = nsText.substring(with: numRange)
            let replacement = "<w lemma=\"strong:\(prefix)\(number)\"></w>"
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }
        return result
    }

    /// Check if an OSIS book ID is in the Old Testament.
    private static func isOldTestament(_ osisBookId: String) -> Bool {
        let otBooks: Set<String> = [
            "Gen", "Exod", "Lev", "Num", "Deut", "Josh", "Judg", "Ruth",
            "1Sam", "2Sam", "1Kgs", "2Kgs", "1Chr", "2Chr", "Ezra", "Neh",
            "Esth", "Job", "Ps", "Prov", "Eccl", "Song", "Isa", "Jer",
            "Lam", "Ezek", "Dan", "Hos", "Joel", "Amos", "Obad", "Jonah",
            "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal"
        ]
        return otBooks.contains(osisBookId)
    }

    /// Load placeholder chapter content (fallback when no SWORD module available).
    private func loadPlaceholderChapter(osisBookId: String, bookName: String) -> (String, Int) {
        let verseCount = Self.verseCount(for: bookName, chapter: currentChapter)
        let xml = buildChapterXML(
            osisBookId: osisBookId,
            bookName: bookName,
            chapter: currentChapter,
            verseCount: verseCount
        )
        return (xml, verseCount)
    }

    // MARK: - Bookmark Helpers

    /// Query bookmarks for the current chapter's ordinal range, filtered by current book.
    private func bookmarksForCurrentChapter(verseCount: Int) -> [BibleBookmark] {
        guard let service = bookmarkService else { return [] }
        guard let range = chapterOrdinalRange(book: currentBook, chapter: currentChapter, verseCount: verseCount) else {
            logger.error("Failed to resolve bookmark range for \(self.currentBook, privacy: .public) \(self.currentChapter)")
            return []
        }
        return service.bookmarks(for: range.start, endOrdinal: range.end, book: currentBook)
    }

    // MARK: - Default Labels

    /// Fixed UUID for the "Unlabeled" system label, sent to Vue.js so bookmarks always have a valid label reference.
    private static let unlabeledLabelId = BibleCore.Label.unlabeledId.uuidString

    /// Recently used label IDs (most recent first, max 5).
    private var recentLabelIds: [String] = []

    /// Track a label as recently used (for Vue.js recentLabels config).
    private func trackRecentLabel(_ labelId: String) {
        recentLabelIds.removeAll { $0 == labelId }
        recentLabelIds.insert(labelId, at: 0)
        if recentLabelIds.count > 5 { recentLabelIds = Array(recentLabelIds.prefix(5)) }
        // Persist to settings
        settingsStore?.setString("recent_labels", value: recentLabelIds.joined(separator: ","))
    }

    /// Load recent label IDs from settings.
    private func loadRecentLabels() {
        guard let stored = settingsStore?.getString("recent_labels"), !stored.isEmpty else { return }
        recentLabelIds = stored.components(separatedBy: ",")
    }

    /**
     Sends bookmark label data to Vue.js before bookmark-bearing documents are emitted.

     - Side effects: emits `update_labels` through the WebView bridge.
     - Failure modes: skips labels whose SwiftData model has already been deleted; bridge encoding
       failures are handled by `BibleBridge.emit<T: Encodable>`.
     */
    private func sendLabelsToVueJS() {
        var allLabels = [
            LabelData(
                id: Self.unlabeledLabelId,
                name: BibleCore.Label.unlabeledName,
                style: BookmarkStyleData(color: BibleCore.Label.defaultColor),
                isRealLabel: false
            ),
            LabelData(
                id: BibleCore.Label.paragraphBreakLabelId.uuidString,
                name: BibleCore.Label.paragraphBreakLabelName,
                style: BookmarkStyleData(
                    color: BibleCore.Label.defaultColor,
                    isParagraphBreak: true
                ),
                isRealLabel: false
            ),
        ]
        if let service = bookmarkService {
            for label in service.allLabels() {
                guard let labelData = buildLabelData(label) else {
                    continue
                }
                allLabels.append(labelData)
            }
        }

        bridge.emit(event: "update_labels", data: allLabels)
    }

    // MARK: - Annotation Bridge Payload Builders

    /**
     Builds a payload factory from the controller's current reader state.

     - Returns: A factory that can project bookmark, label, My Notes, and StudyPad models into
       typed bridge DTOs.
     - Side effects: None during construction; factory methods may read from the active SWORD
       module.
     - Failure modes: None during construction.
     */
    private func annotationPayloadFactory() -> BibleReaderAnnotationPayloadFactory {
        BibleReaderAnnotationPayloadFactory(
            currentBook: currentBook,
            activeModuleName: activeModuleName,
            activeModule: activeModule,
            bookList: bookList,
            unlabeledLabelID: Self.unlabeledLabelId
        )
    }

    /**
     Builds the typed Bible bookmark bridge payload consumed by Vue.js.

     - Parameter bookmark: SwiftData Bible bookmark model to project.
     - Returns: A key-preserving bridge DTO; nullable fields encode as explicit JSON `null`.
     - Side effects: reads verse text from the active SWORD module when available.
     - Failure modes: missing label relationships are filtered and replaced with the synthetic
       unlabeled relation required by the web client.
    */
    private func buildBookmarkJSON(_ bookmark: BibleBookmark) -> BibleBookmarkData {
        annotationPayloadFactory().bookmarkJSON(bookmark)
    }

    /**
     Builds a My Notes bookmark payload with the same shape as a standard Bible bookmark.
     */
    private func buildBookmarkJSONForMyNotes(_ bookmark: BibleBookmark) -> BibleBookmarkData {
        annotationPayloadFactory().bookmarkJSONForMyNotes(bookmark)
    }

    // MARK: - StudyPad Bridge Payload Builders

    /**
     Builds a typed StudyPad text entry payload for Vue.js.
    */
    private func buildStudyPadEntryJSON(_ entry: StudyPadTextEntry) -> StudyPadTextItemData {
        annotationPayloadFactory().studyPadEntryJSON(entry)
    }

    /**
     Builds a typed Bible bookmark-to-label payload for Vue.js.
     */
    private func buildBibleBookmarkToLabelJSON(_ btl: BibleBookmarkToLabel) -> BookmarkToLabelData? {
        annotationPayloadFactory().bibleBookmarkToLabelJSON(btl)
    }

    /**
     Builds a typed generic bookmark-to-label payload for Vue.js.
     */
    private func buildGenericBookmarkToLabelJSON(_ gbtl: GenericBookmarkToLabel) -> BookmarkToLabelData? {
        annotationPayloadFactory().genericBookmarkToLabelJSON(gbtl)
    }

    /**
     Builds a typed label payload for bridge documents and label update events.
     */
    private func buildLabelData(_ label: Label) -> LabelData? {
        annotationPayloadFactory().labelData(label)
    }

    /**
     Builds a typed Bible bookmark payload for a StudyPad document.
    */
    private func buildBookmarkJSONForStudyPad(_ bookmark: BibleBookmark) -> BibleBookmarkData {
        annotationPayloadFactory().bookmarkJSONForStudyPad(bookmark)
    }

    /**
     Builds a typed generic bookmark payload for StudyPad and bookmark update events.
    */
    private func buildGenericBookmarkJSONForStudyPad(_ bookmark: GenericBookmark) -> GenericBookmarkData {
        annotationPayloadFactory().genericBookmarkJSONForStudyPad(bookmark)
    }

    /**
     Parses an optional raw JSON state blob into a typed bridge JSON value.

     - Parameter json: Raw JSON saved from Vue state.
     - Returns: Typed JSON value, or `nil` when no state was provided or parsing fails.
     - Side effects: logs malformed state and otherwise performs no mutation.
     - Failure modes: malformed JSON is dropped so document rendering can continue.
     */
    private func bridgeJSONValue(from json: String?) -> BridgeJSONValue? {
        guard let json,
              let data = json.data(using: .utf8) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return BridgeJSONValue(object)
        } catch {
            logger.error("Failed to parse saved bridge state JSON: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Bookmark Event Helpers

    /**
     Creates the coordinator that owns bookmark bridge action mutation rules.

     - Returns: A coordinator bound to the current bookmark service and reader payload context, or
       `nil` when bookmark persistence is not available.
     - Side effects: None during construction; returned coordinator methods mutate persistence.
     - Failure modes: Returns `nil` rather than accepting bookmark actions without persistence.
     */
    private func bookmarkActionCoordinator() -> BibleReaderBookmarkActionCoordinator? {
        guard let bookmarkService else { return nil }
        return BibleReaderBookmarkActionCoordinator(
            bookmarkService: bookmarkService,
            payloadFactory: annotationPayloadFactory(),
            currentBook: currentBook,
            currentNotesContentType: { [weak self] in
                self?.currentNotesContentType() ?? "HTML"
            }
        )
    }

    /**
     Applies a coordinated bookmark action result to controller-owned state and the active bridge.

     - Parameters:
       - result: Mutation result produced by `BibleReaderBookmarkActionCoordinator`.
       - bridge: Bridge instance associated with the delegate callback being handled.
     - Side effects: may advance My Notes revision state, update workspace settings, persist state,
       refresh labels/config, track recent labels, and emit JavaScript events.
     - Failure modes: Encoding failures inside `BibleBridge.emit` are swallowed by the bridge.
     */
    private func applyBookmarkActionResult(
        _ result: BibleReaderBookmarkActionResult,
        bridge: BibleBridge
    ) {
        if result.incrementsMyNotesRevision {
            myNotesMutationRevision += 1
        }
        if let updatedWorkspaceSettings = result.updatedWorkspaceSettings {
            activeWindow?.workspace?.workspaceSettings = updatedWorkspaceSettings
        }
        if result.requiresPersistState {
            onPersistState?()
        }
        if let recentLabelId = result.recentLabelId {
            trackRecentLabel(recentLabelId)
        }
        for event in result.events {
            emitBookmarkActionEvent(event, bridge: bridge)
        }
        if result.refreshesLabels {
            sendLabelsToVueJS()
        }
        if result.refreshesConfig {
            bridge.emit(event: "set_config", data: buildConfigJSON())
        }
    }

    /**
     Emits one bookmark action event into Vue.js.

     - Parameters:
       - event: Typed event produced by the bookmark action coordinator.
       - bridge: Bridge instance associated with the delegate callback being handled.
     - Side effects: Sends JavaScript to the web client.
     - Failure modes: Encoding failures inside `BibleBridge.emit` are swallowed by the bridge.
     */
    private func emitBookmarkActionEvent(
        _ event: BibleReaderBookmarkActionEvent,
        bridge: BibleBridge
    ) {
        switch event {
        case .bookmarksUpdated(let payloads):
            bridge.emit(event: "add_or_update_bookmarks", data: payloads)
        case .genericBookmarksUpdated(let payloads):
            bridge.emit(event: "add_or_update_bookmarks", data: payloads)
        case .bookmarksDeleted(let ids):
            bridge.emitEncoded(event: "delete_bookmarks", data: ids)
        case .bookmarkClicked(let id, let openLabels, let openNotes):
            bridge.emit(
                event: "bookmark_clicked",
                data: "\"\(id)\", {\"openLabels\":\(openLabels),\"openNotes\":\(openNotes)}"
            )
        case .bookmarkNoteModified(let payload):
            bridge.emit(event: "bookmark_note_modified", data: payload)
        }
    }

    // MARK: - StudyPad Event Helpers

    /**
     Creates the coordinator that owns StudyPad bridge action mutation rules.

     - Returns: A coordinator bound to the current bookmark service and reader payload context, or
       `nil` when bookmark persistence is not available.
     - Side effects: None during construction; returned coordinator methods mutate persistence.
     - Failure modes: Returns `nil` rather than accepting StudyPad actions without persistence.
     */
    private func studyPadActionCoordinator() -> BibleReaderStudyPadActionCoordinator? {
        guard let bookmarkService else { return nil }
        return BibleReaderStudyPadActionCoordinator(
            bookmarkService: bookmarkService,
            payloadFactory: annotationPayloadFactory(),
            currentNotesContentType: { [weak self] in
                self?.currentNotesContentType() ?? "HTML"
            }
        )
    }

    /// Emit an updated bookmark (Bible or generic) back to Vue.js after label changes.
    private func emitBookmarkUpdate(bookmarkId: UUID, type: String? = nil) {
        guard let service = bookmarkService else { return }

        // Try Bible bookmark first (or if type hint says "bible")
        if type != "generic", let bookmark = service.bibleBookmark(id: bookmarkId) {
            bridge.emit(event: "add_or_update_bookmarks", data: [buildBookmarkJSON(bookmark)])
            return
        }

        // Try generic bookmark
        if let bookmark = service.genericBookmark(id: bookmarkId) {
            bridge.emit(event: "add_or_update_bookmarks", data: [buildGenericBookmarkJSONForStudyPad(bookmark)])
        }
    }

    /**
     Applies a coordinated StudyPad action result to controller-owned state and the active bridge.

     - Parameters:
       - result: Mutation result produced by `BibleReaderStudyPadActionCoordinator`.
       - bridge: Bridge instance associated with the delegate callback being handled.
     - Side effects: may advance `studyPadMutationRevision` and emits JavaScript events.
     - Failure modes: Encoding failures inside `BibleBridge.emit` are swallowed by the bridge.
     */
    private func applyStudyPadActionResult(
        _ result: BibleReaderStudyPadActionResult,
        bridge: BibleBridge
    ) {
        if result.incrementsStudyPadRevision {
            studyPadMutationRevision += 1
        }
        for event in result.events {
            emitStudyPadActionEvent(event, bridge: bridge)
        }
    }

    /**
     Emits one StudyPad action event into Vue.js.

     - Parameters:
       - event: Typed event produced by the StudyPad action coordinator.
       - bridge: Bridge instance associated with the delegate callback being handled.
     - Side effects: Sends JavaScript to the web client.
     - Failure modes: Encoding failures inside `BibleBridge.emit` are swallowed by the bridge.
     */
    private func emitStudyPadActionEvent(
        _ event: BibleReaderStudyPadActionEvent,
        bridge: BibleBridge
    ) {
        switch event {
        case .studyPadUpdated(let payload):
            bridge.emit(event: "add_or_update_study_pad", data: payload)
        case .studyPadTextEntryDeleted(let id):
            bridge.emitEncoded(event: "delete_study_pad_text_entry", data: id.uuidString)
        case .bookmarkToLabelUpdated(let payload):
            bridge.emit(event: "add_or_update_bookmark_to_label", data: payload)
        }
    }

    // MARK: - Active Window State

    /**
     Whether this controller's window is the active (focused) window.
     Matches Android: `windowControl.activeWindow.id == window.id`
     */
    private func computeIsActiveWindow() -> Bool {
        guard let myWindow = activeWindow,
              let wm = windowManagerRef else { return true }
        return wm.activeWindow?.id == myWindow.id
    }

    /**
     Emit set_active event to Vue.js with current active window state.
     Called after content load and when active window changes.
     */
    func emitActiveState() {
        let isActive = computeIsActiveWindow()
        let indicatorEnabled = appPreferenceBool(.showActiveWindowIndicator)
        let hasIndicator = indicatorEnabled && isActive && (windowManagerRef?.visibleWindows.count ?? 0) > 1
        bridge.emit(event: "set_active", data: "{\"hasActiveIndicator\":\(hasIndicator),\"isActive\":\(isActive)}")
    }

    // MARK: - JSON Builders

    /// Reads a boolean parity preference, falling back to the registry default when unset.
    private func appPreferenceBool(_ key: AppPreferenceKey) -> Bool {
        settingsStore?.getBool(key) ?? (AppPreferenceRegistry.boolDefault(for: key) ?? false)
    }

    /// Reads an integer parity preference, falling back to the registry default when unset.
    private func appPreferenceInt(_ key: AppPreferenceKey) -> Int {
        settingsStore?.getInt(key) ?? (AppPreferenceRegistry.intDefault(for: key) ?? 0)
    }

    /// Reads a string parity preference, falling back to the registry default when unset.
    private func appPreferenceString(_ key: AppPreferenceKey) -> String {
        settingsStore?.getString(key) ?? (AppPreferenceRegistry.stringDefault(for: key) ?? "")
    }

    /**
     Reads the Android-compatible global notes content type used for newly created note rows.

     - Returns: `HTML` or `MARKDOWN` after applying the shared preference normalizer.
     - Side effects: reads the active settings store.
     - Failure modes: none; missing or invalid values fall back to Android's default `HTML`.
     */
    private func currentNotesContentType() -> String {
        AppPreferenceValueNormalizer.notesContentType(appPreferenceString(.notesContentType))
    }

    /// Reads a string-set parity preference and returns an empty array when unset.
    private func appPreferenceStringSet(_ key: AppPreferenceKey) -> [String] {
        settingsStore?.getStringSet(key) ?? []
    }

    private func readingProgressSettingsPayload() -> [String: Any] {
        let bundle = readingProgressStore?.settingsBundle() ?? ReadingProgressSettingsBundle()
        return [
            "autoMarkMemorized": bundle.autoMarkMemorized,
            "memorizeTypeFullWords": bundle.memorizeTypeFullWords,
            "memorizeWordVisibility": bundle.memorizeWordVisibility,
            "memorizeErrorHeatmap": bundle.memorizeErrorHeatmap,
            "memorizeScrambleHideUsed": bundle.memorizeScrambleHideUsed,
            "memorizeIncludeReference": bundle.memorizeIncludeReference,
        ]
    }

    /**
     Wire payload for the Vue.js `set_config` event.

     The shape mirrors Android's `bibleView.emit('set_config', { config, appSettings, initial })`
     contract: a fully resolved text-display config, native app settings needed by the web reader,
     and an initial-load marker. Encoding this struct keeps bridge payload generation type-checked
     and avoids the brittle hand-built JSON string that previously had to be extended field by field.

     - Side effects: none; callers gather live settings before constructing the value.
     - Failure modes: encoding can only fail if one of the nested payload types stops conforming to
       `Encodable`; `buildConfigJSON()` logs and emits an empty object in that case.
     */
    private struct ReaderSetConfigPayload: Encodable {
        /// Fully resolved reader display settings consumed by the Vue text renderer.
        let config: ReaderDisplayConfig
        /// Application/runtime settings consumed by Vue components outside text rendering.
        let appSettings: ReaderAppSettings
        /// Whether this config is sent as part of first WebView attachment.
        let initial: Bool
    }

    /**
     Text-display configuration sent to the Vue reader.

     - Parameter settings: Window/workspace/global-resolved settings currently active for the pane.
     - Parameter defaults: App-level fallback values for any unset field.
     - Returns: A non-optional bridge projection whose keys match the Android/Vue `config` object.
     - Side effects: none.
     - Failure modes: none; unset settings fall back through `defaults` and hard-coded Vue defaults
       that match the previous bridge payload.
     */
    private struct ReaderDisplayConfig: Encodable {
        let developmentMode: Bool
        let testMode: Bool
        let showAnnotations: Bool
        let showChapterNumbers: Bool
        let showVerseNumbers: Bool
        let strongsMode: Int
        let showMorphology: Bool
        let showRedLetters: Bool
        let showVersePerLine: Bool
        let showNonCanonical: Bool
        let makeNonCanonicalItalic: Bool
        let showSectionTitles: Bool
        let showStrongsSeparately: Bool
        let showFootNotes: Bool
        let showFootNotesInline: Bool
        let showXrefs: Bool
        let expandXrefs: Bool
        let fontFamily: String
        let fontSize: Int
        let disableBookmarking: Bool
        let showBookmarks: Bool
        let showMyNotes: Bool
        let bookmarksHideLabels: [String]
        let bookmarksAssignLabels: [String]
        let colors: ReaderDisplayColors
        let hyphenation: Bool
        let lineSpacing: Int
        let justifyText: Bool
        let marginSize: ReaderDisplayMarginSize
        let topMargin: Int
        let showPageNumber: Bool
        let infiniteScroll: Bool
        let nonStrongsWordItalic: Bool
        let showMarkAsReadButton: Bool
        let showTitleScrollButton: Bool
        let showMemorizationIndicators: Bool
        let showAiDocMarkers: Bool
        let pageScrollAmount: Int
        let showOrdinals: Bool

        init(settings s: TextDisplaySettings, defaults d: TextDisplaySettings) {
            self.developmentMode = false
            self.testMode = false
            self.showAnnotations = true
            self.showChapterNumbers = true
            self.showVerseNumbers = s.showVerseNumbers ?? d.showVerseNumbers ?? true
            self.strongsMode = s.strongsMode ?? d.strongsMode ?? 0
            self.showMorphology = s.showMorphology ?? d.showMorphology ?? false
            self.showRedLetters = s.showRedLetters ?? d.showRedLetters ?? true
            self.showVersePerLine = s.showVersePerLine ?? d.showVersePerLine ?? false
            self.showNonCanonical = true
            self.makeNonCanonicalItalic = true
            self.showSectionTitles = s.showSectionTitles ?? d.showSectionTitles ?? true
            self.showStrongsSeparately = false
            self.showFootNotes = s.showFootNotes ?? d.showFootNotes ?? false
            self.showFootNotesInline = s.showFootNotesInline ?? d.showFootNotesInline ?? false
            self.showXrefs = s.showXrefs ?? d.showXrefs ?? false
            self.expandXrefs = s.expandXrefs ?? d.expandXrefs ?? false
            self.fontFamily = s.fontFamily ?? d.fontFamily ?? "sans-serif"
            self.fontSize = s.fontSize ?? d.fontSize ?? 18
            self.disableBookmarking = false
            self.showBookmarks = s.showBookmarks ?? d.showBookmarks ?? true
            self.showMyNotes = s.showMyNotes ?? d.showMyNotes ?? true
            self.bookmarksHideLabels = (s.bookmarksHideLabels ?? d.bookmarksHideLabels ?? []).map(\.uuidString)
            self.bookmarksAssignLabels = []
            self.colors = ReaderDisplayColors(settings: s, defaults: d)
            self.hyphenation = s.hyphenation ?? d.hyphenation ?? true
            self.lineSpacing = s.lineSpacing ?? d.lineSpacing ?? 10
            self.justifyText = s.justifyText ?? d.justifyText ?? false
            self.marginSize = ReaderDisplayMarginSize(settings: s, defaults: d)
            self.topMargin = s.topMargin ?? d.topMargin ?? 0
            self.showPageNumber = s.showPageNumber ?? d.showPageNumber ?? false
            self.infiniteScroll = s.infiniteScroll ?? d.infiniteScroll ?? true
            self.nonStrongsWordItalic = s.nonStrongsWordItalic ?? d.nonStrongsWordItalic ?? false
            self.showMarkAsReadButton = s.showMarkAsReadButton ?? d.showMarkAsReadButton ?? true
            self.showTitleScrollButton = s.showTitleScrollButton ?? d.showTitleScrollButton ?? false
            self.showMemorizationIndicators = s.showMemorizationIndicators ?? d.showMemorizationIndicators ?? false
            self.showAiDocMarkers = s.showAiDocMarkers ?? d.showAiDocMarkers ?? true
            self.pageScrollAmount = TextDisplaySettings.normalizedPageScrollAmount(s.pageScrollAmount ?? d.pageScrollAmount)
            self.showOrdinals = s.showOrdinals ?? d.showOrdinals ?? false
        }
    }

    /**
     Color sub-object inside the Vue reader `config` payload.

     - Parameters:
       - settings: Active pane settings that may override individual color values.
       - defaults: App-level fallback colors.
     - Side effects: none.
     - Failure modes: none; every field falls back to the previous hard-coded bridge default.
     */
    private struct ReaderDisplayColors: Encodable {
        let dayBackground: Int
        let dayNoise: Int
        let nightBackground: Int
        let nightNoise: Int
        let dayTextColor: Int
        let nightTextColor: Int

        init(settings s: TextDisplaySettings, defaults d: TextDisplaySettings) {
            self.dayBackground = s.dayBackground ?? d.dayBackground ?? -1
            self.dayNoise = s.dayNoise ?? d.dayNoise ?? 0
            self.nightBackground = s.nightBackground ?? d.nightBackground ?? -16777216
            self.nightNoise = s.nightNoise ?? d.nightNoise ?? 0
            self.dayTextColor = s.dayTextColor ?? d.dayTextColor ?? -16777216
            self.nightTextColor = s.nightTextColor ?? d.nightTextColor ?? -1
        }
    }

    /**
     Margin sub-object inside the Vue reader `config` payload.

     - Parameters:
       - settings: Active pane settings that may override individual margin values.
       - defaults: App-level fallback margins.
     - Side effects: none.
     - Failure modes: none; every field falls back to the previous hard-coded bridge default.
     */
    private struct ReaderDisplayMarginSize: Encodable {
        let marginLeft: Int
        let marginRight: Int
        let maxWidth: Int

        init(settings s: TextDisplaySettings, defaults d: TextDisplaySettings) {
            self.marginLeft = s.marginLeft ?? d.marginLeft ?? 2
            self.marginRight = s.marginRight ?? d.marginRight ?? 2
            self.maxWidth = s.maxWidth ?? d.maxWidth ?? 600
        }
    }

    /**
     Native app settings included in the Vue reader `set_config` payload.

     These values are not part of `TextDisplaySettings` on Android, but Android sends them beside
     `config` in the same `set_config` event. Keeping them as a typed projection preserves that
     contract while avoiding ad-hoc JSON fragments for arrays and dictionaries.

     - Side effects: none; all values are captured by the controller before initialization.
     - Failure modes: none; the struct stores only JSON-encodable primitive, array, dictionary, and
       reading-progress bundle values.
     */
    private struct ReaderAppSettings: Encodable {
        let nightMode: Bool
        let errorBox: Bool
        let favouriteLabels: [String]
        let recentLabels: [String]
        let studyPadCursors: [String: Int]
        let autoAssignLabels: [String]
        let hideCompareDocuments: [String]
        let activeWindow: Bool
        let rightToLeft: Bool
        let actionMode: Bool
        let hasActiveIndicator: Bool
        let activeSince: Int
        let limitAmbiguousModalSize: Bool
        let windowId: String
        let disableBibleModalButtons: [String]
        let disableGenericModalButtons: [String]
        let monochromeMode: Bool
        let disableAnimations: Bool
        let disableClickToEdit: Bool
        let notesContentType: String
        let fontSizeMultiplier: Double
        let enabledExperimentalFeatures: [String]
        let autoTrackReading: Bool
        let readingProgressSettings: ReadingProgressSettingsBundle
    }

    /**
     Builds the combined reader/configuration payload consumed by the Vue.js application.

     - Returns: Typed payload containing `config` and `appSettings` sections for the current pane.

     Side effects:
     - reads persisted settings, workspace cursor state, recent/favourite labels, and active-window
       state to compute the emitted payload

     Failure modes:
     - none; missing services or settings fall back to empty collections and app defaults
     */
    private func buildConfigPayload() -> ReaderSetConfigPayload {
        let settings = displaySettings
        let defaults = TextDisplaySettings.appDefaults
        let isActiveWindow = computeIsActiveWindow()
        let activeIndicatorEnabled = appPreferenceBool(.showActiveWindowIndicator)
        let hasActiveIndicator = activeIndicatorEnabled && isActiveWindow && (windowManagerRef?.visibleWindows.count ?? 0) > 1
        let fontSizeMultiplierPercent = max(10, appPreferenceInt(.fontSizeMultiplier))
        let fontSizeMultiplier = Double(fontSizeMultiplierPercent) / 100.0
        let favouriteIds = bookmarkService?.allLabels()
            .filter { $0.favourite }
            .map { $0.id.uuidString } ?? []
        let cursors = activeWindow?.workspace?.workspaceSettings?.studyPadCursors ?? [:]
        let studyPadCursors = Dictionary(
            uniqueKeysWithValues: cursors.map { ($0.key.uuidString, $0.value) }
        )
        let autoAssignLabels = activeWindow?.workspace?.workspaceSettings?.autoAssignLabels
            .map(\.uuidString) ?? []
        let readingProgressSettings = readingProgressStore?.snapshot().settings ?? ReadingProgressSettingsSnapshot()
        let readingProgressBundle = ReadingProgressSettingsBundle(settings: readingProgressSettings)

        return ReaderSetConfigPayload(
            config: ReaderDisplayConfig(settings: settings, defaults: defaults),
            appSettings: ReaderAppSettings(
                nightMode: nightMode,
                errorBox: appPreferenceBool(.showErrorBox),
                favouriteLabels: favouriteIds,
                recentLabels: recentLabelIds,
                studyPadCursors: studyPadCursors,
                autoAssignLabels: autoAssignLabels,
                hideCompareDocuments: currentHiddenCompareDocuments().sorted(),
                activeWindow: isActiveWindow,
                rightToLeft: false,
                actionMode: false,
                hasActiveIndicator: hasActiveIndicator,
                activeSince: Int(Date().timeIntervalSince1970 * 1000) - 1000,
                limitAmbiguousModalSize: false,
                windowId: "",
                disableBibleModalButtons: appPreferenceStringSet(.disableBibleBookmarkModalButtons),
                disableGenericModalButtons: appPreferenceStringSet(.disableGenBookmarkModalButtons),
                monochromeMode: appPreferenceBool(.monochromeMode),
                disableAnimations: appPreferenceBool(.disableAnimations),
                disableClickToEdit: appPreferenceBool(.disableClickToEdit),
                notesContentType: currentNotesContentType(),
                fontSizeMultiplier: fontSizeMultiplier,
                enabledExperimentalFeatures: appPreferenceStringSet(.experimentalFeatures),
                autoTrackReading: readingProgressSettings.autoTrackReading,
                readingProgressSettings: readingProgressBundle
            ),
            initial: false
        )
    }

    /**
     Encodes the combined reader/configuration payload consumed by the Vue.js application.

     - Returns: JSON string containing `config` and `appSettings` sections for the current pane.

     Side effects:
     - reads persisted settings, workspace cursor state, recent/favourite labels, and active-window
       state to compute the emitted payload

     Failure modes:
     - logs and returns `{}` if the typed bridge payload unexpectedly fails to encode
     */
    private func buildConfigJSON() -> String {
        let payload = buildConfigPayload()
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode set_config bridge payload")
            return "{}"
        }
        return json
    }

    /**
     Generates fallback OSIS XML for placeholder chapters when real SWORD content is unavailable.

     - Parameters:
       - osisBookId: OSIS book abbreviation for the chapter.
       - bookName: Localized/native book name displayed in titles.
       - chapter: Chapter number to render.
       - verseCount: Number of placeholder verses to include.

     - Returns: OSIS XML fragment with generated verse and paragraph structure.
     */
    private func buildChapterXML(osisBookId: String, bookName: String, chapter: Int, verseCount: Int) -> String {
        // For Genesis 1, use the real ESV-like content
        if osisBookId == "Gen" && chapter == 1 {
            return genesis1OSISXML()
        }

        // For other chapters, generate placeholder OSIS XML with verse structure
        var xml = "<div>"
        xml += "<title type=\"x-gen\">\(bookName) \(chapter)</title>"
        xml += "<div sID=\"p1\" type=\"paragraph\"/>"

        for verse in 1...verseCount {
            let ordinal = compatibilityOrdinal(chapter: chapter, verse: verse)
            let text = Self.placeholderVerseText(book: bookName, chapter: chapter, verse: verse)
            xml += "<verse osisID=\"\(osisBookId).\(chapter).\(verse)\" verseOrdinal=\"\(ordinal)\">"
            xml += "\(text) "
            xml += "</verse>"
        }

        xml += "<div eID=\"p1\" type=\"paragraph\"/>"
        xml += "<div eID=\"sec1\" type=\"section\"/>"
        xml += "</div>"
        return xml
    }

    /**
     Creates the document payload factory for the controller's current reader state.

     `BibleReaderDocumentPayloadFactory` owns bridge JSON assembly; this method supplies the
     controller-owned dependencies it needs for the current render pass. The factory receives
     closures instead of the controller so it cannot mutate navigation, modal, bridge, or
     persistence state outside the document payload contract.

     - Returns: A factory configured with active module initials, Strong's capability, bookmark
       projection, JSword/SWORD ordinal resolution, reading progress, and memorization progress.
     - Side effects: None during construction. The returned factory may read controller services
       through closures while serializing a document.
     - Failure modes: Missing optional stores resolve to empty progress data; Bible ordinal lookup
       failures are reported by the factory as `nil` document payloads.
     */
    private func documentPayloadFactory() -> BibleReaderDocumentPayloadFactory {
        BibleReaderDocumentPayloadFactory(
            activeModuleName: activeModuleName,
            hasStrongs: hasStrongs,
            bookmarkPayload: { [self] bookmark in
                buildBookmarkJSON(bookmark)
            },
            chapterOrdinalRange: { [self] book, chapter, verseCount in
                chapterOrdinalRange(book: book, chapter: chapter, verseCount: verseCount)
            },
            kjvBookOrdinal: { [self] book in
                kjvBookOrdinal(for: book)
            },
            chapterReadCount: { [readingProgressStore] kjvBookOrdinal, chapter in
                readingProgressStore?.chapterReadCount(
                    kjvBookOrdinal: kjvBookOrdinal,
                    chapter: chapter
                )
            },
            memorizedOrdinals: { [memorizationProgressStore] bookInitials, startOrdinal, endOrdinal in
                memorizationProgressStore?.memorizedOrdinals(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                ) ?? []
            },
            targetOrdinals: { [memorizationProgressStore] bookInitials, startOrdinal, endOrdinal in
                memorizationProgressStore?.targetOrdinals(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                ) ?? []
            }
        )
    }

    /**
     Wraps chapter XML and bookmark metadata in the document JSON format expected by Vue.js.

     - Parameters:
       - osisBookId: OSIS book abbreviation for the current chapter.
       - bookName: Display name of the book.
       - chapter: Chapter number being rendered.
       - verseCount: Number of verses represented by `xml`.
       - isNT: Whether the document belongs to the New Testament.
       - xml: Escaped OSIS XML payload for the rendered content.
       - bookmarks: Chapter bookmarks to serialize alongside the document.
       - bookCategory: Document category string consumed by the frontend.
       - bookInitials: Optional module initials override for compare/nonstandard documents.
       - addChapter: Whether Vue should inject a chapter marker for this document.
       - originalOrdinalRange: Optional source navigation target used for highlight restoration.
       - documentKey: Optional exact document key. Bible chapters use `Book.Chapter`; commentary
         single-key documents use `Book.Chapter.Verse`.
       - keyName: Optional display label for the fragment key.
       - ordinalRangeOverride: Optional exact ordinal range for single-key or non-chapter
         documents.

     - Returns: JSON string for one Vue.js document record, or `nil` when a Bible document cannot
       resolve its active-module ordinal range.
     */
    private func buildDocumentJSON(osisBookId: String,
                                   bookName: String,
                                   chapter: Int,
                                   verseCount: Int,
                                   isNT: Bool,
                                   xml: String,
                                   bookmarks: [BibleBookmark] = [],
                                   bookCategory: String = "BIBLE",
                                   bookInitials: String? = nil,
                                   addChapter: Bool = true,
                                   originalOrdinalRange: [Int]? = nil,
                                   documentKey: String? = nil,
                                   keyName: String? = nil,
                                   ordinalRangeOverride: [Int]? = nil) -> String? {
        documentPayloadFactory().documentJSON(
            BibleReaderDocumentPayloadRequest(
                osisBookId: osisBookId,
                bookName: bookName,
                chapter: chapter,
                verseCount: verseCount,
                isNewTestament: isNT,
                xml: xml,
                bookmarks: bookmarks,
                bookCategory: bookCategory,
                bookInitials: bookInitials,
                addChapter: addChapter,
                originalOrdinalRange: originalOrdinalRange,
                documentKey: documentKey,
                keyName: keyName,
                ordinalRangeOverride: ordinalRangeOverride
            )
        )
    }

    // MARK: - Genesis 1 Real Content

    /**
     Returns the hard-coded Genesis 1 sample used by placeholder rendering.

     - Returns: Static OSIS XML fragment for Genesis 1.
     */
    private func genesis1OSISXML() -> String {
        "<div><title type=\"x-gen\">Genesis 1</title><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv1\"/><div sID=\"gen1\" type=\"section\"/><title>The Creation of the World</title><div sID=\"gen2\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv1\"/><verse osisID=\"Gen.1.1\" verseOrdinal=\"1\">In the beginning, God created the heavens and the earth. </verse><verse osisID=\"Gen.1.2\" verseOrdinal=\"2\">The earth was without form and void, and darkness was over the face of the deep. And the Spirit of God was hovering over the face of the waters. <div eID=\"gen2\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv2\"/><div sID=\"gen3\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv2\"/><verse osisID=\"Gen.1.3\" verseOrdinal=\"3\">And God said, \u{201C}Let there be light,\u{201D} and there was light. </verse><verse osisID=\"Gen.1.4\" verseOrdinal=\"4\">And God saw that the light was good. And God separated the light from the darkness. </verse><verse osisID=\"Gen.1.5\" verseOrdinal=\"5\">God called the light Day, and the darkness he called Night. And there was evening and there was morning, the first day. <div eID=\"gen3\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv3\"/><div sID=\"gen4\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv3\"/><verse osisID=\"Gen.1.6\" verseOrdinal=\"6\">And God said, \u{201C}Let there be an expanse in the midst of the waters, and let it separate the waters from the waters.\u{201D} </verse><verse osisID=\"Gen.1.7\" verseOrdinal=\"7\">And God made the expanse and separated the waters that were under the expanse from the waters that were above the expanse. And it was so. </verse><verse osisID=\"Gen.1.8\" verseOrdinal=\"8\">And God called the expanse Heaven. And there was evening and there was morning, the second day. <div eID=\"gen4\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv4\"/><div sID=\"gen5\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv4\"/><verse osisID=\"Gen.1.9\" verseOrdinal=\"9\">And God said, \u{201C}Let the waters under the heavens be gathered together into one place, and let the dry land appear.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.10\" verseOrdinal=\"10\">God called the dry land Earth, and the waters that were gathered together he called Seas. And God saw that it was good. </verse><verse osisID=\"Gen.1.11\" verseOrdinal=\"11\">And God said, \u{201C}Let the earth sprout vegetation, plants yielding seed, and fruit trees bearing fruit in which is their seed, each according to its kind, on the earth.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.12\" verseOrdinal=\"12\">The earth brought forth vegetation, plants yielding seed according to their own kinds, and trees bearing fruit in which is their seed, each according to its kind. And God saw that it was good. </verse><verse osisID=\"Gen.1.13\" verseOrdinal=\"13\">And there was evening and there was morning, the third day. <div eID=\"gen5\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv5\"/><div sID=\"gen6\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv5\"/><verse osisID=\"Gen.1.14\" verseOrdinal=\"14\">And God said, \u{201C}Let there be lights in the expanse of the heavens to separate the day from the night. And let them be for signs and for seasons, and for days and years, </verse><verse osisID=\"Gen.1.15\" verseOrdinal=\"15\">and let them be lights in the expanse of the heavens to give light upon the earth.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.16\" verseOrdinal=\"16\">And God made the two great lights\u{2014}the greater light to rule the day and the lesser light to rule the night\u{2014}and the stars. </verse><verse osisID=\"Gen.1.17\" verseOrdinal=\"17\">And God set them in the expanse of the heavens to give light on the earth, </verse><verse osisID=\"Gen.1.18\" verseOrdinal=\"18\">to rule over the day and over the night, and to separate the light from the darkness. And God saw that it was good. </verse><verse osisID=\"Gen.1.19\" verseOrdinal=\"19\">And there was evening and there was morning, the fourth day. <div eID=\"gen6\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv6\"/><div sID=\"gen7\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv6\"/><verse osisID=\"Gen.1.20\" verseOrdinal=\"20\">And God said, \u{201C}Let the waters swarm with swarms of living creatures, and let birds fly above the earth across the expanse of the heavens.\u{201D} </verse><verse osisID=\"Gen.1.21\" verseOrdinal=\"21\">So God created the great sea creatures and every living creature that moves, with which the waters swarm, according to their kinds, and every winged bird according to its kind. And God saw that it was good. </verse><verse osisID=\"Gen.1.22\" verseOrdinal=\"22\">And God blessed them, saying, \u{201C}Be fruitful and multiply and fill the waters in the seas, and let birds multiply on the earth.\u{201D} </verse><verse osisID=\"Gen.1.23\" verseOrdinal=\"23\">And there was evening and there was morning, the fifth day. <div eID=\"gen7\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv7\"/><div sID=\"gen8\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv7\"/><verse osisID=\"Gen.1.24\" verseOrdinal=\"24\">And God said, \u{201C}Let the earth bring forth living creatures according to their kinds\u{2014}livestock and creeping things and beasts of the earth according to their kinds.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.25\" verseOrdinal=\"25\">And God made the beasts of the earth according to their kinds and the livestock according to their kinds, and everything that creeps on the ground according to its kind. And God saw that it was good. <div eID=\"gen8\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv8\"/><div sID=\"gen9\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv8\"/><verse osisID=\"Gen.1.26\" verseOrdinal=\"26\">Then God said, \u{201C}Let us make man in our image, after our likeness. And let them have dominion over the fish of the sea and over the birds of the heavens and over the livestock and over all the earth and over every creeping thing that creeps on the earth.\u{201D} </verse><verse osisID=\"Gen.1.27\" verseOrdinal=\"27\">So God created man in his own image, in the image of God he created him; male and female he created them. </verse><verse osisID=\"Gen.1.28\" verseOrdinal=\"28\">And God blessed them. And God said to them, \u{201C}Be fruitful and multiply and fill the earth and subdue it, and have dominion over the fish of the sea and over the birds of the heavens and over every living thing that moves on the earth.\u{201D} </verse><verse osisID=\"Gen.1.29\" verseOrdinal=\"29\">And God said, \u{201C}Behold, I have given you every plant yielding seed that is on the face of all the earth, and every tree with seed in its fruit. You shall have them for food. </verse><verse osisID=\"Gen.1.30\" verseOrdinal=\"30\">And to every beast of the earth and to every bird of the heavens and to everything that creeps on the earth, everything that has the breath of life, I have given every green plant for food.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.31\" verseOrdinal=\"31\">And God saw everything that he had made, and behold, it was very good. And there was evening and there was morning, the sixth day. <div eID=\"gen9\" type=\"paragraph\"/></verse><div eID=\"gen1\" type=\"section\"/></div>"
    }

    // MARK: - Book Data

    /// Default 66-book Protestant canon, used as fallback when no module is loaded.
    static let defaultBooks: [BookInfo] = {
        let books: [(String, String, String, Int, Int)] = [
            ("Genesis", "Gen", "Gen", 50, 1), ("Exodus", "Exod", "Exod", 40, 1),
            ("Leviticus", "Lev", "Lev", 27, 1), ("Numbers", "Num", "Num", 36, 1),
            ("Deuteronomy", "Deut", "Deut", 34, 1), ("Joshua", "Josh", "Josh", 24, 1),
            ("Judges", "Judg", "Judg", 21, 1), ("Ruth", "Ruth", "Ruth", 4, 1),
            ("1 Samuel", "1Sam", "1Sam", 31, 1), ("2 Samuel", "2Sam", "2Sam", 24, 1),
            ("1 Kings", "1Kgs", "1Kgs", 22, 1), ("2 Kings", "2Kgs", "2Kgs", 25, 1),
            ("1 Chronicles", "1Chr", "1Chr", 29, 1), ("2 Chronicles", "2Chr", "2Chr", 36, 1),
            ("Ezra", "Ezra", "Ezra", 10, 1), ("Nehemiah", "Neh", "Neh", 13, 1),
            ("Esther", "Esth", "Esth", 10, 1), ("Job", "Job", "Job", 42, 1),
            ("Psalms", "Ps", "Ps", 150, 1), ("Proverbs", "Prov", "Prov", 31, 1),
            ("Ecclesiastes", "Eccl", "Eccl", 12, 1), ("Song of Solomon", "Song", "Song", 8, 1),
            ("Isaiah", "Isa", "Isa", 66, 1), ("Jeremiah", "Jer", "Jer", 52, 1),
            ("Lamentations", "Lam", "Lam", 5, 1), ("Ezekiel", "Ezek", "Ezek", 48, 1),
            ("Daniel", "Dan", "Dan", 12, 1), ("Hosea", "Hos", "Hos", 14, 1),
            ("Joel", "Joel", "Joel", 3, 1), ("Amos", "Amos", "Amos", 9, 1),
            ("Obadiah", "Obad", "Obad", 1, 1), ("Jonah", "Jonah", "Jonah", 4, 1),
            ("Micah", "Mic", "Mic", 7, 1), ("Nahum", "Nah", "Nah", 3, 1),
            ("Habakkuk", "Hab", "Hab", 3, 1), ("Zephaniah", "Zeph", "Zeph", 3, 1),
            ("Haggai", "Hag", "Hag", 2, 1), ("Zechariah", "Zech", "Zech", 14, 1),
            ("Malachi", "Mal", "Mal", 4, 1),
            ("Matthew", "Matt", "Matt", 28, 2), ("Mark", "Mark", "Mark", 16, 2),
            ("Luke", "Luke", "Luke", 24, 2), ("John", "John", "John", 21, 2),
            ("Acts", "Acts", "Acts", 28, 2), ("Romans", "Rom", "Rom", 16, 2),
            ("1 Corinthians", "1Cor", "1Cor", 16, 2), ("2 Corinthians", "2Cor", "2Cor", 13, 2),
            ("Galatians", "Gal", "Gal", 6, 2), ("Ephesians", "Eph", "Eph", 6, 2),
            ("Philippians", "Phil", "Phil", 4, 2), ("Colossians", "Col", "Col", 4, 2),
            ("1 Thessalonians", "1Thess", "1Thess", 5, 2), ("2 Thessalonians", "2Thess", "2Thess", 3, 2),
            ("1 Timothy", "1Tim", "1Tim", 6, 2), ("2 Timothy", "2Tim", "2Tim", 4, 2),
            ("Titus", "Titus", "Titus", 3, 2), ("Philemon", "Phlm", "Phlm", 1, 2),
            ("Hebrews", "Heb", "Heb", 13, 2), ("James", "Jas", "Jas", 5, 2),
            ("1 Peter", "1Pet", "1Pet", 5, 2), ("2 Peter", "2Pet", "2Pet", 3, 2),
            ("1 John", "1John", "1John", 5, 2), ("2 John", "2John", "2John", 1, 2),
            ("3 John", "3John", "3John", 1, 2), ("Jude", "Jude", "Jude", 1, 2),
            ("Revelation", "Rev", "Rev", 22, 2),
        ]
        return books.map { BookInfo(name: $0.0, osisId: $0.1, abbreviation: $0.2, chapterCount: $0.3, testament: $0.4) }
    }()

    /// JSword `BibleBook.ordinal` values persisted by Android reading-progress rows.
    private static let jswordBibleBookOrdinalByOsisId: [String: Int] = [
        "Gen": 2, "Exod": 3, "Lev": 4, "Num": 5, "Deut": 6,
        "Josh": 7, "Judg": 8, "Ruth": 9, "1Sam": 10, "2Sam": 11,
        "1Kgs": 12, "2Kgs": 13, "1Chr": 14, "2Chr": 15, "Ezra": 16,
        "Neh": 17, "Esth": 18, "Job": 19, "Ps": 20, "Prov": 21,
        "Eccl": 22, "Song": 23, "Isa": 24, "Jer": 25, "Lam": 26,
        "Ezek": 27, "Dan": 28, "Hos": 29, "Joel": 30, "Amos": 31,
        "Obad": 32, "Jonah": 33, "Mic": 34, "Nah": 35, "Hab": 36,
        "Zeph": 37, "Hag": 38, "Zech": 39, "Mal": 40,
        "Matt": 42, "Mark": 43, "Luke": 44, "John": 45, "Acts": 46,
        "Rom": 47, "1Cor": 48, "2Cor": 49, "Gal": 50, "Eph": 51,
        "Phil": 52, "Col": 53, "1Thess": 54, "2Thess": 55,
        "1Tim": 56, "2Tim": 57, "Titus": 58, "Phlm": 59, "Heb": 60,
        "Jas": 61, "1Pet": 62, "2Pet": 63, "1John": 64,
        "2John": 65, "3John": 66, "Jude": 67, "Rev": 68,
        "1Esd": 84, "2Esd": 85, "Tob": 69, "Jdt": 70, "AddEsth": 71,
        "Wis": 72, "WisSol": 72, "Sir": 73, "Bar": 74, "EpJer": 75,
        "PrAzar": 76, "Sus": 77, "Bel": 78, "PrMan": 83,
        "1Macc": 79, "2Macc": 80,
    ]

    /// Backward-compatible static accessor — returns just the book names from the default list.
    static let allBooks: [String] = defaultBooks.map(\.name)

    /// Refresh the book list from the active module's versification.
    private func refreshBookList() {
        guard let mod = activeModule else {
            moduleBookList = []
            return
        }
        let books = mod.getBookList()
        if books.isEmpty {
            logger.error("Module \(mod.info.name, privacy: .public) returned no books; refusing static canon fallback while active")
            moduleBookList = []
        } else {
            logger.info("Module \(mod.info.name) has \(books.count) books (versification: \(mod.configEntry("Versification") ?? "KJV"))")
            moduleBookList = books
        }
    }

    /// Chapter count for a book, using the active module's versification.
    func chapterCount(for book: String) -> Int {
        if let chapterCount = bookList.first(where: { $0.name == book })?.chapterCount {
            return chapterCount
        }
        return activeModule == nil ? Self.chapterCount(for: book) : 0
    }

    /// Static chapter count using the default 66-book list.
    static func chapterCount(for book: String) -> Int {
        defaultBooks.first(where: { $0.name == book })?.chapterCount ?? 1
    }

    /// Next book after the given book in the active module's versification.
    func nextBook(after book: String) -> String? {
        let books = bookList
        guard let index = books.firstIndex(where: { $0.name == book }), index + 1 < books.count else { return nil }
        return books[index + 1].name
    }

    /// Previous book before the given book in the active module's versification.
    func previousBook(before book: String) -> String? {
        let books = bookList
        guard let index = books.firstIndex(where: { $0.name == book }), index > 0 else { return nil }
        return books[index - 1].name
    }

    /// OSIS book ID lookup, using the active module's versification.
    func osisBookId(for bookName: String) -> String {
        if let osisId = bookList.first(where: { $0.name == bookName })?.osisId {
            return osisId
        }
        return activeModule == nil ? Self.osisBookId(for: bookName) : ""
    }

    /// KJVA-compatible ordinal for the canonical book position used by local reading progress.
    private func kjvBookOrdinal(for bookName: String) -> Int? {
        let osisId = osisBookId(for: bookName)
        return Self.jswordBibleBookOrdinalByOsisId[osisId]
    }

    private struct ReadingProgressBridgeTarget {
        let kjvBookOrdinal: Int
        let bookName: String
    }

    private func readingProgressBridgeTarget(
        bookInitials: String,
        startOrdinal: Int,
        chapter: Int
    ) -> ReadingProgressBridgeTarget? {
        guard let chapterRange = currentChapterOrdinalRange(),
              currentCategory == .bible,
              !bookInitials.isEmpty,
              bookInitials == activeModuleName,
              startOrdinal >= chapterRange.start,
              startOrdinal <= chapterRange.end,
              chapter == currentChapter,
              let kjvBookOrdinal = kjvBookOrdinal(for: currentBook) else {
            return nil
        }
        return ReadingProgressBridgeTarget(kjvBookOrdinal: kjvBookOrdinal, bookName: currentBook)
    }

    private func emitChapterReadStatus(chapter: Int, count: Int) {
        bridge.emit(
            event: "update_chapter_read_status",
            data: "{\"chapter\":\(chapter),\"count\":\(count)}"
        )
    }

    @discardableResult
    func saveReadingProgressSettings(_ settings: ReadingProgressSettingsSnapshot) -> ReadingProgressSettingsSnapshot? {
        guard let store = readingProgressStore else { return nil }
        let savedSettings = store.saveSettings(settings)
        emitReadingProgressSettings()
        bridge.emit(event: "set_config", data: buildConfigJSON())
        return savedSettings
    }

    private func emitReadingProgressSettings() {
        guard let settingsJSON = readingProgressStore?.settingsBundleJSON() else { return }
        bridge.emit(event: "update_reading_progress_settings", data: settingsJSON)
    }

    /// Static OSIS book ID lookup using the default list.
    static func osisBookId(for bookName: String) -> String {
        defaultBooks.first(where: { $0.name == bookName })?.osisId ?? bookName.prefix(3).description
    }

    /// Reverse lookup: OSIS ID → book name using the active module's versification.
    func bookName(forOsisId osisId: String) -> String? {
        bookList.first(where: { $0.osisId == osisId })?.name
    }

    /// Static reverse lookup using the default list.
    static func bookName(forOsisId osisId: String) -> String? {
        defaultBooks.first(where: { $0.osisId == osisId })?.name
    }

    /// Check if a book is in the New Testament, using the active module's versification.
    func isNewTestament(_ bookName: String) -> Bool {
        bookList.first(where: { $0.name == bookName })?.isNewTestament ?? false
    }

    /// Static NT check using the default list.
    static func isNewTestament(_ bookName: String) -> Bool {
        defaultBooks.first(where: { $0.name == bookName })?.isNewTestament ?? false
    }

    /**
     Returns the verse count for a book/chapter using the active Bible module when available.

     Android's passage chooser asks the current document versification for
     `getLastVerse(book, chapterNo)`. The iOS reader obtains the same value from the active SWORD
     module's `VerseKey` metadata and falls back to the legacy static table only when no module is
     active.

     - Parameters:
       - book: Display book name from the active module book list.
       - chapter: One-based chapter number selected in the chooser.
     - Returns: The last selectable verse number for the chapter, or `nil` when the active module
       cannot resolve the chapter exactly.
     - Side effects: May temporarily move the active module cursor through `SwordModule`; that
       method restores the previous key before returning.
     */
    func verseCountForActiveModule(book: String, chapter: Int) -> Int? {
        let osisId = osisBookId(for: book)
        if let activeModule {
            guard let count = activeModule.verseCount(osisBookId: osisId, chapter: chapter),
                  count > 0 else {
                return nil
            }
            return count
        }
        return Self.verseCount(for: book, chapter: chapter)
    }

    /// Returns the verse count for a book/chapter. Defaults to 30 if unknown.
    static func verseCount(for book: String, chapter: Int) -> Int {
        // Common verse counts for well-known chapters
        let key = "\(osisBookId(for: book)).\(chapter)"
        return knownVerseCounts[key] ?? 30
    }

    private static let knownVerseCounts: [String: Int] = [
        "Gen.1": 31, "Gen.2": 25, "Gen.3": 24, "Gen.4": 26, "Gen.5": 32,
        "Gen.6": 22, "Gen.7": 24, "Gen.8": 22, "Gen.9": 29, "Gen.10": 32,
        "Gen.11": 32, "Gen.12": 20, "Gen.50": 26,
        "Ps.1": 6, "Ps.23": 6, "Ps.91": 16, "Ps.119": 176, "Ps.150": 6,
        "Prov.1": 33, "Prov.3": 35, "Prov.31": 31,
        "Isa.1": 31, "Isa.40": 31, "Isa.53": 12,
        "Matt.1": 25, "Matt.5": 48, "Matt.6": 34, "Matt.28": 20,
        "Mark.1": 45, "Mark.16": 20,
        "Luke.1": 80, "Luke.2": 52, "Luke.24": 53,
        "John.1": 51, "John.3": 36, "John.14": 31, "John.21": 25,
        "Acts.1": 26, "Acts.2": 47,
        "Rom.1": 32, "Rom.8": 39, "Rom.12": 21,
        "1Cor.13": 13, "1Cor.15": 58,
        "Eph.1": 23, "Eph.6": 24,
        "Phil.4": 23,
        "Heb.11": 40,
        "Rev.1": 20, "Rev.21": 27, "Rev.22": 21,
    ]

    /// Generate placeholder verse text for chapters without real content.
    private static func placeholderVerseText(book: String, chapter: Int, verse: Int) -> String {
        // A selection of real-ish sounding placeholder texts per verse position
        let texts = [
            "And the word of the Lord came, saying,",
            "Behold, the days are coming when all things shall be made new.",
            "The Lord is gracious and merciful, slow to anger and abounding in steadfast love.",
            "For the Lord God is a sun and shield; he bestows favor and honor.",
            "Trust in the Lord with all your heart, and do not lean on your own understanding.",
            "In all your ways acknowledge him, and he will make straight your paths.",
            "The heavens declare the glory of God, and the sky above proclaims his handiwork.",
            "Day to day pours out speech, and night to night reveals knowledge.",
            "Let the words of my mouth and the meditation of my heart be acceptable in your sight.",
            "O Lord, my rock and my redeemer.",
            "He makes me lie down in green pastures. He leads me beside still waters.",
            "He restores my soul. He leads me in paths of righteousness for his name\u{2019}s sake.",
            "Even though I walk through the valley of the shadow of death, I will fear no evil.",
            "For you are with me; your rod and your staff, they comfort me.",
            "Surely goodness and mercy shall follow me all the days of my life.",
            "And I shall dwell in the house of the Lord forever.",
            "The Lord is my light and my salvation; whom shall I fear?",
            "The Lord is the stronghold of my life; of whom shall I be afraid?",
            "Wait for the Lord; be strong, and let your heart take courage.",
            "Blessed is the man who walks not in the counsel of the wicked.",
            "But his delight is in the law of the Lord, and on his law he meditates day and night.",
            "He is like a tree planted by streams of water that yields its fruit in its season.",
            "The Lord knows the way of the righteous, but the way of the wicked will perish.",
            "For God so loved the world, that he gave his only Son.",
            "That whoever believes in him should not perish but have eternal life.",
            "Come to me, all who labor and are heavy laden, and I will give you rest.",
            "Take my yoke upon you, and learn from me, for I am gentle and lowly in heart.",
            "And you will find rest for your souls. For my yoke is easy, and my burden is light.",
            "I can do all things through him who strengthens me.",
            "And my God will supply every need of yours according to his riches in glory.",
        ]
        let index = (verse - 1) % texts.count
        return texts[index]
    }
}

// MARK: - Cross-Reference Types

/**
 Parsed OSIS verse reference used by cross-reference resolution.
 */
struct OsisRef {
    /// Human-readable book name.
    let book: String

    /// 1-based chapter number.
    let chapter: Int

    /// 1-based verse number.
    let verse: Int

    /// Original OSIS book identifier.
    let osisId: String

    /// Human-readable display string for the reference.
    var displayName: String {
        "\(book) \(chapter):\(verse)"
    }
}

/**
 Cross-reference row containing both the parsed reference and preview verse text.
 */
public struct CrossReference: Identifiable {
    /// Stable identifier for SwiftUI list rendering.
    public let id = UUID()

    /// Parsed reference coordinates.
    let ref: OsisRef

    /// Verse text preview resolved for the reference.
    let text: String

    /// Human-readable display string for the reference.
    var displayName: String { ref.displayName }
    /// Human-readable book name for navigation callbacks.
    var book: String { ref.book }
    /// Chapter number for navigation callbacks.
    var chapter: Int { ref.chapter }
}
