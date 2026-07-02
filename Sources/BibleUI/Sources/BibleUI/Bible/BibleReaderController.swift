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
    let bridge: BibleBridge
    var bookmarkService: BookmarkService?
    var myDocumentStore: MyDocumentStore?
    private(set) var currentBook: String = "Genesis"
    private(set) var currentChapter: Int = 1
    private(set) var currentVerse: Int = 1
    private var clientReady = false
    /// Sync-scroll feedback state used to keep inactive target panes passive until interaction.
    private let synchronizedScrollCoordinator = BibleReaderSynchronizedScrollCoordinator()

    /// Whether the WebView is currently showing the My Notes document (vs Bible text).
    private(set) var showingMyNotes = false
    /// Optional My Notes row ordinal requested before the Vue client was ready.
    private var pendingClientReadyMyNotesJumpOrdinal: Int?
    /// Monotonic marker used by lightweight UI-test exports when My Notes state or documents rebuild.
    private(set) var myNotesMutationRevision = 0

    /// Whether the WebView is currently showing a StudyPad document.
    private(set) var showingStudyPad = false
    /// Monotonic marker used by lightweight UI-test exports when StudyPad state mutates.
    private(set) var studyPadMutationRevision = 0
    /// The label ID of the currently active StudyPad.
    private(set) var activeStudyPadLabelId: UUID?
    /// The name of the currently active StudyPad label (for the header).
    private(set) var activeStudyPadLabelName: String?
    /// Optional StudyPad row requested before the Vue client was ready.
    private var pendingClientReadyStudyPadBookmarkId: UUID?
    /// Whether the WebView is in editing mode (Quill editor active).
    private(set) var editingInWebView = false
    /// Whether the Vue reader client currently reports an open modal for this pane.
    private(set) var webModalIsOpen = false
    /// Router for bridge events whose behavior is limited to pane-local modal and host callbacks.
    @ObservationIgnored
    private lazy var bridgeEventRouter = makeBridgeEventRouter()
    /// Router for annotation bridge delegate calls and UI-test annotation mutation hooks.
    @ObservationIgnored
    private lazy var annotationBridgeHandler = makeAnnotationBridgeHandler()
    /// Pure classifier for Android-compatible external link and pseudo-link strings.
    private let externalLinkRouter = BibleReaderExternalLinkRouter()

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
        bookCatalog.books
    }

    /// Commentary module support
    private(set) var installedCommentaryModules: [ModuleInfo] = []
    private(set) var activeCommentaryModule: SwordModule?
    private(set) var activeCommentaryModuleName: String?
    private(set) var currentCategory: DocumentCategory = .bible
    /// Pure planner for Android-style module/category PageManager transitions.
    private let moduleSwitchCoordinator = BibleReaderModuleSwitchCoordinator()
    /// State machine for Android-style Bible navigation and visible-position persistence.
    @ObservationIgnored
    private let navigationCoordinator = BibleReaderNavigationCoordinator()

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
    private(set) var renderedDocumentKind: ReaderRenderedDocumentKind = .standard
    /// Coordinator for Android-style transient `MultiDocument` state and fake-document identity.
    private var specialDocumentCoordinator = BibleReaderSpecialDocumentCoordinator()
    /// Reader-local My Documents active page state and document payload assembly.
    private var myDocumentCoordinator = BibleReaderMyDocumentCoordinator()

    /// Reader-local loaded-range state for Vue infinite-scroll prepend/append requests.
    private var infiniteScrollCoordinator = BibleReaderInfiniteScrollCoordinator()

    /// Catalog boundary for active-module book metadata and SWORD/JSword versification lookup.
    private var bookCatalog: BibleReaderBookCatalog {
        BibleReaderBookCatalog(activeModule: activeModule, moduleBookList: moduleBookList)
    }

    /// Legacy ordinal fallback used only when no SWORD verse-key module can resolve the reference.
    private func compatibilityOrdinal(chapter: Int, verse: Int) -> Int {
        BibleReaderBookCatalog.compatibilityOrdinal(chapter: chapter, verse: verse)
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
        bookCatalog.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
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
        bookCatalog.verseReference(book: book, ordinal: ordinal)
    }

    /**
     Resolves the currently visible synchronized ordinal into a stable verse identity.

     Android synchronizes inactive Bible windows by copying the active `Verse` key, then lets each
     target page convert that verse into its own versification before scrolling. This helper exposes
     the source side of that contract to the reader shell so synchronized panes do not exchange raw
     module-local ordinals.

     - Parameter ordinal: Ordinal reported by the source web client.
     - Returns: The source controller's current book/chapter/verse identity for the ordinal, or
       `nil` when the ordinal cannot be resolved in the current source book.
     - Side effects: May temporarily move the active SWORD module cursor through `verseReference`.
     - Failure modes: Invalid ordinals or source books unsupported by the active module return
       `nil`.
     */
    func synchronizedVerseReference(ordinal: Int) -> VerseKeyReference? {
        verseReference(book: currentBook, ordinal: ordinal)
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
        bookCatalog.chapterOrdinalRange(book: book, chapter: chapter, verseCount: verseCount)
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

    /// Whether the rendered document allows native horizontal swipes to navigate to another page.
    var allowsHorizontalDocumentNavigation: Bool {
        renderedDocumentKind.allowsHorizontalDocumentNavigation
    }

    /// Records the latest content identity that native requested the reader WebView to display.
    private func setRenderedContentState(
        category: DocumentCategory,
        moduleName: String?,
        book: String,
        chapter: Int? = nil,
        key: String? = nil,
        documentKind: ReaderRenderedDocumentKind = .standard
    ) {
        myDocumentCoordinator.clearActivePageUnless(category: category, moduleName: moduleName)
        renderedDocumentKind = documentKind
        renderedContentState = BibleReaderRenderedContentState(
            category: category,
            moduleName: moduleName,
            book: book,
            chapter: chapter,
            key: key
        ).encodedValue
    }

    /// Whether the visible page is Android's synthetic `Multi` general-book document.
    var isShowingAndroidMultiDocument: Bool {
        AndroidSpecialDocumentIdentity.isMultiDocument(
            categoryName: currentCategory.pageManagerKey,
            moduleName: activeGeneralBookModuleName ?? activeWindow?.pageManager?.generalBookDocument
        )
    }

    /**
     Visible toolbar summary for Android's synthetic `Multi` document.

     The page identity intentionally remains `general_book/Multi` for Android restore and links-window
     parity. This summary is derived from the active transient Vue payload so the SwiftUI toolbar can
     mirror Android's display title, for example `BDBT: H430`, without mutating the durable document
     identity to the selected dictionary tab.
     */
    var androidMultiDocumentHeaderSummary: AndroidSpecialDocumentIdentity.MultiDocumentHeaderSummary? {
        guard let activeRequest = specialDocumentCoordinator.activeRequest(
            isShowingAndroidMultiDocument: isShowingAndroidMultiDocument
        ) else {
            return nil
        }
        return AndroidSpecialDocumentIdentity.multiDocumentHeaderSummary(
            from: activeRequest.documentJSON,
            subtitle: Bundle.main.localizedString(
                forKey: "multi_description",
                value: "Multiple references",
                table: nil
            )
        )
    }

    /// Whether the current page should expose Strong's actions (matching Android CurrentPageManager.hasStrongs).
    var hasStrongs: Bool {
        switch currentCategory {
        case .bible:
            return activeModule?.info.features.contains(.strongsNumbers) == true
        case .commentary:
            return activeCommentaryModule?.info.features.contains(.strongsNumbers) == true
        case .generalBook:
            return isShowingAndroidMultiDocument
        default:
            return false
        }
    }

    /**
     Whether actions that depend on an active Bible verse reference are valid for the visible page.

     Android exposes share, compare, and Bible bookmark actions only when selection metadata includes
     `verseInfo`. The synthetic `Multi` links-window page and other auxiliary documents may render
     text derived from Bible modules, but their native page identity is not a Bible page and must not
     fall back to stale `currentBook/currentChapter` state.

     - Returns: `true` only for an actual Bible page; `false` for Android special documents and all
       auxiliary categories.
     - Side effects: None.
     */
    var canUseBibleReferenceActions: Bool {
        currentCategory == .bible && !isShowingAndroidMultiDocument
    }

    /**
     Whether the current page should expose Android's page search action.

     Android delegates toolbar search visibility to `CurrentPage.isSearchable`: Bible and regular
     commentary pages are searchable, dictionary pages are not, and general-book pages are searchable
     only for EPUB-backed content. The iOS reader currently represents EPUB with its own category, so
     non-EPUB general books, including `Multi`, remain non-searchable.

     - Returns: `true` when the toolbar/search shortcut should be enabled for the visible page.
     - Side effects: None.
     */
    var isCurrentPageSearchable: Bool {
        switch currentCategory {
        case .bible, .commentary, .epub:
            return !isShowingAndroidMultiDocument
        default:
            return false
        }
    }

    /**
     Whether the current page can be spoken by Android's page-level speak action.

     Android's `CurrentGeneralBookPage` disables speech for special documents such as `Multi`, while
     ordinary Bible/commentary pages remain speakable. iOS page-level speech is backed by the current
     SWORD text context, so this property intentionally suppresses special links-window pages instead
     of invoking speech with stale Bible coordinates.

     - Returns: `true` when page-level speech is valid for the visible page.
     - Side effects: None.
     */
    var isCurrentPageSpeakable: Bool {
        switch currentCategory {
        case .bible, .commentary:
            return !isShowingAndroidMultiDocument
        default:
            return false
        }
    }

    /**
     Whether the current page participates in synchronized scrolling.

     Android reports `CurrentGeneralBookPage.isSyncable=false`, while dictionary/map-style pages
     inherit the default syncable behavior. iOS mirrors that distinction by disabling general-book
     and EPUB sync controls, including links-window `Multi`, without globally limiting sync to Bible
     and commentary pages.

     - Returns: `true` for Android-syncable page categories; `false` for general-book/EPUB pages and
       special `Multi` content.
     - Side effects: None.
     */
    var isCurrentPageSyncable: Bool {
        switch currentCategory {
        case .generalBook, .epub:
            return false
        default:
            return !isShowingAndroidMultiDocument
        }
    }

    /// Resolved text display settings used for Vue.js config
    var displaySettings: TextDisplaySettings = .appDefaults
    /// Night mode toggle
    var nightMode: Bool = false

    /// Latest asynchronous compare request used to ignore stale background payloads.
    private var compareDocumentRequestID = UUID()
    /// TTS service
    var speakService: SpeakService?
    /// Speech-specific collaborator that builds TTS payloads and owns word-highlight state.
    private let speechCoordinator = BibleReaderSpeechCoordinator()
    /// SWORD setup collaborator that owns manager option mapping and module-state projection.
    private let swordCoordinator = BibleReaderSwordCoordinator()
    /// Reader config/window-state collaborator that owns bridge payload projection and compare visibility state.
    private var configurationCoordinator = BibleReaderConfigurationCoordinator()
    /// Reader-local native selection state and pure action-payload decisions.
    private var selectionCoordinator = BibleReaderSelectionCoordinator()
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
     Creates the collaborator that owns pane-local bridge event routing.

     The closures deliberately bounce back into controller-owned dependencies for navigation,
     preference lookup, bridge emission, and host callbacks. This keeps the router focused on
     dispatch rules while preserving the controller as the state/presentation orchestration boundary.

     - Returns: A router configured for this controller's bridge and host callbacks.
     - Side effects: None during creation; side effects happen when the router handles bridge events.
     - Failure modes: Deallocated controllers or unset host callbacks become no-ops, matching the
       previous optional-callback behavior.
     */
    private func makeBridgeEventRouter() -> BibleReaderBridgeEventRouter {
        BibleReaderBridgeEventRouter(
            emitBridgeEvent: { [weak self] event in
                self?.bridge.emit(event: event) ?? false
            },
            navigatePrevious: { [weak self] in
                self?.navigatePrevious()
            },
            navigateNext: { [weak self] in
                self?.navigateNext()
            },
            showToast: { [weak self] text in
                self?.onShowToast?(text)
            },
            shareHtml: { [weak self] html in
                self?.onShareHtml?(html)
            },
            openDownloads: { [weak self] searchText in
                self?.onRequestOpenDownloads?(searchText)
            },
            shouldToggleFullScreen: { [weak self] in
                self?.appPreferenceBool(.doubleTapToFullscreen) ?? false
            },
            toggleFullScreen: { [weak self] in
                self?.onToggleFullScreen?()
            }
        )
    }

    /**
     Callback for pane-owned routing of transient dictionary-style documents.

     The controller builds already-serialized Vue `MultiDocument` payloads for Strong's,
     morphology, and word-lookup dictionary results. The owning pane decides whether those payloads
     render in the current pane or in the Android-style links target window.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload.
       - renderedBook: Legacy label retained for the existing routing callback. Target controllers
         normalize Strong's and dictionary documents to Android's `Multi` page identity.
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

    /// Coordinates Android-compatible reading-progress and memorization bridge mutations.
    @ObservationIgnored
    private lazy var progressBridgeCoordinator = makeProgressBridgeCoordinator()

    /// Callback to persist SwiftData changes (called after PageManager updates).
    var onPersistState: (() -> Void)?

    /// Persists the current page-manager state either immediately or after a short debounce for scroll updates.
    private func persistVisibleVerseState(immediate: Bool) {
        navigationCoordinator.persistVisibleVerseState(immediate: immediate) { [weak self] in
            self?.onPersistState?()
        }
    }

    /**
     Builds the controller-owned dependency context used by the navigation coordinator.

     The coordinator owns the Bible position transition rules while this controller remains the
     owner of observed reader state, SWORD/JSword-compatible versification lookups, history storage,
     active-window PageManager access, and WebView reloads. Weak captures prevent deferred
     visible-verse persistence from extending pane lifetime.
     */
    private func makeNavigationContext() -> BibleReaderNavigationContext {
        BibleReaderNavigationContext(
            currentPosition: { [weak self] in
                BibleReaderNavigationPosition(
                    book: self?.currentBook ?? "Genesis",
                    chapter: self?.currentChapter ?? 1,
                    verse: self?.currentVerse ?? 1
                )
            },
            setCurrentPosition: { [weak self] position in
                self?.currentBook = position.book
                self?.currentChapter = position.chapter
                self?.currentVerse = position.verse
            },
            pageManager: { [weak self] in
                self?.activeWindow?.pageManager
            },
            bookList: { [weak self] in
                self?.bookList.map {
                    BibleReaderNavigationBook(
                        name: $0.name,
                        osisId: $0.osisId,
                        chapterCount: $0.chapterCount
                    )
                } ?? []
            },
            isShowingAndroidMultiDocument: { [weak self] in
                self?.isShowingAndroidMultiDocument ?? false
            },
            clientReady: { [weak self] in
                self?.clientReady ?? false
            },
            chapterCount: { [weak self] book in
                self?.chapterCount(for: book) ?? 0
            },
            nextBook: { [weak self] book in
                self?.nextBook(after: book)
            },
            previousBook: { [weak self] book in
                self?.previousBook(before: book)
            },
            bookNameForOsisId: { [weak self] osisId in
                self?.bookName(forOsisId: osisId)
            },
            ordinalForVerse: { [weak self] book, chapter, verse in
                guard let self else { return nil }
                return self.verseOrdinal(
                    osisBookId: self.osisBookId(for: book),
                    chapter: chapter,
                    verse: verse
                )
            },
            verseReference: { [weak self] book, ordinal in
                self?.verseReference(book: book, ordinal: ordinal).map {
                    BibleReaderNavigationVerseReference(
                        chapter: $0.chapter,
                        verse: $0.verse,
                        osisBookId: $0.osisBookId
                    )
                }
            },
            recordHistory: { [weak self] book, chapter, verse in
                guard let self,
                      let store = self.workspaceStore,
                      let window = self.activeWindow else {
                    return
                }
                let osisId = self.osisBookId(for: book)
                store.addHistoryItem(
                    to: window,
                    document: self.activeModuleName,
                    key: "\(osisId).\(chapter).\(verse)"
                )
            },
            persistState: { [weak self] in
                self?.onPersistState?()
            },
            loadCurrentContent: { [weak self] in
                self?.loadCurrentContent()
            }
        )
    }

    /**
     Builds the controller-owned mutation context used by the module switch coordinator.

     The coordinator owns module/category switching rules while this controller remains the owner of
     observed active-module state, current keys, persistence callbacks, and WebView reloads. Closures
     capture the controller weakly so a pending switch action cannot extend pane lifetime.
     */
    private func makeModuleSwitchContext() -> BibleReaderModuleSwitchContext {
        BibleReaderModuleSwitchContext(
            swordManager: swordManager,
            activeWindow: activeWindow,
            clientReady: clientReady,
            currentCategory: currentCategory,
            setBibleModule: { [weak self] module, moduleName in
                self?.activeModule = module
                self?.activeModuleName = moduleName
            },
            setCommentaryModule: { [weak self] module, moduleName in
                self?.activeCommentaryModule = module
                self?.activeCommentaryModuleName = moduleName
            },
            setDictionaryModule: { [weak self] module, moduleName in
                self?.activeDictionaryModule = module
                self?.activeDictionaryModuleName = moduleName
                self?.currentDictionaryKey = nil
            },
            setGeneralBookModule: { [weak self] module, moduleName in
                self?.activeGeneralBookModule = module
                self?.activeGeneralBookModuleName = moduleName
                self?.currentGeneralBookKey = nil
            },
            setMapModule: { [weak self] module, moduleName in
                self?.activeMapModule = module
                self?.activeMapModuleName = moduleName
                self?.currentMapKey = nil
            },
            setCurrentCategory: { [weak self] category in
                self?.currentCategory = category
            },
            refreshBookList: { [weak self] in
                self?.refreshBookList()
            },
            moduleBookListCount: { [weak self] in
                self?.moduleBookList.count ?? 0
            },
            persistState: { [weak self] in
                self?.onPersistState?()
            },
            loadCurrentContent: { [weak self] in
                self?.loadCurrentContent()
            }
        )
    }

    /**
     Builds the coordinator for Android-compatible reading-progress and memorization bridge actions.

     The controller still owns active-document validation, native presentation callbacks, and the
     concrete `BibleBridge` emitter. The coordinator owns store mutations and emitted progress
     events so these bridge concerns no longer live inline with the full reader controller.
     */
    private func makeProgressBridgeCoordinator() -> BibleReaderProgressBridgeCoordinator {
        BibleReaderProgressBridgeCoordinator(
            memorizationStore: { [weak self] in
                self?.memorizationProgressStore
            },
            readingStore: { [weak self] in
                self?.readingProgressStore
            },
            resolveReadingTarget: { [weak self] bookInitials, startOrdinal, chapter in
                self?.readingProgressBridgeTarget(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    chapter: chapter
                )
            },
            loadMemorizeDocument: { [weak self] bookInitials, startOrdinal, endOrdinal in
                self?.loadMemorizeDocument(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                )
            },
            showReadingProgress: { [weak self] tab in
                self?.onShowReadingProgress?(tab)
            },
            showReadingProgressSettings: { [weak self] in
                self?.onShowReadingProgressSettings?()
            },
            showChapterReadHistory: { [weak self] target in
                self?.onShowChapterReadHistory?(target)
            },
            emit: { [weak self] event, data in
                self?.bridge.emit(event: event, data: data)
            },
            buildConfigJSON: { [weak self] in
                self?.buildConfigJSON() ?? "{}"
            }
        )
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
        navigationCoordinator.prepareForContentReload()
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
        guard isCurrentPageSpeakable else { return }
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
        moduleSwitchCoordinator.switchModule(to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a Bible module in one Android-parity transition.

     Android's `CurrentPageManager.setCurrentDocument(book)` updates the selected Bible and active
     page together before notifying the reader. This method gives iOS the same contract for toolbar
     quick selectors and the full module picker: the pane's Bible document and category are updated
     together, persisted together, and then rendered once when the web client is ready.

     - Parameter moduleName: Installed SWORD Bible module abbreviation to make current.
     Side effects:
     - mutates the active Bible module and current document category
     - refreshes the cached Bible book list for the selected module
     - writes `bibleDocument` and `currentCategoryName` to the active pane's `PageManager`
     - invokes `onPersistState` once when pane state is available
     - reloads the visible reader document once when the JavaScript client is ready
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a Bible, logs a warning and leaves controller/page state
       unchanged
     - Important: Main-actor isolated because successful switches can mutate SwiftUI-observed reader
       state and synchronously emit WebView bridge updates through `loadCurrentContent()`.
     */
    @MainActor
    public func switchBibleDocument(to moduleName: String) {
        moduleSwitchCoordinator.switchBibleDocument(to: moduleName, context: makeModuleSwitchContext())
    }

    /// Switch to a different installed commentary module.
    public func switchCommentaryModule(to moduleName: String) {
        moduleSwitchCoordinator.switchCommentaryModule(to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a commentary module in one Android-parity transition.

     Android's toolbar quick selector delegates selected commentary documents to
     `setCurrentDocument(book)`, so the selected module and visible document category change
     together. This method keeps iOS on that contract for both quick selectors and full chooser
     selections that should show commentary content immediately.

     - Parameter moduleName: Installed SWORD commentary module abbreviation to make current.
     Side effects:
     - mutates the active commentary module and current document category
     - writes `commentaryDocument` and `currentCategoryName` to the active pane's `PageManager`
     - invokes `onPersistState` once when pane state is available
     - reloads the visible reader document once when the JavaScript client is ready
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a commentary, logs a warning and leaves state unchanged
     */
    @MainActor
    public func switchCommentaryDocument(to moduleName: String) {
        moduleSwitchCoordinator.switchCommentaryDocument(to: moduleName, context: makeModuleSwitchContext())
    }

    /// Switch the active dictionary module.
    public func switchDictionaryModule(to moduleName: String) {
        moduleSwitchCoordinator.switchDictionaryModule(to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a dictionary module in one Android-parity transition.

     Android's commentary quick popup can include dictionaries and selects them through the same
     current-document path as commentaries. The selected dictionary, cleared entry key, and visible
     document category must therefore be persisted together before rendering dictionary content.

     - Parameter moduleName: Installed SWORD dictionary module abbreviation to make current.
     Side effects:
     - mutates the active dictionary module, clears the selected dictionary key, and sets the
       current category to dictionary
     - writes `dictionaryDocument`, `dictionaryKey`, and `currentCategoryName` to `PageManager`
     - invokes `onPersistState` once when pane state is available
     - reloads the visible reader document once when the JavaScript client is ready
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a dictionary, logs a warning and leaves state unchanged
     */
    @MainActor
    public func switchDictionaryDocument(to moduleName: String) {
        moduleSwitchCoordinator.switchDictionaryDocument(to: moduleName, context: makeModuleSwitchContext())
    }

    /// Switch the active general book module.
    public func switchGeneralBookModule(to moduleName: String) {
        moduleSwitchCoordinator.switchGeneralBookModule(to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a general-book module in one Android-parity transition.

     Android's commentary quick popup includes general books and routes selected rows through the
     same current-document switch as other documents. iOS should not split this into separate module
     and category updates because that can persist partial pane state or reload stale content.

     - Parameter moduleName: Installed SWORD general-book module abbreviation to make current.
     Side effects:
     - mutates the active general-book module, clears the selected general-book key, and sets the
       current category to general book
     - writes `generalBookDocument`, `generalBookKey`, and `currentCategoryName` to `PageManager`
     - invokes `onPersistState` once when pane state is available
     - reloads the visible reader document once when the JavaScript client is ready
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a general book, logs a warning and leaves state unchanged
     */
    @MainActor
    public func switchGeneralBookDocument(to moduleName: String) {
        moduleSwitchCoordinator.switchGeneralBookDocument(to: moduleName, context: makeModuleSwitchContext())
    }

    /// Switch the active map module.
    public func switchMapModule(to moduleName: String) {
        moduleSwitchCoordinator.switchMapModule(to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a map module in one Android-parity transition.

     Android routes map rows through the same `setCurrentDocument(book)` path as Bible,
     commentary, dictionary, and general-book rows. iOS must therefore persist the selected map,
     clear stale map entry state, and switch the visible category together instead of splitting map
     selection and category selection across separate controller mutations.

     - Parameter moduleName: Installed SWORD map module abbreviation to make current.
     Side effects:
     - mutates the active map module, clears the selected map key, and sets the current category to
       map
     - writes `mapDocument`, `mapKey`, and `currentCategoryName` to `PageManager`
     - invokes `onPersistState` once when pane state is available
     - reloads the visible reader document once when the JavaScript client is ready
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a map, logs a warning and leaves state unchanged
     */
    @MainActor
    public func switchMapDocument(to moduleName: String) {
        moduleSwitchCoordinator.switchMapDocument(to: moduleName, context: makeModuleSwitchContext())
    }

    /// Switch between document categories (Bible, Commentary, Dictionary, General Book, Map).
    public func switchCategory(to category: DocumentCategory) {
        moduleSwitchCoordinator.switchCategory(to: category, context: makeModuleSwitchContext())
    }

    /// Load the appropriate content for the current category.
    public func loadCurrentContent() {
        if isShowingAndroidMultiDocument {
            if let activeRequest = specialDocumentCoordinator.activeRequest(
                isShowingAndroidMultiDocument: isShowingAndroidMultiDocument
            ) {
                emitTransientMultiDocument(activeRequest)
                return
            }
            if loadRestoredAndroidMultiDocument() {
                return
            }
        }

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
       setup payload, resets selection state, updates the rendered-content accessibility token,
       persists Android's `general_book` + `Multi` PageManager identity for the links window, and
       reapplies the reader background.
     - Failure modes: assumes the payload is already valid JSON; invalid payloads are forwarded to
       the Vue bridge after the transient reader state is prepared, so caller-owned builders should
       validate or serialize before invoking this method.
     */
    func loadMultiReferenceDocument(_ documentJSON: String) {
        loadTransientMultiDocument(
            documentJSON,
            renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            renderedKey: AndroidSpecialDocumentIdentity.multiRenderedKey,
            renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(from: documentJSON)
        )
    }

    /**
     Re-emits a restored Android `Multi` fake document from durable PageManager state.

     A live links-window load keeps its serialized Vue payload in memory for client-ready replay.
     After process restart, Android rebuilds that payload from the saved `BookAndKeyList.osisRef`
     string. iOS follows that contract here so `general_book/Multi` is not merely a tab label.

     - Returns: `true` when a restored payload was rebuilt and emitted; otherwise `false` so callers
       can continue through ordinary category loading.
     - Side effects: Emits a Vue `MultiDocument`, refreshes rendered-content state, and persists the
       same `general_book/Multi` PageManager identity through `loadTransientMultiDocument`.
     - Failure modes: Returns `false` when the saved key is missing, malformed, references no
       installed source documents, or cannot be encoded.
     */
    private func loadRestoredAndroidMultiDocument() -> Bool {
        guard let restored = restoredMultiDocumentBuilder().build(pageKey: currentGeneralBookKey) else { return false }
        loadTransientMultiDocument(
            restored.documentJSON,
            renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            renderedKey: restored.renderedKey,
            renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageKey: restored.pageKey
        )
        return true
    }

    /**
     Builds the restored Android `Multi` payload builder bound to this pane's SWORD/catalog state.

     The controller keeps only the orchestration decision of whether a restored fake document should
     render now. The builder owns Android's `BookAndKeyList` reconstruction rules while these
     closures preserve the active module versification used elsewhere in the reader.

     - Returns: A builder configured with the active SWORD manager, active Bible module, and
       active-versification book metadata.
     - Side effects: None.
     - Failure modes: Missing SWORD/module state is deferred to the builder, which returns `nil`
       when it cannot rebuild a valid document.
     */
    private func restoredMultiDocumentBuilder() -> BibleReaderRestoredMultiDocumentBuilder {
        BibleReaderRestoredMultiDocumentBuilder(
            swordManager: swordManager,
            activeModule: activeModule,
            bookNameForOsisId: { [weak self] osisId in
                self?.bookName(forOsisId: osisId) ?? Self.bookName(forOsisId: osisId)
            },
            isNewTestament: { [weak self] bookName in
                self?.isNewTestament(bookName) ?? Self.isNewTestament(bookName)
            }
        )
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
            let documentJSON = BibleReaderCompareDocumentBuilder.buildDocumentJSON(request)
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
       - pageCategory: Optional durable PageManager category for Android fake-document parity.
       - pageDocumentInitials: Optional durable PageManager document initials for Android
         fake-document parity.
       - pageKey: Optional durable PageManager key for Android fake-document parity.
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
        renderedModuleName: String? = nil,
        pageCategory: DocumentCategory? = nil,
        pageDocumentInitials: String? = nil,
        pageKey: String? = nil
    ) {
        let request = BibleReaderTransientDocumentRequest(
            documentJSON: documentJSON,
            renderedBook: renderedBook,
            renderedKey: renderedKey,
            renderedCategory: renderedCategory,
            renderedModuleName: renderedModuleName,
            pageCategory: pageCategory,
            pageDocumentInitials: pageDocumentInitials,
            pageKey: pageKey
        )
        specialDocumentCoordinator.store(request, clientReady: clientReady)
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
    private func emitTransientMultiDocument(_ request: BibleReaderTransientDocumentRequest) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        applyTransientPageIdentity(request)

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
     Applies the native PageManager identity for a transient rendered document.

     Android link-result windows do not stay on the source Bible category when they display aggregate
     result content. For `FakeBookFactory.multiDocument`, the destination window becomes a
     `GENERAL_BOOK` page with document initials `Multi` and a `BookAndKeyList` key. The special
     document coordinator owns that mapping; this method applies its transition plan to controller
     and PageManager state.

     - Parameter request: Transient document request carrying optional durable PageManager fields.
     - Side effects: Mutates `currentCategory`, category-specific controller fields, active
       `PageManager` fields, and may invoke `onPersistState`.
     - Failure modes: Requests without `pageCategory` fall back to the previous transient Bible
       identity and do not persist page-manager state. General-book requests without a non-empty
       durable document/key update only the transient controller category so malformed bridge
       payloads cannot erase the last restorable Android `Multi` key.
     */
    private func applyTransientPageIdentity(_ request: BibleReaderTransientDocumentRequest) {
        let update = specialDocumentCoordinator.pageIdentityUpdate(for: request)
        currentCategory = update.currentCategory
        if update.clearsActiveGeneralBookModule {
            activeGeneralBookModule = nil
        }
        if update.assignsActiveGeneralBookModuleName {
            activeGeneralBookModuleName = update.activeGeneralBookModuleName
        }
        if let currentGeneralBookKey = update.currentGeneralBookKey {
            self.currentGeneralBookKey = currentGeneralBookKey
        }
        guard update.persistsPageManagerState,
              let pm = activeWindow?.pageManager else { return }
        if let pageManagerCategoryName = update.pageManagerCategoryName {
            pm.currentCategoryName = pageManagerCategoryName
        }
        if let pageManagerGeneralBookDocument = update.pageManagerGeneralBookDocument {
            pm.generalBookDocument = pageManagerGeneralBookDocument
        }
        if let pageManagerGeneralBookKey = update.pageManagerGeneralBookKey {
            pm.generalBookKey = pageManagerGeneralBookKey
        }
        onPersistState?()
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
        clearNativeSelectionState()

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
        clearNativeSelectionState()
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
        clearNativeSelectionState()

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

        let state = swordCoordinator.configure(
            manager: mgr,
            selection: currentSwordSelection(),
            displaySettings: displaySettings
        )
        logger.info("SWORD found \(state.installedModules.count) installed modules")
        for mod in state.installedModules {
            let hasStrongs = mod.features.contains(.strongsNumbers)
            logger.info("  Module: \(mod.name) (\(mod.description)) [\(mod.category.rawValue)] strongs=\(hasStrongs)")
        }

        applySwordState(state)
        if activeModule == nil {
            logger.warning("No Bible modules installed — using placeholder text")
        } else {
            logger.info("Using Bible module: \(self.activeModuleName)")
        }

        logBookListRefresh(module: activeModule, books: moduleBookList)
    }

    /**
     Builds the current module-selection DTO consumed by the SWORD setup coordinator.

     - Returns: The category-owned module initials currently stored on this controller.
     - Side effects: None.
     - Failure modes: None; nil optional categories indicate no explicit auxiliary selection.
     */
    private func currentSwordSelection() -> BibleReaderSwordSelection {
        BibleReaderSwordSelection(
            activeModuleName: activeModuleName,
            activeCommentaryModuleName: activeCommentaryModuleName,
            activeDictionaryModuleName: activeDictionaryModuleName,
            activeGeneralBookModuleName: activeGeneralBookModuleName,
            activeMapModuleName: activeMapModuleName
        )
    }

    /**
     Applies a SWORD setup projection to controller-owned observable state.

     - Parameter state: Installed-module catalog and active module handles generated from the
       current `SwordManager`.
     - Side effects: Mutates installed-module arrays, active module references, selected initials,
       and `moduleBookList` on the controller.
     - Failure modes: None; absent modules are represented by nil handles in `state`.
     */
    private func applySwordState(_ state: BibleReaderSwordState) {
        installedBibleModules = state.installedBibleModules
        installedCommentaryModules = state.installedCommentaryModules
        installedDictionaryModules = state.installedDictionaryModules
        installedGeneralBookModules = state.installedGeneralBookModules
        installedMapModules = state.installedMapModules
        activeModule = state.activeModule
        activeModuleName = state.activeModuleName
        activeCommentaryModule = state.activeCommentaryModule
        activeCommentaryModuleName = state.activeCommentaryModuleName
        activeDictionaryModule = state.activeDictionaryModule
        activeDictionaryModuleName = state.activeDictionaryModuleName
        activeGeneralBookModule = state.activeGeneralBookModule
        activeGeneralBookModuleName = state.activeGeneralBookModuleName
        activeMapModule = state.activeMapModule
        activeMapModuleName = state.activeMapModuleName
        moduleBookList = state.moduleBookList
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

        swordCoordinator.applyBaseOptions(to: mgr)
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

        // Restore general book module or Android synthetic Multi document
        if pm.generalBookDocument == AndroidSpecialDocumentIdentity.multiDocumentInitials {
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = AndroidSpecialDocumentIdentity.multiDocumentInitials
            currentGeneralBookKey = pm.generalBookKey
            logger.info("Restored Android synthetic Multi document")
        } else if let savedGB = pm.generalBookDocument,
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
        navigationCoordinator.restoreSavedPosition(
            BibleReaderNavigationPosition(
                book: currentBook,
                chapter: currentChapter,
                verse: currentVerse
            )
        ) { [weak self] book, chapter, verse in
            guard let self else { return nil }
            return self.verseOrdinal(
                osisBookId: self.osisBookId(for: book),
                chapter: chapter,
                verse: verse
            )
        }
        logger.info("Restored position: \(self.currentBook) \(self.currentChapter):\(self.currentVerse)")
    }

    /// Apply SWORD global options based on current display settings.
    private func applySwordOptions() {
        guard let mgr = swordManager else { return }
        swordCoordinator.applyDisplayOptions(to: mgr, settings: displaySettings)
    }

    // MARK: - Public Navigation API

    /// Navigate to a specific book and chapter. Sends content to the WebView.
    public func navigateTo(book: String, chapter: Int, verse: Int? = nil) {
        navigationCoordinator.navigateTo(
            book: book,
            chapter: chapter,
            verse: verse,
            context: makeNavigationContext()
        )
    }

    /// Navigate to the next chapter, wrapping to the next book if needed.
    public func navigateNext() {
        navigationCoordinator.navigateNext(context: makeNavigationContext())
    }

    /// Navigate to the previous chapter, wrapping to the previous book if needed.
    public func navigatePrevious() {
        navigationCoordinator.navigatePrevious(context: makeNavigationContext())
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
        navigationCoordinator.hasNext(context: makeNavigationContext())
    }

    /// Whether there's a previous chapter available.
    public var hasPrevious: Bool {
        navigationCoordinator.hasPrevious(context: makeNavigationContext())
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
        let deferredSynchronizedScrollOrdinal = synchronizedScrollCoordinator
            .consumeDeferredClientReadyOrdinalForReplay()
        loadRecentLabels()
        applyNightModeBackground()
        updateActiveLanguages()
        bridge.emit(event: "set_config", data: buildConfigJSON())
        reloadVisibleDocumentAfterClientReady()
        if let deferredSynchronizedScrollOrdinal {
            synchronizedScrollCoordinator.markClientReadyReplayPending(
                ordinal: deferredSynchronizedScrollOrdinal
            )
        }
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
        if let pendingClientReadyRequest = specialDocumentCoordinator.consumePendingClientReadyRequest() {
            emitTransientMultiDocument(pendingClientReadyRequest)
            return
        }

        if showingMyNotes {
            let pendingJumpOrdinal = pendingClientReadyMyNotesJumpOrdinal
            pendingClientReadyMyNotesJumpOrdinal = nil
            loadMyNotesDocument(jumpToOrdinal: pendingJumpOrdinal)
            return
        }

        if showingStudyPad, let activeStudyPadLabelId {
            let pendingBookmarkId = pendingClientReadyStudyPadBookmarkId
            pendingClientReadyStudyPadBookmarkId = nil
            loadStudyPadDocument(labelId: activeStudyPadLabelId, bookmarkId: pendingBookmarkId)
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
     - preserves compatibility for legacy transient dictionary rendered-content labels
     - invokes `onPersistState` so the owning view can save SwiftData changes
     */
    public func bridge(_ bridge: BibleBridge, saveState state: String) {
        activeWindow?.pageManager?.jsState = state
        updateDefinitionRenderedModuleIfNeeded(from: state)
        onPersistState?()
    }

    /**
     Preserves legacy dictionary rendered-content labels when Vue tab-selection state changes.

     Android exposes Strong's and dictionary result pages as the synthetic general-book `Multi`
     document, and Swift now keeps that durable native identity stable while Vue owns the
     per-dictionary tab selection inside the document. This method remains only for older
     dictionary-rendered transient state that can exist during migration or tests of the legacy
     token format.

     - Parameter state: Serialized Vue state from `android.saveState(...)`.
     - Returns: No direct return value; legacy dictionary `renderedContentState` is updated when the
       state applies.
     - Side effects: May update legacy dictionary `renderedContentState`.
     - Failure modes: Android `Multi` content, invalid JSON, or missing selected dictionary fields
       leave the current rendered-content state unchanged.
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
        bridgeEventRouter.reportModalState(isOpen)
        webModalIsOpen = bridgeEventRouter.webModalIsOpen
    }

    /**
     Receives web-client focus changes for text inputs.

     - Parameters:
       - bridge: Bridge reporting the focus transition.
       - focused: Whether a text input is currently focused in the web client.

     - Note: iOS currently does not need this signal, so the callback is intentionally a no-op.
     */
    public func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool) {
        bridgeEventRouter.reportInputFocus(focused)
    }

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
        bridgeEventRouter.handleKeyDown(key)
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
        bridgeEventRouter.closeWebModalIfNeeded()
    }

    // MARK: - BibleBridgeDelegate — Navigation & Scroll

    /**
     Tracks visible-verse changes reported by the web client during scrolling.

     - Parameters:
       - bridge: Bridge reporting the scroll position change.
       - ordinal: Approximate verse ordinal currently near the viewport focus.
       - key: Document OSIS ref such as `Gen.1` or `Gen.1.5` used to infer chapter changes,
         or an empty value when the web client can only report ordinal telemetry.

     Side effects:
     - updates scroll-restoration state and persists chapter/book changes to the page manager
     - notifies the window manager for synchronized scrolling only when this pane is already active
       from explicit user interaction, the callback did not acknowledge sync-origin feedback, and
       the visible Bible position actually changed
     */
    public func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool) {
        let previousBook = currentBook
        let previousChapter = currentChapter
        let previousVerse = currentVerse
        let acknowledgedSynchronizedScroll = synchronizedScrollCoordinator
            .acknowledgeVisibleOrdinal(ordinal)
        navigationCoordinator.updateVisiblePosition(
            ordinal: ordinal,
            key: key,
            atChapterTop: atChapterTop,
            context: makeNavigationContext()
        )

        let visibleVerseChanged = previousBook != currentBook
            || previousChapter != currentChapter
            || previousVerse != currentVerse
        let shouldBroadcastSynchronizedScroll = !acknowledgedSynchronizedScroll
            && visibleVerseChanged
            && computeIsActiveWindow()

        // Notify WindowManager for synchronized scrolling
        if shouldBroadcastSynchronizedScroll, let window = activeWindow {
            windowManagerRef?.notifyVerseChanged(sourceWindow: window, ordinal: ordinal, key: key)
        }
    }

    /**
     Records explicit user interaction in this pane and makes it eligible to become the sync source.

     Bridge messages that are not classified as passive, native taps, and drag-start callbacks all
     represent direct user intent in the pane. Android hands synchronized-scroll source ownership to
     the touched pane through `BibleView.onTouchEvent`; iOS mirrors that by clearing any
     secondary-scroll feedback guard before invoking the focus callback.

     Side effects:
     - clears pending synchronized-scroll feedback state
     - invokes `onInteraction`, which usually focuses this pane in `WindowManager`

     Failure modes:
     - if no `onInteraction` callback is installed, suppression is still cleared but no external
       focus state is changed
     */
    func handleUserInteraction() {
        synchronizedScrollCoordinator.clearForUserInteraction()
        onInteraction?()
    }

    /**
     Indicates whether a native vertical scroll delta should be forwarded as user-origin input.

     UIKit can report `UIScrollView` deltas while WebKit is applying a synchronized secondary
     scroll. Those deltas are passive feedback, not a source-window handoff, until explicit user
     interaction clears the synchronized-scroll coordinator's feedback guard.

     - Returns: `true` when no synchronized secondary-scroll feedback guard is active.

     Side effects: none.

     Failure modes:
     - returns `false` for sync-origin programmatic scroll movement so pane hosts can avoid focusing
       or auto-hiding chrome from passive target-pane motion
     */
    func shouldTreatNativeScrollDeltaAsUserInteraction() -> Bool {
        synchronizedScrollCoordinator.shouldTreatNativeScrollDeltaAsUserInteraction
    }

    /**
     Scrolls this pane's WebView to a verse ordinal as a synchronized secondary-window update.

     - Parameter ordinal: SWORD/JSword ordinal to bring near the viewport top.

     Side effects:
     - updates this pane's native visible verse state so pre-ready content replay lands on the
       synchronized target, matching Android's inactive-window key update
     - emits `scroll_to_verse` to the Vue reader
     - records `ordinal` as the latest pending synchronized scroll acknowledgement once native
       sync state is applied, even if the WebView is temporarily detached

     Failure modes:
     - if the Vue client is not ready, no bridge event is emitted; the ordinal is deferred until
       `bridgeDidSetClientReady(_:)` replays the native content state
     - if the web view is not attached after client-ready, `BibleBridge` logs the failed JavaScript
       evaluation while the native sync-origin guard remains active until explicit user interaction
     - if no scroll callback is produced, feedback suppression remains active until explicit user
       interaction makes this pane a source again
     */
    public func scrollToOrdinal(_ ordinal: Int) {
        applySynchronizedScrollPosition(ordinal: ordinal)
        guard clientReady else {
            synchronizedScrollCoordinator.deferUntilClientReady(ordinal: ordinal)
            return
        }
        synchronizedScrollCoordinator.armSynchronizedFeedback(ordinal: ordinal)
        bridge.emit(event: "scroll_to_verse", data: "{\"ordinal\":\(ordinal),\"now\":false}")
    }

    /**
     Scrolls this pane to a synchronized source verse using this pane's own ordinal space.

     Android does not send a raw source ordinal to the target WebView. It updates the inactive
     window to the same verse key and then emits a target-local `scroll_to_verse` ordinal. iOS
     mirrors that by converting `(osisBookId, chapter, verse)` through the target controller's
     active module before scrolling.

     - Parameters:
       - osisBookId: Source verse OSIS book identifier.
       - chapter: Source verse chapter.
       - verse: Source verse number.

     Side effects:
     - arms synchronized-scroll feedback suppression
     - updates native target state and its page manager to the synchronized verse
     - emits `scroll_to_verse` only when the target chapter is already loaded
     - delegates cross-chapter changes to `navigateTo` so content loads before the WebView scrolls

     Failure modes:
     - returns without mutation when the target module cannot resolve the source book or verse
     */
    func scrollToSynchronizedVerse(osisBookId: String, chapter: Int, verse: Int) {
        guard let book = bookName(forOsisId: osisBookId),
              let targetOrdinal = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse) else {
            return
        }

        let alreadyShowingChapter = currentBook == book && currentChapter == chapter
        synchronizedScrollCoordinator.armSynchronizedFeedback(ordinal: targetOrdinal)

        if alreadyShowingChapter {
            applySynchronizedVersePosition(book: book, chapter: chapter, verse: verse, ordinal: targetOrdinal)
            guard clientReady else {
                synchronizedScrollCoordinator.deferUntilClientReady(ordinal: targetOrdinal)
                return
            }
            bridge.emit(event: "scroll_to_verse", data: "{\"ordinal\":\(targetOrdinal),\"now\":false}")
            return
        }

        navigateTo(book: book, chapter: chapter, verse: verse)
    }

    /**
     Navigates this pane as a synchronized secondary-window update.

     Cross-chapter synchronized movement cannot use `scroll_to_verse` because the target WebView
     may need new chapter content first. This method marks the upcoming navigation and resulting
     visible-verse callbacks as sync-origin feedback, resolves the source ordinal to a verse when
     possible, then delegates the actual content load to the normal navigation path.

     - Parameters:
       - book: Localized SWORD book name resolved from the source OSIS id.
       - chapter: Chapter number reported by the synchronized source key.
       - ordinal: SWORD/JSword ordinal reported by the source pane.

     Side effects:
     - arms synchronized feedback suppression before navigation
     - stores `ordinal` as the expected target callback
     - updates native navigation state and emits/reloads chapter content through `navigateTo`

     Failure modes:
     - if `ordinal` cannot be resolved to a verse in `book`, navigation falls back to the chapter
       top while feedback suppression remains active until explicit user interaction
     */
    func navigateToSynchronizedPosition(book: String, chapter: Int, ordinal: Int) {
        let verse = verseReference(book: book, ordinal: ordinal).flatMap { reference in
            reference.chapter == chapter ? reference.verse : nil
        }
        if let verse {
            scrollToSynchronizedVerse(osisBookId: osisBookId(for: book), chapter: chapter, verse: verse)
            return
        }

        synchronizedScrollCoordinator.armSynchronizedFeedback(ordinal: ordinal)
        navigateTo(book: book, chapter: chapter, verse: verse)
    }

    /**
     Updates native pane state for a synchronized secondary scroll without treating it as focus input.

     - Parameter ordinal: SWORD/JSword ordinal received from the source synchronized pane.

     Side effects:
     - updates `currentChapter`, `currentVerse`, and the active `PageManager` Bible book/chapter/verse
       position when the ordinal resolves in the current book
     - schedules normal visible-verse persistence so workspace state follows Android's inactive key
       synchronization

     Failure modes:
     - invalid ordinals or ordinals that cannot be resolved by the active module leave state unchanged
     */
    private func applySynchronizedScrollPosition(ordinal: Int) {
        guard let reference = verseReference(book: currentBook, ordinal: ordinal) else { return }
        applySynchronizedVersePosition(
            book: currentBook,
            chapter: reference.chapter,
            verse: reference.verse,
            ordinal: ordinal
        )
    }

    /**
     Updates native synchronized target state to an already-converted verse ordinal.

     - Parameters:
       - book: Target controller's local book name.
       - chapter: Target chapter.
       - verse: Target verse.
       - ordinal: Target-local ordinal for the verse.

     Side effects:
     - updates reader state and page-manager Bible position
     - stores the target ordinal for content replay
     - schedules normal visible-verse persistence

     Failure modes: none.
     */
    private func applySynchronizedVersePosition(book: String, chapter: Int, verse: Int, ordinal: Int) {
        navigationCoordinator.applySynchronizedVersePosition(
            book: book,
            chapter: chapter,
            verse: verse,
            ordinal: ordinal,
            context: makeNavigationContext()
        )
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
        guard let candidate = infiniteScrollCoordinator.previousCandidate(
            previousBook: { [self] in previousBook(before: $0) },
            chapterCount: { [self] in chapterCount(for: $0) }
        ) else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        if let document = loadChapterJSON(book: candidate.book, chapter: candidate.chapter) {
            infiniteScrollCoordinator.commitPrevious(candidate)
            bridge.sendResponse(callId: callId, value: document)
        } else {
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
        guard let candidate = infiniteScrollCoordinator.nextCandidate(
            nextBook: { [self] in nextBook(after: $0) },
            chapterCount: { [self] in chapterCount(for: $0) }
        ) else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        if let document = loadChapterJSON(book: candidate.book, chapter: candidate.chapter) {
            infiniteScrollCoordinator.commitNext(candidate)
            bridge.sendResponse(callId: callId, value: document)
        } else {
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
        annotationBridgeHandler.addOrUpdateBibleBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote,
            wholeVerse: wholeVerse,
            startOffset: startOffset,
            endOffset: endOffset
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
        annotationBridgeHandler.addBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote
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
        annotationBridgeHandler.addGenericBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote
        )
    }

    /// Creates a Bible paragraph-break bookmark requested from the web client.
    public func bridge(_ bridge: BibleBridge, addParagraphBreakBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        annotationBridgeHandler.addParagraphBreakBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Creates a generic paragraph-break bookmark requested from the web client.
    public func bridge(_ bridge: BibleBridge, addGenericParagraphBreakBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int) {
        annotationBridgeHandler.addGenericParagraphBreakBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
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
        annotationBridgeHandler.removeBookmark(bridge: bridge, bookmarkId: bookmarkId)
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
        annotationBridgeHandler.removeGenericBookmark(bridge: bridge, bookmarkId: bookmarkId)
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
        annotationBridgeHandler.saveBookmarkNote(bridge: bridge, bookmarkId: bookmarkId, note: note)
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
        annotationBridgeHandler.assignLabels(bookmarkId: bookmarkId)
    }

    /// Refresh bookmark data in Vue.js after label changes (called after LabelAssignmentView dismisses).
    public func refreshBookmarkInVueJS(bookmarkId: UUID) {
        annotationBridgeHandler.refreshBookmark(bridge: bridge, bookmarkId: bookmarkId)
    }

    /**
     Toggles one label assignment on a bookmark and re-emits the updated bookmark state.
     */
    public func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String) {
        annotationBridgeHandler.toggleBookmarkLabel(bridge: bridge, bookmarkId: bookmarkId, labelId: labelId)
    }

    /**
     Removes one label assignment from a bookmark and re-emits the updated bookmark state.
     */
    public func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {
        annotationBridgeHandler.removeBookmarkLabel(bridge: bridge, bookmarkId: bookmarkId, labelId: labelId)
    }

    /**
     Sets the primary label used to style a bookmark in Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {
        annotationBridgeHandler.setPrimaryLabel(bridge: bridge, bookmarkId: bookmarkId, labelId: labelId)
    }

    /**
     Updates whether a bookmark should highlight whole verses or a text-range selection.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {
        annotationBridgeHandler.setBookmarkWholeVerse(bridge: bridge, bookmarkId: bookmarkId, value: value)
    }

    /**
     Updates the custom icon attached to a bookmark.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {
        annotationBridgeHandler.setBookmarkCustomIcon(bridge: bridge, bookmarkId: bookmarkId, value: value)
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
        annotationBridgeHandler.createNewStudyPadEntry(
            bridge: bridge,
            labelId: labelId,
            entryType: entryType,
            afterEntryId: afterEntryId
        )
    }

    /**
     Deletes one StudyPad text entry and emits the resulting reordered state.
     */
    public func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String) {
        annotationBridgeHandler.deleteStudyPadEntry(bridge: bridge, studyPadId: studyPadId)
    }

    /**
     Updates StudyPad entry metadata such as indent level or order number from a Vue.js payload.
     */
    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String) {
        annotationBridgeHandler.updateStudyPadTextEntry(bridge: bridge, data: data)
    }

    /**
     Persists edited text for one StudyPad text entry.
     */
    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {
        annotationBridgeHandler.updateStudyPadTextEntryText(bridge: bridge, id: id, text: text)
    }

    /**
     Persists reordered StudyPad rows and bookmark associations for one label.
     */
    public func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String) {
        annotationBridgeHandler.updateOrderNumber(bridge: bridge, labelId: labelId, data: data)
    }

    /**
     Updates one `BibleBookmarkToLabel` association from a JSON payload emitted by Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String) {
        annotationBridgeHandler.updateBookmarkToLabel(bridge: bridge, data: data)
    }

    /**
     Updates one `GenericBookmarkToLabel` association from a JSON payload emitted by Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String) {
        annotationBridgeHandler.updateGenericBookmarkToLabel(bridge: bridge, data: data)
    }

    /**
     Persists an optional bookmark edit action configured in the web client.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String) {
        annotationBridgeHandler.setBookmarkEditAction(bridge: bridge, bookmarkId: bookmarkId, value: value)
    }

    /**
     Tracks whether the embedded web client is currently editing content.
     */
    public func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {
        annotationBridgeHandler.setEditing(bridge: bridge, enabled: enabled)
    }

    /**
     Persists the current insertion cursor position for a StudyPad label.
     */
    public func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int) {
        annotationBridgeHandler.setStudyPadCursor(bridge: bridge, labelId: labelId, orderNumber: orderNumber)
    }

    // MARK: - BibleBridgeDelegate — Selection

    /**
     Records the latest text selection reported by the web client and enables native action mode UI.
     */
    public func bridge(_ bridge: BibleBridge, selectionChanged text: String) {
        selectionCoordinator.selectionChanged(text)
        bridge.emit(event: "set_action_mode", data: "true")
    }

    /**
     Clears native selection state when the web client deselects text.
     */
    public func bridgeSelectionCleared(_ bridge: BibleBridge) {
        clearNativeSelectionState()
        bridge.emit(event: "set_action_mode", data: "false")
    }

    // MARK: - Selection Actions

    /**
     Builds the current page context used by pure native-selection payload decisions.

     - Returns: A snapshot of the page identity and Bible-reference eligibility at action time.
     - Side effects: None.
     - Failure modes: None.
     */
    private func selectionPageContext() -> BibleReaderSelectionPageContext {
        BibleReaderSelectionPageContext(
            canUseBibleReferenceActions: canUseBibleReferenceActions,
            currentBook: currentBook,
            currentChapter: currentChapter,
            activeModuleName: activeModuleName
        )
    }

    /**
     Clears native selection bookkeeping without emitting bridge action-mode events.

     Document replacement paths already clear the WebView selection separately when needed. This
     helper centralizes the native state reset so those paths do not mutate selection fields owned by
     the coordinator.

     - Side effects: Mutates only native selection state.
     - Failure modes: None.
     */
    private func clearNativeSelectionState() {
        selectionCoordinator.clearSelection()
    }

    /**
     Queries the active web selection using Android-compatible selection metadata.

     The Vue `bibleView.querySelection()` contract includes `bookInitials`, `osisRef`, ordinals, and
     offsets for both Bible `verseInfo` and generic `ordinalInfo` selections. Native selection
     actions use those fields to choose the Bible bookmark/share path versus the generic bookmark
     path. When the richer bridge API is unavailable, the method falls back to the lightweight DOM
     query, which only supplies text and ordinals and is therefore unsuitable for generic bookmarks.

     - Returns: Selection text plus optional document identity, ordinals, and offsets, or `nil` when
       no usable selection exists.
     - Side effects: Executes JavaScript in the active web view and may log bridge query failures.
     - Failure modes: Malformed JSON, JavaScript exceptions, missing web views, and collapsed
       selections return `nil` or the lightweight fallback rather than throwing.
     */
    @MainActor
    private func querySelectionDetails() async -> (
        text: String,
        bookInitials: String?,
        osisRef: String?,
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
                    let bookInitials = dict["bookInitials"] as? String
                    let osisRef = dict["osisRef"] as? String
                    let startOrdinal = asInt(dict["startOrdinal"])
                    let endOrdinal = asInt(dict["endOrdinal"])
                    let startOffset = asInt(dict["startOffset"])
                    let endOffset = asInt(dict["endOffset"])

                    if !text.isEmpty || startOrdinal != nil || endOrdinal != nil {
                        return (text, bookInitials, osisRef, startOrdinal, endOrdinal, startOffset, endOffset)
                    }
                }
            } catch {
                logger.debug("querySelectionDetails JS error: \(error.localizedDescription)")
            }
        }

        if let fallback = await bridge.querySelection() {
            return (fallback.text, nil, nil, fallback.startOrdinal, fallback.endOrdinal, nil, nil)
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
            if !canUseBibleReferenceActions {
                guard let bookInitials = sel.bookInitials,
                      let osisRef = sel.osisRef,
                      let startOrdinal = sel.startOrdinal else {
                    logger.warning("Generic selection bookmark ignored because selection metadata is incomplete")
                    return
                }
                addGenericBookmark(
                    bookInitials: bookInitials,
                    osisRef: osisRef,
                    startOrdinal: startOrdinal,
                    endOrdinal: sel.endOrdinal ?? startOrdinal,
                    addNote: false
                )
                bridge.clearSelection()
                return
            }

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

    /**
     Creates a generic bookmark for a non-Bible native selection.

     Android's generic selection action uses the selected document's `bookInitials`, `osisRef`, and
     ordinals instead of deriving a Bible reference from the active page manager. Native iOS selection
     actions share that same route so links-window `Multi`, dictionary, and general-book content do
     not produce stale Bible bookmarks.

     - Parameters:
       - bookInitials: Module initials from the selected document's DOM metadata.
       - osisRef: Document/key reference from the selected document's DOM metadata.
       - startOrdinal: Inclusive start ordinal for the selected generic content.
       - endOrdinal: Inclusive end ordinal for the selected generic content.
       - addNote: Whether the bookmark modal should open with note editing active.
     - Side effects: Inserts a generic bookmark through the annotation bridge coordinator, emits
       bookmark update events to Vue, and may persist workspace settings or refresh labels/config.
     - Failure modes: Returns without side effects when bookmark services are unavailable.
     */
    private func addGenericBookmark(
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool
    ) {
        annotationBridgeHandler.addGenericBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote
        )
    }

    /**
     Builds the text payload used by the native copy action.

     Bible pages mirror Android's verse-selection copy behavior by appending the active Bible
     reference and module. Android `Multi` link-result pages are special general-book documents, so
     they must copy only the selected text instead of inventing a stale Bible reference from the pane
     that opened the links window.

     - Returns: The text to write to the system pasteboard, or `nil` when there is no selection.
     - Side effects: None; callers perform pasteboard writes and selection clearing.
     - Failure modes: Returns `nil` for an empty native selection.
     */
    func selectionCopyTextForCurrentPage() -> String? {
        selectionCoordinator.copyText(context: selectionPageContext())
    }

    /**
     Copies the current selection to the system clipboard.

     The payload is delegated to `selectionCopyTextForCurrentPage()` so Android `Multi` links-window
     pages and normal Bible pages share the same eligibility rules across test and production code.
     The method writes to the platform pasteboard and clears the WebView selection after a successful
     copy.
     */
    func copySelection() {
        guard let copyText = selectionCopyTextForCurrentPage() else { return }
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
        guard let shareText = selectionCoordinator.shareText(context: selectionPageContext()) else { return }
        onShareVerseText?(shareText)
        bridge.clearSelection()
    }

    /// Speak the selected text.
    func speakSelection() {
        Task { @MainActor in
            guard let sel = await querySelectionDetails(), !sel.text.isEmpty else { return }
            guard let service = speakService else { return }
            if canUseBibleReferenceActions {
                service.currentTitle = "\(currentBook) \(currentChapter)"
                service.currentSubtitle = activeModuleName
            } else {
                service.currentTitle = sel.bookInitials ?? activeGeneralBookModuleName ?? activeCommentaryModuleName ?? activeModuleName
                service.currentSubtitle = sel.osisRef
            }
            let lang = activeModule?.info.language
                ?? activeCommentaryModule?.info.language
                ?? activeGeneralBookModule?.info.language
                ?? "en"
            let speechLang = lang.hasPrefix("en") ? "en-US" : lang
            service.speak(text: sel.text, language: speechLang)
            bridge.clearSelection()
        }
    }

    /// Compare translations for the selected verse(s) through the Vue document pipeline.
    func compareSelection() {
        guard canUseBibleReferenceActions else { return }
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
        guard let url = selectionCoordinator.webSearchURL() else { return }
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

     - Parameters: None; the method reads the current selection from the selection coordinator.
     - Returns: No direct return value; a successful lookup emits a Vue document payload through
       the current pane or configured links-window target.
     - Side effects: May show a localized "not found" toast, route a dictionary document payload,
       and clear the active WebView selection after a successful lookup.
     - Failure modes: Empty selections, empty normalized queries, or missing dictionary payloads
       exit without navigation and show the existing not-found toast where user-facing feedback is
       required.
     */
    func lookupSelectionInDictionaries() {
        guard let query = selectionCoordinator.normalizedDictionaryQuery() else { return }
        guard !query.isEmpty else {
            onShowToast?(String(
                localized: "word_not_found_in_dictionaries",
                defaultValue: "Word not found in any dictionary"
            ))
            return
        }
        guard let multiDocJSON = wordLookupDocumentBuilder()
            .buildWordLookupMultiDocumentJSON(query: query) else {
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
    var hasActiveSelection: Bool { selectionCoordinator.hasActiveSelection }
    /// The currently selected text.
    var selectedText: String { selectionCoordinator.selectedText }
    /// Whether any plain word-lookup dictionaries are currently available.
    var hasWordLookupDictionaries: Bool { wordLookupDocumentBuilder().hasWordLookupDictionaries }

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

        guard let documentJSON = myDocumentCoordinator.documentJSON(document: document, page: page) else {
            logger.error("Failed to serialize My Documents page JSON for \(document.initials, privacy: .public)")
            return false
        }

        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        currentCategory = .generalBook
        myDocumentCoordinator.setActivePage(bookInitials: bookInitials, pageKey: pageKey)
        setRenderedContentState(
            category: .generalBook,
            moduleName: document.initials,
            book: document.name,
            key: page.pageKey
        )

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

        onShareVerseText?(myDocumentCoordinator.shareText(for: payload))
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
        guard let pageKey = myDocumentCoordinator.activePageKey(for: bookInitials) else {
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
        guard myDocumentCoordinator.isActiveDocument(context) else {
            return
        }

        if myDocumentCoordinator.isActivePage(context) {
            myDocumentCoordinator.clearActivePage()
            currentCategory = .bible
            if let pageManager = activeWindow?.pageManager {
                pageManager.currentCategoryName = DocumentCategory.bible.pageManagerKey
            }
            onPersistState?()
            loadCurrentChapter()
            return
        }

        if let pageKey = myDocumentCoordinator.activePageKey(for: context.bookInitials) {
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
        progressBridgeCoordinator.memorize(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Marks the selected verse range as memorized in local iOS memorization state.
     */
    public func bridge(_ bridge: BibleBridge, markAsMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        progressBridgeCoordinator.markAsMemorized(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Adds the selected verse range to local iOS memorization targets.
     */
    public func bridge(_ bridge: BibleBridge, addMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        progressBridgeCoordinator.addMemorizationTarget(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Removes the selected verse range from local iOS memorization targets.
     */
    public func bridge(_ bridge: BibleBridge, removeMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        progressBridgeCoordinator.removeMemorizationTarget(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Removes the selected verse range from local iOS memorized ranges.
     */
    public func bridge(_ bridge: BibleBridge, unmarkMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        progressBridgeCoordinator.unmarkMemorized(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Records one chapter-read history row in local iOS reading-progress state.
     */
    public func bridge(_ bridge: BibleBridge, recordChapterRead bookInitials: String, startOrdinal: Int, chapter: Int, source: String) {
        progressBridgeCoordinator.recordChapterRead(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            chapter: chapter,
            source: source
        )
    }

    /**
     Opens native chapter-read history for the active Bible chapter identity.
     */
    public func bridge(_ bridge: BibleBridge, openChapterReadHistory bookInitials: String, startOrdinal: Int, chapter: Int) {
        progressBridgeCoordinator.openChapterReadHistory(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            chapter: chapter
        )
    }

    /**
     Opens native reading-progress UI using Android's numeric tab positions.
     */
    public func bridge(_ bridge: BibleBridge, openReadingProgress tab: Int) {
        progressBridgeCoordinator.openReadingProgress(tab: tab)
    }

    /**
     Opens native reading-progress settings UI.
     */
    public func bridgeDidRequestOpenReadingProgressSettings(_ bridge: BibleBridge) {
        progressBridgeCoordinator.openReadingProgressSettings()
    }

    /**
     Persists Android-compatible reading-progress settings and notifies the embedded client.
     */
    public func bridge(_ bridge: BibleBridge, setReadingProgressSettings json: String) {
        progressBridgeCoordinator.setReadingProgressSettings(json: json)
    }

    /**
     Clears chapter-read status for the active reading-progress cycle.
     */
    public func bridge(_ bridge: BibleBridge, unmarkChapterRead bookInitials: String, startOrdinal: Int, chapter: Int) {
        progressBridgeCoordinator.unmarkChapterRead(bookInitials: bookInitials, startOrdinal: startOrdinal, chapter: chapter)
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
     Loads the My Notes document for the current chapter into the WebView.

     - Parameter jumpToOrdinal: Optional rendered My Notes row ordinal to scroll to after loading.
     - Side effects: Marks My Notes as the visible reader document, clears competing StudyPad and
       editing state, rebuilds the chapter's note-backed bookmarks, emits the My Notes document to
       Vue when the client is ready, or stores the request for client-ready replay when it is not.
     - Failure modes: If the current chapter range cannot be resolved, logs the failure and leaves
       the visible My Notes intent in place for the native header/state export.
     */
    public func loadMyNotesDocument(jumpToOrdinal: Int? = nil) {
        guard clientReady else {
            pendingClientReadyMyNotesJumpOrdinal = jumpToOrdinal
            showingMyNotes = true
            showingStudyPad = false
            activeStudyPadLabelId = nil
            activeStudyPadLabelName = nil
            editingInWebView = false
            clearNativeSelectionState()
            return
        }
        pendingClientReadyMyNotesJumpOrdinal = nil
        annotationDocumentLoader().loadMyNotesDocument(
            currentBook: currentBook,
            currentChapter: currentChapter,
            osisBookId: osisBookId(for: currentBook),
            jumpToOrdinal: jumpToOrdinal,
            chapterRange: { [weak self] in self?.currentChapterOrdinalRange() },
            bookmarks: { [weak self] in self?.currentChapterMyNotesBookmarks() ?? [] },
            bookmarkPayload: { [self] bookmark in buildBookmarkJSONForMyNotes(bookmark) },
            prepareVisibleState: { [weak self] in
                self?.showingMyNotes = true
                self?.showingStudyPad = false
                self?.activeStudyPadLabelId = nil
                self?.activeStudyPadLabelName = nil
                self?.editingInWebView = false
                self?.clearNativeSelectionState()
            }
        )
    }

    /**
     Opens the bundled Memorize document for the selected verse range.

     The document is backed by the same local `MemorizationProgressStore` state that the bridge
     mutation methods update. The current frontend renders the practice modes from `texts`; the
     extra metadata keeps the payload aligned with Android's document shape for future client-side
     target/memorized controls.
     */
    private func loadMemorizeDocument(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        guard clientReady else { return }
        annotationDocumentLoader().loadMemorizeDocument(
            request: MemorizeDocumentRequest(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                activeModuleName: activeModuleName,
                currentBook: currentBook,
                currentChapter: currentChapter,
                osisBookId: osisBookId(for: currentBook),
                activeModule: activeModule,
                verseReference: { [weak self] book, ordinal in
                    self?.verseReference(book: book, ordinal: ordinal)
                },
                parseVerseKey: { [weak self] key in
                    self?.parseVerseKey(key)
                },
                placeholderVerseText: { book, chapter, verse in
                    Self.placeholderVerseText(book: book, chapter: chapter, verse: verse)
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
                },
                readingProgressSettings: { [progressBridgeCoordinator] in
                    progressBridgeCoordinator.readingProgressSettingsPayload()
                }
            ),
            prepareVisibleState: { [weak self] in
                self?.showingMyNotes = false
                self?.showingStudyPad = false
                self?.activeStudyPadLabelId = nil
                self?.activeStudyPadLabelName = nil
                self?.editingInWebView = false
                self?.clearNativeSelectionState()
            }
        )
    }

    /// Return from My Notes to the Bible text view.
    public func returnFromMyNotes() {
        guard showingMyNotes else { return }
        loadCurrentChapter()
        myNotesMutationRevision += 1
    }

    /**
     Loads a StudyPad document for a label into the WebView.

     Android preserves a StudyPad document selection made while the shared reader client is still
     bootstrapping, then emits the journal document once the client is ready. iOS follows the same
     contract: valid pre-ready StudyPad selections update native visible state immediately and keep
     the optional target bookmark for `setup_content` replay.

     - Parameters:
       - labelId: Persisted StudyPad label to render.
       - bookmarkId: Optional bookmark row to scroll to after Vue renders the document.
     - Side effects: Mutates visible StudyPad/My Notes state, may clear native selection, and emits
       annotation document bridge events when `clientReady` is true.
     - Failure modes: Missing bookmark persistence or a stale label leaves the current reader state
       unchanged and emits no bridge event.
     */
    public func loadStudyPadDocument(labelId: UUID, bookmarkId: UUID? = nil) {
        guard clientReady else {
            guard let labelName = bookmarkService?.label(id: labelId)?.name else { return }
            showingMyNotes = false
            showingStudyPad = true
            activeStudyPadLabelId = labelId
            activeStudyPadLabelName = labelName
            pendingClientReadyStudyPadBookmarkId = bookmarkId
            editingInWebView = false
            clearNativeSelectionState()
            return
        }
        pendingClientReadyStudyPadBookmarkId = nil
        annotationDocumentLoader().loadStudyPadDocument(
            labelId: labelId,
            bookmarkId: bookmarkId,
            labelPayload: { [self] label in buildLabelData(label) },
            bookmarkPayload: { [self] bookmark in buildBookmarkJSONForStudyPad(bookmark) },
            genericBookmarkPayload: { [self] bookmark in buildGenericBookmarkJSONForStudyPad(bookmark) },
            bibleBookmarkToLabelPayload: { [self] relation in buildBibleBookmarkToLabelJSON(relation) },
            genericBookmarkToLabelPayload: { [self] relation in buildGenericBookmarkToLabelJSON(relation) },
            studyPadEntryPayload: { [self] entry in buildStudyPadEntryJSON(entry) },
            prepareVisibleState: { [weak self] labelName in
                self?.showingMyNotes = false
                self?.showingStudyPad = true
                self?.activeStudyPadLabelId = labelId
                self?.activeStudyPadLabelName = labelName
                self?.editingInWebView = false
                self?.clearNativeSelectionState()
            }
        )
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
        guard let route = externalLinkRouter.route(for: link) else { return }
        handleExternalLinkRoute(route)
    }

    /**
     Executes a typed Android-compatible external link route for this reader pane.

     `BibleReaderExternalLinkRouter` owns pure parsing and classification. This method owns the
     side effects Android performs through `LinkControl`: navigation, transient `MultiDocument`
     emission, downloads presentation, EPUB jumps, My Notes, StudyPad, and platform URL opening.

     - Parameter route: Classified route generated from a bridge link.
     - Side effects: May navigate the active pane, emit transient documents, invoke owner callbacks,
       or open platform URLs.
     - Failure modes: Invalid references or payload-build failures are ignored, matching Android's
       no-op behavior for unresolved links.
     */
    private func handleExternalLinkRoute(_ route: BibleReaderExternalLinkRouter.Route) {
        switch route {
        case let .definition(strongs, robinson):
            logger.info("handleExternalLinkRoute.definition: strongs=\(strongs), robinson=\(robinson)")
            guard let multiDocJSON = buildStrongsMultiDocJSON(
                strongs: strongs,
                robinson: robinson,
                stateJSON: currentStrongsDocumentStateJSON()
            ) else {
                return
            }
            openDefinitionDocument(
                multiDocJSON,
                renderedBook: "Strongs",
                renderedKey: "strongs"
            )
        case let .findAllOccurrences(name):
            onShowStrongsSearch?(name)
        case .errorReport:
            handleErrorReportLink()
        case let .epubReference(book, toKey, toId):
            bridge(self.bridge, openEpubLink: book, toKey: toKey, toId: toId)
        case let .downloads(searchText):
            bridgeEventRouter.requestOpenDownloads(searchText: searchText)
        case let .myNotes(osisRef, ordinal):
            if let osisRef, let ref = parseOsisReferences(osisRef).first {
                navigateTo(book: ref.book, chapter: ref.chapter, verse: ref.verse)
                loadMyNotesDocument(jumpToOrdinal: ordinal)
            } else {
                loadMyNotesDocument(jumpToOrdinal: ordinal)
            }
        case let .studyPad(labelId, bookmarkId):
            loadStudyPadDocument(labelId: labelId, bookmarkId: bookmarkId)
        case let .osisReferences(values):
            handleOsisReferenceValues(values)
        case let .multiReferences(values):
            handleMultiReferenceValues(values)
        case let .swordReference(ref), let .osisNavigation(ref):
            _ = navigateToOsisRef(ref)
        case let .platformURL(url):
            openPlatformURL(url)
        }
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
        BibleReaderBridgeEventRouter.downloadSearchText(from: link)
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
     Renders a Strong's or dictionary result through the shared document pipeline.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload already shaped for Vue.
       - renderedBook: Caller-provided legacy label. It is intentionally ignored for native page
         identity because Android exposes Strong's and dictionary result documents as `Multi`.
       - renderedKey: Accessibility/test-state key token for the transient result.
     - Returns: No direct return value; the embedded document client receives an `add_documents`
       event.
     - Side effects: Replaces the current web document with the supplied payload and persists the
       destination window as Android's `general_book` + `Multi` fake document. The dictionary module
       selection remains inside the Vue `MultiDocument`; it does not become the native window's
       document identity.
     - Failure modes: Invalid JSON is forwarded unchanged to the Vue bridge, matching the existing
       transient document contract.
     */
    func loadDefinitionDocument(_ documentJSON: String, renderedBook _: String, renderedKey: String) {
        loadTransientMultiDocument(
            documentJSON,
            renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            renderedKey: renderedKey,
            renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(from: documentJSON)
        )
    }

    /**
     Routes a definition-style transient document through the pane owner when possible.

     - Parameters:
       - documentJSON: Serialized `MultiDocument` payload already shaped for Vue.
       - renderedBook: Legacy label retained for the existing routing callback; destination
         controllers normalize native identity to Android's `Multi` document.
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

    /**
     Builds the Android-style Strong's `MultiDocument` payload for bridge routing.

     The controller only supplies pane dependencies; lookup, module selection, linkification, and
     fallback-document construction are owned by `BibleReaderStrongsDocumentBuilder`.
     */
    func buildStrongsMultiDocJSON(strongs: [String], robinson: [String], stateJSON: String? = nil) -> String? {
        strongsDocumentBuilder().buildStrongsMultiDocumentJSON(
            strongs: strongs,
            robinson: robinson,
            stateJSON: stateJSON
        )
    }

    /**
     Creates the Strong's document builder bound to this pane's SWORD and settings state.
     */
    private func strongsDocumentBuilder() -> BibleReaderStrongsDocumentBuilder {
        BibleReaderStrongsDocumentBuilder(
            swordManager: swordManager,
            selectedPreferenceValues: { [weak self] key in
                self?.settingsStore?.getStringSet(key) ?? []
            },
            moduleDisplayLabel: BibleReaderStrongsDocumentBuilder.moduleDisplayLabel,
            localizedString: { key, defaultValue in
                Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
            }
        )
    }

    /**
     Creates the selected-word lookup document builder bound to this pane's SWORD and settings state.

     The controller keeps orchestration concerns while `BibleReaderWordLookupDocumentBuilder` owns
     Android-parity dictionary discovery, query normalization, and multi-document payload assembly.
     */
    private func wordLookupDocumentBuilder() -> BibleReaderWordLookupDocumentBuilder {
        BibleReaderWordLookupDocumentBuilder(
            swordManager: swordManager,
            disabledDictionaryNames: { [weak self] in
                Set(self?.settingsStore?.getStringSet(.disabledWordLookupDictionaries) ?? [])
            }
        )
    }

    /**
     Builds the compare document builder bound to this pane's SWORD and installed-module state.
     */
    private func compareDocumentBuilder() -> BibleReaderCompareDocumentBuilder {
        BibleReaderCompareDocumentBuilder(
            swordManager: swordManager,
            installedBibleModules: installedBibleModules,
            activeModuleName: activeModuleName
        )
    }

    /**
     Builds the background-safe Compare request for the active passage.

     The controller supplies live reader coordinates while `BibleReaderCompareDocumentBuilder` owns
     module ordering and payload construction.
     */
    private func makeBibleCompareDocumentRequest(
        startVerse: Int?,
        endVerse: Int?
    ) -> BibleReaderCompareDocumentBuilder.Request? {
        let bookName = currentBook
        let chapter = currentChapter
        let osisBookId = osisBookId(for: bookName)
        return compareDocumentBuilder().makeRequest(
            osisBookId: osisBookId,
            bookName: bookName,
            chapter: chapter,
            isNewTestament: isNewTestament(bookName),
            startVerse: startVerse,
            endVerse: endVerse
        )
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
        BibleReaderMultiReferenceDocumentBuilder(
            activeModule: activeModule,
            activeModuleName: activeModuleName,
            compatibilityOrdinal: { [weak self] chapter, verse in
                self?.compatibilityOrdinal(chapter: chapter, verse: verse)
                    ?? BibleChapterDocumentBuilder.ordinal(chapter: chapter, verse: verse)
            },
            isNewTestament: { [weak self] bookName in
                self?.isNewTestament(bookName) ?? Self.isNewTestament(bookName)
            }
        ).buildDocumentJSON(refs: refs)
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
        BibleReaderMultiReferenceDocumentBuilder.buildBibleMultiReferenceXML(
            ref: ref,
            module: module,
            ordinal: ordinal
        )
    }

    /**
     Performs dictionary lookup through the shared Android-parity dictionary validation helper.
     */
    private func lookupInModule(
        _ module: SwordModule,
        keyOptions: [String]
    ) -> BibleReaderStrongsDocumentBuilder.DictionaryLookupResult? {
        BibleReaderStrongsDocumentBuilder.lookupInModule(module, keyOptions: keyOptions)
    }

    /**
     Handles already-classified `osis://` query values from Android-compatible links.

     - Parameter values: Raw OSIS query values preserved in link order.
     - Side effects: Navigates a single reference or opens Android's transient `Multi` document for
       range/list references.
     - Failure modes: Invalid values are ignored; no side effects occur when nothing parses.
     */
    private func handleOsisReferenceValues(_ values: [String]) {
        guard let value = values.first else { return }
        let refs = parseOsisReferences(value)
        if refs.count == 1, let ref = refs.first {
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

    /**
     Handles already-classified `multi://` OSIS query values from Android-compatible links.

     - Parameter values: OSIS query values from the pseudo-link.
     - Side effects: Navigates a single parsed reference or opens a transient `Multi` document for
       multiple parsed references.
     - Failure modes: Invalid values are ignored; no side effects occur when nothing parses.
     */
    private func handleMultiReferenceValues(_ values: [String]) {
        let allRefs = values.flatMap(parseOsisReferences)
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
        bridgeEventRouter.requestOpenDownloads()
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

        if let osisRef = referenceResolver().resolveReference(trimmed) {
            let escaped = osisRef.replacingOccurrences(of: "\"", with: "\\\"")
            bridge.sendResponse(callId: callId, value: "\"\(escaped)\"")
            return
        }

        // Fallback: return null if we can't parse
        bridge.sendResponse(callId: callId, value: "null")
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

    /**
     Creates a reference resolver snapshot for the pane's current module state.

     The controller keeps ownership of active reader state, while `BibleReaderReferenceResolver`
     owns parsing and validation. Passing both the active module and its current book list lets the
     resolver preserve Android/JSword active-versification behavior and fail closed if active module
     metadata is unavailable.

     - Returns: Resolver configured with the active module, active book list, and no-module fallback
       canon.
     - Side effects: None; the returned resolver may later query SWORD while resolving references.
     - Failure modes: None during construction. Invalid module/book metadata is handled by resolver
       calls returning `nil`.
     */
    private func referenceResolver() -> BibleReaderReferenceResolver {
        BibleReaderReferenceResolver(
            activeModule: activeModule,
            bookList: bookList,
            fallbackBooks: Self.defaultBooks,
            fallbackVerseCount: Self.verseCount(for:chapter:)
        )
    }

    /**
     Navigate to a reference entered as human-readable text (e.g. "Genesis 1:1", "Gen 1", "Matt 5:3")
     or OSIS format (e.g. "Gen.1.1"). Returns true if navigation succeeded.
     */
    @discardableResult
    public func navigateToRef(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let resolver = referenceResolver()
        if let osisRef = resolver.resolveOsisRef(trimmed) {
            return navigateToOsisRef(osisRef)
        }

        if let osisRef = resolver.resolveHumanRef(trimmed) {
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
        bridgeEventRouter.showToast(text)
    }

    /**
     Forwards HTML sharing content to the host view so platform share UI can be presented.
     */
    public func bridge(_ bridge: BibleBridge, shareHtml html: String) {
        bridgeEventRouter.shareHtml(html)
    }

    /**
     Toggles whether one compare document should be hidden in the current compare session.
     */
    public func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String) {
        configurationCoordinator.toggleHiddenCompareDocument(documentId, activeWindow: activeWindow) { [weak self] in
            self?.onPersistState?()
        }
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
        configurationCoordinator.hiddenCompareDocuments(activeWindow: activeWindow)
    }

    /// Callback for fullscreen toggle requests (from double-tap in WebView).
    public var onToggleFullScreen: (() -> Void)?

    /**
     Handles double-tap fullscreen requests originating in the embedded web client.

     Failure modes:
     - returns without side effects when the user has disabled double-tap fullscreen in preferences
     */
    public func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge) {
        bridgeEventRouter.requestToggleFullScreen()
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
        clearNativeSelectionState()
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
            originalOrdinalRange: navigationCoordinator.originalNavigationOrdinalRange
        ) else { return }
        bridge.emit(event: "add_documents", data: document)

        infiniteScrollCoordinator.reset(book: currentBook, chapter: currentChapter)

        // Restore either the exact verse anchor or the chapter-top reading context.
        let restoreTarget = navigationCoordinator.consumeContentRestoreTarget(
            currentPosition: BibleReaderNavigationPosition(
                book: currentBook,
                chapter: currentChapter,
                verse: currentVerse
            )
        ) { [weak self] book, chapter, verse in
            guard let self else { return nil }
            return self.verseOrdinal(
                osisBookId: self.osisBookId(for: book),
                chapter: chapter,
                verse: verse
            )
        }
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
     Reapplies the pane's current SWORD display options immediately before raw entry extraction
     because controllers can share a manager whose global filter state is mutable.
     Returns (xml, verseCount) or nil if no module is available.
     */
    private func loadChapterFromSword(osisBookId: String, chapter: Int) -> BibleChapterDocumentBuilder.LoadedChapterContent? {
        guard let module = activeModule else { return nil }
        applySwordOptions()
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

    /// Owns recent-label ordering, de-duplication, and persisted settings representation.
    private var recentLabelCoordinator = BibleReaderRecentLabelCoordinator()

    /**
     Delegates recent-label tracking for bookmark actions that selected or created a label.

     - Parameter labelId: Opaque label UUID string produced by the bookmark action coordinator.
     - Side effects: Updates the recent-label coordinator and persists the joined label IDs through
       `SettingsStore` using the legacy key consumed by reader configuration.
     - Failure modes: If `settingsStore` is unavailable, the in-memory recent-label list still
       updates for the current config payload, matching other controller-owned optional stores.
     */
    private func trackRecentLabel(_ labelId: String) {
        recentLabelCoordinator.track(labelId) { [settingsStore] persistedValue in
            settingsStore?.setString(BibleReaderRecentLabelCoordinator.settingsKey, value: persistedValue)
        }
    }

    /**
     Loads recently used bookmark labels before reader configuration is emitted to Vue.

     - Side effects: Reads `SettingsStore` and updates `recentLabelCoordinator` when the legacy
       setting exists and is non-empty.
     - Failure modes: Missing or empty settings leave the coordinator unchanged, preserving the
       prior controller behavior.
     */
    private func loadRecentLabels() {
        recentLabelCoordinator.load(
            storedValue: settingsStore?.getString(BibleReaderRecentLabelCoordinator.settingsKey)
        )
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
            bookCatalog: bookCatalog,
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

    // MARK: - Annotation Document Loader

    /**
     Builds the loader for Android-style My Notes, StudyPad, and Memorize fake documents.

     The controller keeps visible pane state and public entry points. The loader owns document
     payload assembly and bridge emission order so annotation document rendering does not remain
     embedded in the controller's bridge delegate surface.

     - Returns: Loader bound to this pane's bridge and controller state callbacks.
     - Side effects: None during construction; supplied closures may emit bridge events and mutate
       rendered-content state when loader methods are invoked.
     - Failure modes: None during construction.
     */
    private func annotationDocumentLoader() -> BibleReaderAnnotationDocumentLoader {
        BibleReaderAnnotationDocumentLoader(
            bridge: bridge,
            bookmarkService: bookmarkService,
            sendLabels: { [weak self] in
                self?.sendLabelsToVueJS()
            },
            setRenderedContentState: { [weak self] category, moduleName, book, chapter, key, documentKind in
                self?.setRenderedContentState(
                    category: category,
                    moduleName: moduleName,
                    book: book,
                    chapter: chapter,
                    key: key,
                    documentKind: documentKind
                )
            },
            incrementMyNotesRevision: { [weak self] in
                self?.myNotesMutationRevision += 1
            },
            applyNightModeBackground: { [weak self] in
                self?.applyNightModeBackground()
            },
            clearSelection: { [weak self] in
                self?.bridge.clearSelection()
            }
        )
    }

    // MARK: - Annotation Bridge Coordinator

    /**
     Creates the persistent annotation bridge handler for delegate routing and UI-test fixtures.

     The handler owns bookmark/StudyPad bridge dispatch while this controller supplies only the
     reader state accessors that must remain controller-owned: visible My Notes/StudyPad state,
     editing mode, native label-assignment presentation, and current bookmark rows for UI-test
     fixture mutation.

     - Returns: Handler bound to this controller's bridge coordinator factory and state closures.
     - Side effects: None during construction; handler methods mutate controller state only through
       explicit closures.
     - Failure modes: None.
     */
    private func makeAnnotationBridgeHandler() -> BibleReaderAnnotationBridgeHandler {
        BibleReaderAnnotationBridgeHandler(
            coordinator: { [weak self] bridge in
                self?.annotationBridgeCoordinator(bridge: bridge)
            },
            bookmarkService: { [weak self] in
                self?.bookmarkService
            },
            isShowingMyNotes: { [weak self] in
                self?.showingMyNotes ?? false
            },
            isShowingStudyPad: { [weak self] in
                self?.showingStudyPad ?? false
            },
            activeStudyPadLabelId: { [weak self] in
                self?.activeStudyPadLabelId
            },
            currentChapterMyNotesBookmarks: { [weak self] in
                self?.currentChapterMyNotesBookmarks() ?? []
            },
            setEditingInWebView: { [weak self] enabled in
                self?.editingInWebView = enabled
            },
            assignLabels: { [weak self] bookmarkId in
                self?.onAssignLabels?(bookmarkId)
            }
        )
    }

    /**
     Creates the coordinator that owns bookmark and StudyPad bridge result application.

     - Parameter bridge: Bridge instance associated with the delegate callback being handled.
     - Returns: A coordinator bound to the current bookmark service and controller state hooks, or
       `nil` when bookmark persistence is not available.
     - Side effects: None during construction; returned coordinator methods mutate persistence,
       controller-owned revision/config state, and bridge events.
     - Failure modes: Returns `nil` rather than accepting annotation bridge actions without
       persistence.
     */
    private func annotationBridgeCoordinator(bridge: BibleBridge) -> BibleReaderAnnotationBridgeCoordinator? {
        guard let bookmarkService else { return nil }
        return BibleReaderAnnotationBridgeCoordinator(
            bridge: bridge,
            bookmarkService: bookmarkService,
            payloadFactory: annotationPayloadFactory(),
            currentBook: currentBook,
            currentNotesContentType: { [weak self] in
                self?.currentNotesContentType() ?? "HTML"
            },
            workspaceSettings: { [weak self] in
                self?.activeWindow?.workspace?.workspaceSettings
            },
            setWorkspaceSettings: { [weak self] settings in
                self?.activeWindow?.workspace?.workspaceSettings = settings
            },
            persistState: { [weak self] in
                self?.onPersistState?()
            },
            incrementMyNotesRevision: { [weak self] in
                self?.myNotesMutationRevision += 1
            },
            incrementStudyPadRevision: { [weak self] in
                self?.studyPadMutationRevision += 1
            },
            trackRecentLabel: { [weak self] labelId in
                self?.trackRecentLabel(labelId)
            },
            sendLabels: { [weak self] in
                self?.sendLabelsToVueJS()
            },
            buildConfigJSON: { [weak self] in
                self?.buildConfigJSON() ?? "{}"
            }
        )
    }

    // MARK: - Active Window State

    /**
     Whether this controller's window is the active (focused) window.
     Matches Android: `windowControl.activeWindow.id == window.id`
     */
    private func computeIsActiveWindow() -> Bool {
        activeWindowState().isActive
    }

    /**
     Emit set_active event to Vue.js with current active window state.
     Called after content load and when active window changes.
     */
    func emitActiveState() {
        bridge.emit(event: "set_active", data: activeWindowState().eventJSON)
    }

    /**
     Builds the active-window state projection used by both config and active-state bridge events.

     - Returns: Active-window flags matching Android focus semantics and existing indicator rules.
     - Side effects: Reads app preferences and current window manager state.
     - Failure modes: Missing window-manager state falls back inside the configuration coordinator.
     */
    private func activeWindowState() -> BibleReaderActiveWindowState {
        configurationCoordinator.activeWindowState(
            activeWindow: activeWindow,
            windowManager: windowManagerRef,
            activeIndicatorEnabled: appPreferenceBool(.showActiveWindowIndicator)
        )
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
        guard let json = configurationCoordinator.configJSON(context: buildConfigContext()) else {
            logger.error("Failed to encode set_config bridge payload")
            return "{}"
        }
        return json
    }

    /**
     Captures the live controller inputs needed to build one reader configuration payload.

     - Returns: Immutable configuration context consumed by `BibleReaderConfigurationCoordinator`.
     - Side effects: Reads settings, workspace state, bookmark labels, and reading-progress settings.
     - Failure modes: Missing stores or workspace settings fall back to empty collections and app
       defaults, preserving the previous controller behavior.
     */
    private func buildConfigContext() -> BibleReaderConfigurationContext {
        let fontSizeMultiplierPercent = max(10, appPreferenceInt(.fontSizeMultiplier))
        let readingProgressSettings = readingProgressStore?.snapshot().settings ?? ReadingProgressSettingsSnapshot()
        return BibleReaderConfigurationContext(
            displaySettings: displaySettings,
            defaults: .appDefaults,
            nightMode: nightMode,
            errorBox: appPreferenceBool(.showErrorBox),
            favouriteLabelIds: bookmarkService?.allLabels()
                .filter { $0.favourite }
                .map { $0.id.uuidString } ?? [],
            recentLabelIds: recentLabelCoordinator.labelIds,
            studyPadCursors: activeWindow?.workspace?.workspaceSettings?.studyPadCursors ?? [:],
            autoAssignLabelIds: activeWindow?.workspace?.workspaceSettings?.autoAssignLabels ?? [],
            hiddenCompareDocuments: currentHiddenCompareDocuments(),
            activeWindowState: activeWindowState(),
            disableBibleModalButtons: appPreferenceStringSet(.disableBibleBookmarkModalButtons),
            disableGenericModalButtons: appPreferenceStringSet(.disableGenBookmarkModalButtons),
            monochromeMode: appPreferenceBool(.monochromeMode),
            disableAnimations: appPreferenceBool(.disableAnimations),
            disableClickToEdit: appPreferenceBool(.disableClickToEdit),
            notesContentType: currentNotesContentType(),
            fontSizeMultiplier: Double(fontSizeMultiplierPercent) / 100.0,
            enabledExperimentalFeatures: appPreferenceStringSet(.experimentalFeatures),
            autoTrackReading: readingProgressSettings.autoTrackReading,
            readingProgressSettings: ReadingProgressSettingsBundle(settings: readingProgressSettings)
        )
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
    static let defaultBooks = BibleReaderBookCatalog.defaultBooks

    /// Backward-compatible static accessor — returns just the book names from the default list.
    static let allBooks: [String] = defaultBooks.map(\.name)

    /// Refresh the book list from the active module's versification.
    private func refreshBookList() {
        guard let mod = activeModule else {
            moduleBookList = []
            return
        }
        moduleBookList = swordCoordinator.bookList(for: mod)
        logBookListRefresh(module: mod, books: moduleBookList)
    }

    /**
     Logs the outcome of an active-module book-list refresh.

     - Parameters:
       - module: Active Bible module used to read the list.
       - books: Books returned by SWORD for that module.
     - Side effects: Writes diagnostic log entries only.
     - Failure modes: Empty book lists are logged as errors because static-canon fallback while a
       SWORD Bible is active would diverge from Android/JSword versification behavior.
     */
    private func logBookListRefresh(module: SwordModule?, books: [BookInfo]) {
        guard let module else { return }
        if books.isEmpty {
            logger.error("Module \(module.info.name, privacy: .public) returned no books; refusing static canon fallback while active")
        } else {
            logger.info("Module \(module.info.name) has \(books.count) books (versification: \(module.configEntry("Versification") ?? "KJV"))")
        }
    }

    /// Chapter count for a book, using the active module's versification.
    func chapterCount(for book: String) -> Int {
        bookCatalog.chapterCount(for: book)
    }

    /// Static chapter count using the default 66-book list.
    static func chapterCount(for book: String) -> Int {
        BibleReaderBookCatalog.chapterCount(for: book)
    }

    /// Next book after the given book in the active module's versification.
    func nextBook(after book: String) -> String? {
        bookCatalog.nextBook(after: book)
    }

    /// Previous book before the given book in the active module's versification.
    func previousBook(before book: String) -> String? {
        bookCatalog.previousBook(before: book)
    }

    /// OSIS book ID lookup, using the active module's versification.
    func osisBookId(for bookName: String) -> String {
        bookCatalog.osisBookId(for: bookName)
    }

    /// KJVA-compatible ordinal for the canonical book position used by local reading progress.
    private func kjvBookOrdinal(for bookName: String) -> Int? {
        bookCatalog.kjvBookOrdinal(for: bookName)
    }

    /// Resolves the active Bible chapter into the JSword/KJVA identity used by reading progress.
    private func readingProgressBridgeTarget(
        bookInitials: String,
        startOrdinal: Int,
        chapter: Int
    ) -> BibleReaderProgressBridgeCoordinator.ReadingProgressBridgeTarget? {
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
        return BibleReaderProgressBridgeCoordinator.ReadingProgressBridgeTarget(
            kjvBookOrdinal: kjvBookOrdinal,
            bookName: currentBook
        )
    }

    @discardableResult
    func saveReadingProgressSettings(_ settings: ReadingProgressSettingsSnapshot) -> ReadingProgressSettingsSnapshot? {
        progressBridgeCoordinator.saveReadingProgressSettings(settings)
    }

    /// Static OSIS book ID lookup using the default list.
    static func osisBookId(for bookName: String) -> String {
        BibleReaderBookCatalog.osisBookId(for: bookName)
    }

    /// Reverse lookup: OSIS ID → book name using the active module's versification.
    func bookName(forOsisId osisId: String) -> String? {
        bookCatalog.bookName(forOsisId: osisId)
    }

    /// Static reverse lookup using the default list.
    static func bookName(forOsisId osisId: String) -> String? {
        BibleReaderBookCatalog.bookName(forOsisId: osisId)
    }

    /// Check if a book is in the New Testament, using the active module's versification.
    func isNewTestament(_ bookName: String) -> Bool {
        bookCatalog.isNewTestament(bookName)
    }

    /// Static NT check using the default list.
    static func isNewTestament(_ bookName: String) -> Bool {
        BibleReaderBookCatalog.isNewTestament(bookName)
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
        bookCatalog.verseCount(book: book, chapter: chapter)
    }

    /// Returns the verse count for a book/chapter. Defaults to 30 if unknown.
    static func verseCount(for book: String, chapter: Int) -> Int {
        BibleReaderBookCatalog.verseCount(for: book, chapter: chapter)
    }

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
