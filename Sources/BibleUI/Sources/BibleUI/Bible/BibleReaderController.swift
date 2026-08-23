// BibleReaderController.swift — Handles bridge delegate for BibleReaderView

import BibleCore
import BibleView
import Foundation
import SwordKit
import os.log

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private let logger = Logger(subsystem: "org.andbible", category: "BibleReaderController")

/// Fail-closed reasons an exact bookmark target cannot be committed by the active reader.
enum BibleReaderBookmarkNavigationCommitFailure: Error, Equatable, LocalizedError {
  /// The active reader or one of its required persistence backends is unavailable.
  case readerUnavailable
  /// A backend identity changed between validation and the single commit boundary.
  case destinationChanged
  /// The exact destination could not be serialized for the Vue reader.
  case serializationFailed

  /** Returns Android's shared reader error instead of introducing iOS-only message keys. */
  var errorDescription: String? {
    String(localized: "error_occurred", defaultValue: "An error has occurred")
  }
}

/**
 Typed native WebView selection metadata used to route Speak through Android's source providers.

 Bible and generic documents expose category, module, key, versification, and ordinal identity from
 the selected DOM document. The text-only fallback is retained solely for selections outside a
 structured document; partially populated source identity fails closed instead of speaking through
 the wrong provider.
 */
struct BibleReaderSpeechSelection: Equatable {
    let text: String
    let bookInitials: String?
    let osisRef: String?
    let bookCategory: String?
    let versification: String?
    let startOrdinal: Int?
    let endOrdinal: Int?
    let startOffset: Int?
    let endOffset: Int?

    /// Whether the bridge supplied any source field that must be treated atomically.
    var hasSourceMetadata: Bool {
        bookInitials != nil
            || osisRef != nil
            || bookCategory != nil
            || versification != nil
            || startOrdinal != nil
            || endOrdinal != nil
    }
}

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
    /// Native/Vue bridge dedicated to this controller's reader window.
    let bridge: BibleBridge

    /**
     Per-window owner of the live WebView host and its weak WebKit delegates.

     The window manager retains this controller while a pane is minimized, so retaining the render
     session here gives iOS and macOS Android's `BibleViewFactory` lifetime: SwiftUI can detach the
     pane without destroying the loaded Vue client. Closing the window unregisters this controller
     and releases the cached host.
     */
    let webViewSession: BibleWebViewSession

  /// Cancellable app-owned subscription that keeps this pane's Vue marker state current.
  @ObservationIgnored
  private var aiDocMarkerEventObservation: MyDocumentAIDocMarkerEventObservation?
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
    /// KJVA-owned My Notes destination retained independently from the active Bible pane.
    private struct MyNotesTarget {
        let bookName: String
        let osisBookId: String
        let chapter: Int
        let jumpOrdinal: Int?
    }
    /// My Notes destination currently rendered or awaiting a client-ready replay.
    private var activeMyNotesTarget: MyNotesTarget?
    /// Explicit KJVA My Notes destination requested before the Vue client was ready.
    private var pendingClientReadyMyNotesTarget: MyNotesTarget?
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
  /// Android SQLite discovery, canonical identity, and category-selection policy.
  private var sqliteRuntimeCoordinator = BibleReaderSQLiteRuntimeCoordinator()
  /// Exact-key preflight shared by SQLite dictionary switching and chooser presentation.
  private let sqliteDictionaryChooser = BibleReaderSQLiteDictionaryChooser()
  /// Active MyBible, MySword, or e-Sword Bible when the selected document is not SWORD-backed.
  private var activeSQLiteBibleModule: BibleReaderSQLiteModuleHandle?
    /// All installed Bible modules (for module switching)
    private(set) var installedBibleModules: [ModuleInfo] = []

    /**
     Bible modules eligible for normal reader shortcuts and automatic fallback selection.

     Android's `SwordDocumentFacade.unlockedBibles` keeps locked modules out of toolbar menus while
     the full document chooser retains inclusive installed inventory for its unlock workflow. Native
     SWORD rows are classified through the manager's fresh access snapshot; validated Android SQLite
     projections are readable by construction.

     - Returns: Installed Bible metadata in the existing catalog order, excluding locked or
       unavailable native SWORD rows.
     - Side effects: Reads one fresh native inventory snapshot; it does not mutate selection,
       persistence, rendered content, or the controller's stable catalog order.
     - Failure modes: Missing managers and unsupported native modules fail closed. SQLite modules
       remain available because catalog discovery has already validated their readable payload.
     */
    var readableBibleModules: [ModuleInfo] {
        let readableNativeNames: Set<SQLiteDocumentIdentity>
        if let swordManager {
            readableNativeNames = Set(
                swordManager.installedModules().lazy.filter { info in
                    !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info)
                        && info.category == .bible
                        && (!info.isEncrypted || info.isUnlocked)
                }.map { SQLiteDocumentIdentity($0.name) }
            )
        } else {
            readableNativeNames = []
        }
        return installedBibleModules.filter { info in
            if BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info) {
                return true
            }
            return readableNativeNames.contains(SQLiteDocumentIdentity(info.name))
        }
    }

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
  /// Active MyBible or MySword commentary selected through Android's custom-book catalog.
  private var activeSQLiteCommentaryModule: BibleReaderSQLiteModuleHandle?
    private(set) var activeCommentaryModuleName: String?
    private(set) var currentCategory: DocumentCategory = .bible
    /// Pure planner for Android-style module/category PageManager transitions.
    private let moduleSwitchCoordinator = BibleReaderModuleSwitchCoordinator()
  /// SQLite switch sequencing over controller-owned state and persistence seams.
  private let sqliteModuleSwitchCoordinator = BibleReaderSQLiteModuleSwitchCoordinator()
  /// SQLite speech source selection, DOM presentation, and exact-key callback routing.
  private let sqliteSpeechDispatchCoordinator = BibleReaderSQLiteSpeechDispatchCoordinator()
    /// State machine for Android-style Bible navigation and visible-position persistence.
    @ObservationIgnored
    private let navigationCoordinator = BibleReaderNavigationCoordinator()
    /// Source-aware link range consumed by the next Bible document setup emission.
    private var pendingLinkNavigationOrdinalRange: [Int]?

  /**
   Complete target-owned identity for one contiguous Android Bible link.

   The source `OsisRef` remains unchanged while this value records the destination module's
   strictly mapped first verse and inclusive ordinal span. It is created only after every source
   verse maps to an exact target-module verse in canonical order.
   */
  private struct BibleLinkNavigationTarget {
    /// Installed Bible module that must own the visible destination page.
    let moduleName: String

    /// Target-module display name for the mapped first book.
    let book: String

    /// Target-versification chapter containing the mapped first verse.
    let chapter: Int

    /// Target-versification first verse used as Android's visible navigation anchor.
    let verse: Int

    /// Inclusive target-module ordinal range retained for highlight and scroll setup.
    let ordinalRange: [Int]
  }

    /// Dictionary/Lexicon module support
    private(set) var installedDictionaryModules: [ModuleInfo] = []
    private(set) var activeDictionaryModule: SwordModule?
  /// Active MyBible or MySword dictionary selected through Android's custom-book catalog.
  private var activeSQLiteDictionaryModule: BibleReaderSQLiteModuleHandle?
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
    /// Live Memorize fake-document payload used to replay Android's commentary `Memorize` page.
    private var activeMemorizeEmission: MemorizeDocumentEmission?
    /// Decoded Android `BookAndKeySerialized` payload for restored Memorize source ranges.
    private struct SerializedBookAndKey: Decodable {
        let key: String
        let document: String?
    }

    /// Concrete restored Memorize source used to rebuild a cold-start fake document.
    private struct RestoredMemorizeSource {
        let bookInitials: String
        let references: [VerseKeyReference]
    }

    /// Reader-local My Documents active page state and document payload assembly.
    private var myDocumentCoordinator = BibleReaderMyDocumentCoordinator()

    /// Reader-local loaded-range state for Vue infinite-scroll prepend/append requests.
    private var infiniteScrollCoordinator = BibleReaderInfiniteScrollCoordinator()

    /// Catalog boundary for active-module book metadata and SWORD/JSword versification lookup.
    private var bookCatalog: BibleReaderBookCatalog {
    BibleReaderBookCatalog(
      activeModule: activeModule,
      moduleBookList: moduleBookList,
      usesExactKJVAOrdinals: activeSQLiteBibleModule != nil
    )
    }

    /**
     Resolves a verse ordinal through the active module's SWORD versification.

     - Parameters:
       - osisBookId: OSIS book identifier for the verse.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: The active module's SWORD ordinal when available, the generated placeholder's
       genuine KJVA ordinal when no module is present, or `nil` for an invalid reference.
     - Side effects: May temporarily move the active SWORD module cursor; `SwordModule` restores it
       before returning.
     */
    private func verseOrdinal(osisBookId: String, chapter: Int, verse: Int) -> Int? {
        if activeModule == nil {
            return JSwordKJVAVersification.verseOrdinal(
                osisId: osisBookId,
                chapter: chapter,
                verse: verse
            )
        }
        return bookCatalog.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
    }

    /**
     Resolves a persisted ordinal back to a verse reference for a book.

     Android resolves these values through JSword's versification when building bookmark,
     memorization, and note payloads. iOS mirrors that by asking the active SWORD module to position
     a `VerseKey` by index. Generated no-module documents already use KJVA verse ordinals, so their
     reverse lookup stays in that explicit synthetic domain instead of applying compatibility math.

     - Parameters:
       - book: User-facing book name used to derive the OSIS identifier.
       - ordinal: Persisted verse ordinal.
     - Returns: A verse reference in the requested book, or `nil` for invalid ordinals.
     - Side effects: May temporarily move the active SWORD module cursor; `SwordModule` restores it
       before returning.
     */
    private func verseReference(book: String, ordinal: Int) -> VerseKeyReference? {
        if activeModule == nil {
            let expectedOsisId = osisBookId(for: book)
      guard
        let reference = JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: ordinal
        ), reference.osisId == expectedOsisId
      else {
                return nil
            }
            return VerseKeyReference(
                osisBookId: reference.osisId,
                chapter: reference.chapter,
                verse: reference.verse,
                ordinal: reference.ordinal
            )
        }
        return bookCatalog.verseReference(book: book, ordinal: ordinal)
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
     Builds the bookmark-list active-versification resolver, or `nil` when the active module renders
     in KJVA-compatible numbering.

     Android renders bookmark-list rows in the current Bible's versification (Android's
     `BookmarkItemAdapter`), so a bookmark stored at a KJVA ordinal shows and navigates to the active
     module's mapped verse — KJVA Psalm 10 in a Vulgate module is Psalm 9. But KJV-family modules
     (KJV/KJVA, or no module) render identically to KJVA, so this returns `nil` for them and the list
     keeps its fast in-memory KJVA path with no per-row mapping work. For a divergent canon it returns
     a closure that memoizes the pinned JSword projection and target-module lookup per ordinal.

     - Returns: A resolver mapping a KJVA ordinal to the active versification's book name plus
       chapter/verse, or `nil` when the active module is KJVA-compatible.
     - Side effects: May temporarily move the active SWORD module cursor once per unique ordinal;
       each lookup restores the prior key.
     - Failure modes: The returned resolver yields `nil` for malformed or unmappable ordinals.
     */
  func bookmarkListActiveReferenceResolver() -> (
    (Int) -> (bookName: String, reference: BookmarkListVerseReference)?
  )? {
        guard let activeModule else { return nil }
        let activeVersification = VersificationMapper.versificationName(for: activeModule)
        let normalized = normalizedVersificationName(activeVersification)
        guard normalized != JSwordKJVAVersification.name, normalized != "KJV" else { return nil }

        var cache: [Int: (bookName: String, reference: BookmarkListVerseReference)?] = [:]
        return { [weak self] kjvOrdinal in
            if let cached = cache[kjvOrdinal] { return cached }
            let resolved = self?.bookmarkListActiveReference(
                kjvOrdinal: kjvOrdinal,
                activeModule: activeModule
            )
            cache[kjvOrdinal] = resolved
            return resolved
        }
    }

    /**
     Projects one stored KJVA ordinal into the active module for bookmark-list rows.

     - Parameters:
       - kjvOrdinal: Persisted Android-compatible KJVA ordinal.
       - activeModule: Target module whose versification and ordinal domain own the result.
     - Returns: Active-versification display book name plus chapter/verse, or `nil` when the ordinal
       cannot be resolved or mapped.
     - Side effects: Reads pinned JSword mapping resources and temporarily moves the target module
       cursor while resolving its ordinal, restoring the prior key before returning.
     - Failure modes: Returns `nil` for malformed KJVA ordinals, unsupported versifications,
       non-authoritative mappings, or references the target module cannot address.
     */
    private func bookmarkListActiveReference(
        kjvOrdinal: Int,
        activeModule: SwordModule
    ) -> (bookName: String, reference: BookmarkListVerseReference)? {
    guard
      let projection = VersificationMapper.moduleProjection(
                  forKJVAOrdinal: kjvOrdinal,
                  targetModule: activeModule
      ), projection.isAddressable
    else { return nil }
        let mapped = projection.reference
    let displayName =
      bookName(forOsisId: mapped.osisBookId)
            ?? JSwordKJVAVersification.longBookName(osisId: mapped.osisBookId)
            ?? mapped.osisBookId
        return (
            bookName: displayName,
            reference: BookmarkListVerseReference(chapter: mapped.chapter, verse: mapped.verse)
        )
    }

    /**
     Converts a bookmark-modal My Notes link target into Android's My Notes document ordinal domain.

     Android builds the link from `bookmark.verseRange.start.ordinal` plus its source
     versification, then opens a My Notes document whose row ordinals are KJVA. iOS mirrors that by
     decoding the source ordinal from canon metadata and converting the resulting verse identity
     through the pinned JSword mapper before selecting the KJVA-owned destination.

     - Parameters:
       - v11nName: Source versification emitted by the bookmark payload.
       - sourceOrdinal: Bookmark start ordinal in `v11nName`.
     - Returns: KJVA ordinal for the same verse, or `nil` when the declared versification cannot
       soundly resolve or map the source ordinal.
     - Side effects: Reads the compiled SWORD canon and pinned JSword mapping resources.
     - Failure modes: Returns `nil` for invalid ordinals, unsupported versifications, and missing
       authoritative mappings. It never depends on an installed source module or relabels the
       source ordinal as KJVA.
     */
    private func kjvaMyNotesOrdinal(v11nName: String, sourceOrdinal: Int) -> Int? {
        guard sourceOrdinal > 0 else { return nil }
        let sourceVersification = v11nName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceVersification.isEmpty else { return nil }
        if normalizedVersificationName(sourceVersification) == JSwordKJVAVersification.name {
            return JSwordKJVAVersification.referenceIncludingIntroductions(ordinal: sourceOrdinal) == nil
                ? nil
                : sourceOrdinal
        }
    guard
      let reference = SwordVersification.reference(
                  forIndex: sourceOrdinal,
                  versification: sourceVersification
      )
    else { return nil }
        return kjvaOrdinal(
            osisBookId: reference.osisBookId,
            chapter: reference.chapter,
            verse: reference.verse,
            sourceVersification: sourceVersification
        )
    }

    /** Resolves one KJVA ordinal into the complete synthetic My Notes page destination. */
    private func myNotesTarget(kjvaOrdinal: Int) -> MyNotesTarget? {
    guard
      let reference = JSwordKJVAVersification.referenceIncludingIntroductions(
                  ordinal: kjvaOrdinal
              ),
              let bookName = JSwordKJVAVersification.localizedLongBookName(
                  osisId: reference.osisId
      )
    else {
            return nil
        }
        return MyNotesTarget(
            bookName: bookName,
            osisBookId: reference.osisId,
            chapter: reference.chapter,
            jumpOrdinal: kjvaOrdinal
        )
    }

    /** Resolves an Android My Notes route from its source domain into a KJVA-owned page target. */
    private func myNotesTarget(v11nName: String, sourceOrdinal: Int) -> MyNotesTarget? {
    guard
      let ordinal = kjvaMyNotesOrdinal(
                  v11nName: v11nName,
                  sourceOrdinal: sourceOrdinal
      )
    else {
            return nil
        }
        return myNotesTarget(kjvaOrdinal: ordinal)
    }

    /** Resolves the active pane verse into the KJVA page selected by Android's My Notes document. */
    private func currentMyNotesTarget(jumpToOrdinal: Int?) -> MyNotesTarget? {
        if let jumpToOrdinal {
            return myNotesTarget(kjvaOrdinal: jumpToOrdinal)
        }
    guard
      let ordinal = kjvaOrdinal(
                  osisBookId: osisBookId(for: currentBook),
                  chapter: currentChapter,
                  verse: max(1, currentVerse),
                  sourceVersification: activeSourceVersificationName()
              ),
      let target = myNotesTarget(kjvaOrdinal: ordinal)
    else {
            return nil
        }
        return MyNotesTarget(
            bookName: target.bookName,
            osisBookId: target.osisBookId,
            chapter: target.chapter,
            jumpOrdinal: nil
        )
    }

    /** Returns the exact KJVA chapter span owned by one synthetic My Notes page. */
    private func myNotesChapterRange(
        for target: MyNotesTarget
    ) -> (start: Int, end: Int, verseCount: Int)? {
    guard
      let verseCount = JSwordKJVAVersification.verseCount(
                  osisId: target.osisBookId,
                  chapter: target.chapter
              ),
              let start = JSwordKJVAVersification.chapterIntroOrdinal(
                  osisId: target.osisBookId,
                  chapter: target.chapter
              ),
              let end = JSwordKJVAVersification.verseOrdinal(
                  osisId: target.osisBookId,
                  chapter: target.chapter,
                  verse: verseCount
      )
    else {
            return nil
        }
        return (start: start, end: end, verseCount: verseCount)
    }

    /**
     Returns every bookmark inside one explicit KJVA My Notes page.

     Android's `CurrentMyNotePage` passes all of `bookmarksForVerseRange(...)` to the shared
     `MyNotesDocument`, including bookmarks without notes; the Vue layer then applies the
     `showBookmarks` and hidden-label display filters. iOS must not pre-filter to note-bearing
     bookmarks here, or chapters whose bookmarks have no notes render Android's empty state
     instead of their bookmark rows.
     */
    private func myNotesBookmarks(for target: MyNotesTarget) -> [BibleBookmark] {
        guard let service = bookmarkService,
      let range = myNotesChapterRange(for: target)
    else { return [] }
        return service.bookmarks(
            for: range.start,
            endOrdinal: range.end,
            book: target.bookName
        )
        .sorted {
            if $0.kjvOrdinalStart != $1.kjvOrdinalStart {
                return $0.kjvOrdinalStart < $1.kjvOrdinalStart
            }
            // Android orders chapter rows by kjvOrdinalStart then startOffset (SQLite sorts NULL
            // offsets first); the UUID tail only keeps equal-offset rows deterministic.
            let lhsOffset = $0.startOffset ?? Int.min
            let rhsOffset = $1.startOffset ?? Int.min
            if lhsOffset != rhsOffset {
                return lhsOffset < rhsOffset
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /**
     Maps a source-versification verse reference to its KJVA ordinal via SWORD's `VersificationMgr`.

     Mirrors Android's `Verse.toV11n(KJVA)`: the reference is translated through SWORD's own
     pinned JSword mapping resources, so divergent canons (Vulgate/LXX/Synodal and similar)
     resolve onto their true KJVA verses rather than being re-interpreted under KJVA numbering.
     Persistence rejects JSword's coordinate-retaining public fallback; the mapped reference is
     converted to the JSword intro-inclusive KJVA ordinal only after authoritative conversion.

     - Parameters:
       - reference: Verse reference in `sourceVersification`.
       - sourceVersification: SWORD versification name owning `reference`; empty means KJV.
     - Returns: KJVA ordinal for the mapped verse, or `nil` when mapping or ordinal lookup fails.
     - Side effects: Runs inside the SWORD serialization queue via `SwordVersification`.
     - Failure modes: Returns `nil` for unknown versifications or references SWORD cannot map.
     */
  private func kjvaOrdinal(forReference reference: VerseKeyReference, sourceVersification: String)
    -> Int?
  {
        VersificationMapper.kjvaOrdinal(
            for: reference,
            sourceVersification: sourceVersification
        )
    }

    /**
     Maps an OSIS book/chapter/verse from a source versification to its KJVA ordinal.

     - Parameters:
       - osisBookId: OSIS book id in `sourceVersification`.
       - chapter: One-based chapter number in `sourceVersification`.
       - verse: One-based verse number in `sourceVersification`.
       - sourceVersification: SWORD versification name; empty means KJV.
     - Returns: KJVA ordinal for the mapped verse, or `nil` when mapping or ordinal lookup fails.
     - Side effects: Runs inside the SWORD serialization queue via `SwordVersification`.
     - Failure modes: Returns `nil` for unknown versifications or references SWORD cannot map.
     */
    private func kjvaOrdinal(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        sourceVersification: String
    ) -> Int? {
        VersificationMapper.kjvaOrdinal(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            sourceVersification: sourceVersification
        )
    }

    /**
     KJVA chapter-introduction ordinal for the chapter a source reference's verse 1 maps into.

     Android's whole-chapter bookmark query starts its range at `Verse(v11n, book, chapter, 0)` — the
     chapter superscription — so a bookmark stored on a Psalm title (KJVA verse 0, ordinal
     `chapterStart - 1`) is included whenever that Psalm is read in any versification. iOS mirrors
     that lower bound: it maps the source chapter's verse 1 to locate the KJVA chapter, then takes
     that chapter's introduction ordinal. Using verse 1's own ordinal instead would start one slot
     too high and silently exclude superscription bookmarks in KJV-family modules.

     - Parameters:
       - osisBookId: OSIS book id in `sourceVersification`.
       - chapter: One-based chapter number in `sourceVersification`.
       - sourceVersification: SWORD versification name; empty means KJV.
     - Returns: The mapped KJVA chapter's introduction ordinal, or `nil` when mapping fails.
     - Side effects: Runs inside the SWORD serialization queue via `SwordVersification`.
     - Failure modes: Returns `nil` for unknown versifications or references SWORD cannot map.
     */
    private func kjvaChapterIntroOrdinal(
        osisBookId: String,
        chapter: Int,
        sourceVersification: String
    ) -> Int? {
    guard
      let mapped = VersificationMapper.convertStrictly(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: 1,
            from: sourceVersification,
            to: JSwordKJVAVersification.name
      )?.reference
    else {
            return nil
        }
        return JSwordKJVAVersification.chapterIntroOrdinal(
            osisId: mapped.osisBookId,
            chapter: mapped.chapter
        )
    }

    /**
     Returns the active reader source versification name for KJVA mapping.

     - Returns: The active module's SWORD versification (empty conf value becomes `KJV`), or KJVA
       when no module is loaded because the fallback catalog already resolves in the KJVA domain.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func activeSourceVersificationName() -> String {
        guard let activeModule else { return JSwordKJVAVersification.name }
    let raw =
      activeModule.configEntry("Versification")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "KJV" : raw
    }

    /**
     Normalizes empty/SWORD versification names the same way Android and SWORD treat defaults.

     - Parameter name: Raw versification value.
     - Returns: Uppercase versification key; empty input becomes `KJV`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func normalizedVersificationName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "KJV" : trimmed.uppercased()
    }

    /**
     Resolves the ordinal range for a chapter in the active module's versification.

     - Parameters:
       - book: User-facing book name.
       - chapter: One-based chapter number.
       - verseCount: Optional known last verse count; when omitted, the method asks the active
         module or the KJVA canon that owns generated no-module documents.
     - Returns: Start/end ordinals and the verse count used to compute the end, or `nil` when an
       active module cannot resolve the chapter exactly.
     - Side effects: May query the active SWORD module for verse counts and ordinals.
     */
  private func chapterOrdinalRange(book: String, chapter: Int, verseCount: Int? = nil) -> (
    start: Int, end: Int, verseCount: Int
  )? {
        if activeModule == nil {
            let osisId = osisBookId(for: book)
      guard
        let resolvedVerseCount = verseCount
                ?? JSwordKJVAVersification.verseCount(osisId: osisId, chapter: chapter),
                resolvedVerseCount > 0,
                let start = JSwordKJVAVersification.verseOrdinal(
                    osisId: osisId,
                    chapter: chapter,
                    verse: 1
                ),
                let end = JSwordKJVAVersification.verseOrdinal(
                    osisId: osisId,
                    chapter: chapter,
                    verse: resolvedVerseCount
        )
      else {
                return nil
            }
            return (start, end, resolvedVerseCount)
        }
        return bookCatalog.chapterOrdinalRange(book: book, chapter: chapter, verseCount: verseCount)
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
                bookmarkQueryOrdinalRange(book: currentBook, chapter: currentChapter)
            },
            verseReference: { [self] book, ordinal in
                verseReference(book: book, ordinal: ordinal)
            }
        )
    }

    /**
     Bookmark rows backing the visible My Notes document, or note-bearing chapter bookmarks for
     the pre-open accessibility export.
     */
    private func currentChapterMyNotesBookmarks() -> [BibleBookmark] {
        if showingMyNotes, let activeMyNotesTarget {
            return myNotesBookmarks(for: activeMyNotesTarget)
        }
        return accessibilitySnapshotFactory().currentChapterMyNotesBookmarks()
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
    renderedContentState =
      BibleReaderRenderedContentState(
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

    /// Whether the visible page is Android's synthetic commentary `Memorize` document.
    var isShowingAndroidMemorizeDocument: Bool {
        AndroidSpecialDocumentIdentity.isMemorizeDocument(
            categoryName: currentCategory.pageManagerKey,
            moduleName: activeCommentaryModuleName ?? activeWindow?.pageManager?.commentaryDocument
        )
    }

    /**
     Visible toolbar summary for Android's synthetic `Multi` document.

     The page identity intentionally remains `general_book/Multi` for Android restore and links-window
     parity. This summary is derived from the active transient Vue payload so the SwiftUI toolbar can
     mirror Android's display title, for example `BDBT: H430`, without mutating the durable document
     identity to the selected dictionary tab.
     */
  var androidMultiDocumentHeaderSummary: AndroidSpecialDocumentIdentity.MultiDocumentHeaderSummary?
  {
    guard
      let activeRequest = specialDocumentCoordinator.activeRequest(
            isShowingAndroidMultiDocument: isShowingAndroidMultiDocument
      )
    else {
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
        || activeSQLiteBibleModule?.metadata.hasStrongs == true
        case .commentary:
            return activeCommentaryModule?.info.features.contains(.strongsNumbers) == true
        || activeSQLiteCommentaryModule?.metadata.hasStrongs == true
        case .generalBook:
            return isShowingAndroidMultiDocument
        default:
            return false
        }
    }

    /// Whether Android enables the recent Red Letter preference for the active Bible document.
    var hasRedLetterWords: Bool {
        guard currentCategory == .bible else { return false }
        return activeModule?.info.features.contains(.redLetterWords) == true
            || activeSQLiteBibleModule?.metadata.hasWordsOfChrist == true
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
     only for EPUB-backed content. Non-EPUB general books, including `Multi`, remain non-searchable.
     Android also marks hidden
     commentary fake documents such as Memorize as special documents, so they do not expose ordinary
     commentary search.

     - Returns: `true` when the toolbar/search shortcut should be enabled for the visible page.
     - Side effects: None.
     */
    var isCurrentPageSearchable: Bool {
        switch currentCategory {
        case .bible, .commentary:
            return !isShowingAndroidMultiDocument && !isShowingAndroidMemorizeDocument
        case .generalBook, .epub:
            return activeEpubReader != nil && !isShowingAndroidMultiDocument
        default:
            return false
        }
    }

    /**
     Whether the current page can be spoken by Android's page-level speak action.

     Android disables speech for special documents such as `Multi` and Memorize, while ordinary
     Bible and generic pages, including maps, remain speakable. iOS suppresses the same special
     links-window pages and routes every supported visible category through its source-owned
     provider instead of borrowing Bible coordinates.

     - Returns: `true` when page-level speech is valid for the visible page.
     - Side effects: None.
     */
    var isCurrentPageSpeakable: Bool {
        switch currentCategory {
        case .bible, .commentary, .dictionary, .generalBook, .map, .epub, .dailyDevotion:
            return !isShowingAndroidMultiDocument && !isShowingAndroidMemorizeDocument
        }
    }

    /**
     Whether the current page participates in synchronized scrolling.

     Android reports `CurrentGeneralBookPage.isSyncable=false`, while dictionary/map-style pages
     inherit the default syncable behavior. iOS mirrors that distinction by disabling general-book
     and EPUB sync controls, including links-window `Multi`, and by treating Memorize as Android's
     non-syncable hidden commentary fake document without globally limiting sync to Bible and
     commentary pages.

     - Returns: `true` for Android-syncable page categories; `false` for general-book/EPUB pages and
       special `Multi` content.
     - Side effects: None.
     */
    var isCurrentPageSyncable: Bool {
        switch currentCategory {
        case .generalBook, .epub:
            return false
        default:
            return !isShowingAndroidMultiDocument && !isShowingAndroidMemorizeDocument
        }
    }

    /// Resolved text display settings used for Vue.js config
    var displaySettings: TextDisplaySettings = .appDefaults
    /// Night mode toggle
    var nightMode: Bool = false

    /// Monotonic owner token for every native intent that can replace reader content.
    private var contentIntentGeneration: UInt64 = 0
    /// Injectable asynchronous Compare build boundary used by deterministic race coverage.
    @ObservationIgnored
    private let compareDocumentBuildOperation: (BibleReaderCompareDocumentBuilder.Request) -> String?
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
       - webViewSession: Optional pre-created render session already used by the pane's first
         SwiftUI pass. When omitted, the controller creates a session around `bridge`.
       - bookmarkService: Optional bookmark/studypad service used for annotation features.
       - initializesSword: Whether to initialize SWORD immediately. Pane controllers that will
         copy an existing controller's shared module state pass `false` to avoid creating a
         transient extra `SwordManager`.
     - aiDocMarkerEventCenter: App-owned typed marker event channel shared by reader panes.

     Side effects:
     - assigns itself as the bridge delegate
     - retains the render session until the controller leaves the window registry
     - initializes SWORD state and installed-module caches when `initializesSword` is `true`

     Failure modes:
     - a supplied render session paired with another bridge fails fast because mixing the two would
       route Vue callbacks and native emissions to different windows
     - if SWORD initialization is requested and `SwordManager` creation fails, the controller
       remains usable for placeholder/fallback rendering with empty installed-module caches.
     */
    public init(
        bridge: BibleBridge,
        webViewSession: BibleWebViewSession? = nil,
        bookmarkService: BookmarkService? = nil,
    initializesSword: Bool = true,
    aiDocMarkerEventCenter: MyDocumentAIDocMarkerEventCenter = .shared
    ) {
        let resolvedWebViewSession = webViewSession ?? BibleWebViewSession(bridge: bridge)
        precondition(
            resolvedWebViewSession.bridge === bridge,
            "BibleReaderController and BibleWebViewSession must share one bridge"
        )
        self.bridge = bridge
        self.webViewSession = resolvedWebViewSession
        self.bookmarkService = bookmarkService
        self.compareDocumentBuildOperation = BibleReaderCompareDocumentBuilder.buildDocumentJSON
        super.init()
        bridge.delegate = self
    observeAIDocMarkerEvents(aiDocMarkerEventCenter)
        if initializesSword {
            initializeSwordIfNeeded()
        }
    }

    /**
     Creates a controller with an injected SWORD manager for deterministic integration tests.

     - Parameters:
       - bridge: Window-scoped native/Vue bridge.
       - webViewSession: Optional matching render session; omitted tests receive a lazy empty
         session that never creates a WebView unless explicitly attached.
       - bookmarkService: Optional bookmark service used by annotation paths.
       - swordManagerOverride: Preconfigured SWORD manager replacing production discovery.
       - compareDocumentBuildOperation: Injectable Compare payload builder.
       - aiDocMarkerEventCenter: Typed marker event source observed by this pane.
     - Side Effects: Assigns the bridge delegate, retains the render session, subscribes to marker
       events, and projects the supplied SWORD manager into controller state.
     - Failure Modes: A render session paired with another bridge fails fast.
     */
    init(
        bridge: BibleBridge,
        webViewSession: BibleWebViewSession? = nil,
        bookmarkService: BookmarkService? = nil,
        swordManagerOverride: SwordManager,
    compareDocumentBuildOperation:
      @escaping (BibleReaderCompareDocumentBuilder.Request) -> String? =
      BibleReaderCompareDocumentBuilder.buildDocumentJSON,
    aiDocMarkerEventCenter: MyDocumentAIDocMarkerEventCenter = .shared
    ) {
        let resolvedWebViewSession = webViewSession ?? BibleWebViewSession(bridge: bridge)
        precondition(
            resolvedWebViewSession.bridge === bridge,
            "BibleReaderController and BibleWebViewSession must share one bridge"
        )
        self.bridge = bridge
        self.webViewSession = resolvedWebViewSession
        self.bookmarkService = bookmarkService
        self.compareDocumentBuildOperation = compareDocumentBuildOperation
        super.init()
        bridge.delegate = self
    observeAIDocMarkerEvents(aiDocMarkerEventCenter)
        configureSwordManager(swordManagerOverride)
    }

  /**
   Subscribes this pane to committed AI marker changes from app persistence owners.

   - Parameter eventCenter: Typed event center shared by all open reader controllers.
   - Side effects: Retains one observation token and emits future marker changes to this bridge.
   - Failure modes: None; deinitializing the controller cancels the retained observation token.
   */
  private func observeAIDocMarkerEvents(_ eventCenter: MyDocumentAIDocMarkerEventCenter) {
    aiDocMarkerEventObservation = eventCenter.observe { [weak self] event in
      self?.emitAIDocMarkerChanges(event)
    }
  }

  /**
   Serializes one marker change event for this pane's displayed versification.

   - Parameter event: Committed marker upserts and generated-page deletions.
   - Side effects: Emits Vue `add_or_update_ai_doc_markers` and `delete_ai_doc_markers` events.
   - Failure modes: Marker JSON serialization failure suppresses only the upsert emission; delete
     identifiers still emit. Non-Bible panes retain stored KJVA marker ordinals like Android.
   */
  private func emitAIDocMarkerChanges(_ event: MyDocumentAIDocMarkersChangedEvent) {
    if !event.markers.isEmpty {
      let targetVersification =
        currentCategory == .bible
        ? activeModule.map(VersificationMapper.versificationName)
        : nil
      let markerObjects = event.markers.map {
        BibleReaderMyDocumentCoordinator.markerJSON(
          $0,
          targetVersification: targetVersification
        )
      }
      if let data = try? JSONSerialization.data(
        withJSONObject: markerObjects,
        options: [.sortedKeys]
      ), let json = String(data: data, encoding: .utf8) {
        bridge.emit(event: "add_or_update_ai_doc_markers", data: json)
      } else {
        logger.error("Failed to serialize AI document marker change event")
      }
    }

    if !event.deletedPageIDs.isEmpty {
      bridge.emitEncoded(
        event: "delete_ai_doc_markers",
        data: event.deletedPageIDs.map(\.uuidString)
      )
    }
  }

    /**
     Starts one reader-content replacement intent and invalidates every older asynchronous result.

     - Returns: Monotonic generation owned by the new intent.
     - Side effects: Advances controller-local replacement state.
     - Failure modes: None; wrapping increment preserves ordering for the practical process lifetime.
     */
    @discardableResult
    private func beginReplacingContentIntent() -> UInt64 {
        contentIntentGeneration &+= 1
        return contentIntentGeneration
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
     Callback for opening a transient multi-reference Vue document in the Android-style links window.

     The string parameter is a serialized `MultiDocument` payload. The owning pane decides whether
     to route it into a dedicated links window or render it in the current controller.
     */
    var onOpenMultiReferenceDocumentInLinksWindow: ((String) -> Void)?

    /**
     Callback for opening Android's commentary-category Memorize fake document in the links window.

     The controller builds the serialized Vue payload and Android fake-document metadata, then lets
     the owning pane choose the destination controller. When no owner installs this callback,
     Memorize renders in the current controller as Android's direct-window fallback.
     */
    var onOpenMemorizeDocumentInLinksWindow: ((MemorizeDocumentEmission) -> Void)?

  /**
   Callback for routing an exact AI-generated page through the pane-owned links-window policy.

   The owning pane chooses the current or dedicated links controller using the same preference,
   window creation, and registration retry path as other links. Without an owner, the bridge
   retains its exact current-pane fallback for standalone controller use.
   */
  var onOpenAIDocumentPageInLinksWindow: ((AIDocumentPageRequest) -> Void)?

    /**
     Callback for routing a StudyPad journal document through the pane-owned links-window policy.

     Android's `LinkControl.openStudyPad` wraps the label in a `StudyPadKey` and hands it to
     `showLink`, so modal StudyPad buttons open the journal document in the dedicated links window
     by default. The owning pane applies the same preference, window-creation, and registration
     retry path as other link results. Without an owner, the bridge keeps its current-pane
     fallback for standalone controller use.
     */
    var onOpenStudyPadInLinksWindow: ((UUID, UUID?) -> Void)?

    /**
     Callback for routing the My Notes document through the pane-owned links-window policy.

     Android's `LinkControl.openMyNotes` resolves the source-versification verse and routes it
     through `showLink` like any other link result. The parameters are the raw source
     versification name and source ordinal from the bridge, so the destination controller performs
     its own KJVA projection. Without an owner, the bridge keeps its current-pane fallback for
     standalone controller use.
     */
    var onOpenMyNotesInLinksWindow: ((String, Int) -> Void)?

    /// Callback for presenting native AI regeneration for a validated My Documents page.
    var onRegenerateMyDocumentPage: ((MyDocumentAIPageActionContext) -> Void)?

  /// Callback for presenting bridge-requested help through the pane-owned native help surface.
  var onShowReaderHelp: ((AIReaderHelpPresentation) -> Void)?

  /// Callback for resolving an exact BibleView selection into the native AI prompt workflow.
  var onRequestAIAction: ((AISelectionActionRequest) -> Void)?

  /// Callback for resolving an exact note-editor destination into the native AI prompt workflow.
  var onRequestNoteEditorAIAction: ((AINoteEditorActionRequest) -> Void)?

  /// Callback for presenting or directly opening exact AI document marker destinations.
  var onChooseAIDocumentPage: (([AIDocumentPageMarker]) -> Void)?

  /// Callback for opening an exact built-in, add-on, or user source prompt.
  var onOpenAIPromptEditor: ((UUID) -> Void)?

  /// Callback for Android's workspace-level AI action menu entry.
  var onRequestWorkspaceAIAction: (() -> Void)?

  /// Callback for Android's exact current-window AI action menu entry.
  var onRequestWindowAIAction: (() -> Void)?

  /// Live Android-compatible provider-row predicate used by native and Vue AI action visibility.
  var isAIProviderConfigured: (() -> Bool)?

  /**
   Resolves pane ownership after the active AI My Documents page is deleted successfully.

   The owning `BibleWindowPane` closes removable windows through `WindowManager`. A missing owner
   or `.showBible` result preserves the standalone/primary-pane fallback used by controller tests
   and the app's sole non-removable pane.
   */
  var onDeleteActiveMyDocumentPage: (() -> MyDocumentPageDeletionResolution)?

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
          let window = self.activeWindow
        else {
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
   capture the controller weakly so a pending switch action cannot extend pane lifetime. Generic
   exact-key validation and key-list enumeration remain throwing so the coordinator can abort
   before mutating controller or persisted pane state. `SwordModule` shares a successful immutable
   key snapshot with the chooser, avoiding a second native traversal.
     */
    private func makeModuleSwitchContext() -> BibleReaderModuleSwitchContext {
        BibleReaderModuleSwitchContext(
            swordManager: swordManager,
            activeWindow: activeWindow,
            clientReady: clientReady,
            currentCategory: currentCategory,
      currentDictionaryKey: currentDictionaryKey,
      currentGeneralBookKey: currentGeneralBookKey,
      currentMapKey: currentMapKey,
      containsExactGenericKey: { module, key in
        try module.containsExactKey(key)
      },
      loadGenericKeys: { module in
        try module.loadAllKeys()
      },
            setBibleModule: { [weak self] module, moduleName in
                self?.activeModule = module
        self?.activeSQLiteBibleModule = nil
                self?.activeModuleName = moduleName
            },
            setCommentaryModule: { [weak self] module, moduleName in
                self?.activeCommentaryModule = module
        self?.activeSQLiteCommentaryModule = nil
                self?.activeCommentaryModuleName = moduleName
            },
            setDictionaryModule: { [weak self] module, moduleName in
                self?.activeDictionaryModule = module
        self?.activeSQLiteDictionaryModule = nil
                self?.activeDictionaryModuleName = moduleName
            },
            setGeneralBookModule: { [weak self] module, moduleName in
                self?.activeGeneralBookModule = module
                self?.activeGeneralBookModuleName = moduleName
                self?.activeEpubReader = nil
                self?.activeEpubIdentifier = nil
                self?.activeEpubTitle = nil
                self?.currentEpubTitle = nil
            },
            setMapModule: { [weak self] module, moduleName in
                self?.activeMapModule = module
                self?.activeMapModuleName = moduleName
      },
      setDictionaryKey: { [weak self] key in
        self?.currentDictionaryKey = key
      },
      setGeneralBookKey: { [weak self] key in
        self?.currentGeneralBookKey = key
      },
      setMapKey: { [weak self] key in
        self?.currentMapKey = key
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
                // Android's document/category switches select the new page and leave the MYNOTE
                // category (CurrentPageManager.setCurrentDocument*), so switch-driven reloads
                // must exit My Notes; only navigation-driven reloads keep it current.
                self?.showingMyNotes = false
                self?.loadCurrentContent()
            }
        )
    }

  /**
   Builds state, persistence, and render seams for the SQLite switch coordinator.

   The coordinator owns switch ordering and preflight while this controller remains the only
   owner of observable backend handles and pane fields. Closures capture weakly so an in-flight
   action cannot extend pane lifetime.

   - Returns: Ephemeral synchronous switch context for one user/runtime operation.
   - Side effects: None during construction; invoked callbacks mutate active category state,
     PageManager selection fields, persistence, and reader content.
   - Failure modes: Callbacks become no-ops after controller deallocation or without a pane.
   */
  private func makeSQLiteModuleSwitchContext() -> BibleReaderSQLiteModuleSwitchContext {
    BibleReaderSQLiteModuleSwitchContext(
      resolveModule: { [weak self] name, category in
        self?.sqliteRuntimeCoordinator.preferredModule(named: name, category: category)
      },
      currentDictionaryKey: { [weak self] in
        self?.currentDictionaryKey
      },
      currentCategory: { [weak self] in
        self?.currentCategory ?? .bible
      },
      isClientReady: { [weak self] in
        self?.clientReady == true
      },
      activateBible: { [weak self] module in
        self?.activeModule = nil
        self?.activeSQLiteBibleModule = module
        self?.activeModuleName = module.info.name
      },
      activateCommentary: { [weak self] module in
        self?.activeCommentaryModule = nil
        self?.activeSQLiteCommentaryModule = module
        self?.activeCommentaryModuleName = module.info.name
      },
      activateDictionary: { [weak self] module, key in
        self?.activeDictionaryModule = nil
        self?.activeSQLiteDictionaryModule = module
        self?.activeDictionaryModuleName = module.info.name
        self?.currentDictionaryKey = key
      },
      setCurrentCategory: { [weak self] category in
        self?.currentCategory = category
      },
      refreshBookList: { [weak self] in
        self?.refreshBookList()
      },
      persistSelection: { [weak self] category, moduleName, key, updatesVisible in
        guard let self, let pageManager = self.activeWindow?.pageManager else { return }
        switch category {
        case .bible:
          pageManager.bibleDocument = moduleName
        case .commentary:
          pageManager.commentaryDocument = moduleName
        case .dictionary:
          pageManager.dictionaryDocument = moduleName
          pageManager.dictionaryKey = key
        default:
          return
        }
        if updatesVisible {
          pageManager.currentCategoryName = category.pageManagerKey
        }
        self.onPersistState?()
      },
      reloadContent: { [weak self] in
        // Android's document/category switches select the new page and leave the MYNOTE
        // category, so SQLite-backed switches must exit My Notes like the SWORD switch path.
        self?.showingMyNotes = false
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
            resolveMemorizationRange: { [weak self] bookInitials, startOrdinal, endOrdinal in
                self?.memorizationOrdinalResolution(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
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

    /**
     Injects the night/day page background colors.

     Body/document colors are set natively because they must hold before the Vue client is ready
     (initial load, document replacement) when no `set_config` styling exists yet; once the client
     runs, the shared frontend derives the same colors from config. All layout and playback
     styling belongs exclusively to the shared frontend so Android's behavior keeps authority
     (issues #377 and the speak-highlight parity that followed it).

     - Side effects: Evaluates one JavaScript block in the pane web view.
     - Failure modes: Evaluation failures leave the previous styling; the next content load retries.
     */
    private func applyNightModeBackground() {
        let s = displaySettings
        let d = TextDisplaySettings.appDefaults
    let bgInt =
      nightMode
      ? (s.nightBackground ?? d.nightBackground ?? -16_777_216)
            : (s.dayBackground ?? d.dayBackground ?? -1)
    let fgInt =
      nightMode
            ? (s.nightTextColor ?? d.nightTextColor ?? -1)
      : (s.dayTextColor ?? d.dayTextColor ?? -16_777_216)
        let bg = Self.cssColor(fromArgbInt: bgInt)
        let fg = Self.cssColor(fromArgbInt: fgInt)
    bridge.webView?.evaluateJavaScript(
      """
        document.documentElement.style.backgroundColor = '\(bg)';
        document.body.style.backgroundColor = '\(bg)';
        document.body.style.color = '\(fg)';
        var content = document.getElementById('content');
        if (content) {
            content.style.removeProperty('padding-top');
            content.style.removeProperty('padding-bottom');
        }
        // Live speak-position marker styled as Android's red speak-label bookmark so the
        // reading position stays visible during playback on both platforms' visual language.
        if (!document.getElementById('ios-speak-position')) {
            var s = document.createElement('style');
            s.id = 'ios-speak-position';
            s.textContent = '.speak-position { text-decoration: underline; text-decoration-thickness: 2px; text-decoration-color: rgb(255, 0, 0); text-underline-offset: 3px; }';
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
        guard let service = speakService else { return }
        service.bookmarkManager = bookmarkService

        switch currentCategory {
        case .bible:
            guard let session = defaultSpeechSession(service: service) else { return }
            service.currentTitle = session.title
            service.currentSubtitle = session.subtitle
            service.speak(provider: session.provider, callbacks: session.callbacks)
        case .commentary:
            guard let name = activeCommentaryModuleName else { return }
            let key = "\(osisBookId(for: currentBook)) \(currentChapter):\(currentVerse)"
            _ = startGenericSpeech(
                bookInitials: name,
                key: key,
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .commentary,
                service: service
            )
        case .dictionary:
            guard let name = activeDictionaryModuleName else { return }
            _ = startGenericSpeech(
                bookInitials: name,
                key: currentDictionaryKey,
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .dictionary,
                service: service
            )
        case .generalBook, .epub, .dailyDevotion:
            speakCurrentGeneralDocument(service: service)
        case .map:
            guard let name = activeMapModuleName else { return }
            _ = startGenericSpeech(
                bookInitials: name,
                key: currentMapKey,
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .generalBook,
                service: service
            )
        }
    }

    /**
     Starts an explicitly identified Bible or memorization source through strict v11n conversion.

     - Parameters describe the Android bridge category, requested installed module, source
       versification, and inclusive source ordinals.
     - Returns: `true` only when the requested source resolves and starts.
     - Side effects: Replaces active speech and installs generation-scoped reader callbacks.
     - Failure modes: Missing modules, wrong categories, unsupported versifications, and unmappable
       or unaddressable ordinals fail closed without using the active Bible.
     */
    @discardableResult
    private func startBibleSpeech(
        category: SpeakDocumentCategory,
        bookInitials: String,
        versification: String,
        startOrdinal: Int,
        endOrdinal: Int,
        service: SpeakService
    ) -> Bool {
    if let module = sqliteRuntimeCoordinator.preferredModule(
      named: bookInitials,
      category: .bible
    ),
      let session = sqliteBibleSpeechSession(
        module: module,
        category: category,
        sourceVersification: versification,
        startOrdinal: startOrdinal,
        endOrdinal: category == .memorization ? endOrdinal : startOrdinal,
        service: service
      )
    {
      service.currentTitle = session.title
      service.currentSubtitle = session.subtitle
      service.speak(provider: session.provider, callbacks: session.callbacks)
      return true
    }
        guard let requestedModule = swordManager?.module(named: bookInitials),
      let context = makeSpeechContext(module: requestedModule)
    else {
            return false
        }
        let effectiveEnd = category == .memorization ? endOrdinal : startOrdinal
        return speechCoordinator.speakBibleRequest(
            SpeakSelectionRequest(
                category: category,
                bookInitials: bookInitials,
                key: "",
                startOrdinal: startOrdinal,
                endOrdinal: effectiveEnd,
                versification: versification
            ),
            service: service,
            context: context
        )
    }

  /**
   Builds a serialized SQLite Bible speech session and pane-owned synchronization callbacks.

   - Parameters describe exact source identity/ordinals or an optional persisted checkpoint.
   - Returns: A complete session, or nil when source mapping or real verse addressability fails.
   - Side effects: Enumerates real SQLite verses; lazy text reads remain serialized by the handle.
   - Failure modes: Never falls back to SWORD or placeholder text.
   */
  private func sqliteBibleSpeechSession(
    module: BibleReaderSQLiteModuleHandle,
    category: SpeakDocumentCategory,
    sourceVersification: String = JSwordKJVAVersification.name,
    startOrdinal: Int?,
    endOrdinal: Int?,
    checkpoint: SpeakProviderCheckpoint? = nil,
    service: SpeakService
  ) -> SpeakSessionReconstruction? {
    sqliteSpeechDispatchCoordinator.bibleSession(
      module: module,
      category: category,
      sourceVersification: sourceVersification,
      startOrdinal: startOrdinal,
      endOrdinal: endOrdinal,
      checkpoint: checkpoint,
      service: service,
      context: BibleReaderSQLiteBibleSpeechContext(
        evaluateJavaScript: { [weak bridge] script in
          bridge?.webView?.evaluateJavaScript(script)
        },
        shouldSynchronize: { [weak service] in
          service?.advancedSettings.synchronize == true
        },
        synchronize: { [weak self] sourceModule, position in
          guard let self,
            let ordinal = position.ordinalStart,
            let chapter = position.chapter
          else {
            return
          }
          if !SwordJavaStringIdentity.equalsIgnoreCase(
            self.activeModuleName,
            sourceModule.info.name
          ) {
            self.switchBibleDocument(to: sourceModule.info.name)
          }
          self.navigateToSynchronizedPosition(
            book: position.bookName,
            chapter: chapter,
            ordinal: ordinal
          )
        }
      )
    )
  }

    /**
     Builds the speech collaborator context from the controller's current reader state.

     The context captures only the dependencies required for speech extraction and highlight
     emission. Closures capture the controller or bridge weakly so `SpeakService` callbacks do not
     retain the reader controller after the pane is dismissed.
     */
  private func makeSpeechContext(module requestedModule: SwordModule? = nil)
    -> BibleReaderSpeechContext?
  {
        guard let module = requestedModule ?? activeModule else { return nil }
        return BibleReaderSpeechContext(
            module: module,
            swordManager: swordManager,
            currentBook: currentBook,
            currentChapter: currentChapter,
            currentVerse: currentVerse,
            activeModuleName: module.info.name,
            displaySettings: displaySettings,
            osisBookId: { [weak self] bookName in
                self?.osisBookId(for: bookName) ?? BibleReaderController.osisBookId(for: bookName)
            },
            parseVerseKey: { [weak self] key in
                self?.parseVerseKey(key)
            },
            verseOrdinal: { osisBookId, chapter, verse in
                module.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
            },
            evaluateJavaScript: { [weak bridge] js in
                bridge?.webView?.evaluateJavaScript(js)
            },
            synchronizePosition: { [weak self] book, chapter, ordinal in
                guard let self else { return }
                if self.activeModuleName != module.info.name {
                    self.switchBibleDocument(to: module.info.name)
                }
                self.navigateToSynchronizedPosition(book: book, chapter: chapter, ordinal: ordinal)
            }
        )
    }

  /**
   Loads Android's optional raw versification property for one reading-plan definition.

   - Parameter planCode: Stable Android reading-plan code selected in the reader.
   - Returns: The selected definition's raw versification value, or nil when it omits the key.
   - Side effects: Reads bundled, user, and add-on plan definitions from the active module tree.
   - Throws: ReadingPlanDefinitionError when no valid definition exists for the supplied code.
   */
  @MainActor
  func readingPlanVersificationProperty(forPlanCode planCode: String) throws -> String? {
    try ReadingPlanService.versificationProperty(
      forPlanCode: planCode,
      modulePath: swordManager?.modulePath ?? SwordManager.defaultModulePath()
    )
  }

  /**
   Performs one Android-compatible Daily Reading request in the active Bible.

   Every passage is converted through the selected SWORD or Android SQLite source and proven
   addressable before either callback runs. Read preserves the complete mapped ordinal range for
   reader highlighting. Speak queues the ordered bounded passage list and succeeds only after the
   first utterance reaches the synthesizer acceptance boundary, allowing Daily Reading to persist
   progress only after a real action starts.

   - Parameter request: Exact plan-canon Read, Speak, or Speak All request.
   - Side effects: Navigates the exact active Bible once or appends one ordered passage list to
     source-owned speech.
   - Throws: Cancellation or BibleReaderDailyReadingActionFailure. Validation failures perform no
     navigation, speech, or progress mutation. Backend identity changes fail without fallback.
   */
  @MainActor
  func performDailyReadingAction(_ request: DailyReadingActionRequest) async throws {
    try Task.checkCancellation()
    let source: BibleReaderInstalledScriptureSource
    if let module = activeSQLiteBibleModule, module.info.category == .bible {
      source = .sqlite(module)
    } else if let module = activeModule, module.info.category == .bible {
      source = .sword(module)
    } else {
      throw BibleReaderDailyReadingActionFailure.activeBibleUnavailable
    }
    try BibleReaderDailyReadingActionCoordinator.perform(
      request,
      source: source,
      navigate: { [self] passage in
        switch source {
        case .sword(let module):
          guard activeModule === module, activeSQLiteBibleModule == nil else {
            throw BibleReaderDailyReadingActionFailure.activeBibleUnavailable
          }
        case .sqlite(let module):
          guard activeSQLiteBibleModule === module, activeModule == nil else {
            throw BibleReaderDailyReadingActionFailure.activeBibleUnavailable
          }
        }
        guard let bookName = try source.bookList().first(where: {
          $0.osisId == passage.start.osisBookId
        })?.name else {
          throw BibleReaderDailyReadingActionFailure.activeBibleUnavailable
        }
        pendingLinkNavigationOrdinalRange = [
          passage.ordinalRange.lowerBound,
          passage.ordinalRange.upperBound,
        ]
        navigationCoordinator.navigateTo(
          book: bookName,
          chapter: passage.start.chapter,
          verse: passage.start.verse,
          context: makeNavigationContext()
        )
      },
      speak: { [self] passages in
        guard let service = speakService else { return false }
        service.bookmarkManager = bookmarkService
        switch source {
        case .sword(let module):
          guard activeModule === module,
            activeSQLiteBibleModule == nil,
            let context = makeSpeechContext(module: module)
          else {
            return false
          }
          return speechCoordinator.speakBiblePassageList(
            ranges: passages.map(\.speechRange),
            service: service,
            context: context
          )
        case .sqlite(let module):
          guard activeSQLiteBibleModule === module, activeModule == nil,
            let session = sqliteSpeechDispatchCoordinator.biblePassageListSession(
              module: module,
              ranges: passages.map(\.speechRange),
              service: service,
              context: BibleReaderSQLiteBibleSpeechContext(
                evaluateJavaScript: { [weak bridge] script in
                  bridge?.webView?.evaluateJavaScript(script)
                },
                shouldSynchronize: { [weak service] in
                  service?.advancedSettings.synchronize == true
                },
                synchronize: { [weak self] sourceModule, position in
                  guard let self,
                    let ordinal = position.ordinalStart,
                    let chapter = position.chapter
                  else {
                    return
                  }
                  if !SwordJavaStringIdentity.equalsIgnoreCase(
                    self.activeModuleName,
                    sourceModule.info.name
                  ) {
                    self.switchBibleDocument(to: sourceModule.info.name)
                  }
                  self.navigateToSynchronizedPosition(
                    book: position.bookName,
                    chapter: chapter,
                    ordinal: ordinal
                  )
                }
              )
            )
          else {
            return false
          }
          let result = service.start(
            provider: session.provider,
            callbacks: session.callbacks,
            queue: true
          )
          guard result.succeeded else { return false }
          service.currentTitle = session.title
          service.currentSubtitle = session.subtitle
          return true
        }
      }
    )
  }

    /** One exact non-Bible source resolved from Android module initials. */
    private enum GenericSpeechSource {
        case sword(module: SwordModule, category: SpeakDocumentCategory)
        case epub(EpubReader)
        case myDocument(MyDocument)
    }

    /** Builds category-correct SWORD generic context with source-owned document-switch navigation. */
    func makeGenericSpeechContext(
        module: SwordModule,
        moduleName: String,
        category: SpeakDocumentCategory,
        currentKey: String?
    ) -> BibleReaderGenericSpeechContext? {
        guard module.info.name == moduleName else { return nil }
        return BibleReaderGenericSpeechContext(
            category: category,
            module: module,
            currentKey: currentKey,
            moduleName: moduleName,
            displayName: module.info.description.isEmpty ? moduleName : module.info.description,
            displaySettings: displaySettings,
            swordManager: swordManager,
            ordinalForKey: { [weak self] sourceKey, index in
                guard category == .commentary,
          let (book, chapter, verse) = self?.parseVerseKey(sourceKey)
        else {
                    return index
                }
                let osisID = self?.osisBookId(for: book) ?? BibleReaderController.osisBookId(for: book)
                return module.verseOrdinal(osisBookId: osisID, chapter: chapter, verse: verse) ?? index
            },
            synchronizeKey: { [weak self] sourceKey, _ in
                guard let self else { return }
                switch category {
                case .commentary:
                    if self.activeCommentaryModuleName != moduleName {
                        self.switchCommentaryDocument(to: moduleName)
                    }
                    if let (book, chapter, verse) = self.parseVerseKey(sourceKey) {
                        self.currentBook = book
                        self.currentChapter = chapter
                        self.currentVerse = verse
                        self.loadCommentaryForCurrentVerse()
                    }
                case .dictionary:
                    if self.activeDictionaryModuleName != moduleName {
                        self.switchDictionaryDocument(to: moduleName)
                    }
                    self.loadDictionaryEntry(key: sourceKey)
                case .generalBook:
                    if module.info.category == .map {
                        if self.activeMapModuleName != moduleName {
                            self.switchMapDocument(to: moduleName)
                        }
                        self.loadMapEntry(key: sourceKey)
                    } else {
                        if self.activeGeneralBookModuleName != moduleName {
                            self.switchGeneralBookDocument(to: moduleName)
                        }
                        self.loadGeneralBookEntry(key: sourceKey)
                    }
                case .myDocument, .bible, .memorization, .selection:
                    break
                }
            }
        )
    }

    /** Maps one SWORD category to Android's corresponding generic speech provider. */
  private static func genericSpeechCategory(for category: ModuleCategory) -> SpeakDocumentCategory?
  {
        BibleReaderSpeechProviderFactory.category(for: category)
    }

    /**
     Resolves one readable generic source while preserving Android global-registry ownership.

     - Parameters:
       - bookInitials: Exact persisted source initials.
       - expectedCategory: Persisted provider category, or `nil` for bridge-owned routing.
     - Returns: One authorized SWORD, EPUB, or My Documents source when identity is unambiguous.
     - Side effects: Captures one fresh installed-module resolver snapshot; no content is read.
     - Failure modes: Locked native owners and registered SQLite identities fail closed and suppress
       colliding local-document/EPUB sources. Missing, wrong-category, and ambiguous sources return
       `nil` without constructing a speech provider.
     */
    private func genericSpeechSource(
        bookInitials: String,
        expectedCategory: SpeakDocumentCategory?
    ) -> GenericSpeechSource? {
        let resolver = installedModuleResolver()
        let registeredSource = resolver.module(named: bookInitials)
        let globalRegistryOwnsIdentity = resolver.hasNativeRegistration(named: bookInitials)
            || registeredSource != nil
        var candidates: [GenericSpeechSource] = []
    if !globalRegistryOwnsIdentity,
      expectedCategory == nil || expectedCategory == .generalBook
      || expectedCategory == .myDocument,
      let document = myDocumentStore?.document(initials: bookInitials)
    {
            candidates.append(.myDocument(document))
        }
        if !globalRegistryOwnsIdentity,
           expectedCategory == nil || expectedCategory == .generalBook,
           let reader = activeEpubReader?.initials == bookInitials
               ? activeEpubReader
        : EpubReader(initials: bookInitials)
    {
            candidates.append(.epub(reader))
        }
        if case .sword(let module)? = registeredSource,
           let category = Self.genericSpeechCategory(for: module.info.category),
      expectedCategory == nil || expectedCategory == category
    {
            candidates.append(.sword(module: module, category: category))
        }
        guard candidates.count == 1 else {
            if candidates.count > 1 {
                logger.error("Ambiguous speech source identity: \(bookInitials, privacy: .public)")
            }
            return nil
        }
        return candidates[0]
    }

    /** Projects My Documents pages into deterministic provider order. */
    private func myDocumentSpeechPages(_ document: MyDocument) -> [BibleReaderSpeechPage] {
        (document.pages ?? []).sorted {
            if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
            return $0.pageKey < $1.pageKey
        }.map { page in
            let content = page.pageContent?.content ?? ""
            return BibleReaderSpeechPage(
                key: page.pageKey,
                title: page.title,
                plainText: GenericBookmarkSourceTextProjection.myDocumentText(
                    content,
                    contentType: page.contentType
                ),
                rawMarkup: page.contentType == .osis ? content : "",
                ordinalRange: 0...0,
                language: page.languageCode ?? "en"
            )
        }
    }

    /**
     Builds one exact generic session without falling back to the visible Bible or another source.

     The optional checkpoint selects reconstruction mode; otherwise `key` and local ordinal bounds
     represent Android's `BookAndKey`. An expected category is authoritative, except that Android's
     generated MyDocument modules arrive through the general-book DOM category and are reclassified.
     */
    private func genericSpeechSession(
        bookInitials: String,
        key: String?,
        startOrdinal: Int?,
        endOrdinal: Int?,
        expectedCategory: SpeakDocumentCategory?,
        checkpoint: SpeakProviderCheckpoint? = nil,
        service: SpeakService
    ) -> SpeakSessionReconstruction? {
    if let session = sqliteGenericSpeechSession(
      bookInitials: bookInitials,
      key: key,
      startOrdinal: startOrdinal,
      endOrdinal: endOrdinal,
      expectedCategory: expectedCategory,
      checkpoint: checkpoint,
      service: service
    ) {
      return session
    }
    guard
      let source = genericSpeechSource(
            bookInitials: bookInitials,
            expectedCategory: expectedCategory
      )
    else {
            return nil
        }
        switch source {
        case .sword(let module, let category):
      guard
        let context = makeGenericSpeechContext(
                module: module,
                moduleName: bookInitials,
                category: category,
                currentKey: key
        )
      else {
                return nil
            }
            if let checkpoint {
                return speechCoordinator.reconstructGenericModuleSession(
                    checkpoint: checkpoint,
                    service: service,
                    context: context
                )
            }
            return speechCoordinator.genericModuleSession(
                service: service,
                context: context,
                requestedKey: key,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        case .epub(let reader):
            let synchronize: @MainActor (String, Int) -> Void = { [weak self] sourceKey, ordinal in
                guard let self else { return }
                if self.activeEpubReader?.initials != reader.initials {
                    self.activateEpub(reader, identifier: reader.identifier, requestedKey: sourceKey)
                }
                self.loadEpubEntry(key: sourceKey, jumpToOrdinal: ordinal)
            }
            if let checkpoint {
                return speechCoordinator.reconstructPageSession(
                    checkpoint: checkpoint,
                    category: .generalBook,
                    bookInitials: reader.initials,
                    bookName: reader.title,
                    pages: epubSpeechPages(reader),
                    service: service,
                    synchronize: synchronize
                )
            }
            return speechCoordinator.pageSession(
                category: .generalBook,
                bookInitials: reader.initials,
                bookName: reader.title,
                pages: epubSpeechPages(reader),
                currentKey: key,
                service: service,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                synchronize: synchronize
            )
        case .myDocument(let document):
            let synchronize: @MainActor (String, Int) -> Void = { [weak self] sourceKey, _ in
                _ = self?.loadMyDocumentPage(bookInitials: document.initials, pageKey: sourceKey)
            }
            if let checkpoint {
                return speechCoordinator.reconstructPageSession(
                    checkpoint: checkpoint,
                    category: .myDocument,
                    bookInitials: document.initials,
                    bookName: document.name,
                    pages: myDocumentSpeechPages(document),
                    service: service,
                    synchronize: synchronize
                )
            }
            return speechCoordinator.pageSession(
                category: .myDocument,
                bookInitials: document.initials,
                bookName: document.name,
                pages: myDocumentSpeechPages(document),
                currentKey: key,
                service: service,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                synchronize: synchronize
            )
        }
    }

  /**
   Builds an exact SQLite commentary/dictionary speech session before SWORD resolution.

   - Parameters:
     - bookInitials: Android document identity requested by speech or checkpoint restoration.
     - key: Exact commentary or dictionary source key.
     - startOrdinal: Optional inclusive source start ordinal.
     - endOrdinal: Optional inclusive source end ordinal.
     - expectedCategory: Optional category constraint carried by the request.
     - checkpoint: Optional persisted provider state to reconstruct.
     - service: Speech service whose settings and callbacks own the session.
   - Returns: A source-backed reconstruction, or `nil` when the SQLite source/key cannot be proven.
   - Side effects: Reads SQLite content lazily and synchronizes accepted positions into the pane;
     Android-37 Java identity decides whether synchronization switches the active document first.
   - Failure modes: Missing, shadowed, wrong-category, malformed, and unreadable SQLite sources fail
     closed without falling through to SWORD or mutating an unrelated active document.
   */
  private func sqliteGenericSpeechSession(
    bookInitials: String,
    key: String?,
    startOrdinal: Int?,
    endOrdinal: Int?,
    expectedCategory: SpeakDocumentCategory?,
    checkpoint: SpeakProviderCheckpoint?,
    service: SpeakService
  ) -> SpeakSessionReconstruction? {
    sqliteSpeechDispatchCoordinator.genericSession(
      bookInitials: bookInitials,
      key: key,
      startOrdinal: startOrdinal,
      endOrdinal: endOrdinal,
      expectedCategory: expectedCategory,
      checkpoint: checkpoint,
      service: service,
      context: BibleReaderSQLiteGenericSpeechContext(
        resolveModule: { [weak self] name, category in
          self?.sqliteRuntimeCoordinator.preferredModule(
            named: name,
            category: category
          )
        },
        synchronize: { [weak self] module, category, sourceKey in
          guard let self else { return }
          switch category {
          case .commentary:
            if self.activeCommentaryModuleName.map({
              SwordJavaStringIdentity.equalsIgnoreCase($0, module.info.name)
            }) != true {
              self.switchCommentaryDocument(to: module.info.name)
            }
            guard
              let reference = SQLiteReaderNavigationResolver.commentaryCoordinate(
                for: sourceKey
              ), let bookName = self.bookName(forOsisId: reference.osisBookId)
            else {
              return
            }
            self.currentBook = bookName
            self.currentChapter = reference.chapter
            self.currentVerse = reference.verse
            self.loadCommentaryForCurrentVerse()
          case .dictionary:
            if self.activeDictionaryModuleName.map({
              SwordJavaStringIdentity.equalsIgnoreCase($0, module.info.name)
            }) != true {
              _ = self.switchDictionaryDocument(to: module.info.name)
            }
            self.loadDictionaryEntry(key: sourceKey)
          case .bible, .memorization, .generalBook, .myDocument, .selection:
            break
          }
        }
      )
    )
  }

    /** Starts one exact generic session and publishes its source-owned Now Playing metadata. */
    @discardableResult
    private func startGenericSpeech(
        bookInitials: String,
        key: String?,
        startOrdinal: Int?,
        endOrdinal: Int?,
        expectedCategory: SpeakDocumentCategory?,
        service: SpeakService
    ) -> Bool {
    guard
      let session = genericSpeechSession(
            bookInitials: bookInitials,
            key: key,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            expectedCategory: expectedCategory,
            service: service
      )
    else {
            return false
        }
        service.currentTitle = session.title
        service.currentSubtitle = session.subtitle
        service.speak(provider: session.provider, callbacks: session.callbacks)
        return true
    }

    /** Routes page-level Speak to the exact active EPUB, MyDocument, or SWORD general book. */
    private func speakCurrentGeneralDocument(service: SpeakService) {
        guard let initials = activeGeneralBookModuleName else { return }
        _ = startGenericSpeech(
            bookInitials: initials,
            key: currentGeneralBookKey,
            startOrdinal: nil,
            endOrdinal: nil,
            expectedCategory: .generalBook,
            service: service
        )
    }

    /** Builds deterministic EPUB speech pages in spine order without flattening them into one utterance. */
    private func epubSpeechPages(_ reader: EpubReader) -> [BibleReaderSpeechPage] {
        var pages: [BibleReaderSpeechPage] = []
        var visited = Set<String>()
        var key = reader.firstKey()
        while let currentKey = key, visited.insert(currentKey).inserted {
            if let content = reader.content(forKey: currentKey) {
                pages.append(
                    BibleReaderSpeechPage(
                        key: content.persistedKey,
                        title: content.title,
                        plainText: GenericBookmarkSourceTextProjection.xhtmlText(content.html),
                        rawMarkup: content.html,
                        ordinalRange: content.ordinalRange,
                        language: reader.language
                    )
                )
            }
            key = reader.nextKey(after: currentKey)
        }
        return pages
    }

    /** Reconstructs a persisted pause/last-position checkpoint from its exact source identity. */
    func reconstructSpeechSession(
        from checkpoint: SpeakProviderCheckpoint,
        service: SpeakService
    ) -> SpeakSessionReconstruction? {
        let cursor = checkpoint.current
        switch cursor.category {
        case .bible, .memorization:
      if let module = sqliteRuntimeCoordinator.preferredModule(
        named: cursor.bookInitials,
        category: .bible
      ) {
        return sqliteBibleSpeechSession(
          module: module,
          category: cursor.category,
          startOrdinal: cursor.ordinalStart,
          endOrdinal: cursor.ordinalEnd,
          checkpoint: checkpoint,
          service: service
        )
      }
            guard let module = swordManager?.readableModule(named: cursor.bookInitials),
        let context = makeSpeechContext(module: module)
      else {
                return nil
            }
            return speechCoordinator.reconstructBibleSession(
                checkpoint: checkpoint,
                service: service,
                context: context
            )
        case .commentary, .dictionary, .generalBook, .myDocument:
            return genericSpeechSession(
                bookInitials: cursor.bookInitials,
                key: cursor.key,
                startOrdinal: cursor.ordinalStart,
                endOrdinal: cursor.ordinalEnd,
                expectedCategory: cursor.category,
                checkpoint: checkpoint,
                service: service
            )
        case .selection:
            return nil
        }
    }

    /** Builds Android remote Play's default provider from the exact currently visible source. */
    func defaultSpeechSession(service: SpeakService) -> SpeakSessionReconstruction? {
        switch currentCategory {
        case .bible:
      if let module = activeSQLiteBibleModule,
        let coordinate = SQLiteReaderNavigationResolver.coordinate(
          osisBookId: osisBookId(for: currentBook),
          chapter: currentChapter,
          verse: currentVerse
        ),
        let session = sqliteBibleSpeechSession(
          module: module,
          category: .bible,
          startOrdinal: coordinate.ordinal,
          endOrdinal: coordinate.ordinal,
          service: service
        )
      {
        _ = service.resetPassageRepeatIfOutsideRange(for: session.provider)
        return session
      }
            guard let module = activeModule,
                  let context = makeSpeechContext(module: module),
                  let ordinal = module.verseOrdinal(
                      osisBookId: osisBookId(for: currentBook),
                      chapter: currentChapter,
                      verse: currentVerse
        )
      else {
                return nil
            }
      guard
        let session = speechCoordinator.bibleSession(
                request: SpeakSelectionRequest(
                    category: .bible,
                    bookInitials: module.info.name,
                    key: "\(osisBookId(for: currentBook)).\(currentChapter).\(currentVerse)",
                    startOrdinal: ordinal,
                    endOrdinal: ordinal,
                    versification: VersificationMapper.versificationName(for: module)
                ),
                service: service,
                context: context
        )
      else {
                return nil
            }
            _ = service.resetPassageRepeatIfOutsideRange(for: session.provider)
            return session
        case .commentary:
            guard let initials = activeCommentaryModuleName else { return nil }
            return genericSpeechSession(
                bookInitials: initials,
                key: "\(osisBookId(for: currentBook)) \(currentChapter):\(currentVerse)",
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .commentary,
                service: service
            )
        case .dictionary:
            guard let initials = activeDictionaryModuleName else { return nil }
            return genericSpeechSession(
                bookInitials: initials,
                key: currentDictionaryKey,
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .dictionary,
                service: service
            )
        case .generalBook, .epub, .dailyDevotion:
            guard let initials = activeGeneralBookModuleName else { return nil }
            return genericSpeechSession(
                bookInitials: initials,
                key: currentGeneralBookKey,
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .generalBook,
                service: service
            )
        case .map:
            guard let initials = activeMapModuleName else { return nil }
            return genericSpeechSession(
                bookInitials: initials,
                key: currentMapKey,
                startOrdinal: nil,
                endOrdinal: nil,
                expectedCategory: .generalBook,
                service: service
            )
        }
    }

    /** Returns the visible Bible position used when settings change while playback is stopped. */
    func stoppedBibleSpeechPosition(service: SpeakService) -> SpeakStreamPosition? {
        guard currentCategory == .bible else { return nil }
        return defaultSpeechSession(service: service)?.provider.currentPosition
    }

    /**
     Creates the backend-neutral installed-Bible registry used by one Search presentation.

     Freshly verified readable SWORD modules are registered first. Android-compatible SQLite modules
     reuse the runtime coordinator's validated, registration-ordered handles while
     `BibleSearchIndexSourceRegistry` keeps native SWORD ownership of collisions.

     - Returns: Immutable source snapshot, or nil before a SWORD manager is configured.
     - Side effects: Reads one fresh native inventory snapshot and reuses the coordinator's
       validated SQLite snapshot; no module is unlocked or rediscovered.
     - Failure modes: Locked/unreadable native Bibles and SQLite identities shadowed by any native
       registration are absent, preventing Search from indexing a source reader cannot navigate.
     */
    @MainActor
    func makeSearchIndexSourceRegistry() -> BibleSearchIndexSourceRegistry? {
        guard let swordManager else { return nil }

        var registeredSwordIdentities = Set<SQLiteDocumentIdentity>()
        var swordSources: [any BibleSearchIndexSource] = []
        for info in swordManager.installedModules()
        where info.category == .bible
            && !BibleReaderSQLiteModuleCatalog.isSQLiteProjection(info)
            && (!info.isEncrypted || info.isUnlocked) {
            let identity = SQLiteDocumentIdentity(info.name)
            guard registeredSwordIdentities.insert(identity).inserted,
                  let module = swordManager.module(named: info.name),
                  module.info.category == .bible else {
                continue
            }
            swordSources.append(module)
        }

        let sqliteSources: [any BibleSearchIndexSource] = sqliteRuntimeCoordinator
            .unshadowedSQLiteModules(category: .bible)
            .map(\.searchIndexSource)
        return BibleSearchIndexSourceRegistry(
            primarySources: swordSources,
            additionalSources: sqliteSources
        )
    }

    /**
     Opens the exact module and canonical verse carried by a Search result.

     - Parameter target: Search-owned module identity and canonical OSIS coordinate.
     - Returns: True only after the requested backend became active and navigation was dispatched.
     - Side effects: May switch the visible Bible, persist pane selection, and load the target verse.
     - Failure modes: Missing/stale modules, failed switches, category mismatches, and unresolved book
       names return false without navigating through the previously active Bible.
     */
    @MainActor
    @discardableResult
    func navigateToSearchResult(_ target: SearchNavigationTarget) -> Bool {
        guard target.chapter > 0,
              target.verse > 0,
              !target.osisBookId.isEmpty,
              let source = makeSearchIndexSourceRegistry()?.source(named: target.moduleName) else {
            return false
        }
        let resolvedName = source.searchIndexModuleInfo.name
        if activeModuleName != resolvedName || currentCategory != .bible {
            switchBibleDocument(to: resolvedName)
        }
        guard activeModuleName == resolvedName,
              currentCategory == .bible,
              let bookName = bookName(forOsisId: target.osisBookId)
                ?? (!target.displayBook.isEmpty ? target.displayBook : nil) else {
            return false
        }
        navigateTo(book: bookName, chapter: target.chapter, verse: target.verse)
        return true
    }

    /**
     Opens Android SearchResults' complete visible match set in the configured links window.

     Android converts every displayed translation match into a `BookAndKey` and opens the resulting
     `FakeBookFactory.multiDocument`. iOS preserves each match's exact module and source
     versification, builds the shared Vue `MultiDocument`, and routes it through the same links-window
     callback used by cross references and dictionary results.

     - Parameter results: Canonically grouped Search results in current display order.
     - Returns: `true` only when at least one exact fragment was serialized and routed.
     - Side effects: May create/select the configured links window or replace the current pane with
       the transient Multi document when no owner callback is installed.
     - Failure modes: Empty results, stale modules, unmappable coordinates, unreadable exact verse
       entries, and serialization failure return `false` without dismissing Search.
     */
    @MainActor
    @discardableResult
    func openSearchResultsInLinksWindow(_ results: SearchGroupedResults) -> Bool {
        guard let registry = makeSearchIndexSourceRegistry() else { return false }
        let references: [OsisRef] = results.groups.flatMap { group in
            group.matches.compactMap { hit in
                guard let source = registry.source(named: hit.moduleName) else { return nil }
                let moduleInfo = source.searchIndexModuleInfo
                let configuredVersification = moduleInfo.aboutMetadata.versification
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceVersification = (source as? SwordModule)
                    .map(VersificationMapper.versificationName(for:))
                    ?? (configuredVersification.isEmpty
                        ? JSwordKJVAVersification.name
                        : configuredVersification)
                return OsisRef(
                    book: hit.displayBook,
                    chapter: hit.identity.chapter,
                    verse: hit.identity.verse,
                    osisId: hit.identity.osisBookId,
                    sourceVersification: sourceVersification,
                    targetBookInitials: moduleInfo.name
                )
            }
        }
        guard !references.isEmpty,
              let documentJSON = buildBibleMultiReferenceDocumentJSON(refs: references) else {
            return false
        }
        if let openInLinksWindow = onOpenMultiReferenceDocumentInLinksWindow {
            openInLinksWindow(documentJSON)
        } else {
            loadMultiReferenceDocument(documentJSON)
        }
        return true
    }

    /** Reconstructs the correct provider for an Android Speak-label bookmark selection. */
    @MainActor
    func resumeSpeech(from bookmark: SpeakResumeBookmark) {
        guard let service = speakService else { return }
        service.bookmarkManager = bookmarkService
        let position = bookmark.position
        if position.category == .bible || position.category == .memorization {
            let verified = position.verifiedBibleRange
      let requestedInitials =
        position.bookInitials.isEmpty
                ? (verified?.sourceBookInitials ?? activeModuleName)
                : position.bookInitials
      let sourceVersification =
        position.versification
                ?? verified?.sourceVersification
        ?? sqliteRuntimeCoordinator.preferredModule(
          named: requestedInitials,
          category: .bible
        )
        .map { _ in JSwordKJVAVersification.name }
        ?? swordManager?.module(named: requestedInitials)
        .map(VersificationMapper.versificationName(for:))
      guard let sourceVersification else { return }
            guard let startOrdinal = position.ordinalStart ?? verified?.sourceOrdinalStart else {
                return
            }
            let endOrdinal = position.ordinalEnd ?? verified?.sourceOrdinalEnd ?? startOrdinal
            _ = startBibleSpeech(
                category: position.category,
                bookInitials: requestedInitials,
                versification: sourceVersification,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                service: service
            )
            service.reloadResumeBookmarks()
            return
        }

        guard let startOrdinal = position.ordinalStart else { return }
        _ = startGenericSpeech(
            bookInitials: position.bookInitials,
            key: position.key,
            startOrdinal: startOrdinal,
            endOrdinal: nil,
            expectedCategory: position.category,
            service: service
        )
        service.reloadResumeBookmarks()
    }

  /**
   Switches the selected Bible module without changing the visible category.

   - Parameter moduleName: Case-insensitive installed SWORD or Android SQLite initials.
   - Returns: `.switched` after activation, `.requiresUnlock` for a locked native SWORD module, or
     `.unavailable` when no compatible backend resolves.
   - Side effects: Updates the active backend, refreshes its real book list, persists
     `PageManager.bibleDocument`, and reloads current content when the client is ready.
   - Failure modes: Locked, unknown, and unsupported native modules leave controller, persisted, and
     rendered state unchanged. Serialized SQLite modules are readable and preserve their existing
     switch path.
  */
    @discardableResult
    public func switchModule(to moduleName: String) -> BibleReaderBibleModuleSwitchOutcome {
    if sqliteModuleSwitchCoordinator.switchBible(
      to: moduleName,
      updatesVisibleCategory: false,
      context: makeSQLiteModuleSwitchContext()
    ) {
      return .switched
    }
    return moduleSwitchCoordinator.switchModule(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext()
    )
    }

    /**
     Switches the visible document to a Bible module in one Android-parity transition.

     Android's `CurrentPageManager.setCurrentDocument(book)` updates the selected Bible and active
     page together before notifying the reader. This method gives iOS the same contract for toolbar
     quick selectors and the full module picker: the pane's Bible document and category are updated
     together, persisted together, and then rendered once when the web client is ready.

     - Parameter moduleName: Installed SWORD Bible module abbreviation to make current.
     - Returns: `.switched` after the atomic transition, `.requiresUnlock` before mutation for a
       locked native SWORD module, or `.unavailable` for missing and incompatible targets.
     - Side effects:
       - mutates the active Bible module and current document category
       - refreshes the cached Bible book list for the selected module
       - writes `bibleDocument` and `currentCategoryName` to the active pane's `PageManager`
       - invokes `onPersistState` once when pane state is available
       - reloads the visible reader document once when the JavaScript client is ready
     - Failure modes:
       - locked and unavailable native modules leave controller/page/render state unchanged
       - if the resolved module is not a Bible, logs a warning and leaves controller/page state
         unchanged
     - Important: Main-actor isolated because successful switches can mutate SwiftUI-observed reader
       state and synchronously emit WebView bridge updates through `loadCurrentContent()`.
     */
    @MainActor
    @discardableResult
    public func switchBibleDocument(to moduleName: String) -> BibleReaderBibleModuleSwitchOutcome {
    if sqliteModuleSwitchCoordinator.switchBible(
      to: moduleName,
      updatesVisibleCategory: true,
      context: makeSQLiteModuleSwitchContext()
    ) {
      return .switched
    }
    return moduleSwitchCoordinator.switchBibleDocument(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext()
    )
    }

  /**
   Switches the selected commentary module without changing the visible category.

   - Parameter moduleName: Case-insensitive installed SWORD or Android SQLite initials.
   - Returns: `.switched` after readable activation, or `.failed` before mutation.
   - Side effects: Updates and persists the commentary backend, reloading only when commentary is
     already visible and the client is ready.
   - Failure modes: Locked, unknown, unreadable, and unsupported modules leave controller,
     persisted state, and rendered content unchanged.
  */
  @discardableResult
  public func switchCommentaryModule(
    to moduleName: String
  ) -> BibleReaderCommentaryModuleSwitchOutcome {
    if sqliteModuleSwitchCoordinator.switchCommentary(
      to: moduleName,
      updatesVisibleCategory: false,
      context: makeSQLiteModuleSwitchContext()
    ) {
      return .switched
    }
    return moduleSwitchCoordinator.switchCommentaryModule(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext()
    )
    }

    /**
     Switches the visible document to a commentary module in one Android-parity transition.

     Android's toolbar quick selector delegates selected commentary documents to
     `setCurrentDocument(book)`, so the selected module and visible document category change
     together. This method keeps iOS on that contract for both quick selectors and full chooser
     selections that should show commentary content immediately.

     - Parameter moduleName: Installed SWORD commentary module abbreviation to make current.
     - Returns: `.switched` after readable activation, or `.failed` before mutation.
     - Side effects: On success, mutates the active commentary module/category, writes
       `commentaryDocument` and `currentCategoryName`, persists once, and reloads once when ready.
     - Failure modes: Locked, missing, unreadable, and wrong-category modules leave controller,
       `PageManager`, persistence, navigation, and rendered content unchanged.
     */
    @MainActor
    @discardableResult
    public func switchCommentaryDocument(
      to moduleName: String
    ) -> BibleReaderCommentaryModuleSwitchOutcome {
    if sqliteModuleSwitchCoordinator.switchCommentary(
      to: moduleName,
      updatesVisibleCategory: true,
      context: makeSQLiteModuleSwitchContext()
    ) {
      return .switched
    }
    return moduleSwitchCoordinator.switchCommentaryDocument(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext()
    )
    }

  /**
   Switches the selected dictionary module without changing the visible category.

   - Parameter moduleName: Installed dictionary initials to select.
   - Returns: Exact-key preservation, required key selection, or a retryable SWORD failure.
   - Side effects: On successful preflight, updates controller and `PageManager` dictionary state
     and invokes `onPersistState` when pane state exists.
   - Failure modes: Missing modules and validation/enumeration errors return `.failed` without
     changing module, key, category, or persistence state.
   */
  @discardableResult
  public func switchDictionaryModule(to moduleName: String) -> BibleReaderGenericModuleSwitchOutcome
  {
    if let outcome = sqliteModuleSwitchCoordinator.switchDictionary(
      to: moduleName,
      updatesVisibleCategory: false,
      context: makeSQLiteModuleSwitchContext()
    ) {
      return outcome
    }
    return moduleSwitchCoordinator.switchDictionaryModule(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext()
    )
    }

    /**
     Switches the visible document to a dictionary module in one Android-parity transition.

     Android's commentary quick popup can include dictionaries and selects them through the same
   current-document path as commentaries. The selected dictionary, exact retained key (or cleared
   invalid key), and visible category are persisted together before rendering content.

     - Parameter moduleName: Installed SWORD dictionary module abbreviation to make current.
   - Returns: Whether the previous exact key was retained, selection is required, or validation
     failed without mutating state.
     Side effects:
   - mutates the active dictionary module, retains a valid exact key or clears an invalid one, and
     sets the current category to dictionary
     - writes `dictionaryDocument`, `dictionaryKey`, and `currentCategoryName` to `PageManager`
     - invokes `onPersistState` once when pane state is available
   - reloads the visible reader document only when an exact retained key can render immediately;
     missing or empty keys wait for the caller's chooser selection
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a dictionary, logs a warning and leaves state unchanged
   - if SWORD cannot validate the current key or enumerate a required chooser, returns `.failed`
     and leaves state unchanged
     */
    @MainActor
  @discardableResult
  public func switchDictionaryDocument(
    to moduleName: String
  ) -> BibleReaderGenericModuleSwitchOutcome {
    if let outcome = sqliteModuleSwitchCoordinator.switchDictionary(
      to: moduleName,
      updatesVisibleCategory: true,
      context: makeSQLiteModuleSwitchContext()
    ) {
      return outcome
    }
    return moduleSwitchCoordinator.switchDictionaryDocument(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext()
    )
  }

  /**
   Returns exact chooser keys for the active dictionary backend.

   - Returns: Source-order SQLite keys or the SWORD module's immutable key snapshot.
   - Side effects: May populate the selected backend's bounded key cache.
   - Throws: The underlying SQLite or SWORD key-enumeration error.
   */
  public func activeDictionaryKeys() throws -> [String] {
    try sqliteDictionaryChooser.keys(
      sqliteModule: activeSQLiteDictionaryModule,
      swordModule: activeDictionaryModule
    )
  }

  /**
   Captures the active dictionary as one backend-independent browser source.

   - Returns: An immutable SQLite or SWORD source snapshot, or `nil` when no dictionary is active.
   - Side effects: None; key and entry reads remain lazy until the browser requests them.
   - Failure modes: None. Backend failures are surfaced by the browser source's read operations.
   */
  func activeDictionaryBrowserSource() -> DictionaryBrowserSource? {
    if let module = activeSQLiteDictionaryModule {
      return DictionaryBrowserSource(sqliteModule: module)
    }
    if let module = activeDictionaryModule {
      return DictionaryBrowserSource(swordModule: module)
    }
    return nil
    }

  /**
   Switches the selected general-book module without changing the visible category.

   - Parameter moduleName: Installed general-book initials to select.
   - Returns: Exact-key preservation, required key selection, or a retryable SWORD failure.
   - Side effects: On successful preflight, updates controller and `PageManager` general-book
     state and invokes `onPersistState` when pane state exists.
   - Failure modes: Missing modules and validation/enumeration errors return `.failed` without
     changing module, key, category, or persistence state.
   */
  @discardableResult
  public func switchGeneralBookModule(to moduleName: String)
    -> BibleReaderGenericModuleSwitchOutcome
  {
    moduleSwitchCoordinator.switchGeneralBookModule(
      to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a general-book module in one Android-parity transition.

     Android's commentary quick popup includes general books and routes selected rows through the
     same current-document switch as other documents. iOS should not split this into separate module
     and category updates because that can persist partial pane state or reload stale content.

     - Parameter moduleName: Installed SWORD general-book module abbreviation to make current.
   - Returns: Whether the previous exact key was retained, selection is required, or validation
     failed without mutating state.
     Side effects:
   - mutates the active general-book module, retains a valid exact key or clears an invalid one, and
     sets the current category to general book
     - writes `generalBookDocument`, `generalBookKey`, and `currentCategoryName` to `PageManager`
     - invokes `onPersistState` once when pane state is available
   - reloads the visible reader document only when an exact retained key can render immediately;
     missing or empty keys wait for the caller's chooser selection
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a general book, logs a warning and leaves state unchanged
   - if SWORD cannot validate the current key or enumerate a required chooser, returns `.failed`
     and leaves state unchanged
     */
    @MainActor
  @discardableResult
  public func switchGeneralBookDocument(
    to moduleName: String
  ) -> BibleReaderGenericModuleSwitchOutcome {
    moduleSwitchCoordinator.switchGeneralBookDocument(
      to: moduleName, context: makeModuleSwitchContext())
    }

  /**
   Switches the selected map module without changing the visible category.

   - Parameter moduleName: Installed map initials to select.
   - Returns: Exact-key preservation, required key selection, or a retryable SWORD failure.
   - Side effects: On successful preflight, updates controller and `PageManager` map state and
     invokes `onPersistState` when pane state exists.
   - Failure modes: Missing modules and validation/enumeration errors return `.failed` without
     changing module, key, category, or persistence state.
   */
  @discardableResult
  public func switchMapModule(to moduleName: String) -> BibleReaderGenericModuleSwitchOutcome {
        moduleSwitchCoordinator.switchMapModule(to: moduleName, context: makeModuleSwitchContext())
    }

    /**
     Switches the visible document to a map module in one Android-parity transition.

     Android routes map rows through the same `setCurrentDocument(book)` path as Bible,
   commentary, dictionary, and general-book rows. iOS therefore persists the selected map, exact
   retained key (or cleared invalid key), and visible category together.

     - Parameter moduleName: Installed SWORD map module abbreviation to make current.
   - Returns: Whether the previous exact key was retained, selection is required, or validation
     failed without mutating state.
     Side effects:
   - mutates the active map module, retains a valid exact key or clears an invalid one, and sets the
     current category to map
     - writes `mapDocument`, `mapKey`, and `currentCategoryName` to `PageManager`
     - invokes `onPersistState` once when pane state is available
   - reloads the visible reader document only when an exact retained key can render immediately;
     missing or empty keys wait for the caller's chooser selection
     Failure modes:
     - if the module cannot be resolved, logs a warning and leaves controller/page state unchanged
     - if the resolved module is not a map, logs a warning and leaves state unchanged
   - if SWORD cannot validate the current key or enumerate a required chooser, returns `.failed`
     and leaves state unchanged
     */
    @MainActor
  @discardableResult
  public func switchMapDocument(to moduleName: String) -> BibleReaderGenericModuleSwitchOutcome {
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
        if isShowingAndroidMemorizeDocument {
            if let activeMemorizeEmission {
                renderMemorizeDocument(activeMemorizeEmission)
                return
            }
            // A persisted fake document keeps its own identity even when its source was relocked.
            // Never reinterpret that authorization failure as ordinary commentary content.
            _ = loadRestoredAndroidMemorizeDocument()
            return
        }

        if showingMyNotes {
            // Android keeps the My Notes page current through chapter stepping and passage
            // selection (`pageManager.currentPage.setKey` stays on the MYNOTE category), so
            // position-driven reloads regenerate the notes document for the new position
            // instead of exiting to the Bible text. Bookmark-list navigation and the return
            // affordance exit explicitly before loading. An explicit verse keeps its row jump
            // like Android's key-anchored reload; chapter stepping lands at the chapter top.
            let target: MyNotesTarget?
            if currentVerse > 1,
               let ordinal = kjvaOrdinal(
                   osisBookId: osisBookId(for: currentBook),
                   chapter: currentChapter,
                   verse: currentVerse,
                   sourceVersification: activeSourceVersificationName()
               ) {
                target = myNotesTarget(kjvaOrdinal: ordinal)
            } else {
                target = currentMyNotesTarget(jumpToOrdinal: nil)
            }
            if let target {
                loadMyNotesDocument(target: target)
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
    guard let restored = restoredMultiDocumentBuilder().build(pageKey: currentGeneralBookKey) else {
      return false
    }
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
     Rebuilds a restored Android Memorize fake document.

     Android persists Memorize as `commentary/Memorize` plus a serialized
     `commentary_sourceBookAndKey` source range. iOS stores that Android-only source in the existing
     workspace fidelity store and falls back to the local commentary anchor for older state that does
     not yet have the source JSON.

     - Returns: `true` when a Memorize document was rebuilt and rendered.
     - Side effects: May move the active SWORD module cursor while building Memorize text, emits the
       document through `renderMemorizeDocument`, and reapplies Android's fake-document identity.
     - Failure modes: Returns `false` when neither source JSON nor anchor ordinal can be resolved, or
       the resulting Memorize payload cannot be serialized.
     */
    private func loadRestoredAndroidMemorizeDocument() -> Bool {
        if let source = restoredMemorizeSourceFromFidelity() {
            return loadRestoredAndroidMemorizeDocument(source: source)
        }

        guard let anchorOrdinal = activeWindow?.pageManager?.commentaryAnchorOrdinal,
      let kjvaReference = JSwordKJVAVersification.verseReference(ordinal: anchorOrdinal)
    else {
            return false
        }
        let reference = VerseKeyReference(
            osisBookId: kjvaReference.osisId,
            chapter: kjvaReference.chapter,
            verse: kjvaReference.verse,
            ordinal: kjvaReference.ordinal
        )
        return loadRestoredAndroidMemorizeDocument(
            source: RestoredMemorizeSource(bookInitials: activeModuleName, references: [reference])
        )
    }

    /**
     Reads Android's preserved Memorize source range from page-manager fidelity storage.

     - Returns: Decoded source document initials and concrete verse references, or `nil` when no
       source key is available for the active window.
     - Side effects: Reads `SettingsStore` through `RemoteSyncWorkspaceFidelityStore`.
     - Failure modes: Malformed JSON, unsupported OSIS keys, or empty ranges return `nil`.
     */
    private func restoredMemorizeSourceFromFidelity() -> RestoredMemorizeSource? {
        guard let settingsStore,
              let windowID = activeWindow?.id,
              let sourceBookAndKey = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
                .pageManagerEntry(for: windowID)?
        .commentarySourceBookAndKey
    else {
            return nil
        }
        return restoredMemorizeSource(serializedSourceBookAndKey: sourceBookAndKey)
    }

    /**
     Decodes one Android `BookAndKeySerialized` source value.

     Android writes JSON for current versions, but older tests and imported data may carry a plain
     OSIS key. Both forms are accepted so restore remains compatible with existing local state.

     - Parameter serializedSourceBookAndKey: Android source key JSON or plain OSIS key.
     - Returns: Source document initials and expanded verse references, or `nil` when invalid.
     - Side effects: None.
     - Failure modes: Malformed JSON falls back to plain OSIS parsing; invalid OSIS returns `nil`.
     */
  private func restoredMemorizeSource(serializedSourceBookAndKey: String) -> RestoredMemorizeSource?
  {
        let trimmed = serializedSourceBookAndKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(SerializedBookAndKey.self, from: data),
      let references = memorizeReferences(fromOsisKey: payload.key)
    {
            let document = payload.document?.isEmpty == false ? payload.document! : activeModuleName
            return RestoredMemorizeSource(bookInitials: document, references: references)
        }

        guard let references = memorizeReferences(fromOsisKey: trimmed) else { return nil }
        return RestoredMemorizeSource(bookInitials: activeModuleName, references: references)
    }

    /**
     Expands an OSIS verse or verse range into concrete KJVA references.

     - Parameter key: OSIS key such as `Gen.1.1` or `Gen.1.1-Gen.1.3`.
     - Returns: Ordered concrete verse references for the range, or `nil` when invalid.
     - Side effects: None.
     - Failure modes: Unsupported books, malformed chapters/verses, or reversed ranges return `nil`.
     */
    private func memorizeReferences(fromOsisKey key: String) -> [VerseKeyReference]? {
    let pieces =
      key
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .map { String($0) }
        guard let startToken = pieces.first,
      let start = parseOsisVerseReference(startToken)
    else {
            return nil
        }
    let end =
      pieces.count > 1
      ? parseOsisVerseReference(
                pieces[1],
                defaultBook: start.osisBookId,
                defaultChapter: start.chapter
      ) : start
        guard let end, start.ordinal <= end.ordinal else { return nil }

        let references = (start.ordinal...end.ordinal).compactMap { ordinal -> VerseKeyReference? in
            guard let reference = JSwordKJVAVersification.verseReference(ordinal: ordinal) else {
                return nil
            }
            return VerseKeyReference(
                osisBookId: reference.osisId,
                chapter: reference.chapter,
                verse: reference.verse,
                ordinal: reference.ordinal
            )
        }
        return references.isEmpty ? nil : references
    }

    /**
     Parses one OSIS verse token, optionally inheriting book/chapter from a range start.

     - Parameters:
       - token: OSIS token such as `Gen.1.1`, `1.3`, or `3`.
       - defaultBook: Book to use when `token` omits a book.
       - defaultChapter: Chapter to use when `token` omits a chapter.
     - Returns: Concrete verse reference with a KJVA ordinal, or `nil` when invalid.
     - Side effects: None.
     - Failure modes: Unsupported books and non-numeric chapter/verse components return `nil`.
     */
    private func parseOsisVerseReference(
        _ token: String,
        defaultBook: String? = nil,
        defaultChapter: Int? = nil
    ) -> VerseKeyReference? {
    let components =
      token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: true)
            .map { String($0) }

        let osisId: String
        let chapter: Int
        let verse: Int
        switch components.count {
        case 3:
            osisId = components[0]
            guard let parsedChapter = Int(components[1]),
        let parsedVerse = Int(components[2])
      else { return nil }
            chapter = parsedChapter
            verse = parsedVerse
        case 2:
            guard let defaultBook,
                  let parsedChapter = Int(components[0]),
        let parsedVerse = Int(components[1])
      else { return nil }
            osisId = defaultBook
            chapter = parsedChapter
            verse = parsedVerse
        case 1:
            guard let defaultBook,
                  let defaultChapter,
        let parsedVerse = Int(components[0])
      else { return nil }
            osisId = defaultBook
            chapter = defaultChapter
            verse = parsedVerse
        default:
            return nil
        }

    guard
      let ordinal = JSwordKJVAVersification.verseOrdinal(
            osisId: osisId,
            chapter: chapter,
            verse: verse
      )
    else {
            return nil
        }
        return VerseKeyReference(osisBookId: osisId, chapter: chapter, verse: verse, ordinal: ordinal)
    }

    /**
     Emits a restored Memorize source through the shared request builder.

     - Parameter source: Decoded Android source document initials and concrete verse references.
     - Returns: `true` when a valid Memorize emission was built and rendered.
     - Side effects: May move the source SWORD module cursor while extracting canonical text.
     - Failure modes: Returns `false` when the source has no references or cannot serialize.
     */
    private func loadRestoredAndroidMemorizeDocument(source: RestoredMemorizeSource) -> Bool {
        guard let request = restoredMemorizeDocumentRequest(source: source),
      let emission = annotationDocumentLoader().makeMemorizeDocumentEmission(request: request)
    else {
            return false
        }
        renderMemorizeDocument(emission)
        return true
    }

    /**
     Builds a Memorize document request for one restored source range.

     - Parameter source: Restored Android source document initials and verse references.
     - Returns: Request configured with an authorized SWORD handle and progress state.
     - Side effects: Captures one fresh installed-module resolver snapshot; no content is read.
     - Failure modes: Returns `nil` when the source has no concrete references, is no longer
       readable, is not a native SWORD Bible, or is shadowed by a locked native owner.
     */
  private func restoredMemorizeDocumentRequest(source: RestoredMemorizeSource)
    -> MemorizeDocumentRequest?
  {
        guard let firstReference = source.references.first,
      let lastReference = source.references.last
    else { return nil }
        let bookInitials = source.bookInitials.isEmpty ? activeModuleName : source.bookInitials
    guard case .sword(let sourceModule)? = installedModuleResolver().scripture(named: bookInitials)
    else { return nil }
        let referenceOrdinals = Set(source.references.map(\.ordinal))
        let request = MemorizeDocumentRequest(
            bookInitials: bookInitials,
            startOrdinal: firstReference.ordinal,
            endOrdinal: lastReference.ordinal,
            activeModuleName: bookInitials,
            currentBook: Self.bookName(forOsisId: firstReference.osisBookId) ?? firstReference.osisBookId,
            currentChapter: firstReference.chapter,
            osisBookId: firstReference.osisBookId,
            activeModule: sourceModule,
            swordManager: swordManager,
            stateJSON: activeWindow?.pageManager?.jsState,
            directVerseReferences: source.references,
            verseReference: { [weak self] book, ordinal in
                self?.verseReference(book: book, ordinal: ordinal)
            },
            parseVerseKey: { [weak self] key in
                self?.parseVerseKey(key)
            },
            placeholderVerseText: { book, chapter, verse in
                Self.placeholderVerseText(book: book, chapter: chapter, verse: verse)
            },
            memorizedOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                self?.memorizationProgressStore?.memorizedOrdinals(
                    bookInitials: "",
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                )
                .filter { referenceOrdinals.contains($0) }
                .sorted() ?? []
            },
            targetOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                self?.memorizationProgressStore?.targetOrdinals(
                    bookInitials: "",
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                )
                .filter { referenceOrdinals.contains($0) }
                .sorted() ?? []
            },
            readingProgressSettings: { [progressBridgeCoordinator] in
                progressBridgeCoordinator.readingProgressSettingsPayload()
            }
        )
        return request
    }

    /**
     Builds the restored Android `Multi` payload builder bound to this pane's SWORD/catalog state.

     The controller keeps only the orchestration decision of whether a restored fake document should
     render now. The builder owns Android's `BookAndKeyList` reconstruction rules and resolves each
     child against its persisted source module instead of the active pane's book catalog.

     - Returns: A builder configured with the active SWORD manager and active Bible fallback used
       only for Android's persisted `null:` source marker.
     - Side effects: None.
     - Failure modes: Missing SWORD/module state is deferred to the builder, which returns `nil`
       when it cannot rebuild a valid document.
     */
    private func restoredMultiDocumentBuilder() -> BibleReaderRestoredMultiDocumentBuilder {
        BibleReaderRestoredMultiDocumentBuilder(
            moduleResolver: installedModuleResolver(),
            activeModuleName: activeInstalledScriptureSource()?.info.name
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
    func loadCompareDocument(
        bookInitials: String? = nil,
        startOrdinal: Int? = nil,
        endOrdinal: Int? = nil
    ) {
    guard
      let request = makeBibleCompareDocumentRequest(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
      )
    else {
            return
        }
        let generation = beginReplacingContentIntent()
        let buildDocument = compareDocumentBuildOperation

        DispatchQueue.global(qos: .userInitiated).async {
            let documentJSON = buildDocument(request)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.contentIntentGeneration == generation,
          let documentJSON
        else {
                    return
                }
        self.loadTransientMultiDocument(
          documentJSON, renderedBook: "Compare", renderedKey: "compare")
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
     - Side effects: Emits labels and one Android-parity replacement transaction, resets transient
       selection/editing state, updates rendered-content state, emits active-window state, clears
       web selection, and reapplies the reader background.
     - Failure modes: Invalid JSON is forwarded unchanged to the bridge, matching the existing
       transient document contract.
     */
    private func emitTransientMultiDocument(_ request: BibleReaderTransientDocumentRequest) {
        beginReplacingContentIntent()
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        applyTransientPageIdentity(request)

        sendLabelsToVueJS()
        replaceDocument(
            documentJSON: request.documentJSON,
            setup: ReaderSetupContentPayload()
        )
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
      let pm = activeWindow?.pageManager
    else { return }
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
     Loads Android's exact commentary entry and linked-block metadata for the selected Bible verse.

     Side effects:
     - converts the active Bible verse into the commentary module's versification
     - reads structural OSIS and resolves the complete equal-content commentary block
     - clears and replaces the Vue document, emits typed setup/state events, and clears selection

     Failure modes:
     - missing modules, unsupported verse mappings, empty blocks, malformed OSIS, and encoding
       failures produce a deterministic no-content error document; no rendered-text or synthetic
       XML fallback is fabricated.
     */
    private func loadCommentaryForCurrentVerse() {
        beginReplacingContentIntent()
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()

    if let module = activeSQLiteCommentaryModule {
      loadSQLiteCommentaryForCurrentVerse(module: module)
      return
    }

        guard let module = activeCommentaryModule else {
            emitCommentaryErrorDocument(
                key: "\(osisBookId(for: currentBook)).\(currentChapter).\(max(1, currentVerse))",
                message: "No commentary module is installed. Download one from the module browser."
            )
            return
        }

        let walker = SwordModuleCommentaryWalker(module: module)
        guard let selected = commentaryReferenceForCurrentVerse(module: module, walker: walker) else {
            emitCommentaryErrorDocument(
                key: "\(osisBookId(for: currentBook)).\(currentChapter).\(max(1, currentVerse))",
        message: String(
          localized: "error_no_content", defaultValue: "No content for selected verse")
            )
            return
        }
        let block = SwordCommentaryBlockResolver(walker: walker).resolveBlock(containing: selected)
        guard let fragment = block.fragment, fragment.hasRenderableContent else {
            emitCommentaryErrorDocument(
                key: selected.osisRef,
        message: String(
          localized: "error_no_content", defaultValue: "No content for selected verse")
            )
            return
        }

        let source = fragment.source
        let localRange = fragment.contentOrdinalRange
        let commentaryRange = ReaderCommentaryRangePayload(
            startOsisRef: block.range.start.osisRef,
            endOsisRef: block.range.end.osisRef,
            name: block.range.name
        )
    guard
      let document = documentPayloadFactory().documentJSON(
            BibleReaderDocumentPayloadRequest(
                osisBookId: selected.osisBookId,
                bookName: fragment.keyName,
                chapter: selected.chapter,
                verseCount: 1,
                isNewTestament: fragment.isNewTestament,
                xml: fragment.xml,
                bookCategory: DocumentCategory.commentary.rawValue,
                bookInitials: source.initials,
                addChapter: false,
                documentKey: fragment.key,
                keyName: fragment.keyName,
                ordinalRangeOverride: [localRange.lowerBound, localRange.upperBound],
          fragmentOrdinalRange: fragment.keyOrdinalRange.map {
            [$0.lowerBound, $0.upperBound]
          },
                fragmentKey: fragment.fragmentKey,
                fragmentOsisRef: fragment.osisRef,
                annotateRef: fragment.annotateRef,
                fragmentFeatures: fragment.features,
                commentaryRange: commentaryRange,
                moduleName: source.name.isEmpty ? source.initials : source.name,
                moduleAbbreviation: source.abbreviation,
                versificationName: source.versification,
                language: source.language,
                direction: source.direction,
                sourceHasStrongs: source.hasStrongs
            )
      )
    else { return }
        sendLabelsToVueJS()
        replaceDocument(
            documentJSON: document,
            setup: ReaderSetupContentPayload()
        )
        setRenderedContentState(
            category: .commentary,
            moduleName: source.initials,
            book: selected.name,
            chapter: selected.chapter,
            key: fragment.key
        )
        emitActiveState()
        bridge.clearSelection()
        applyNightModeBackground()
    }

  /**
   Emits covering SQLite commentary for the selected KJVA verse.

   - Parameter module: Serialized active commentary handle.
   - Side effects: Performs one covering lookup, replaces Vue content, and updates rendered state.
   - Failure modes: Missing rows, reader errors, malformed markup, and serialization failure use
     the deterministic no-content error path; no SWORD or placeholder content is substituted.
   */
  private func loadSQLiteCommentaryForCurrentVerse(
    module: BibleReaderSQLiteModuleHandle
  ) {
    let sourceReference = SwordVersification.Reference(
      osisBookId: osisBookId(for: currentBook),
      chapter: currentChapter,
      verse: max(1, currentVerse)
    )
    let sourceKey =
      "\(sourceReference.osisBookId).\(sourceReference.chapter).\(sourceReference.verse)"
    guard
      let selected = SQLiteCommentaryReferenceRouter.kjvaReference(
        for: sourceReference,
        sourceVersification: activeSourceVersificationName()
      ), let selectedBookName = bookName(forOsisId: selected.osisId)
    else {
      emitCommentaryErrorDocument(
        key: sourceKey,
        message: String(
          localized: "error_no_content",
          defaultValue: "No content for selected verse"
        )
      )
      return
    }
    let content: BibleReaderSQLiteAuxiliaryDocument
    do {
      content = try SQLiteReaderDocumentContentBuilder(module: module).commentary(
        osisBookId: selected.osisId,
        bookName: selectedBookName,
        chapter: selected.chapter,
        verse: selected.verse,
        isNewTestament: isNewTestament(selectedBookName)
      )
    } catch {
      emitCommentaryErrorDocument(
        key: selected.osisRef,
        message: String(
          localized: "error_no_content",
          defaultValue: "No content for selected verse"
        )
      )
      return
    }

    guard let document = documentPayloadFactory().documentJSON(content.request) else { return }
    sendLabelsToVueJS()
    replaceDocument(
      documentJSON: document,
      setup: ReaderSetupContentPayload()
    )
    setRenderedContentState(
      category: .commentary,
      moduleName: module.info.name,
      book: selectedBookName,
      chapter: selected.chapter,
      key: content.key
    )
    emitActiveState()
    bridge.clearSelection()
    applyNightModeBackground()
  }

    /**
     Resolves the active Bible verse into one exact key in the commentary module's versification.

     - Parameters:
       - module: Active commentary module.
       - walker: Module-backed exact commentary reader.
   - Returns: Exact commentary verse metadata, or `nil` when conversion/read fails.
     - Side effects: Reads the commentary's exact structural fragment once.
   - Failure modes: Unknown books and unavailable exact commentary keys return `nil`. Public
     conversion retains Android's same-coordinate fallback before module addressability is tested.
     */
    private func commentaryReferenceForCurrentVerse(
        module: SwordModule,
        walker: SwordModuleCommentaryWalker
    ) -> SwordCommentaryVerseReference? {
        let sourceOsisBookId = osisBookId(for: currentBook)
        let targetVersification = VersificationMapper.versificationName(for: module)
    return BibleReaderCommentaryVersificationRouter.resolve(
      reference: .init(
                  osisBookId: sourceOsisBookId,
                  chapter: currentChapter,
        verse: max(1, currentVerse)
      ),
                  from: activeSourceVersificationName(),
                  to: targetVersification
    ) { mapped in
      try? walker.reference(
        forKey: "\(mapped.osisBookId).\(mapped.chapter).\(mapped.verse)"
      )
    }
    }

    /**
     Emits Android's error-document path for a commentary key without fabricating OSIS content.

     - Parameters:
       - key: Requested commentary OSIS key retained in native rendered state.
       - message: User-visible failure or no-content message.
     - Side effects: Atomically replaces Vue content/config/setup, emits active state, clears
       selection, and reapplies the reader background.
     - Failure modes: If error-document encoding fails, the existing reader document remains.
     */
    private func emitCommentaryErrorDocument(key: String, message: String) {
        guard let document = documentPayloadFactory().errorDocumentJSON(message: message) else {
            return
        }
        replaceDocument(
            documentJSON: document,
            setup: ReaderSetupContentPayload()
        )
        setRenderedContentState(
            category: .commentary,
            moduleName: activeCommentaryModuleName,
            book: currentBook,
            chapter: currentChapter,
            key: key
        )
        emitActiveState()
        bridge.clearSelection()
        applyNightModeBackground()
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
            documentReplacement: documentReplacementEmitter(),
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
   Loads one exact dictionary entry from the active backend into the reader WebView.

   - Parameter key: Exact requested key, or nil to reuse the retained pane key.
   - Side effects: Starts a replacement intent, dispatches to serialized SQLite structural
     content or the shared SWORD auxiliary loader, and persists only a successfully resolved key.
   - Failure modes: Missing selections, case mismatches, unreadable content, and malformed markup
     emit deterministic error documents without snapping keys or crossing backends.
     */
    public func loadDictionaryEntry(key: String? = nil) {
        beginReplacingContentIntent()
    if let module = activeSQLiteDictionaryModule {
      loadSQLiteDictionaryEntry(module: module, requestedKey: key)
      return
    }
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

  /**
   Loads and emits one exact SQLite dictionary entry.

   - Parameters:
     - module: Serialized active dictionary handle.
     - requestedKey: Exact chooser key, or nil to reuse the persisted exact key.
   - Side effects: Replaces reader content and persists only a successfully resolved exact key.
   - Failure modes: Missing selection, case mismatch, missing content, reader failure, malformed
     markup, and serialization failure never snap to a neighboring key or fallback backend.
   */
  private func loadSQLiteDictionaryEntry(
    module: BibleReaderSQLiteModuleHandle,
    requestedKey: String?
  ) {
    resetAuxiliaryContentState()
    guard let key = requestedKey ?? currentDictionaryKey else {
      emitSQLiteAuxiliaryError(
        category: .dictionary,
        moduleName: module.info.name,
        book: module.info.description,
        key: "none",
        message: "Select an entry from the key browser to view its definition."
      )
      return
    }
    let content: BibleReaderSQLiteAuxiliaryDocument
    do {
      content = try SQLiteReaderDocumentContentBuilder(module: module).dictionary(key: key)
    } catch {
      emitSQLiteAuxiliaryError(
        category: .dictionary,
        moduleName: module.info.name,
        book: key,
        key: key,
        message: "No definition available for \"\(key)\" in \(module.info.name)."
      )
      return
    }

    currentDictionaryKey = content.key
    if let pageManager = activeWindow?.pageManager {
      pageManager.dictionaryKey = content.key
      onPersistState?()
    }
    guard let document = documentPayloadFactory().documentJSON(content.request) else { return }
    replaceDocument(
      documentJSON: document,
      setup: ReaderSetupContentPayload()
    )
    setRenderedContentState(
      category: .dictionary,
      moduleName: module.info.name,
      book: content.keyName,
      key: content.key
    )
    applyNightModeBackground()
  }

  /**
   Emits one deterministic SQLite auxiliary error without fabricating source markup.

   - Parameters:
     - category: Reader category whose source failed.
     - moduleName: Exact serialized source initials.
     - book: Display label retained in rendered state.
     - key: Exact requested source key.
     - message: User-visible failure text.
   - Side effects: Atomically replaces Vue content/config/setup and updates rendered state.
   - Failure modes: Serialization failure leaves the existing reader document visible.
   */
  private func emitSQLiteAuxiliaryError(
    category: DocumentCategory,
    moduleName: String,
    book: String,
    key: String,
    message: String
  ) {
    guard let document = documentPayloadFactory().errorDocumentJSON(message: message) else {
      return
    }
    replaceDocument(
      documentJSON: document,
      setup: ReaderSetupContentPayload()
    )
    setRenderedContentState(
      category: category,
      moduleName: moduleName,
      book: book,
      key: key
    )
    applyNightModeBackground()
  }

    /// Load a general book entry and display it in the WebView.
    public func loadGeneralBookEntry(key: String? = nil) {
        if activeEpubReader != nil {
            loadEpubEntry(key: key)
            return
        }
        if let initials = activeGeneralBookModuleName,
      let document = myDocumentStore?.document(initials: initials)
    {
            let requestedKey = key ?? currentGeneralBookKey
      let resolvedKey =
        requestedKey.flatMap {
                myDocumentStore?.page(bookInitials: initials, pageKey: $0)?.pageKey
        }
        ?? (document.pages ?? []).sorted {
                if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
                return $0.pageKey < $1.pageKey
            }.first?.pageKey
            if let resolvedKey {
                _ = loadMyDocumentPage(bookInitials: initials, pageKey: resolvedKey)
            }
            return
        }
        beginReplacingContentIntent()
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
        noModuleMessage:
          "No general book module is selected. Download one from the module browser.",
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
        beginReplacingContentIntent()
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

    /**
     Handles Android's null selection from an empty general-book or map chooser.

     Android's `ChooseGeneralBookKey.itemSelected(null)` returns the owning document initials plus
     `document.globalKeyList.first().osisRef`. The chooser's displayed list may be empty after
   malformed keys are filtered, so the browser passes its already-loaded first raw key through to
   the same document loader as an ordinary selection.

     - Parameters:
       - module: Exact module that owned the dismissed chooser.
       - category: `.generalBook` or `.map`, identifying the destination page contract.
     - firstGlobalKey: First raw key from the browser's successful module enumeration.
     - Side effects: Loads the module's first global key when the same module still owns the pane.
     - Failure modes: Stale chooser callbacks, unsupported categories, and truly keyless modules
       fail closed. Empty/malformed first keys reach the structural loader and surface its explicit
       error document rather than selecting a neighboring key.
     */
  func handleEmptyGenericKeyChooser(
    module: SwordModule,
    category: DocumentCategory,
    firstGlobalKey: String?
  ) {
    guard let firstGlobalKey else { return }
        switch category {
        case .generalBook:
            guard activeGeneralBookModuleName == module.info.name else { return }
            loadGeneralBookEntry(key: firstGlobalKey)
        case .map:
            guard activeMapModuleName == module.info.name else { return }
            loadMapEntry(key: firstGlobalKey)
        default:
            return
        }
    }

    // MARK: - EPUB Support

    /**
     Switches to an EPUB through Android's general-book document contract.

     - Parameter identifier: Stable local EPUB library identifier.
     - Side effects: Activates the EPUB adapter, stores its initials/key in general-book PageManager
       fields, clears legacy EPUB fields, and reloads the reader when ready.
     - Failure modes: An unreadable identifier is logged and leaves the current document unchanged.
     */
    public func switchEpub(identifier: String) {
        guard let reader = EpubReader(identifier: identifier) else {
            logger.warning("Failed to open EPUB: \(identifier)")
            return
        }
        activateEpub(reader, identifier: identifier, requestedKey: reader.firstKey())
        if clientReady {
            loadEpubEntry()
        }
    }

    /**
     Adopts an explicitly rebuilt generation for the currently active EPUB.

     Android's EPUB Search Rebuild index flow replaces the current backend index while preserving
     the selected document and key. The native reader uses immutable generations, so this method
     accepts only the same stable EPUB identity, reuses the existing activation contract, and
     immediately re-renders the current key before the prior generation lease can be released.

     - Parameter reader: Newly published reader returned by `EpubReader.rebuildSearchIndex`.
     - Returns: `true` when the active EPUB was safely replaced; `false` for a stale callback or a
       different document identity.
     - Side effects: Replaces the active EPUB generation, preserves/persists the current key, and
       reloads its Vue document when the bridge is ready.
     - Failure modes: A mismatched identifier or initials fails closed without changing reader,
       PageManager, rendered content, or persistence state.
     */
    @discardableResult
    public func adoptRebuiltEpubReader(_ reader: EpubReader) -> Bool {
        guard activeEpubIdentifier == reader.identifier,
              activeEpubReader?.initials == reader.initials else {
            return false
        }
        let requestedKey = currentGeneralBookKey ?? reader.firstKey()
        activateEpub(reader, identifier: reader.identifier, requestedKey: requestedKey)
        if clientReady {
            loadEpubEntry(key: requestedKey)
        }
        return true
    }

  /**
   Releases a deleted EPUB and returns its pane to the selected Bible document.

   The library removes the EPUB's stable pointer before invoking this method. Existing readers own
   immutable-generation leases, so clearing the active adapter releases that lease only after the
   storage transaction has committed. Other EPUBs and SWORD general books are left untouched.

   - Parameter identifier: Stable library identifier whose deletion committed successfully.
   - Side effects: Clears matching EPUB/general-book state, removes persisted EPUB page identity,
     switches to the pane's selected Bible, and reloads visible content when the bridge is ready.
   - Failure modes: A nonmatching identifier is ignored. If no Bible is selected, the pane enters
     the Bible category and renders the controller's ordinary no-content state.
   */
  @MainActor
  public func reconcileDeletedEpub(identifier: String) {
    guard activeEpubIdentifier == identifier else { return }

    activeEpubReader = nil
    activeEpubIdentifier = nil
    activeEpubTitle = nil
    currentEpubHref = nil
    currentEpubTitle = nil
    activeGeneralBookModule = nil
    activeGeneralBookModuleName = nil
    currentGeneralBookKey = nil

    if let pageManager = activeWindow?.pageManager {
      pageManager.generalBookDocument = nil
      pageManager.generalBookKey = nil
      pageManager.epubIdentifier = nil
      pageManager.epubHref = nil
    }

    if activeModule != nil {
      switchBibleDocument(to: activeModuleName)
      return
    }

    currentCategory = .bible
    activeWindow?.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
    onPersistState?()
    if clientReady {
      loadCurrentContent()
    }
  }

    /// Applies one opened adapter as the active general-book document and persists its identity.
    private func activateEpub(_ reader: EpubReader, identifier: String, requestedKey: String?) {
        activeEpubReader = reader
        activeEpubIdentifier = identifier
        activeEpubTitle = reader.title
        activeGeneralBookModule = nil
        activeGeneralBookModuleName = reader.initials
    currentGeneralBookKey =
      requestedKey.flatMap { reader.content(forKey: $0)?.persistedKey }
            ?? reader.firstKey().flatMap { reader.content(forKey: $0)?.persistedKey }
        currentCategory = .generalBook
        currentEpubHref = nil // Legacy PageManager migration input only.
        currentEpubTitle = nil

        if let pm = activeWindow?.pageManager {
            pm.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
            pm.generalBookDocument = reader.initials
            pm.generalBookKey = currentGeneralBookKey
            pm.epubIdentifier = nil
            pm.epubHref = nil
            onPersistState?()
        }
    }

    /**
     Loads one EPUB fragment through the active general-book adapter.

     - Parameters:
       - key: Numeric general-book key, TOC composite key, manifest id, or legacy href.
       - jumpToOrdinal: Optional BVA ordinal selected from EPUB search.
     - Side effects: Replaces the Vue document, persists the resolved numeric key in general-book
       PageManager state, emits the optional HTML-id jump, and updates rendered pane identity.
     - Failure modes: Missing adapters or keys emit a reader error document instead of leaving an
       indefinite loading state or substituting an unrelated fragment.
     */
    public func loadEpubEntry(key: String? = nil, jumpToOrdinal: Int? = nil) {
        beginReplacingContentIntent()
        resetAuxiliaryContentState()
        guard let reader = activeEpubReader,
              let requestedKey = key ?? currentGeneralBookKey ?? reader.firstKey(),
      let content = reader.content(forKey: requestedKey)
    else {
            if let errorDocument = documentPayloadFactory().errorDocumentJSON(
                message: String(localized: "error_no_content", defaultValue: "No content for this passage")
            ) {
                replaceDocument(
                    documentJSON: errorDocument,
                    setup: epubSetupContentPayload(fragment: nil, ordinal: nil)
                )
            }
            setRenderedContentState(
                category: .generalBook,
                moduleName: activeGeneralBookModuleName,
                book: activeEpubTitle ?? "",
                key: currentGeneralBookKey
            )
            applyNightModeBackground()
            return
        }

        currentCategory = .generalBook
        activeGeneralBookModuleName = reader.initials
        currentGeneralBookKey = content.persistedKey
        currentEpubTitle = content.title
        currentEpubHref = nil
        if let pm = activeWindow?.pageManager {
            pm.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
            pm.generalBookDocument = reader.initials
            pm.generalBookKey = content.persistedKey
            pm.epubIdentifier = nil
            pm.epubHref = nil
            onPersistState?()
        }

        let document = buildEpubDocumentJSON(reader: reader, content: content)
        sendLabelsToVueJS()
        replaceDocument(
            documentJSON: document,
            setup: epubSetupContentPayload(fragment: content.fragment, ordinal: jumpToOrdinal)
        )
        setRenderedContentState(
            category: .generalBook,
            moduleName: reader.initials,
            book: content.title,
            key: content.persistedKey
        )
        emitActiveState()
        bridge.clearSelection()
        applyNightModeBackground()
    }

    /**
     Builds EPUB setup coordinates for Android's atomic document replacement.

     - Parameters:
       - fragment: Optional XHTML element identifier.
       - ordinal: Optional search-result BVA ordinal.
     - Returns: Typed setup payload consumed by the shared replacement emitter.
     - Side effects: None.
     - Failure modes: None; absent targets encode as explicit `null` values.
     */
    private func epubSetupContentPayload(
        fragment: String?,
        ordinal: Int? = nil
    ) -> ReaderSetupContentPayload {
      ReaderSetupContentPayload(
            jumpToOrdinal: ordinal,
            jumpToId: fragment
        )
    }

    /**
     Build document JSON for EPUB content with isNativeHtml: true.

     The controller remains the orchestration boundary for selecting the active EPUB section, while
     `BibleReaderDocumentPayloadFactory` owns the Vue document schema and serialization details.

     - Parameters:
       - reader: Active EPUB adapter supplying stable initials and package language.
       - content: Resolved numeric fragment and rewritten native HTML.
     - Returns: Serialized Vue document JSON, or `{}` when serialization fails.
     - Side effects: None directly; failures are logged by the payload factory.
     - Failure modes: Returns `{}` if the payload cannot be serialized, preserving the legacy
       controller behavior for malformed native HTML payloads.
     */
    private func buildEpubDocumentJSON(reader: EpubReader, content: EpubReader.Content) -> String {
        documentPayloadFactory().epubDocumentJSON(
            bookName: reader.title,
            bookInitials: reader.initials,
            key: content.persistedKey,
            keyName: content.title,
            content: content.html,
            ordinalRange: [content.ordinalRange.lowerBound, content.ordinalRange.upperBound],
            language: reader.language
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
        case .epub: return activeEpubReader?.initials
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
   Refreshes installed modules while retaining the active manager's module root.

   - Side effects: Recreates SWORD and SQLite runtime catalogs, resolves prior category
     selections, refreshes books, and updates observable module inventories.
   - Failure modes: If manager recreation fails, existing runtime state remains unchanged.
   - Note: Retaining `modulePath` keeps injected, migrated, and test module roots authoritative.
     */
    public func refreshInstalledModules() {
    let refreshedManager: SwordManager?
    if let modulePath = swordManager?.modulePath {
      refreshedManager = SwordManager(modulePath: modulePath)
    } else {
      refreshedManager = SwordManager()
    }
    guard let newMgr = refreshedManager else { return }
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

  /**
   Rebuilds the pane runtime from genuine SWORD modules and Android-compatible SQLite modules.

   - Parameter mgr: Configured manager whose module root owns both backend inventories.
   - Side effects: Applies SWORD options, replaces installed inventories and backend handles,
     opens a fresh serialized SQLite catalog, resolves prior category selections, and refreshes
     the active Bible book list.
   - Failure modes: Unreadable SQLite payloads are omitted by discovery; absent supported Bibles
     retain the explicit no-backend state used by placeholder rendering.
   - Important: SQLite discovery and precedence decisions remain in the runtime coordinator; this
     method only applies its immutable results to controller state.
   */
    private func configureSwordManager(_ mgr: SwordManager) {
        swordManager = mgr

    let requestedSelection = currentSwordSelection()
        let state = swordCoordinator.configure(
            manager: mgr,
      selection: requestedSelection,
            displaySettings: displaySettings
        )
        logger.info("SWORD found \(state.installedModules.count) installed modules")
        for mod in state.installedModules {
            let hasStrongs = mod.features.contains(.strongsNumbers)
      logger.info(
        "  Module: \(mod.name) (\(mod.description)) [\(mod.category.rawValue)] strongs=\(hasStrongs)"
      )
        }

        applySwordState(state)
    let sqliteInventories = sqliteRuntimeCoordinator.reload(
      manager: mgr,
      primaryBibles: installedBibleModules,
      primaryCommentaries: installedCommentaryModules,
      primaryDictionaries: installedDictionaryModules
    )
    installedBibleModules = sqliteInventories.bibles
    installedCommentaryModules = sqliteInventories.commentaries
    installedDictionaryModules = sqliteInventories.dictionaries
    let sqliteSelections = sqliteRuntimeCoordinator.resolveSelections(
      requestedSelection,
      hasActiveSwordBible: activeModule != nil,
      hasActiveSwordCommentary: activeCommentaryModule != nil
    )
    applySQLiteRuntimeSelections(sqliteSelections)
    refreshBookList()
    if activeModule == nil && activeSQLiteBibleModule == nil {
            logger.warning("No Bible modules installed — using placeholder text")
        } else {
            logger.info("Using Bible module: \(self.activeModuleName)")
        }

        logBookListRefresh(module: activeModule, books: moduleBookList)
    }

  /**
   Applies pure SQLite selection decisions to mutually exclusive controller backend handles.

   - Parameter selections: Category handles resolved by the SQLite runtime coordinator.
   - Side effects: Replaces category-specific SWORD handles when SQLite is authoritative, clears
     stale SQLite handles otherwise, and canonicalizes retained SWORD names.
   - Failure modes: Nil selections retain supported SWORD state; no persistence or rendering is
     performed until the surrounding setup completes.
   */
  private func applySQLiteRuntimeSelections(
    _ selections: BibleReaderSQLiteSelectionResolution
  ) {
    if let sqliteBible = selections.bible {
      activeModule = nil
      activeSQLiteBibleModule = sqliteBible
      activeModuleName = sqliteBible.info.name
    } else {
      activeSQLiteBibleModule = nil
      if activeModule != nil {
        activeModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(
          activeModuleName
        )
      }
    }

    if let sqliteCommentary = selections.commentary {
      activeCommentaryModule = nil
      activeSQLiteCommentaryModule = sqliteCommentary
      activeCommentaryModuleName = sqliteCommentary.info.name
    } else {
      activeSQLiteCommentaryModule = nil
      if let name = activeCommentaryModuleName, activeCommentaryModule != nil {
        activeCommentaryModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(name)
      }
    }

    if let sqliteDictionary = selections.dictionary {
      activeDictionaryModule = nil
      activeSQLiteDictionaryModule = sqliteDictionary
      activeDictionaryModuleName = sqliteDictionary.info.name
    } else {
      activeSQLiteDictionaryModule = nil
      if let name = activeDictionaryModuleName, activeDictionaryModule != nil {
        activeDictionaryModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(name)
      }
    }
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
   - Side Effects: Reuses `other`'s `SwordManager`, resolves this controller's own SWORD handles,
     opens an independent SQLite catalog/connection set, and reapplies SWORD options.
     - Failure Modes: Returns `false` without mutation when the source controller has no
       `SwordManager`.
     - Important: This avoids constructing multiple C++ `SWMgr` instances during pane creation.
     */
    @discardableResult
    public func copyModuleState(from other: BibleReaderController) -> Bool {
        guard let mgr = other.swordManager else { return false }
    activeModuleName = other.activeModuleName
    activeCommentaryModuleName = other.activeCommentaryModuleName
    activeDictionaryModuleName = other.activeDictionaryModuleName
    activeGeneralBookModuleName = other.activeGeneralBookModuleName
    activeMapModuleName = other.activeMapModuleName
    activeModule = nil
    activeSQLiteBibleModule = nil
    activeCommentaryModule = nil
    activeSQLiteCommentaryModule = nil
    activeDictionaryModule = nil
    activeSQLiteDictionaryModule = nil
    activeGeneralBookModule = nil
    activeMapModule = nil

    // Configuration reuses the SWORD manager but creates a new SQLite library so concurrent
    // pane rendering never shares one unchecked SQLite connection.
    configureSwordManager(mgr)

        if let epubIdentifier = other.activeEpubIdentifier,
      let epubReader = EpubReader(identifier: epubIdentifier)
    {
            self.activeEpubReader = epubReader
            self.activeEpubIdentifier = epubIdentifier
            self.activeEpubTitle = epubReader.title
            self.activeGeneralBookModule = nil
            self.activeGeneralBookModuleName = epubReader.initials
        }
        return true
    }

    /**
   Restores category-owned module selections, exact generic keys, and Bible position from a pane.

   - Side effects: Resolves genuine SWORD or serialized SQLite handles for Bible, commentary, and
     dictionary fields; restores other document categories; canonicalizes persisted module
     spelling; validates exact SQLite dictionary keys; refreshes books; and restores navigation.
   - Failure modes: Missing, locked, wrong-category, unreadable, and SWORD-shadowed SQLite selections
     never activate content handles. Commentary keeps its readable setup fallback when available;
     optional categories preserve their requested identity without inventing a fallback. Invalid
     SQLite dictionary keys are cleared rather than normalized. The method is a no-op before
     `activeWindow` is attached.
   - Note: Canonicalized fields invoke `onPersistState` once after all restore decisions.
     */
    public func restoreSavedPosition() {
        guard let pm = activeWindow?.pageManager else { return }
    var normalizedPersistedSelection = false

        // Restore the saved Bible module only after the manager's fresh access state confirms it is
        // readable. Locked and unsupported selections retain the readable module chosen during
        // SWORD configuration instead of entering content rendering. ADR-0010 and issue #389.
    if let saved = pm.bibleDocument {
      let canonicalSaved = sqliteRuntimeCoordinator.canonicalSwordModuleName(saved)
      if sqliteRuntimeCoordinator.hasGenuineSwordModule(named: saved),
        let manager = swordManager,
        manager.moduleAccessState(named: canonicalSaved) == .readable,
        let mod = manager.module(named: canonicalSaved),
        mod.info.category == .bible
      {
        activeSQLiteBibleModule = nil
            activeModule = mod
        activeModuleName = canonicalSaved
        if pm.bibleDocument != canonicalSaved {
          pm.bibleDocument = canonicalSaved
          normalizedPersistedSelection = true
        }
            refreshBookList()
            logger.info("Restored saved Bible module: \(saved)")
      } else if let mod = sqliteRuntimeCoordinator.preferredModule(
        named: saved,
        category: .bible
      ) {
        activeModule = nil
        activeSQLiteBibleModule = mod
        activeModuleName = mod.info.name
        if pm.bibleDocument != mod.info.name {
          pm.bibleDocument = mod.info.name
          normalizedPersistedSelection = true
        }
        refreshBookList()
        logger.info("Restored saved SQLite Bible module: \(saved)")
      }
        }

        // One fresh global registry snapshot authorizes every auxiliary restore below. Native rows
        // retain ownership while locked, so a colliding SQLite module cannot become a content
        // fallback during session restoration.
        let auxiliaryModuleResolver = installedModuleResolver()

        // Restore saved commentary module or Android synthetic Memorize document
        if pm.commentaryDocument == AndroidSpecialDocumentIdentity.memorizeDocumentInitials {
            activeCommentaryModule = nil
      activeSQLiteCommentaryModule = nil
            activeCommentaryModuleName = AndroidSpecialDocumentIdentity.memorizeDocumentInitials
            logger.info("Restored Android synthetic Memorize document")
        } else if let savedComm = pm.commentaryDocument,
      let source = auxiliaryModuleResolver.module(named: savedComm),
      source.info.category == .commentary
    {
      switch source {
      case .sword(let module):
        activeCommentaryModule = module
        activeSQLiteCommentaryModule = nil
      case .sqlite(let module):
        activeCommentaryModule = nil
        activeSQLiteCommentaryModule = module
      }
      activeCommentaryModuleName = source.info.name
      if pm.commentaryDocument != activeCommentaryModuleName {
        pm.commentaryDocument = activeCommentaryModuleName
        normalizedPersistedSelection = true
      }
            logger.info("Restored saved commentary module: \(savedComm)")
    } else if let firstCommentary = auxiliaryModuleResolver.modules(
      category: .commentary,
      orderedBy: installedCommentaryModules
    ).first {
      switch firstCommentary {
      case .sword(let module):
        activeCommentaryModule = module
        activeSQLiteCommentaryModule = nil
      case .sqlite(let module):
        activeCommentaryModule = nil
        activeSQLiteCommentaryModule = module
      }
      activeCommentaryModuleName = firstCommentary.info.name
    } else if let savedComm = pm.commentaryDocument {
      activeCommentaryModule = nil
      activeSQLiteCommentaryModule = nil
      activeCommentaryModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(savedComm)
        }

        // Restore dictionary module
        if let savedDict = pm.dictionaryDocument,
      let source = auxiliaryModuleResolver.module(named: savedDict),
      source.info.category == .dictionary || source.info.category == .glossary
    {
      switch source {
      case .sword(let module):
        activeDictionaryModule = module
        activeSQLiteDictionaryModule = nil
        currentDictionaryKey = pm.dictionaryKey
      case .sqlite(let module):
        let restoredKey: String?
        do {
          let keys = try module.dictionaryKeys()
          restoredKey = BibleReaderSQLiteDictionaryChooser.exactSourceKey(
            matching: pm.dictionaryKey,
            in: keys
          )
        } catch {
          restoredKey = nil
        }
        activeDictionaryModule = nil
        activeSQLiteDictionaryModule = module
        currentDictionaryKey = restoredKey
        if pm.dictionaryKey != restoredKey {
          pm.dictionaryKey = restoredKey
          normalizedPersistedSelection = true
        }
      }
      activeDictionaryModuleName = source.info.name
      if pm.dictionaryDocument != activeDictionaryModuleName {
        pm.dictionaryDocument = activeDictionaryModuleName
        normalizedPersistedSelection = true
      }
            logger.info("Restored saved dictionary module: \(savedDict)")
    } else if let savedDict = pm.dictionaryDocument {
      activeDictionaryModule = nil
      activeSQLiteDictionaryModule = nil
      activeDictionaryModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(savedDict)
      currentDictionaryKey = nil
        }

        var restoredEpub = false

        // Restore general book module, My Document, EPUB adapter, or Android synthetic Multi document.
        if pm.generalBookDocument == AndroidSpecialDocumentIdentity.multiDocumentInitials {
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = AndroidSpecialDocumentIdentity.multiDocumentInitials
            currentGeneralBookKey = pm.generalBookKey
            logger.info("Restored Android synthetic Multi document")
        } else if let savedGB = pm.generalBookDocument,
      let document = myDocumentStore?.document(initials: savedGB)
    {
            activeEpubReader = nil
            activeEpubIdentifier = nil
            activeEpubTitle = nil
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = savedGB
      currentGeneralBookKey =
        pm.generalBookKey.flatMap {
                myDocumentStore?.page(bookInitials: savedGB, pageKey: $0)?.pageKey
        }
        ?? (document.pages ?? []).sorted {
                if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
                return $0.pageKey < $1.pageKey
            }.first?.pageKey
            logger.info("Restored My Documents general book: \(savedGB)")
        } else if let savedGB = pm.generalBookDocument,
      let reader = EpubReader(initials: savedGB)
    {
            activeEpubReader = reader
            activeEpubIdentifier = reader.identifier
            activeEpubTitle = reader.title
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = reader.initials
      currentGeneralBookKey =
        pm.generalBookKey
                .flatMap { reader.content(forKey: $0)?.persistedKey }
                ?? reader.firstKey().flatMap { reader.content(forKey: $0)?.persistedKey }
            currentEpubTitle = currentGeneralBookKey.flatMap { reader.content(forKey: $0)?.title }
            currentEpubHref = nil
            restoredEpub = true
            logger.info("Restored EPUB general book: \(savedGB)")
        } else if let savedGB = pm.generalBookDocument,
      case .sword(let module)? = auxiliaryModuleResolver.module(named: savedGB)
    {
            activeGeneralBookModule = module
            activeGeneralBookModuleName = module.info.name
            currentGeneralBookKey = pm.generalBookKey
            logger.info("Restored saved general book module: \(savedGB)")
        } else if let savedGB = pm.generalBookDocument {
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(savedGB)
            currentGeneralBookKey = pm.generalBookKey
        }

        // Restore map module
        if let savedMap = pm.mapDocument,
      case .sword(let module)? = auxiliaryModuleResolver.module(named: savedMap)
    {
            activeMapModule = module
            activeMapModuleName = module.info.name
            currentMapKey = pm.mapKey
            logger.info("Restored saved map module: \(savedMap)")
        } else if let savedMap = pm.mapDocument {
            activeMapModule = nil
            activeMapModuleName = sqliteRuntimeCoordinator.canonicalSwordModuleName(savedMap)
            currentMapKey = pm.mapKey
        }

        // Migrate legacy iOS-only EPUB PageManager fields into Android's general-book fields.
        var migratedLegacyEpub = false
        if !restoredEpub,
           let savedEpub = pm.epubIdentifier,
      let reader = EpubReader(identifier: savedEpub)
    {
            activeEpubReader = reader
            activeEpubIdentifier = savedEpub
            activeEpubTitle = reader.title
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = reader.initials
      currentGeneralBookKey =
        pm.epubHref
                .flatMap { reader.content(forKey: $0)?.persistedKey }
                ?? reader.firstKey().flatMap { reader.content(forKey: $0)?.persistedKey }
            currentEpubTitle = currentGeneralBookKey.flatMap { reader.content(forKey: $0)?.title }
            currentEpubHref = nil
            pm.generalBookDocument = reader.initials
            pm.generalBookKey = currentGeneralBookKey
            pm.epubIdentifier = nil
            pm.epubHref = nil
            restoredEpub = true
            migratedLegacyEpub = true
            logger.info("Migrated saved EPUB into general-book state: \(savedEpub)")
        }

        // Restore category
        let categoryName = pm.currentCategoryName
        switch categoryName {
        case "commentary": currentCategory = .commentary
        case "dictionary": currentCategory = .dictionary
        case "general_book": currentCategory = .generalBook
        case "map": currentCategory = .map
        case "epub" where restoredEpub:
            currentCategory = .generalBook
            pm.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
            migratedLegacyEpub = true
        default: currentCategory = .bible
        }
    if migratedLegacyEpub || normalizedPersistedSelection {
            onPersistState?()
        }

        // Restore saved book and chapter
        if let bookIndex = pm.bibleBibleBook,
      bookIndex >= 0, bookIndex < bookList.count
    {
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
    logger.info(
      "Restored position: \(self.currentBook) \(self.currentChapter):\(self.currentVerse)")

        // Android's page manager persists the MYNOTE category so a relaunch restores the My
        // Notes page; the window's persisted Bible position supplies the chapter. An
        // unresolvable target falls back to the Bible document instead of a blank pane.
        if pm.currentCategoryName == Self.myNotesPageManagerCategoryName {
            if let target = currentMyNotesTarget(jumpToOrdinal: nil) {
                loadMyNotesDocument(target: target)
            } else {
                pm.currentCategoryName = DocumentCategory.bible.pageManagerKey
                onPersistState?()
            }
        }
    }

    /// Apply SWORD global options based on current display settings.
    private func applySwordOptions() {
        guard let mgr = swordManager else { return }
        swordCoordinator.applyDisplayOptions(to: mgr, settings: displaySettings)
    }

    // MARK: - Public Navigation API

    /**
     Resolves the adjacent non-empty commentary block in the module's own versification.

     - Parameters:
       - forward: `true` for the next block; `false` for the previous block.
       - module: Active commentary module.
     - Returns: First verse of the adjacent block, or `nil` at a boundary/unresolvable selection.
     - Side effects: Reads structural commentary fragments while walking equal/empty blocks.
   - Failure modes: Public versification conversion or structural read failure returns `nil`.
     */
    private func commentaryBlockNavigationTarget(
        forward: Bool,
        module: SwordModule
    ) -> SwordCommentaryVerseReference? {
        let walker = SwordModuleCommentaryWalker(module: module)
        guard let selected = commentaryReferenceForCurrentVerse(module: module, walker: walker) else {
            return nil
        }
        let resolver = SwordCommentaryBlockResolver(walker: walker)
        let block = resolver.resolveBlock(containing: selected)
        return forward
            ? resolver.nextBlockStart(after: block.range.end)
            : resolver.previousBlockStart(before: block.range.start)
    }

    /**
     Handles Android commentary previous/next as linked-block navigation.

     - Parameter forward: `true` for next, `false` for previous.
     - Returns: `true` whenever a real commentary module owns the action, including boundaries;
       `false` for synthetic/non-module commentary so ordinary navigation can handle it.
     - Side effects: Converts the adjacent commentary target back into the active Bible's
       versification and performs one regular persisted reader navigation.
   - Failure modes: Missing conversion or an unaddressable fallback coordinate stays on the
     current block rather than navigating to a neighboring or fabricated Bible key.
     */
    @discardableResult
    private func navigateCommentaryBlock(forward: Bool) -> Bool {
    if let module = activeSQLiteCommentaryModule {
      let source = SwordVersification.Reference(
        osisBookId: osisBookId(for: currentBook),
        chapter: currentChapter,
        verse: max(1, currentVerse)
      )
      guard
        let selected = SQLiteCommentaryReferenceRouter.kjvaReference(
          for: source,
          sourceVersification: activeSourceVersificationName()
        ),
        let target = SQLiteCommentaryBlockNavigator(module: module).adjacentBlockStart(
          osisId: selected.osisId,
          chapter: selected.chapter,
          verse: selected.verse,
          forward: forward
        )
      else {
        return true
      }
      guard
        let mapped = SQLiteCommentaryReferenceRouter.sourceReference(
          for: target,
          destinationVersification: activeSourceVersificationName(),
          resolve: { [activeModule] candidate in
            guard let activeModule else {
              return SQLiteReaderNavigationResolver.coordinate(
                osisBookId: candidate.osisBookId,
                chapter: candidate.chapter,
                verse: candidate.verse
              ) == nil ? nil : candidate
            }
            return activeModule.verseOrdinal(
              osisBookId: candidate.osisBookId,
              chapter: candidate.chapter,
              verse: candidate.verse
            ) == nil ? nil : candidate
          }
        ), let bookName = bookName(forOsisId: mapped.osisBookId)
      else {
        return true
      }
      navigateTo(book: bookName, chapter: mapped.chapter, verse: mapped.verse)
      return true
    }

        guard let module = activeCommentaryModule else { return false }
        guard let target = commentaryBlockNavigationTarget(forward: forward, module: module) else {
            return true
        }
        let commentaryVersification = VersificationMapper.versificationName(for: module)
    guard
      let mapped = BibleReaderCommentaryVersificationRouter.resolve(
        reference: .init(
                  osisBookId: target.osisBookId,
                  chapter: target.chapter,
          verse: target.verse
        ),
                  from: commentaryVersification,
        to: activeSourceVersificationName(),
        resolve: { [activeModule] candidate in
          guard let activeModule else { return candidate }
          return activeModule.verseOrdinal(
            osisBookId: candidate.osisBookId,
            chapter: candidate.chapter,
            verse: candidate.verse
          ) == nil ? nil : candidate
        }),
      let bookName = bookName(forOsisId: mapped.osisBookId)
    else {
            return true
        }
        navigateTo(book: bookName, chapter: mapped.chapter, verse: mapped.verse)
        return true
    }

    /// Navigate to a specific book and chapter. Sends content to the WebView.
    public func navigateTo(book: String, chapter: Int, verse: Int? = nil) {
        pendingLinkNavigationOrdinalRange = nil
        navigationCoordinator.navigateTo(
            book: book,
            chapter: chapter,
            verse: verse,
            context: makeNavigationContext()
        )
    }

    /// Navigate to the next chapter, wrapping to the next book if needed.
    public func navigateNext() {
        if currentCategory == .commentary, navigateCommentaryBlock(forward: true) {
            return
        }
        if currentCategory == .generalBook,
           let reader = activeEpubReader,
      let key = reader.nextKey(after: currentGeneralBookKey)
    {
            loadEpubEntry(key: key)
            return
        }
        navigationCoordinator.navigateNext(context: makeNavigationContext())
    }

    /// Navigate to the previous chapter, wrapping to the previous book if needed.
    public func navigatePrevious() {
        if currentCategory == .commentary, navigateCommentaryBlock(forward: false) {
            return
        }
        if currentCategory == .generalBook,
           let reader = activeEpubReader,
      let key = reader.previousKey(before: currentGeneralBookKey)
    {
            loadEpubEntry(key: key)
            return
        }
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
        if currentCategory == .commentary, let module = activeCommentaryModule {
            return commentaryBlockNavigationTarget(forward: true, module: module) != nil
        }
        if currentCategory == .generalBook, let reader = activeEpubReader {
            return reader.nextKey(after: currentGeneralBookKey) != nil
        }
        return navigationCoordinator.hasNext(context: makeNavigationContext())
    }

    /// Whether there's a previous chapter available.
    public var hasPrevious: Bool {
        if currentCategory == .commentary, let module = activeCommentaryModule {
            return commentaryBlockNavigationTarget(forward: false, module: module) != nil
        }
        if currentCategory == .generalBook, let reader = activeEpubReader {
            return reader.previousKey(before: currentGeneralBookKey) != nil
        }
        return navigationCoordinator.hasPrevious(context: makeNavigationContext())
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
    let deferredSynchronizedScrollOrdinal =
      synchronizedScrollCoordinator
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
    if let pendingClientReadyRequest = specialDocumentCoordinator.consumePendingClientReadyRequest()
    {
            emitTransientMultiDocument(pendingClientReadyRequest)
            return
        }

        if showingMyNotes {
            guard let target = pendingClientReadyMyNotesTarget ?? activeMyNotesTarget else { return }
            pendingClientReadyMyNotesTarget = nil
            loadMyNotesDocument(target: target)
            return
        }

        if showingStudyPad, let activeStudyPadLabelId {
            let pendingBookmarkId = pendingClientReadyStudyPadBookmarkId
            pendingClientReadyStudyPadBookmarkId = nil
            loadStudyPadDocument(labelId: activeStudyPadLabelId, bookmarkId: pendingBookmarkId)
            return
        }

        if isShowingAndroidMemorizeDocument, let activeMemorizeEmission {
            renderMemorizeDocument(activeMemorizeEmission)
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
      let moduleName = selectedDefinitionModuleName(from: state)
    else {
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
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
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
  public func bridge(
    _ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool
  ) {
        let previousBook = currentBook
        let previousChapter = currentChapter
        let previousVerse = currentVerse
    let acknowledgedSynchronizedScroll =
      synchronizedScrollCoordinator
            .acknowledgeVisibleOrdinal(ordinal)
        navigationCoordinator.updateVisiblePosition(
            ordinal: ordinal,
            key: key,
            atChapterTop: atChapterTop,
            context: makeNavigationContext()
        )

    let visibleVerseChanged =
      previousBook != currentBook
            || previousChapter != currentChapter
            || previousVerse != currentVerse
    let shouldBroadcastSynchronizedScroll =
      !acknowledgedSynchronizedScroll
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
      let targetOrdinal = verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
    else {
            return
        }

        let alreadyShowingChapter = currentBook == book && currentChapter == chapter
        synchronizedScrollCoordinator.armSynchronizedFeedback(ordinal: targetOrdinal)

        if alreadyShowingChapter {
      applySynchronizedVersePosition(
        book: book, chapter: chapter, verse: verse, ordinal: targetOrdinal)
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
  private func applySynchronizedVersePosition(book: String, chapter: Int, verse: Int, ordinal: Int)
  {
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
    guard
      let candidate = infiniteScrollCoordinator.previousCandidate(
            previousBook: { [self] in previousBook(before: $0) },
            chapterCount: { [self] in chapterCount(for: $0) }
      )
    else {
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
    guard
      let candidate = infiniteScrollCoordinator.nextCandidate(
            nextBook: { [self] in nextBook(after: $0) },
            chapterCount: { [self] in chapterCount(for: $0) }
      )
    else {
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
            endOffset: endOffset,
            identity: .create
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
  public func bridge(
    _ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int,
    addNote: Bool
  ) {
        annotationBridgeHandler.addBookmark(
            bridge: bridge,
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
  public func bridge(
    _ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String,
    startOrdinal: Int, endOrdinal: Int, addNote: Bool
  ) {
        annotationBridgeHandler.addGenericBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote,
            wholeVerse: true,
            startOffset: nil,
            endOffset: nil
        )
    }

  /**
   Creates Android's selection-free bookmark for one exact non-Bible page.

   - Parameters:
     - bridge: Reader bridge that receives the resulting bookmark and modal events.
     - request: Exact source initials and key supplied by the rendered document.
   - Side effects: Persists a generic bookmark with nullable ordinals/offsets, applies workspace
     auto-label behavior, and emits the same annotation updates as other generic bookmarks.
   - Failure modes: Missing bookmark services leave persistence unchanged; this path never
     substitutes current Bible identity for the supplied source.
   */
  public func bridge(
    _ bridge: BibleBridge,
    createGenericWholePageBookmark request: GenericWholePageBookmarkRequest
  ) {
    annotationBridgeHandler.addGenericBookmark(
      bridge: bridge,
      bookInitials: request.sourceInitials,
      osisRef: request.sourceKey,
      startOrdinal: nil,
      endOrdinal: nil,
      addNote: false,
      wholeVerse: true,
      startOffset: nil,
      endOffset: nil
    )
  }

    /// Creates a Bible paragraph-break bookmark requested from the web client.
  public func bridge(
    _ bridge: BibleBridge, addParagraphBreakBookmark bookInitials: String, startOrdinal: Int,
    endOrdinal: Int
  ) {
        annotationBridgeHandler.addParagraphBreakBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Creates a generic paragraph-break bookmark requested from the web client.
  public func bridge(
    _ bridge: BibleBridge, addGenericParagraphBreakBookmark bookInitials: String, osisRef: String,
    startOrdinal: Int, endOrdinal: Int
  ) {
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
  public func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String)
  {
    annotationBridgeHandler.toggleBookmarkLabel(
      bridge: bridge, bookmarkId: bookmarkId, labelId: labelId)
    }

    /**
     Removes one label assignment from a bookmark and re-emits the updated bookmark state.
     */
  public func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String)
  {
    annotationBridgeHandler.removeBookmarkLabel(
      bridge: bridge, bookmarkId: bookmarkId, labelId: labelId)
    }

    /**
     Sets the primary label used to style a bookmark in Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {
    annotationBridgeHandler.setPrimaryLabel(
      bridge: bridge, bookmarkId: bookmarkId, labelId: labelId)
    }

    /**
     Updates whether a bookmark should highlight whole verses or a text-range selection.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {
    annotationBridgeHandler.setBookmarkWholeVerse(
      bridge: bridge, bookmarkId: bookmarkId, value: value)
    }

    /**
     Updates the custom icon attached to a bookmark.
     */
  public func bridge(
    _ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?
  ) {
    annotationBridgeHandler.setBookmarkCustomIcon(
      bridge: bridge, bookmarkId: bookmarkId, value: value)
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
  public func bridge(
    _ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String,
    afterEntryId: String
  ) {
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
  public func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String)
  {
    annotationBridgeHandler.setBookmarkEditAction(
      bridge: bridge, bookmarkId: bookmarkId, value: value)
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
    annotationBridgeHandler.setStudyPadCursor(
      bridge: bridge, labelId: labelId, orderNumber: orderNumber)
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
    private func querySelectionDetails() async -> BibleReaderSpeechSelection? {
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
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
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
                    let bookCategory = dict["bookCategory"] as? String
                    let versification = dict["v11n"] as? String
                    let startOrdinal = asInt(dict["startOrdinal"])
                    let endOrdinal = asInt(dict["endOrdinal"])
                    let startOffset = asInt(dict["startOffset"])
                    let endOffset = asInt(dict["endOffset"])

                    if !text.isEmpty || startOrdinal != nil || endOrdinal != nil {
                        return BibleReaderSpeechSelection(
                            text: text,
                            bookInitials: bookInitials,
                            osisRef: osisRef,
                            bookCategory: bookCategory,
                            versification: versification,
                            startOrdinal: startOrdinal,
                            endOrdinal: endOrdinal,
                            startOffset: startOffset,
                            endOffset: endOffset
                        )
                    }
                }
            } catch {
                logger.debug("querySelectionDetails JS error: \(error.localizedDescription)")
            }
        }

        if let fallback = await bridge.querySelection() {
            return BibleReaderSpeechSelection(
                text: fallback.text,
                bookInitials: nil,
                osisRef: nil,
                bookCategory: nil,
                versification: nil,
                startOrdinal: nil,
                endOrdinal: nil,
                startOffset: nil,
                endOffset: nil
            )
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
          let startOrdinal = sel.startOrdinal
        else {
          logger.warning(
            "Generic selection bookmark ignored because selection metadata is incomplete")
                    return
                }
                addGenericBookmark(
                    bookInitials: bookInitials,
                    osisRef: osisRef,
                    startOrdinal: startOrdinal,
                    endOrdinal: sel.endOrdinal ?? startOrdinal,
                    addNote: false,
                    wholeVerse: wholeVerse,
                    startOffset: wholeVerse ? nil : sel.startOffset,
                    endOffset: wholeVerse ? nil : sel.endOffset
                )
                bridge.clearSelection()
                return
            }

      let startOrd =
        sel.startOrdinal
        ?? verseOrdinal(
                osisBookId: osisBookId(for: currentBook),
                chapter: currentChapter,
                verse: 1
            )
            guard let startOrd else {
        logger.error(
          "Failed to resolve selection bookmark start ordinal for \(self.currentBook, privacy: .public) \(self.currentChapter)"
        )
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
        addNote: Bool,
        wholeVerse: Bool,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) {
        annotationBridgeHandler.addGenericBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote,
            wholeVerse: wholeVerse,
            startOffset: startOffset,
            endOffset: endOffset
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
    guard let shareText = selectionCoordinator.shareText(context: selectionPageContext()) else {
      return
    }
        onShareVerseText?(shareText)
        bridge.clearSelection()
    }

    /**
     Starts Speak from the selected document's typed source identity.

     The asynchronous DOM query captures the current service generation before suspension. A newer
     transport request invalidates the result, preventing an old selection from replacing it after
     JavaScript returns.
     */
    func speakSelection() {
        guard let service = speakService else { return }
        let expectedGeneration = service.currentSessionGeneration
        Task { @MainActor in
            guard let sel = await querySelectionDetails(), !sel.text.isEmpty else { return }
            guard self.speakService === service else { return }
            _ = startSpeech(
                for: sel,
                expectedSessionGeneration: expectedGeneration,
                service: service
            )
        }
    }

    /**
     Routes one captured native selection without crossing source categories.

     - Parameters:
       - selection: Atomic DOM source identity plus selected text.
       - expectedSessionGeneration: Generation captured before the asynchronous WebView query.
       - service: Controller-owned live speech service.
     - Returns: `true` only when the unchanged session accepted a category-correct provider.
     - Side effects: Starts speech and clears the WebView selection on success.
     - Failure modes: Stale generations, partial identity, unsupported categories, source collisions,
       and invalid ranges fail closed. Only a completely metadata-free selection uses plain text.
     */
    @MainActor
    @discardableResult
    func startSpeech(
        for selection: BibleReaderSpeechSelection,
        expectedSessionGeneration: UInt64,
        service: SpeakService
    ) -> Bool {
        guard service.currentSessionGeneration == expectedSessionGeneration else { return false }
        service.bookmarkManager = bookmarkService

        if !selection.hasSourceMetadata {
            let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            service.currentTitle = nil
            service.currentSubtitle = nil
            service.speak(text: selection.text, language: locale)
            bridge.clearSelection()
            return true
        }

        guard let rawCategory = selection.bookCategory,
              let category = DocumentCategory(rawValue: rawCategory),
              let bookInitials = selection.bookInitials,
              !bookInitials.isEmpty,
              let key = selection.osisRef,
              !key.isEmpty,
              let startOrdinal = selection.startOrdinal,
              startOrdinal >= 0,
              let endOrdinal = selection.endOrdinal,
      endOrdinal >= startOrdinal
    else {
            return false
        }

        let started: Bool
        switch category {
        case .bible:
            guard let versification = selection.versification,
        !versification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
                return false
            }
            started = startBibleSpeech(
                category: .bible,
                bookInitials: bookInitials,
                versification: versification,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                service: service
            )
        case .commentary:
            started = startGenericSpeech(
                bookInitials: bookInitials,
                key: key,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                expectedCategory: .commentary,
                service: service
            )
        case .dictionary:
            started = startGenericSpeech(
                bookInitials: bookInitials,
                key: key,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                expectedCategory: .dictionary,
                service: service
            )
        case .generalBook, .map, .epub, .dailyDevotion:
            started = startGenericSpeech(
                bookInitials: bookInitials,
                key: key,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                expectedCategory: .generalBook,
                service: service
            )
        }
        if started { bridge.clearSelection() }
        return started
    }

    /// Compare translations for the selected verse(s) through the Vue document pipeline.
    func compareSelection() {
        guard canUseBibleReferenceActions else { return }
        Task { @MainActor in
            if let selection = await querySelectionDetails(),
               let bookInitials = selection.bookInitials,
        let startOrdinal = selection.startOrdinal
      {
                loadCompareDocument(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: selection.endOrdinal ?? startOrdinal
                )
            }
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
      onShowToast?(
        String(
                localized: "word_not_found_in_dictionaries",
                defaultValue: "Word not found in any dictionary"
            ))
            return
        }
    guard
      let multiDocJSON = wordLookupDocumentBuilder()
        .buildWordLookupMultiDocumentJSON(query: query)
    else {
      onShowToast?(
        String(
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

    /// Callback for native My Documents sharing with Android's separate subject/body contract.
    var onShareMyDocumentContent: ((MyDocumentSharePayload) -> Void)?

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

    /** Builds source-owned verse text and forwards it to native sharing UI. */
  public func bridge(
    _ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int
  ) {
        guard let shareText = verseActionText(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) else { return }
        onShareVerseText?(shareText)
    }

    /**
     Shares a Bible bookmark identified by the web client's `shareBookmarkVerse(bookmark.id)` call.
     */
    public func bridge(_ bridge: BibleBridge, shareBookmarkVerse bookmarkId: String) {
        guard let service = bookmarkService,
              let uuid = UUID(uuidString: bookmarkId),
      let bookmark = service.bibleBookmark(id: uuid)
    else {
            logger.warning("shareBookmarkVerse: bookmark not found for id=\(bookmarkId)")
            return
        }
        self.bridge(
            bridge,
            shareVerse: bookmark.bookInitials,
            startOrdinal: bookmark.ordinalStart,
            endOrdinal: bookmark.ordinalEnd
        )
    }

    /**
     Copies a verse selection and its reference to the platform pasteboard.
     */
  public func bridge(
    _ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int
  ) {
        guard let copyText = verseActionText(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) else { return }
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
  public func bridge(
    _ bridge: BibleBridge, getMyDocumentPageRawContent callId: Int, bookInitials: String,
    pageKey: String
  ) {
    guard
      let payload = myDocumentStore?.rawContentPayload(bookInitials: bookInitials, pageKey: pageKey)
    else {
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
      let page = store.page(bookInitials: bookInitials, pageKey: pageKey)
    else {
            return false
        }

        let metadata = store.readerMetadata(
            for: page,
            bookInitials: bookInitials,
            pageKey: pageKey,
            unknownPromptName: String(localized: "ai_unknown_prompt", defaultValue: "AI")
        )
    guard
      let documentJSON = myDocumentCoordinator.documentJSON(
            document: document,
            page: page,
        metadata: metadata,
        genericBookmarks: genericBookmarkPayloads(
          bookInitials: document.initials,
          key: page.pageKey
        )
      )
    else {
      logger.error(
        "Failed to serialize My Documents page JSON for \(document.initials, privacy: .public)")
            return false
        }

        beginReplacingContentIntent()

        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        activeEpubReader = nil
        activeEpubIdentifier = nil
        activeEpubTitle = nil
        currentEpubTitle = nil
        currentEpubHref = nil
        activeGeneralBookModule = nil
        activeGeneralBookModuleName = document.initials
        currentGeneralBookKey = page.pageKey
        currentCategory = .generalBook
        myDocumentCoordinator.setActivePage(bookInitials: bookInitials, pageKey: pageKey)
        if let pageManager = activeWindow?.pageManager {
            pageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
            pageManager.generalBookDocument = document.initials
            pageManager.generalBookKey = page.pageKey
            pageManager.epubIdentifier = nil
            pageManager.epubHref = nil
            onPersistState?()
        }
        setRenderedContentState(
            category: .generalBook,
            moduleName: document.initials,
            book: document.name,
            key: page.pageKey
        )

        replaceDocument(
            documentJSON: documentJSON,
            setup: ReaderSetupContentPayload()
        )
        bridge.clearSelection()
        applyNightModeBackground()
        return true
    }

    /**
     Copies the stored raw My Documents page content to the platform pasteboard.
     */
  public func bridge(
    _ bridge: BibleBridge, copyMyDocumentContent bookInitials: String, pageKey: String
  ) {
    guard
      let payload = myDocumentStore?.rawContentPayload(bookInitials: bookInitials, pageKey: pageKey)
    else {
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
  public func bridge(
    _ bridge: BibleBridge, shareMyDocumentContent bookInitials: String, pageKey: String
  ) {
    guard
      let payload = myDocumentStore?.rawContentPayload(bookInitials: bookInitials, pageKey: pageKey)
    else {
            return
        }

        onShareMyDocumentContent?(myDocumentCoordinator.sharePayload(for: payload))
    }

    /**
     Persists raw My Documents editor content without rebuilding the document immediately.
     */
  public func bridge(
    _ bridge: BibleBridge, saveMyDocumentPageContent bookInitials: String, pageId: String,
    content: String, title: String?
  ) {
        guard let pageUUID = UUID(uuidString: pageId) else {
            logger.warning("saveMyDocumentPageContent: malformed page id=\(pageId, privacy: .public)")
            return
        }

    guard
      myDocumentStore?.savePageContent(
            bookInitials: bookInitials,
            pageId: pageUUID,
            content: content,
            title: title
      ) == true
    else {
      logger.warning(
        "saveMyDocumentPageContent: page not found or save failed for document=\(bookInitials, privacy: .public)"
      )
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
      logger.warning(
        "regenerateMyDocumentPage: source prompt metadata missing for page id=\(pageId, privacy: .public)"
      )
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
   Applies Android's reader-window lifecycle after an AI My Documents page deletion.

   Deleting an inactive marker leaves the active page selected and reloads its metadata. Deleting
   the rendered page asks the pane owner to close a removable window; only an ownerless or sole
   non-removable pane switches to its selected Bible.

   - Parameter context: Store-validated identity captured before the page was deleted.
   - Side effects: Clears reader-local My Documents identity, may invoke the pane lifecycle callback,
     or persists and renders Bible fallback content.
   - Failure modes: Actions for another document are ignored. A missing lifecycle owner safely
     falls back to the selected Bible instead of leaving deleted content visible.
     */
    private func refreshMyDocumentAfterDeletingPage(_ context: MyDocumentAIPageActionContext) {
        guard myDocumentCoordinator.isActiveDocument(context) else {
            return
        }

        if myDocumentCoordinator.isActivePage(context) {
            myDocumentCoordinator.clearActivePage()
      if onDeleteActiveMyDocumentPage?() == .paneClosed {
        return
      }
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
  public func bridge(
    _ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int
  ) {
        logger.info("Compare verses requested: \(startOrdinal)-\(endOrdinal)")
        loadCompareDocument(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal > 0 ? endOrdinal : startOrdinal
        )
    }

    /**
     Starts TTS playback for the selected verse range.
     */
  public func bridge(
    _ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int,
    endOrdinal: Int
  ) {
        guard let service = speakService else { return }
        service.bookmarkManager = bookmarkService
        _ = startBibleSpeech(
            category: .bible,
            bookInitials: bookInitials,
            versification: v11n,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            service: service
        )
    }

    /** Starts Android's generic speech provider without routing through Bible coordinates. */
    public func bridge(
        _ bridge: BibleBridge,
        speakGeneric bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        guard let service = speakService else { return }
        guard startOrdinal >= 0 else { return }
        service.bookmarkManager = bookmarkService
        _ = startGenericSpeech(
            bookInitials: bookInitials,
            key: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal >= 0 ? endOrdinal : nil,
            expectedCategory: nil,
            service: service
        )
    }

    /**
     Starts repeated TTS playback for the selected memorization range.
     */
  public func bridge(
    _ bridge: BibleBridge, speakMemorizationLoop bookInitials: String, v11n: String,
    startOrdinal: Int, endOrdinal: Int
  ) {
        guard let service = speakService else { return }
        service.bookmarkManager = bookmarkService
        _ = startBibleSpeech(
            category: .memorization,
            bookInitials: bookInitials,
            versification: v11n,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            service: service
        )
    }

    /**
     Adds the selected verse range as a memorization target and opens the bundled Memorize document.
     */
  public func bridge(
    _ bridge: BibleBridge, memorize bookInitials: String, startOrdinal: Int, endOrdinal: Int
  ) {
    progressBridgeCoordinator.memorize(
      bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Marks the selected verse range as memorized in local iOS memorization state.
     */
  public func bridge(
    _ bridge: BibleBridge, markAsMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int
  ) {
    progressBridgeCoordinator.markAsMemorized(
      bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Adds the selected verse range to local iOS memorization targets.
     */
  public func bridge(
    _ bridge: BibleBridge, addMemorizationTarget bookInitials: String, startOrdinal: Int,
    endOrdinal: Int
  ) {
    progressBridgeCoordinator.addMemorizationTarget(
      bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Removes the selected verse range from local iOS memorization targets.
     */
  public func bridge(
    _ bridge: BibleBridge, removeMemorizationTarget bookInitials: String, startOrdinal: Int,
    endOrdinal: Int
  ) {
    progressBridgeCoordinator.removeMemorizationTarget(
      bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Removes the selected verse range from local iOS memorized ranges.
     */
  public func bridge(
    _ bridge: BibleBridge, unmarkMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int
  ) {
    progressBridgeCoordinator.unmarkMemorized(
      bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    /**
     Records one chapter-read history row in local iOS reading-progress state.
     */
  public func bridge(
    _ bridge: BibleBridge, recordChapterRead bookInitials: String, startOrdinal: Int, chapter: Int,
    source: String
  ) {
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
  public func bridge(
    _ bridge: BibleBridge, openChapterReadHistory bookInitials: String, startOrdinal: Int,
    chapter: Int
  ) {
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
  public func bridge(
    _ bridge: BibleBridge, unmarkChapterRead bookInitials: String, startOrdinal: Int, chapter: Int
  ) {
    progressBridgeCoordinator.unmarkChapterRead(
      bookInitials: bookInitials, startOrdinal: startOrdinal, chapter: chapter)
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
     Opens a label-backed StudyPad journal document through the links-window policy.

     Android routes `openStudyPad` through `LinkControl.showLink`, so the journal document opens in
     the dedicated links window unless the links preference or window mode selects the current
     window. The pane owner installs that policy through `onOpenStudyPadInLinksWindow`; without an
     owner the document loads in the current pane as the standalone-controller fallback.

     - Parameters:
       - bridge: BibleView bridge instance that delivered the action; unused because routing is
         owned by the controller and its pane owner.
       - labelId: Persisted StudyPad label identifier string from the shared frontend.
       - bookmarkId: Bookmark row to scroll to after the journal document renders.
     - Side effects: Delegates to pane-owned links routing when configured, otherwise loads the
       StudyPad document in this controller.
     - Failure modes: A malformed label identifier fails closed without touching reader state.
     */
    public func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String) {
        logger.info("Open StudyPad for label: \(labelId)")
        guard let uuid = UUID(uuidString: labelId) else { return }
        let bmUuid = UUID(uuidString: bookmarkId)
        if let route = onOpenStudyPadInLinksWindow {
            route(uuid, bmUuid)
            return
        }
        loadStudyPadDocument(labelId: uuid, bookmarkId: bmUuid)
    }

    /**
     Opens the chapter-level My Notes document through the links-window policy.

     Android routes `openMyNotes` through `LinkControl.showLink`, so the My Notes document opens in
     the dedicated links window unless the links preference selects the current window. The pane
     owner installs that policy through `onOpenMyNotesInLinksWindow`; without an owner the document
     loads in the current pane as the standalone-controller fallback.

     - Parameters:
       - bridge: BibleView bridge instance that delivered the action; unused because routing is
         owned by the controller and its pane owner.
       - v11n: Source versification name associated with `ordinal`.
       - ordinal: Source-versification ordinal from the bookmark modal link.
     - Side effects: Delegates to pane-owned links routing when configured, otherwise loads the
       My Notes document through `loadMyNotesDocument(v11nName:sourceOrdinal:)`.
     - Failure modes: If the source ordinal cannot be projected to KJVA, the destination load fails
       closed rather than opening an unrelated active chapter or sending an ordinal from the wrong
       domain.
     */
    public func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int) {
        if let route = onOpenMyNotesInLinksWindow {
            route(v11n, ordinal)
            return
        }
        loadMyNotesDocument(v11nName: v11n, sourceOrdinal: ordinal)
    }

    /**
     Loads the My Notes document for an Android source-domain verse coordinate.

     Android passes My Notes modal links as the source versification plus the bookmark's original
     source ordinal, while the fake My Notes document itself renders rows in KJVA order. This entry
     point converts the source ordinal before loading the document so the optional scroll target
     stays in the document's ordinal domain, and is public so pane-owned links routing can run the
     same conversion on the destination controller.

     - Parameters:
       - v11nName: Source versification name associated with `sourceOrdinal`.
       - sourceOrdinal: Source-versification ordinal from the bookmark modal link.
     - Side effects: Loads or queues the My Notes document through `loadMyNotesDocument`.
     - Failure modes: If the source ordinal cannot be projected to KJVA, the route fails closed
       rather than opening an unrelated active chapter or sending an ordinal from the wrong domain.
     */
    public func loadMyNotesDocument(v11nName: String, sourceOrdinal: Int) {
        guard let target = myNotesTarget(v11nName: v11nName, sourceOrdinal: sourceOrdinal) else {
            return
        }
        loadMyNotesDocument(target: target)
    }

  /**
   Opens the exact generated document page referenced by an AI marker.

   - Parameters:
     - bridge: Reader bridge that delivered the marker navigation request.
     - request: Exact generated-book initials and page key encoded in the marker.
   - Side effects: Delegates to pane-owned link routing when configured, otherwise loads the
     requested My Documents page and updates pane persistence when it exists.
   - Failure modes: Missing documents or keys fail closed without changing the current page,
     matching Android's exact `Books.getBook` and `book.getKey` lookup behavior.
   */
  public func bridge(_ bridge: BibleBridge, openAIDocumentPage request: AIDocumentPageRequest) {
    if let route = onOpenAIDocumentPageInLinksWindow {
      route(request)
      return
    }
    loadMyDocumentPage(
      bookInitials: request.documentInitials,
      pageKey: request.pageKey
    )
  }

    /**
     Loads the KJVA My Notes chapter containing the requested row or active-pane verse.

     - Parameter jumpToOrdinal: Optional KJVA My Notes row ordinal to scroll to after loading.
     - Side effects: Resolves an immutable KJVA target, marks My Notes as visible, clears competing
       StudyPad/editing state, emits the target chapter when the client is ready, or stores that
       complete target for client-ready replay.
     - Failure modes: If the requested row or active verse cannot resolve to a KJVA My Notes page,
       logs the failure and leaves the current reader document unchanged.
     */
    public func loadMyNotesDocument(jumpToOrdinal: Int? = nil) {
        guard let target = currentMyNotesTarget(jumpToOrdinal: jumpToOrdinal) else {
            logger.error("Failed to resolve the KJVA My Notes target")
            return
        }
        loadMyNotesDocument(target: target)
    }

    /**
     Loads one explicit KJVA-owned My Notes chapter.

     - Parameter target: KJVA book, chapter, and optional row ordinal resolved at the route boundary.
     - Side effects: Invalidates older content intents, retains the complete target for client-ready
       replay, emits a target-owned My Notes document, and updates visible annotation state.
     - Failure modes: An unresolved target chapter fails in the annotation loader without falling
       back to the active pane's chapter.
     */
    /**
     Android's persisted page-manager category value for the My Notes fake document; the Android
     backup boundary upper-cases it to the `MYNOTE` enum name.
     */
    static let myNotesPageManagerCategoryName = "mynote"

    /**
     Persists Android's MYNOTE page-manager category for this window.

     Android's `CurrentPageManager` stores the MYNOTE category so relaunch and workspace sync
     restore the My Notes page. iOS mirrors that by writing the lower-case page-manager key the
     backup and sync boundaries translate to Android's enum name.

     - Parameter visible: `true` while the My Notes document owns the pane; `false` restores the
       Bible category, but only when My Notes still owns the stored value so other categories
       keep their own key.
     - Side effects: Mutates the active window's page manager and persists workspace state when
       the stored value changes.
     - Failure modes: Missing page managers are ignored.
     */
    private func persistMyNotesPageCategory(visible: Bool) {
        guard let pm = activeWindow?.pageManager else { return }
        if visible {
            guard pm.currentCategoryName != Self.myNotesPageManagerCategoryName else { return }
            pm.currentCategoryName = Self.myNotesPageManagerCategoryName
        } else {
            guard pm.currentCategoryName == Self.myNotesPageManagerCategoryName else { return }
            pm.currentCategoryName = DocumentCategory.bible.pageManagerKey
        }
        onPersistState?()
    }

    private func loadMyNotesDocument(target: MyNotesTarget) {
        beginReplacingContentIntent()
        persistMyNotesPageCategory(visible: true)
        guard clientReady else {
            pendingClientReadyMyNotesTarget = target
            activeMyNotesTarget = target
            showingMyNotes = true
            showingStudyPad = false
            activeStudyPadLabelId = nil
            activeStudyPadLabelName = nil
            editingInWebView = false
            clearNativeSelectionState()
            return
        }
        pendingClientReadyMyNotesTarget = nil
        activeMyNotesTarget = target
        annotationDocumentLoader().loadMyNotesDocument(
            currentBook: target.bookName,
            currentChapter: target.chapter,
            osisBookId: target.osisBookId,
            jumpToOrdinal: target.jumpOrdinal,
            chapterRange: { [weak self] in
                self?.myNotesChapterRange(for: target)
            },
            bookmarks: { [weak self] in self?.myNotesBookmarks(for: target) ?? [] },
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
     Renders a prebuilt Android Memorize fake document in this controller.

     - Parameter emission: Serialized Vue Memorize payload plus source range metadata.
     - Side effects: Stores the live Memorize emission for client-ready/content replay, applies
       Android's commentary-category `Memorize` PageManager identity, emits bridge document events,
       clears selection, and reapplies reader background.
     - Failure modes: Invalid JSON is forwarded unchanged to the Vue bridge, matching the existing
       transient document contract.
     */
    func renderMemorizeDocument(_ emission: MemorizeDocumentEmission) {
        beginReplacingContentIntent()
        activeMemorizeEmission = emission
        annotationDocumentLoader().emitMemorizeDocument(emission) { [weak self] in
            self?.prepareMemorizeVisibleState(emission: emission)
        }
    }

    /**
     Applies native state for Android's commentary-category Memorize fake document.

     Android stores `FakeBookFactory.memorizeDocument` as a commentary page and keeps the source
     passage as separate `BookAndKey` state. The PageManager owns the fake commentary identity while
     Android-only source JSON stays in the existing workspace fidelity store.

     - Parameter emission: Built Memorize payload and source-range metadata.
     - Side effects: Mutates controller special-document flags, commentary module identity,
       `PageManager` category/document/anchor fields, preserves Android source JSON in
       `SettingsStore`, and may invoke `onPersistState`.
     - Failure modes: If no active `PageManager` exists, only controller-local state is updated.
     */
    private func prepareMemorizeVisibleState(emission: MemorizeDocumentEmission) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        currentCategory = AndroidSpecialDocumentIdentity.memorizeDocumentCategory
        activeCommentaryModule = nil
        activeCommentaryModuleName = AndroidSpecialDocumentIdentity.memorizeDocumentInitials

        guard let pageManager = activeWindow?.pageManager else { return }
    pageManager.currentCategoryName =
      AndroidSpecialDocumentIdentity.memorizeDocumentCategory.pageManagerKey
        pageManager.commentaryDocument = AndroidSpecialDocumentIdentity.memorizeDocumentInitials
        pageManager.commentaryAnchorOrdinal = emission.startOrdinal
        preserveMemorizeSourceBookAndKey(emission.sourceBookAndKeyJSON)
        onPersistState?()
    }

    /**
     Preserves Android's Memorize `commentary_sourceBookAndKey` fidelity value.

     - Parameter sourceBookAndKey: Serialized Android `BookAndKey` source JSON.
     - Side effects: Reads and rewrites one page-manager fidelity settings row while preserving
       unrelated Android-only anchor values already stored for the active window.
     - Failure modes: Missing settings store, active window, or source JSON leaves existing state
       unchanged.
     */
    private func preserveMemorizeSourceBookAndKey(_ sourceBookAndKey: String?) {
        guard let sourceBookAndKey,
              let settingsStore,
      let windowID = activeWindow?.id
    else { return }

        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let existing = fidelityStore.pageManagerEntry(for: windowID)
        fidelityStore.setPageManagerEntry(
            .init(
                windowID: windowID,
                rawCurrentCategoryName: existing?.rawCurrentCategoryName ?? "COMMENTARY",
                commentarySourceBookAndKey: sourceBookAndKey,
                dictionaryAnchorOrdinal: existing?.dictionaryAnchorOrdinal,
                generalBookAnchorOrdinal: existing?.generalBookAnchorOrdinal,
                mapAnchorOrdinal: existing?.mapAnchorOrdinal
            )
        )
    }

    /**
     Routes a built Memorize request through the pane owner when possible.

     - Parameter request: Active reader/module data needed to build the Memorize document.
     - Returns: `true` when a Memorize emission was built and either routed or rendered.
     - Side effects: May move the active SWORD module cursor while building text, may delegate to
       the owning pane for links-window routing, or may render the fake document in this controller.
     - Failure modes: Returns `false` when the selected range cannot produce a valid document.
     */
    @discardableResult
    private func openMemorizeDocument(request: MemorizeDocumentRequest) -> Bool {
    guard let emission = annotationDocumentLoader().makeMemorizeDocumentEmission(request: request)
    else {
            return false
        }
        if let openInLinksWindow = onOpenMemorizeDocumentInLinksWindow {
            openInLinksWindow(emission)
        } else {
            renderMemorizeDocument(emission)
        }
        return true
    }

    /**
     Opens Android's commentary-category Memorize fake document for the selected verse range.

     The document is backed by the same local `MemorizationProgressStore` state that the bridge
     mutation methods update. The source pane builds the Android-shaped payload, then owner routing
     decides whether Android's links window or the current pane becomes the `commentary/Memorize`
     fake-document destination.
     */
    private func loadMemorizeDocument(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        guard clientReady else { return }
        openMemorizeDocument(
            request: MemorizeDocumentRequest(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                activeModuleName: activeModuleName,
                currentBook: currentBook,
                currentChapter: currentChapter,
                osisBookId: osisBookId(for: currentBook),
                activeModule: activeModule,
                swordManager: swordManager,
                stateJSON: activeWindow?.pageManager?.jsState,
                verseReference: { [weak self] book, ordinal in
                    self?.verseReference(book: book, ordinal: ordinal)
                },
                parseVerseKey: { [weak self] key in
                    self?.parseVerseKey(key)
                },
                placeholderVerseText: { book, chapter, verse in
                    Self.placeholderVerseText(book: book, chapter: chapter, verse: verse)
                },
                memorizedOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                    self?.memorizedRenderedOrdinals(
                        startOrdinal: startOrdinal,
                        endOrdinal: endOrdinal
                    ) ?? []
                },
                targetOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                    self?.targetRenderedOrdinals(
                        startOrdinal: startOrdinal,
                        endOrdinal: endOrdinal
                    ) ?? []
                },
                readingProgressSettings: { [progressBridgeCoordinator] in
                    progressBridgeCoordinator.readingProgressSettingsPayload()
                }
            )
        )
    }

    /**
     Opens Memorize for a Reading Progress row stored in Android's global KJVA ordinal domain.

     Reading Progress memorized passages and target rows are not scoped to the current reader book.
     This method resolves the row's KJVA ordinals directly, then lets the existing document loader
     fetch verse text by OSIS reference from the active module when available.

     - Parameters:
       - startOrdinal: First KJVA progress ordinal.
       - endOrdinal: Last KJVA progress ordinal.
     - Returns: `true` when the Memorize document was emitted.
     - Side effects: Emits the Memorize document through the bridge and clears competing document
       state through the same path as bridge-launched Memorize.
     - Failure modes: Returns `false` when the client is not ready or the KJVA range contains no
       concrete verse references.
     */
    @discardableResult
    func openMemorizeKJVARange(startOrdinal: Int, endOrdinal: Int) -> Bool {
        guard clientReady else { return false }
        let effectiveStart = min(startOrdinal, endOrdinal)
        let effectiveEnd = max(startOrdinal, endOrdinal)
        let references = (effectiveStart...effectiveEnd).compactMap { ordinal -> VerseKeyReference? in
            guard let reference = JSwordKJVAVersification.verseReference(ordinal: ordinal) else {
                return nil
            }
            return VerseKeyReference(
                osisBookId: reference.osisId,
                chapter: reference.chapter,
                verse: reference.verse,
                ordinal: reference.ordinal
            )
        }
        guard let firstReference = references.first else { return false }
        let referenceOrdinals = Set(references.map(\.ordinal))

        return openMemorizeDocument(
            request: MemorizeDocumentRequest(
                bookInitials: activeModuleName,
                startOrdinal: effectiveStart,
                endOrdinal: effectiveEnd,
                activeModuleName: activeModuleName,
        currentBook: Self.bookName(forOsisId: firstReference.osisBookId)
          ?? firstReference.osisBookId,
                currentChapter: firstReference.chapter,
                osisBookId: firstReference.osisBookId,
                activeModule: activeModule,
                swordManager: swordManager,
                stateJSON: activeWindow?.pageManager?.jsState,
                directVerseReferences: references,
                verseReference: { [weak self] book, ordinal in
                    self?.verseReference(book: book, ordinal: ordinal)
                },
                parseVerseKey: { [weak self] key in
                    self?.parseVerseKey(key)
                },
                placeholderVerseText: { book, chapter, verse in
                    Self.placeholderVerseText(book: book, chapter: chapter, verse: verse)
                },
                memorizedOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                    self?.memorizationProgressStore?.memorizedOrdinals(
                        bookInitials: "",
                        startOrdinal: startOrdinal,
                        endOrdinal: endOrdinal
                    )
                    .filter { referenceOrdinals.contains($0) }
                    .sorted() ?? []
                },
                targetOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                    self?.memorizationProgressStore?.targetOrdinals(
                        bookInitials: "",
                        startOrdinal: startOrdinal,
                        endOrdinal: endOrdinal
                    )
                    .filter { referenceOrdinals.contains($0) }
                    .sorted() ?? []
                },
                readingProgressSettings: { [progressBridgeCoordinator] in
                    progressBridgeCoordinator.readingProgressSettingsPayload()
                }
            )
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
        beginReplacingContentIntent()
        persistMyNotesPageCategory(visible: false)
        guard clientReady else {
            guard let label = bookmarkService?.label(id: labelId) else { return }
            let labelName = AndroidLabelPresentation.displayName(for: label)
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
      genericBookmarkToLabelPayload: { [self] relation in buildGenericBookmarkToLabelJSON(relation)
      },
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
    case .definition(let strongs, let robinson):
            logger.info("handleExternalLinkRoute.definition: strongs=\(strongs), robinson=\(robinson)")
      guard
        let multiDocJSON = buildStrongsMultiDocJSON(
                strongs: strongs,
                robinson: robinson,
                stateJSON: currentStrongsDocumentStateJSON()
        )
      else {
                return
            }
            openDefinitionDocument(
                multiDocJSON,
                renderedBook: "Strongs",
                renderedKey: "strongs"
            )
    case .findAllOccurrences(let name):
            onShowStrongsSearch?(name)
        case .errorReport:
            handleErrorReportLink()
    case .epubReference(let book, let toKey, let toId):
            bridge(self.bridge, openEpubLink: book, toKey: toKey, toId: toId)
    case .downloads(let searchText):
            bridgeEventRouter.requestOpenDownloads(searchText: searchText)
    case .myNotes(let v11n, let ordinal):
      guard
        let target = myNotesTarget(
                v11nName: v11n,
                sourceOrdinal: ordinal
        )
      else { return }
            loadMyNotesDocument(target: target)
    case .studyPad(let labelId, let bookmarkId):
            loadStudyPadDocument(labelId: labelId, bookmarkId: bookmarkId)
    case .osisReferences(let values, let v11n, let documentInitials, let forceDocument):
            handleOsisReferenceValues(
                values,
                sourceVersification: v11n,
                documentInitials: documentInitials,
                forceDocument: forceDocument
            )
    case .multiReferences(let values, let v11n):
            handleMultiReferenceValues(values, sourceVersification: v11n)
    case .swordReference(let ref), .osisNavigation(let ref):
            _ = navigateToOsisRef(ref)
    case .platformURL(let url):
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
  private func openDefinitionDocument(
    _ documentJSON: String, renderedBook: String, renderedKey: String
  ) {
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
  func buildStrongsMultiDocJSON(strongs: [String], robinson: [String], stateJSON: String? = nil)
    -> String?
  {
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
            installedDictionarySources: { [weak self] in
                self?.installedDictionaryKeySources() ?? []
            },
            installedBookMetadata: { [weak self] in
                self?.installedModuleResolver().registeredBookMetadata() ?? []
            },
            installedDictionarySourceNamed: { [weak self] name in
                self?.installedModuleResolver().module(named: name)?.explicitDictionaryKeySource
            },
            selectedPreferenceValues: { [weak self] key in
                self?.settingsStore?.getStringSet(key) ?? []
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
            installedDictionarySources: { [weak self] in
                self?.installedDictionarySources() ?? []
            },
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
            moduleResolver: installedModuleResolver(),
            installedBibleModules: installedBibleModules
        )
    }

    /**
     Builds the background-safe Compare request for the active passage.

     The controller supplies live reader coordinates while `BibleReaderCompareDocumentBuilder` owns
     module ordering and payload construction.
     */
    private func makeBibleCompareDocumentRequest(
        bookInitials: String?,
        startOrdinal: Int?,
        endOrdinal: Int?
    ) -> BibleReaderCompareDocumentBuilder.Request? {
        if let bookInitials, let startOrdinal {
            return compareDocumentBuilder().makeRequest(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal ?? startOrdinal
            )
        }

        guard let activeSource = activeInstalledScriptureSource(),
      let range = chapterOrdinalRange(book: currentBook, chapter: currentChapter)
    else {
            return nil
        }
        return compareDocumentBuilder().makeRequest(
            bookInitials: activeSource.info.name,
            startOrdinal: range.start,
            endOrdinal: range.end
        )
    }

    /**
     Builds the Vue `MultiDocument` payload Android uses for multi-reference Bible links.

     - Parameter refs: Parsed OSIS references in the order supplied by `multi://` or a
       multi-reference `osis://` link. Empty input produces no document.
     - Returns: Serialized JSON for a transient multi-document, or `nil` if there are no references
       or JSON serialization fails.
     - Side effects: Reads exact source-module entries through cursor-restoring inspectors.
     - Failure modes: Returns `nil` when a source module, versification mapping, exact entry, or JSON
       serialization is unavailable. Partial or relabeled fragments are never emitted.
     - Note: The payload encodes `contentType: null`; Vue routes non-Strong's `type: "multi"`
       documents to `MultiDocument`, matching Android's `FakeBookFactory.multiDocument` path.
     */
    private func buildBibleMultiReferenceDocumentJSON(refs: [OsisRef]) -> String? {
        BibleReaderMultiReferenceDocumentBuilder(
            moduleResolver: installedModuleResolver(),
            activeModuleName: activeModuleName
        ).buildDocumentJSON(refs: refs)
    }

    /**
     Captures Android's global installed-book registry for one reader operation.

     - Returns: A resolver that replays native/custom-driver admission, exact identity maps, locked
       ownership, and JSword TreeSet ordering over the current runtime snapshot.
     - Side effects: Enumerates current SWORD metadata and unshadowed SQLite registrations; it does
       not open content or mutate the registry.
     - Failure modes: A missing manager produces a SQLite-only resolver. Locked native books retain
       ownership metadata but expose no readable handle, so callers fail closed on content access.
     */
    private func installedModuleResolver() -> BibleReaderInstalledModuleResolver {
        BibleReaderInstalledModuleResolver(
            swordManager: swordManager,
            sqliteModules: sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        )
    }

    /** Resolves the pane's selected Bible without substituting another installed source. */
    private func activeInstalledScriptureSource() -> BibleReaderInstalledScriptureSource? {
        installedModuleResolver().scripture(named: activeModuleName)
    }

    /**
     Returns Android's selected-word dictionary inventory in installed-book TreeSet order.

     - Returns: Readable plain-dictionary candidates before Strong/morphology and preference
       filtering by `BibleReaderWordLookupDocumentBuilder`.
     - Side effects: Captures one fresh global resolver snapshot and projects its immutable
       category/abbreviation/initials/name order.
     - Failure modes: Locked, shadowed, wrong-category, and unreadable registrations are omitted.
     */
    private func installedDictionarySources() -> [BibleReaderInstalledDictionarySource] {
        installedModuleResolver().wordLookupDictionarySources()
    }

    /**
     Captures every readable installed book capable of Android's exact dictionary-key API.

     - Returns: Native books and faithful SQLite dictionary backends in JSword TreeSet order for
       automatic Strong's/morphology feature filtering.
     - Side effects: Captures one fresh combined native/custom registry snapshot, including custom
       admission replay and locked ownership metadata; no content entry is read.
     - Failure modes: Locked, unreadable, shadowed, and non-key-capable registrations are omitted
       without substituting a colliding backend.
     */
    private func installedDictionaryKeySources() -> [BibleReaderInstalledDictionarySource] {
        installedModuleResolver().dictionaryKeySources()
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
  private func buildBibleMultiReferenceXML(ref: OsisRef, module: SwordModule?, ordinal: Int)
    -> String?
  {
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
   - Side effects: Navigates one contiguous passage or opens Android's transient `Multi` document
     when parsing produces more than one discontiguous range.
   - Failure modes: Invalid values and requests without an active Bible are ignored; no side
     effects occur when nothing parses.
     */
    private func handleOsisReferenceValues(
        _ values: [String],
        sourceVersification: String,
        documentInitials: String?,
        forceDocument: Bool
    ) {
    guard activeModule?.info.category == .bible else { return }
        guard let value = values.first else { return }
        let targetInitials = forceDocument ? documentInitials : nil
        let refs = parseOsisReferences(
            value,
            sourceVersification: sourceVersification,
            targetBookInitials: targetInitials
        )
        if refs.count == 1, let ref = refs.first {
            if let openInLinks = onOpenInLinksWindow {
        openInLinks(ref)
            } else {
        _ = navigateToBibleLink(ref)
            }
        } else if !refs.isEmpty {
            openMultiReferenceDocument(refs: refs)
        }
    }

    /**
     Handles already-classified `multi://` OSIS query values from Android-compatible links.

     - Parameter values: OSIS query values from the pseudo-link.
   - Side effects: Opens every parsed range in one transient `Multi` document.
   - Failure modes: Invalid values and requests without an active Bible are ignored; no side
     effects occur when nothing parses.
     */
    private func handleMultiReferenceValues(
        _ values: [String],
        sourceVersification: String
    ) {
    guard activeModule?.info.category == .bible else { return }
        let allRefs = values.flatMap {
            parseOsisReferences($0, sourceVersification: sourceVersification)
        }
        guard !allRefs.isEmpty else { return }
        openMultiReferenceDocument(refs: allRefs)
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

   Android resolves cross-reference passages through JSword `PassageKeyFactory`, then checks
   `Passage.countRanges(...)`: one contiguous range remains ordinary Bible navigation and each
   discontiguous run becomes a separate `Multi` fragment. SWORD expands ranges into concrete
   verse keys, so iOS partitions that output by canonical adjacency instead of widening the first
   and last parsed verses into one invented range. Commas and space-delimited lists share this
   path. The static canon parser remains a fallback when no installed module owns the declared
   source versification.

     - Parameter osisString: OSIS reference text such as `Matt.1.1`, `Gen.1.1-Gen.1.3`, or a
       comma-separated list.
     - Returns: Parsed references in module/parser order. Invalid or unknown keys are omitted.
     - Side effects: May temporarily move the active module cursor through `SwordModule`; that
       method restores the previous key before returning.
     */
    private func parseOsisReferences(
        _ osisString: String,
        sourceVersification: String,
        targetBookInitials: String? = nil
    ) -> [OsisRef] {
        let trimmed = osisString.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split {
      $0 == "," || $0.isWhitespace
    }.map(String.init)
        if let parserModule = moduleForVersification(sourceVersification) {
      let parsed = components.flatMap { component -> [OsisRef] in
        guard
          let references = BibleReaderMultiReferenceDocumentBuilder.concreteReferences(
                    parsedKeys: parserModule.parseKeyList(component),
                    module: parserModule
          )
        else { return [] }
        return contiguousReferenceRuns(references, module: parserModule).compactMap {
          makeOsisRef(
            references: $0,
                    sourceModule: parserModule,
                    sourceVersification: sourceVersification,
                    targetBookInitials: targetBookInitials
                )
            }
      }
            if !parsed.isEmpty {
                return parsed
            }
        }

        return components.flatMap { component in
            expandCanonicalReference(
                component,
                sourceVersification: sourceVersification,
                targetBookInitials: targetBookInitials
            )
        }
    }

  /**
   Partitions SWORD's concrete parser output into Android `Passage`-equivalent contiguous ranges.

   - Parameters:
     - references: Ordered exact verses returned by the source module parser.
     - module: Source module whose ordinal domain determines canonical adjacency.
   - Returns: Ordered non-empty verse runs. Adjacent verses across chapter introductions remain in
     one run; a skipped canonical verse starts a new run.
   - Side effects: Reads source-module references by ordinal through serialized SWORD access.
   - Failure modes: An unavailable intermediate ordinal is treated as a range boundary so a
     malformed parser result can never be widened.
   */
  private func contiguousReferenceRuns(
    _ references: [VerseKeyReference],
    module: SwordModule
  ) -> [[VerseKeyReference]] {
    var runs: [[VerseKeyReference]] = []
    for reference in references {
      guard let previous = runs.last?.last else {
        runs.append([reference])
        continue
      }
      if isCanonicallyAdjacent(reference, after: previous, module: module) {
        runs[runs.count - 1].append(reference)
      } else {
        runs.append([reference])
      }
    }
    return runs
  }

  /**
   Checks whether `candidate` is the next concrete verse after `previous` in one SWORD canon.

   Verse-zero introduction slots may sit between the final verse of one chapter and verse one of
   the next. Those slots are skipped, matching JSword passage contiguity, while any intervening
   positive verse proves the references are discontiguous.

   - Parameters:
     - candidate: Later parser result being considered for the current range.
     - previous: Last concrete verse already in that range.
     - module: Source module that owns both ordinals.
   - Returns: `true` only when `candidate` is the next positive verse in the module canon.
   - Side effects: Reads source-module references by ordinal through serialized SWORD access.
   - Failure modes: Reversed, duplicate, or unresolvable ordinals return `false`.
   */
  private func isCanonicallyAdjacent(
    _ candidate: VerseKeyReference,
    after previous: VerseKeyReference,
    module: SwordModule
  ) -> Bool {
    guard candidate.ordinal > previous.ordinal else { return false }
    for ordinal in (previous.ordinal + 1)...candidate.ordinal {
      guard let reference = module.verseReference(ordinal: ordinal) else { return false }
      if reference.verse > 0 {
        return reference == candidate
      }
    }
    return false
  }

    /** Builds one ordered source passage without consulting the active pane's book catalog. */
    private func makeOsisRef(
        references: [VerseKeyReference],
        sourceModule: SwordModule?,
        sourceVersification: String,
        targetBookInitials: String?
    ) -> OsisRef? {
        guard let first = references.first,
      let last = references.last
    else { return nil }
        let coordinates = references.map {
            OsisVerseCoordinate(
                osisBookId: $0.osisBookId,
                chapter: $0.chapter,
                verse: $0.verse
            )
        }
        return OsisRef(
            book: sourceBookName(osisBookId: first.osisBookId, module: sourceModule),
            chapter: first.chapter,
            verse: first.verse,
            osisId: first.osisBookId,
            sourceVersification: sourceVersification,
            targetBookInitials: targetBookInitials,
            sourceVerses: coordinates,
            sourceOsisRef: OsisRef.normalizedOsisRef(for: coordinates),
            endBook: sourceBookName(osisBookId: last.osisBookId, module: sourceModule)
        )
    }

    /** Resolves display metadata from the source module/canon, never the active Bible catalog. */
    private func sourceBookName(osisBookId: String, module: SwordModule?) -> String {
        module?.getBookList().first(where: { $0.osisId == osisBookId })?.name
            ?? JSwordKJVAVersification.longBookName(osisId: osisBookId)
            ?? osisBookId
    }

    /// Parses one concrete source-domain OSIS verse without consulting active-pane coordinates.
    private func parseOsisRef(
        _ osis: String,
        sourceVersification: String = JSwordKJVAVersification.name,
        targetBookInitials: String? = nil,
        sourceModule: SwordModule? = nil
    ) -> OsisRef? {
        // Format: BookId.Chapter.Verse or BookId.Chapter
        let components = osis.components(separatedBy: ".")
        guard components.count >= 2 else { return nil }

        let osisId = components[0]
        guard let chapter = Int(components[1]) else { return nil }
        let verse = components.count >= 3 ? Int(components[2]) : nil

    guard
      SwordVersification.referenceIndex(
                  for: .init(osisBookId: osisId, chapter: chapter, verse: verse ?? 1),
                  versification: sourceVersification
      ) != nil
    else {
            logger.warning("Unknown OSIS book ID: \(osisId)")
            return nil
        }

        return OsisRef(
            book: sourceBookName(osisBookId: osisId, module: sourceModule),
            chapter: chapter,
            verse: verse ?? 1,
            osisId: osisId,
            sourceVersification: sourceVersification,
            targetBookInitials: targetBookInitials
        )
    }

    /** Resolves an installed parser module whose canon exactly matches a link's source domain. */
    private func moduleForVersification(_ sourceVersification: String) -> SwordModule? {
        if let activeModule,
           normalizedVersificationName(VersificationMapper.versificationName(for: activeModule))
        == normalizedVersificationName(sourceVersification)
    {
            return activeModule
        }
        for info in installedBibleModules {
            guard let module = swordManager?.module(named: info.name) else { continue }
            if normalizedVersificationName(VersificationMapper.versificationName(for: module))
        == normalizedVersificationName(sourceVersification)
      {
                return module
            }
        }
        return nil
    }

    /** Expands one source-canon range through SWORD's canon indexes when no module parser exists. */
    private func expandCanonicalReference(
        _ value: String,
        sourceVersification: String,
        targetBookInitials: String?
    ) -> [OsisRef] {
        let endpoints = value.split(separator: "-", maxSplits: 1).map(String.init)
    guard
      let start = parseOsisRef(
            endpoints[0].trimmingCharacters(in: .whitespacesAndNewlines),
            sourceVersification: sourceVersification,
            targetBookInitials: targetBookInitials
      )
    else { return [] }
        guard endpoints.count == 2 else { return [start] }
    guard
      let end = parseOsisRef(
                  endpoints[1].trimmingCharacters(in: .whitespacesAndNewlines),
                  sourceVersification: sourceVersification,
                  targetBookInitials: targetBookInitials
              ),
              let startIndex = SwordVersification.referenceIndex(
                  for: .init(osisBookId: start.osisId, chapter: start.chapter, verse: start.verse),
                  versification: sourceVersification
              ),
              let endIndex = SwordVersification.referenceIndex(
                  for: .init(osisBookId: end.osisId, chapter: end.chapter, verse: end.verse),
                  versification: sourceVersification
              ),
      startIndex <= endIndex
    else { return [] }
        let references = (startIndex...endIndex).compactMap { index -> VerseKeyReference? in
      guard
        let reference = SwordVersification.reference(
                      forIndex: index,
                      versification: sourceVersification
        ), reference.verse > 0
      else { return nil }
            return VerseKeyReference(
                osisBookId: reference.osisBookId,
                chapter: reference.chapter,
                verse: reference.verse,
                ordinal: index
            )
        }
    return makeOsisRef(
      references: references,
      sourceModule: nil,
      sourceVersification: sourceVersification,
      targetBookInitials: targetBookInitials
    ).map { [$0] } ?? []
  }

  /**
   Applies one contiguous Android `BookAndKey`-equivalent reference to this controller.

   The destination controller, not the source pane, owns target-module selection and strict
   source-to-target mapping. This is required for dedicated links windows because their active
   document can differ from the pane that emitted the link.

   - Parameter ref: Complete source passage, source versification, and optional forced target
     module retained from the link parser.
   - Returns: `true` after exact target mapping and navigation; otherwise `false` with no
     navigation mutation.
   - Side effects: For a validated readable destination, may leave My Notes, switch the visible
     Bible document/category, persist pane state, record navigation history, and emit a reader
     document when the web client is ready.
   - Failure modes: Missing current/target Bible modules, unsupported strict mappings, invalid
     target entries, locked targets, non-monotonic mapped ranges, and unavailable target book
     metadata fail closed without leaving My Notes.
   */
  @discardableResult
  func navigateToBibleLink(_ ref: OsisRef) -> Bool {
    guard let target = navigationReference(for: ref) else { return false }

    if activeInstalledScriptureSource()?.info.name != target.moduleName
        || currentCategory != .bible {
      if sqliteRuntimeCoordinator.hasGenuineSwordModule(named: target.moduleName) {
        guard moduleSwitchCoordinator.switchBibleDocument(
          to: sqliteRuntimeCoordinator.canonicalSwordModuleName(target.moduleName),
          context: makeModuleSwitchContext(),
          prepareForSwitch: { self.showingMyNotes = false }
        ) == .switched else { return false }
      } else {
        guard sqliteModuleSwitchCoordinator.switchBible(
          to: target.moduleName,
          updatesVisibleCategory: true,
          context: makeSQLiteModuleSwitchContext(),
          prepareForSwitch: { self.showingMyNotes = false }
        ) else { return false }
      }
    } else {
      // Android routes same-module link results through the Bible page as well.
      showingMyNotes = false
    }
    guard activeInstalledScriptureSource()?.info.name == target.moduleName,
      currentCategory == .bible
    else { return false }

    pendingLinkNavigationOrdinalRange = target.ordinalRange
    navigationCoordinator.navigateTo(
      book: target.book,
      chapter: target.chapter,
      verse: target.verse,
      context: makeNavigationContext()
    )
    return true
  }

  /**
   Captures Android's exact non-special `BookAndKey` state for the shared window popup.

   - Returns: A proven Bible reference or exact generic module/key destination.
   - Side effects: Reads source versification metadata and may temporarily inspect a SWORD verse
     cursor; the module restores its prior key.
   - Failure modes: Special documents, absent source identity, invalid current verses, and
     unverified source-to-KJVA mappings return nil without substituting stale Bible state.
   */
  func windowMenuReference() -> BibleWindowMenuReference? {
    guard !showingMyNotes,
      !showingStudyPad,
      !isShowingAndroidMultiDocument,
      !isShowingAndroidMemorizeDocument,
      let initials = aiCurrentSourceInitials(for: currentCategory),
      let key = aiCurrentSourceKey(for: currentCategory)
    else {
      return nil
    }

    if currentCategory == .bible {
      let osisBookID = osisBookId(for: currentBook)
      let verse = max(1, currentVerse)
      guard !osisBookID.isEmpty else { return nil }

      let sourceVersification: String
      let sourceOrdinal: Int?
      if let module = activeSQLiteBibleModule, module.info.name == initials {
        sourceVersification = BibleReaderSQLiteSourceMetadata(module: module).versification
        sourceOrdinal = JSwordKJVAVersification.verseOrdinal(
          osisId: osisBookID,
          chapter: currentChapter,
          verse: verse
        )
      } else if let module = activeModule, module.info.name == initials {
        sourceVersification = VersificationMapper.versificationName(for: module)
        sourceOrdinal = module.verseOrdinal(
          osisBookId: osisBookID,
          chapter: currentChapter,
          verse: verse
        )
      } else {
        return nil
      }

      guard let sourceOrdinal,
        let verified = VerifiedKJVAOrdinalRange(
          resolvingSourceBookInitials: initials,
          sourceVersification: sourceVersification,
          sourceOrdinalStart: sourceOrdinal,
          sourceOrdinalEnd: sourceOrdinal
        )
      else {
        return nil
      }
      let sourceOSISReference = "\(osisBookID).\(currentChapter).\(verse)"
      return BibleWindowMenuReference.bible(
        displayName: "\(currentBook) \(currentChapter):\(verse)",
        sourceBookName: currentBook,
        sourceOSISReference: sourceOSISReference,
        verifiedRange: verified
      )
    }

    return BibleWindowMenuReference.generic(
      displayName: windowMenuReferenceDisplayName(key: key),
      moduleInitials: initials,
      key: key
    )
  }

  /** Whether Android exposes Export as HTML for the currently rendered special document. */
  var isWindowMenuHTMLExportAvailable: Bool {
    showingMyNotes || showingStudyPad || isShowingAndroidMultiDocument
  }

  /** Exact active Study Pad label used by Android's archive and CSV export commands. */
  var windowMenuStudyPadLabelID: UUID? {
    showingStudyPad ? activeStudyPadLabelId : nil
  }

  /// Whether the current exact source satisfies Android's whole-page bookmark visibility rule.
  var createWindowMenuWholePageBookmarkEligibility: Bool {
    guard currentCategory != .bible,
      let reference = windowMenuReference(),
      case .generic = reference.navigationTarget
    else {
      return false
    }
    return true
  }

  /**
   Creates Android's whole-page bookmark for the current non-Bible, non-special document.

   - Returns: True only when an exact generic request was emitted to the canonical annotation path.
   - Side effects: Persists and emits a generic bookmark through the same bridge handler as Vue.
   - Failure modes: Bible pages, special documents, and missing source identity are no-ops.
   */
  @discardableResult
  func createWindowMenuWholePageBookmark() -> Bool {
    guard currentCategory != .bible,
      let reference = windowMenuReference(),
      case .generic(let target) = reference.navigationTarget
    else {
      return false
    }
    self.bridge(
      bridge,
      createGenericWholePageBookmark: GenericWholePageBookmarkRequest(
        sourceInitials: target.moduleInitials,
        sourceKey: target.key
      )
    )
    return true
  }

  /** Emits Vue's existing shared HTML-export event for Android-supported special documents. */
  func requestWindowMenuHTMLExport() {
    guard isWindowMenuHTMLExportAvailable else { return }
    bridge.emit(event: "export_html")
  }

  /**
   Applies a copied or speech-owned reference using Android's target-page rules.

   Bible references keep the target's current Bible or commentary document when it is already a
   verse page. Other targets use the exact bookmark navigation planner, which may switch to the
   source document and key. This mirrors `CurrentPageManager.isVersePageShown` and
   `setCurrentDocumentAndKey` without flattening generic keys into Bible coordinates.

   - Parameter reference: Typed source destination from the reader-session reference store.
   - Side effects: May navigate the current verse page or switch/render an exact source document.
   - Throws: Existing bookmark commit failures when the target cannot be proven or serialized.
   */
    @MainActor
    func navigateToWindowMenuReference(_ reference: BibleWindowMenuReference) throws {
    if let bibleReference = reference.bibleReference {
      if currentCategory == .bible {
        guard navigateToBibleLink(bibleReference) else {
          throw BibleReaderBookmarkNavigationCommitFailure.readerUnavailable
        }
        return
      }
      if currentCategory == .commentary {
        guard let target = navigationReference(for: bibleReference) else {
          throw BibleReaderBookmarkNavigationCommitFailure.readerUnavailable
        }
        navigateTo(book: target.book, chapter: target.chapter, verse: target.verse)
        return
      }
    }
    try navigate(toBookmarkTarget: reference.navigationTarget)
  }

  /** Formats the generic source key shown in Android's Open-reference menu row. */
  private func windowMenuReferenceDisplayName(key: String) -> String {
    switch currentCategory {
    case .commentary:
      return "\(currentBook) \(currentChapter):\(max(1, currentVerse))"
    case .epub:
      return currentEpubTitle ?? key
    case .bible, .dictionary, .generalBook, .map, .dailyDevotion:
      return key
    }
  }

  /**
   Opens one persisted bookmark through an exact Android-compatible identity proof.

   The planner runs before any pane mutation. A successful plan is revalidated against the live
   backend and serialized before one category-specific commit, so stale modules, duplicate local
   documents, replaced EPUB generations, malformed content, and unsupported mappings leave the
   bookmark list open without selecting current, first, or neighboring content.

   - Parameter target: Exact Bible or generic bookmark destination resolved from persistence.
   - Side effects: On success, updates one pane's durable document state and emits one reader
     navigation or one exact generic document. Failure performs no pane or WebView mutation.
   - Throws: Typed bookmark planning failures or `BibleReaderBookmarkNavigationCommitFailure`
     when the active reader changes before commit or payload serialization fails.
   */
  @MainActor
  func navigate(toBookmarkTarget target: BookmarkNavigationTarget) throws {
    let inventory = try bookmarkNavigationInventory(for: target)
    let plan = try BibleReaderBookmarkNavigationCoordinator().plan(
      target: target,
      inventory: inventory
    )
    // Android's bookmark-list navigation forces the default Bible document whenever the pane is
    // not showing Bible text (MainBibleActivity's isFromBookmark branch), so a successfully
    // planned bookmark target leaves My Notes before committing. Planning failures above throw
    // without mutating reader state.
    showingMyNotes = false

    switch plan {
    case .bible(let biblePlan):
      try commitBibleBookmarkNavigation(biblePlan)
    case .sword(let swordPlan):
      try commitSwordBookmarkNavigation(swordPlan)
    case .myDocument(let documentPlan):
      try commitMyDocumentBookmarkNavigation(documentPlan)
    case .epub(let epubPlan):
      try commitEpubBookmarkNavigation(epubPlan)
    }
  }

  /**
   Builds one exact-identity bookmark inventory from a fresh readable-source snapshot.

   - Parameter target: Persisted Bible or generic bookmark target to plan without mutation.
   - Returns: Authorized candidates preserving native ownership and backend registration order.
   - Side effects: Enumerates installed source registries and may read exact My Documents metadata;
     no reader or WebView state changes.
   - Throws: Typed exact-lookup failures for duplicate or unreadable local metadata. Locked native
     and registered SQLite owners suppress colliding My Documents and EPUB candidates.
   */
  @MainActor
  func bookmarkNavigationInventory(
    for target: BookmarkNavigationTarget
  ) throws -> BibleReaderBookmarkNavigationInventory {
    let resolver = installedModuleResolver()
    let scriptureCandidates = resolver.modules(categories: [.bible])
      .compactMap(\.scripture)
      .map(BibleReaderBookmarkNavigationSwordCandidate.init(source:))
    let genericSwordCategories: Set<ModuleCategory> = [
      .commentary,
      .dictionary,
      .glossary,
      .generalBook,
      .map,
      .dailyDevotion,
    ]
    let genericSwordCandidates = resolver.modules(categories: genericSwordCategories)
      .compactMap { source -> SwordModule? in
        guard case .sword(let module) = source else { return nil }
        return module
      }
      .map(BibleReaderBookmarkNavigationSwordCandidate.init(module:))
    let destinationCandidate = activeInstalledScriptureSource().map(
      BibleReaderBookmarkNavigationSwordCandidate.init(source:)
    )

    guard case .generic(let genericTarget) = target else {
      return BibleReaderBookmarkNavigationInventory(
        destinationBible: destinationCandidate,
        swordCandidates: scriptureCandidates
      )
    }

    let registeredTarget = resolver.module(named: genericTarget.moduleInitials)
    let globalRegistryOwnsTarget = resolver.hasNativeRegistration(
      named: genericTarget.moduleInitials
    ) || registeredTarget != nil
    var documentCandidates: [MyDocument] = []
    if !globalRegistryOwnsTarget, let store = myDocumentStore {
      do {
        documentCandidates = [try store.exactDocument(initials: genericTarget.moduleInitials)]
      } catch let error as MyDocumentExactLookupError {
        switch error {
        case .documentNotFound, .invalidDocumentInitials:
          break
        case .duplicateDocuments:
          throw BibleReaderBookmarkNavigationFailure.genericModuleAmbiguous(
            genericTarget.moduleInitials
          )
        case .documentReadFailed, .pageNotFound, .duplicatePages, .pageReadFailed:
          throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
            moduleInitials: genericTarget.moduleInitials,
            key: genericTarget.key
          )
        }
      }
    }

    let epubReaders = globalRegistryOwnsTarget ? [] : EpubReader.installedEpubs()
      .filter { $0.initials == genericTarget.moduleInitials }
      .compactMap { EpubReader(identifier: $0.identifier) }
    return BibleReaderBookmarkNavigationInventory(
      destinationBible: destinationCandidate,
      swordCandidates: scriptureCandidates + genericSwordCandidates,
      myDocumentCandidates: myDocumentStore.map { store in
        documentCandidates.map {
          BibleReaderBookmarkNavigationMyDocumentCandidate(document: $0, store: store)
        }
      } ?? [],
      epubCandidates: epubReaders.map(BibleReaderBookmarkNavigationEpubCandidate.init(reader:))
    )
  }

  /** Commits one fully mapped Bible range into the already-selected destination module. */
  @MainActor
  private func commitBibleBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationBiblePlan
  ) throws {
    guard let source = activeInstalledScriptureSource(),
      source.info.category == .bible,
      source.info.name == plan.destinationModuleInitials,
      source.versificationName == plan.destinationVersification,
      let first = plan.destinationVerses.first,
      let last = plan.destinationVerses.last,
      first.ordinal == plan.destinationOrdinalRange.lowerBound,
      last.ordinal == plan.destinationOrdinalRange.upperBound,
      let resolvedFirst = source.verseReference(ordinal: first.ordinal),
      resolvedFirst.osisBookId == first.reference.osisBookID,
      resolvedFirst.chapter == first.reference.chapter,
      resolvedFirst.verse == first.reference.verse,
      let resolvedLast = source.verseReference(ordinal: last.ordinal),
      resolvedLast.osisBookId == last.reference.osisBookID,
      resolvedLast.chapter == last.reference.chapter,
      resolvedLast.verse == last.reference.verse,
      let book = (try? source.bookList())?.first(where: {
        $0.osisId == first.reference.osisBookID
      })?.name
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }

    if currentCategory != .bible {
      switchBibleDocument(to: source.info.name)
      guard activeInstalledScriptureSource()?.info.name == source.info.name,
        currentCategory == .bible
      else {
        throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
      }
    }

    pendingLinkNavigationOrdinalRange = [first.ordinal, last.ordinal]
    navigationCoordinator.navigateTo(
      book: book,
      chapter: first.reference.chapter,
      verse: first.reference.verse,
      context: makeNavigationContext()
    )
  }

  /**
   Reauthorizes and commits one exact installed SWORD generic fragment.

   - Parameter plan: Immutable fragment identity produced from an earlier readable inventory.
   - Side effects: Captures one fresh resolver snapshot, re-reads the exact fragment, then mutates
     pane/WebView state only after every identity and serialization check succeeds.
   - Throws: `genericModuleNotFound` when the module was removed, relocked, changed category, or is
     no longer an authorized native SWORD source; typed lookup/commit failures reject stale data.
   */
  @MainActor
  func commitSwordBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationSwordPlan
  ) throws {
    let resolver = installedModuleResolver()
    guard case .sword(let module)? = resolver.module(named: plan.moduleInitials),
      module.info.category == plan.category
    else {
      throw BibleReaderBookmarkNavigationFailure.genericModuleNotFound(plan.moduleInitials)
    }
    let currentFragment: SwordRawOSISFragment
    do {
      currentFragment = try module.rawOSISFragment(forKey: plan.key)
    } catch {
      throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
        moduleInitials: plan.moduleInitials,
        key: plan.key
      )
    }
    guard currentFragment == plan.fragment,
      currentFragment.hasRenderableContent,
      let category = Self.bookmarkDocumentCategory(for: plan.category)
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }

    let source = currentFragment.source
    let contentOrdinalRange = currentFragment.contentOrdinalRange
    guard
      let documentJSON = documentPayloadFactory().documentJSON(
        BibleReaderDocumentPayloadRequest(
          osisBookId: Self.bookmarkPseudoOSISBookID(for: category),
          bookName: currentFragment.keyName,
          chapter: 1,
          verseCount: 1,
          isNewTestament: currentFragment.isNewTestament,
          xml: currentFragment.xml,
          bookCategory: category.rawValue,
          bookInitials: source.initials,
          addChapter: false,
          originalOrdinalRange: plan.selectedOrdinalRange.map {
            [$0.lowerBound, $0.upperBound]
          },
          documentKey: currentFragment.key,
          keyName: currentFragment.keyName,
          ordinalRangeOverride: [
            contentOrdinalRange.lowerBound,
            contentOrdinalRange.upperBound,
          ],
          fragmentOrdinalRange: currentFragment.keyOrdinalRange.map {
            [$0.lowerBound, $0.upperBound]
          },
          fragmentKey: currentFragment.fragmentKey,
          fragmentOsisRef: currentFragment.osisRef,
          annotateRef: currentFragment.annotateRef,
          fragmentFeatures: currentFragment.features,
          moduleName: source.name,
          moduleAbbreviation: source.abbreviation,
          versificationName: source.versification,
          language: source.language,
          direction: source.direction,
          sourceHasStrongs: source.hasStrongs
        )
      )
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.serializationFailed
    }

    beginReplacingContentIntent()
    resetAuxiliaryContentState()
    applyExactSwordBookmarkState(
      module: module,
      category: category,
      key: currentFragment.key
    )
    emitExactGenericBookmarkDocument(
      documentJSON: documentJSON,
      category: category,
      moduleName: plan.moduleInitials,
      bookName: currentFragment.keyName,
      key: currentFragment.key,
      selectedOrdinalRange: plan.selectedOrdinalRange,
      jumpToID: nil
    )
  }

  /** Revalidates and commits one exact My Documents page without permissive fetch fallback. */
  @MainActor
  private func commitMyDocumentBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationMyDocumentPlan
  ) throws {
    guard let store = myDocumentStore else {
      throw BibleReaderBookmarkNavigationCommitFailure.readerUnavailable
    }
    let document: MyDocument
    let page: MyDocumentPage
    do {
      document = try store.exactDocument(initials: plan.fragment.moduleInitials)
      page = try store.exactPage(
        bookInitials: plan.fragment.moduleInitials,
        pageKey: plan.fragment.key
      )
    } catch {
      throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
        moduleInitials: plan.fragment.moduleInitials,
        key: plan.fragment.key
      )
    }
    guard document.id == plan.fragment.documentID,
      document.name == plan.fragment.documentName,
      page.id == plan.fragment.pageID,
      page.document?.id == document.id,
      page.title == plan.fragment.title,
      page.contentTypeRawValue == plan.fragment.contentTypeRawValue,
      page.pageContent?.content ?? "" == plan.fragment.rawContent,
      page.languageCode == plan.fragment.languageCode
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }

    let metadata = store.readerMetadata(
      for: page,
      bookInitials: document.initials,
      pageKey: page.pageKey,
      unknownPromptName: String(localized: "ai_unknown_prompt", defaultValue: "AI")
    )
    guard
      let documentJSON = myDocumentCoordinator.documentJSON(
        document: document,
        page: page,
        metadata: metadata,
        genericBookmarks: genericBookmarkPayloads(
          bookInitials: document.initials,
          key: page.pageKey
        )
      )
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.serializationFailed
    }

    beginReplacingContentIntent()
    resetAuxiliaryContentState()
    activeEpubReader = nil
    activeEpubIdentifier = nil
    activeEpubTitle = nil
    currentEpubTitle = nil
    currentEpubHref = nil
    activeGeneralBookModule = nil
    activeGeneralBookModuleName = document.initials
    currentGeneralBookKey = page.pageKey
    currentCategory = .generalBook
    myDocumentCoordinator.setActivePage(
      bookInitials: document.initials,
      pageKey: page.pageKey
    )
    if let pageManager = activeWindow?.pageManager {
      pageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
      pageManager.generalBookDocument = document.initials
      pageManager.generalBookKey = page.pageKey
      pageManager.epubIdentifier = nil
      pageManager.epubHref = nil
      onPersistState?()
    }
    emitExactGenericBookmarkDocument(
      documentJSON: documentJSON,
      category: .generalBook,
      moduleName: document.initials,
      bookName: document.name,
      key: page.pageKey,
      selectedOrdinalRange: plan.selectedOrdinalRange,
      jumpToID: nil
    )
  }

  /** Revalidates and commits one exact immutable EPUB generation and numeric key. */
  @MainActor
  private func commitEpubBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationEpubPlan
  ) throws {
    guard let reader = EpubReader(identifier: plan.identifier),
      reader.generationIdentifier == plan.generationIdentifier,
      reader.initials == plan.moduleInitials,
      reader.title == plan.title,
      reader.language == plan.language
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }
    let content: EpubReader.Content
    do {
      content = try reader.exactContent(forPersistedKey: plan.content.persistedKey)
    } catch {
      throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
        moduleInitials: plan.moduleInitials,
        key: plan.content.persistedKey
      )
    }
    guard content == plan.content else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }
    let documentJSON = documentPayloadFactory().epubDocumentJSON(
      bookName: reader.title,
      bookInitials: reader.initials,
      key: content.persistedKey,
      keyName: content.title,
      content: content.html,
      ordinalRange: [content.ordinalRange.lowerBound, content.ordinalRange.upperBound],
      language: reader.language
    )
    guard documentJSON != "{}" else {
      throw BibleReaderBookmarkNavigationCommitFailure.serializationFailed
    }

    beginReplacingContentIntent()
    resetAuxiliaryContentState()
    activeEpubReader = reader
    activeEpubIdentifier = reader.identifier
    activeEpubTitle = reader.title
    currentEpubTitle = content.title
    currentEpubHref = nil
    activeGeneralBookModule = nil
    activeGeneralBookModuleName = reader.initials
    currentGeneralBookKey = content.persistedKey
    currentCategory = .generalBook
    if let pageManager = activeWindow?.pageManager {
      pageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
      pageManager.generalBookDocument = reader.initials
      pageManager.generalBookKey = content.persistedKey
      pageManager.epubIdentifier = nil
      pageManager.epubHref = nil
      onPersistState?()
    }
    emitExactGenericBookmarkDocument(
      documentJSON: documentJSON,
      category: .generalBook,
      moduleName: reader.initials,
      bookName: content.title,
      key: content.persistedKey,
      selectedOrdinalRange: plan.selectedOrdinalRange,
      jumpToID: content.fragment
    )
  }

  /** Applies category-owned SWORD module and exact key state without triggering a second read. */
  @MainActor
  private func applyExactSwordBookmarkState(
    module: SwordModule,
    category: DocumentCategory,
    key: String
  ) {
    activeEpubReader = nil
    activeEpubIdentifier = nil
    activeEpubTitle = nil
    currentEpubTitle = nil
    currentEpubHref = nil
    switch category {
    case .commentary:
      activeCommentaryModule = module
      activeCommentaryModuleName = module.info.name
    case .dictionary:
      activeDictionaryModule = module
      activeDictionaryModuleName = module.info.name
      currentDictionaryKey = key
    case .generalBook:
      activeGeneralBookModule = module
      activeGeneralBookModuleName = module.info.name
      currentGeneralBookKey = key
    case .map:
      activeMapModule = module
      activeMapModuleName = module.info.name
      currentMapKey = key
    case .bible, .epub, .dailyDevotion:
      return
    }
    currentCategory = category
    if let pageManager = activeWindow?.pageManager {
      BibleReaderModuleSwitchPlan(
        moduleName: module.info.name,
        category: category,
        updatesVisibleCategory: true,
        retainedGenericKey: key
      ).apply(to: pageManager)
      onPersistState?()
    }
    }

  /** Emits one pre-serialized exact generic destination and its optional BVA highlight. */
  private func emitExactGenericBookmarkDocument(
    documentJSON: String,
    category: DocumentCategory,
    moduleName: String,
    bookName: String,
    key: String,
    selectedOrdinalRange: ClosedRange<Int>?,
    jumpToID: String?
  ) {
    replaceDocument(
      documentJSON: documentJSON,
      setup: ReaderSetupContentPayload(
        jumpToOrdinal: selectedOrdinalRange?.lowerBound,
        jumpToId: jumpToID,
        ordinalStart: selectedOrdinalRange?.lowerBound,
        ordinalEnd: selectedOrdinalRange?.upperBound,
        highlight: selectedOrdinalRange != nil,
        bookInitials: moduleName,
        osisRef: key
      )
    )
    setRenderedContentState(
      category: category,
      moduleName: moduleName,
      book: bookName,
      key: key
        )
    emitActiveState()
    bridge.clearSelection()
    applyNightModeBackground()
    }

  /**
   Maps bookmark-owning JSword categories onto reader document categories.

   - Parameter moduleCategory: Actual installed-book category attached to a generic bookmark.
   - Returns: Reader persistence category, or nil for Bible/add-on/unknown sources handled by other
     bookmark paths.
   - Side effects: None.
   - Failure modes: None; every pinned JSword category has an explicit disposition.
   */
  private static func bookmarkDocumentCategory(
    for moduleCategory: ModuleCategory
  ) -> DocumentCategory? {
    switch moduleCategory {
    case .commentary:
      return .commentary
    case .dictionary, .glossary:
      return .dictionary
    case .generalBook, .dailyDevotion, .questionable, .essays, .images:
      return .generalBook
    case .map:
      return .map
    case .bible, .addon, .unknown:
      return nil
    }
  }

  /** Returns the stable pseudo-book identifier used by generic Vue documents. */
  private static func bookmarkPseudoOSISBookID(for category: DocumentCategory) -> String {
    switch category {
    case .commentary:
      return "Commentary"
    case .dictionary:
      return "Dict"
    case .generalBook, .dailyDevotion:
      return "GenBook"
    case .map:
      return "Map"
    case .bible, .epub:
      return "Document"
    }
  }

  /**
   Resolves one complete source passage into a strict destination-module navigation identity.

   Every source verse is converted independently and validated against the requested module. The
   first mapped verse anchors the visible chapter, while the first and last exact target ordinals
   preserve the full contiguous range for Vue setup.

   - Parameter ref: Source-owned contiguous passage plus optional forced target initials.
   - Returns: Destination module, first verse, and inclusive ordinal range, or `nil` when any part
     cannot be mapped exactly.
   - Side effects: Reads installed module metadata and exact target ordinals; reader state is not
     mutated.
   - Failure modes: Returns `nil` for missing/non-Bible modules, unsupported versifications,
     absent target verses, duplicate-only passages, reversed mappings, or missing book metadata.
   */
  private func navigationReference(for ref: OsisRef) -> BibleLinkNavigationTarget? {
    let resolver = installedModuleResolver()
    let targetSource: BibleReaderInstalledScriptureSource
    if let requestedInitials = ref.targetBookInitials?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !requestedInitials.isEmpty
    {
      guard let requestedSource = resolver.scripture(named: requestedInitials) else { return nil }
      targetSource = requestedSource
    } else {
      guard let activeSource = resolver.scripture(named: activeModuleName) else { return nil }
      targetSource = activeSource
    }

    var mappedReferences: [VerseKeyReference] = []
        for source in ref.sourceVerses {
      guard let reference = targetSource.mappedReference(
        osisBookId: source.osisBookId,
        chapter: source.chapter,
        verse: source.verse,
        from: ref.sourceVersification
      ) else { return nil }
      if let previous = mappedReferences.last {
        guard
          previous == reference
            || targetSource.isCanonicallyAdjacent(reference, after: previous)
        else { return nil }
        if previous == reference {
          continue
        }
            }
      mappedReferences.append(reference)
        }
    guard let first = mappedReferences.first,
      let last = mappedReferences.last,
      let book = (try? targetSource.bookList())?.first(where: {
        $0.osisId == first.osisBookId
      })?.name
    else { return nil }
    return BibleLinkNavigationTarget(
      moduleName: targetSource.info.name,
      book: book,
      chapter: first.chapter,
      verse: first.verse,
      ordinalRange: [first.ordinal, last.ordinal]
    )
    }

    /**
     Requests that the owning SwiftUI view present the downloads/install UI.
     */
    public func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge) {
        bridgeEventRouter.requestOpenDownloads()
    }

    // MARK: - BibleBridgeDelegate — Dialogs

  /// Callback for presenting a reference chooser dialog (returns JSword short `Verse.name`).
    var onRefChooserDialog: ((@escaping (String?) -> Void) -> Void)?

    /**
   Opens the native reference chooser and returns Android's JSword short `Verse.name` to Vue.js.

     - Parameter callId: Bridge response identifier for the pending chooser callback.

     Side effects:
   - invokes the native chooser callback and sends the resolved short verse name or Android's empty
     cancellation string back

     Failure modes:
   - returns an empty string immediately when no native chooser handler is configured
     */
    public func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int) {
        if let handler = onRefChooserDialog {
      handler { [weak bridge] verseName in
        bridge?.sendResponse(callId: callId, value: "\"\(verseName ?? "")\"")
            }
        } else {
      bridge.sendResponse(callId: callId, value: "\"\"")
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
        return activeModule.verseOrdinal(osisBookId: osisBookId, chapter: chapter, verse: verse)
          != nil
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
   Navigates reference text through the full active-module parser used by Android Search.

   Human-readable, localized/module-language, OSIS, range, and passage-list input all resolve
   through `BibleReaderReferenceResolver.resolveReference`. One contiguous passage remains normal
   Bible navigation with its complete ordinal range. Multiple discontiguous passages render in one
   transient `MultiDocument` in the current pane, matching Android Search's force-open-here result.

   - Parameter text: User-entered Search or window-tab reference text.
   - Returns: `true` only when parsing and the complete navigation/document commit succeed.
   - Side effects: May update Bible position and history or replace current rendered content with a
     transient multi-reference document.
   - Failure modes: Empty or invalid text, unavailable active-module metadata, unmappable ranges,
     and multi-document serialization failures return `false` without partial navigation.
     */
    @discardableResult
    public func navigateToRef(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

    guard let resolvedReference = referenceResolver().resolveReference(trimmed) else {
      return false
        }

    guard let activeModule else {
      return navigateToOsisRef(resolvedReference)
    }
    let references = parseOsisReferences(
      resolvedReference,
      sourceVersification: VersificationMapper.versificationName(for: activeModule)
    )
    guard !references.isEmpty else { return false }
    if references.count == 1, let reference = references.first {
      return navigateToBibleLink(reference)
        }

    guard let documentJSON = buildBibleMultiReferenceDocumentJSON(refs: references) else {
        return false
    }
    loadMultiReferenceDocument(documentJSON)
    return true
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

  /** Routes trusted generic BibleView help HTML to the pane-owned native help presenter. */
    public func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?) {
    onShowReaderHelp?(AIReaderHelpCatalog.generic(content: content, title: title))
  }

  /** Routes Android's localized Bookmarks and My Notes help contract to native presentation. */
  public func bridgeDidRequestBookmarkHelp(_ bridge: BibleBridge) {
    guard let presentation = AIReaderHelpCatalog.bookmarks() else { return }
    onShowReaderHelp?(presentation)
  }

  /** Routes one allowlisted scoped help request to its native localized presentation. */
  public func bridge(_ bridge: BibleBridge, showHelp scope: BibleBridgeHelpScope) {
    switch scope {
    case .memorize:
      onShowReaderHelp?(AIReaderHelpCatalog.memorize())
    }
  }

  // MARK: - BibleBridgeDelegate — AI Actions

  /** Forwards an exact web selection to the pane-owned AI action coordinator. */
  public func bridge(_ bridge: BibleBridge, requestAIAction request: AISelectionActionRequest) {
    onRequestAIAction?(request)
  }

  /** Forwards an exact note-editor request to the pane-owned AI action coordinator. */
  public func bridge(
    _ bridge: BibleBridge,
    requestNoteEditorAIAction request: AINoteEditorActionRequest
  ) {
    onRequestNoteEditorAIAction?(request)
  }

  /** Forwards exact generated-page markers to the pane-owned native chooser. */
  public func bridge(
    _ bridge: BibleBridge,
    chooseAIDocumentPage markers: [AIDocumentPageMarker]
  ) {
    onChooseAIDocumentPage?(markers)
  }

  /** Forwards an exact source prompt identity to the pane-owned prompt editor route. */
  public func bridge(_ bridge: BibleBridge, openPromptEditor promptID: UUID) {
    onOpenAIPromptEditor?(promptID)
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
  /// Callback to open one complete source-owned Bible passage in a links window.
  var onOpenInLinksWindow: ((OsisRef) -> Void)?

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
    configurationCoordinator.toggleHiddenCompareDocument(documentId, activeWindow: activeWindow) {
      [weak self] in
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
     Navigates an EPUB link through the exact general-book identity supplied by the web client.

     - Parameters:
       - bridge: Reader bridge that emitted the navigation request.
       - bookInitials: EPUB module initials embedded in the transformed link.
       - toKey: Original EPUB manifest key; an empty key denotes a same-page anchor.
       - toId: Optional XHTML element id within the target manifest item.
     - Side effects: Loads the resolved numeric EPUB fragment or emits an in-page setup request.
     - Failure modes: Ignores links whose initials do not match the active EPUB, and leaves the
       visible page unchanged when the target manifest key or id is not indexed.
     */
  public func bridge(
    _ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String
  ) {
        guard let reader = activeEpubReader,
      bookInitials == reader.initials
    else { return }
        if !toKey.isEmpty {
      guard
        let content = reader.content(
                originalKey: toKey,
                htmlID: toId.isEmpty ? nil : toId
        )
      else { return }
            loadEpubEntry(key: content.key + (content.fragment.map { "#\($0)" } ?? ""))
        } else if !toId.isEmpty {
            bridge.emit(
                event: "setup_content",
                data: epubSetupContentPayload(fragment: toId)
            )
        }
    }

  /**
   Updates active WebView languages from every readable runtime module inventory.

   - Side effects: Emits the sorted distinct SWORD and SQLite language list to the bridge.
   - Failure modes: Empty or unavailable inventories emit English as the existing fallback.
   */
    public func updateActiveLanguages() {
    let languages = sqliteRuntimeCoordinator.activeLanguages(
      inventories: BibleReaderSQLiteRuntimeInventories(
        bibles: installedBibleModules,
        commentaries: installedCommentaryModules,
        dictionaries: installedDictionaryModules
      )
    )
        bridge.updateActiveLanguages(languages.isEmpty ? ["en"] : languages)
    }

    /**
     Convert an ordinal back to a verse number within the current chapter.
     */
    private func ordinalToVerse(_ ordinal: Int) -> Int? {
        guard let reference = verseReference(book: currentBook, ordinal: ordinal),
      reference.chapter == currentChapter
    else {
            return nil
        }
        return reference.verse
    }

  /**
   Builds Android-compatible share/copy text from one explicit installed Bible source.

   - Parameters:
     - bookInitials: Bridge- or bookmark-owned installed module identity.
     - startOrdinal: First source-domain verse ordinal.
     - endOrdinal: Last source-domain verse ordinal.
   - Returns: Plain passage text plus exact source reference and module, or nil on any identity,
     address, content, or formatting failure.
   - Side effects: SWORD performs one cursor-restoring bounded read; SQLite uses operation-owned
     chapter reads. The active pane is never consulted as a substitute.
   - Failure modes: Missing/wrong-category sources, reversed or oversized ranges, non-verse
     endpoints, empty passages, and backend errors fail closed.
   */
    func verseActionText(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> String? {
        BibleReaderVerseActionTextBuilder(
            moduleResolver: installedModuleResolver()
        ).build(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    // MARK: - Content Loading

    /**
     Builds the shared Android-parity replacement emitter for the active reader pane.

     - Returns: An emitter bound to the current bridge and a live `initial: true` config builder.
     - Side effects: None during construction; the returned emitter dispatches only when invoked.
     - Failure modes: Configuration encoding failures use the controller's existing `{}` fallback.
     */
    private func documentReplacementEmitter() -> BibleReaderDocumentReplacementEmitter {
        BibleReaderDocumentReplacementEmitter(
            bridge: bridge,
            buildInitialConfigJSON: { [weak self] in
                self?.buildConfigJSON(initial: true) ?? "{}"
            }
        )
    }

    /**
     Atomically replaces the current Vue document using Android's event ordering.

     - Parameters:
       - documentJSON: Complete raw JSON replacement document.
       - setup: Typed setup/scroll payload for the replacement content.
     - Side effects: Queues one `clear_document`, initial `set_config`, `add_documents`, and
       `setup_content` JavaScript evaluation.
     - Failure modes: Logs and leaves the existing document intact when setup encoding or bridge
       dispatch fails.
     */
    private func replaceDocument(
        documentJSON: String,
        setup: ReaderSetupContentPayload
    ) {
        guard documentReplacementEmitter().replace(
            documentJSON: documentJSON,
            setup: setup
        ) else {
            logger.error("Failed to emit atomic Vue document replacement")
            return
        }
    }

    /**
     Presents one reader-local AI status document without changing the selected source or storage.

     Android uses `BibleView.loadDocument(ErrorDocument(...))` while an AI document regenerates.
     Keeping this path bridge-only prevents loading, cancellation, and failure states from entering
     My Documents, CloudKit, or Android remote-sync patches.

     - Parameter document: Localized message and Vue error-document severity.
     - Side effects: Replaces the current WebView payload, clears selection, and reapplies styling.
     - Failure modes: If payload serialization fails, the existing document remains visible and no
       fabricated persisted document is created.
     */
    func loadTransientAIDocument(_ document: AIReaderTransientDocument) {
        beginReplacingContentIntent()
        let severity: BibleReaderDocumentPayloadFactory.ErrorDocumentSeverity =
            document.severity == .error ? .error : .normal
        if let payload = documentPayloadFactory().errorDocumentJSON(
            message: document.message,
            severity: severity
        ) {
            replaceDocument(
                documentJSON: payload,
                setup: ReaderSetupContentPayload(jumpToId: "top")
            )
        }
        bridge.clearSelection()
        applyNightModeBackground()
    }

    /**
     Loads the currently selected Bible chapter into the embedded Vue.js reader.

   - Side effects: Clears transient state, reads serialized SQLite or active SWORD content, emits
     labels/document/setup/state events, restores navigation, and reapplies reader styling.
   - Failure modes: An active backend that cannot return real content emits the deterministic
     no-content document. Placeholder chapters are permitted only when neither backend is active;
     SQLite rows are never replaced by generated verses.
   - Important: SQLite chapter ordinals come from exact intro-inclusive JSword KJVA coordinates.
     */
    private func loadCurrentChapter() {
        beginReplacingContentIntent()
        persistMyNotesPageCategory(visible: false)
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        let osisBookId = osisBookId(for: currentBook)
        let isNT = isNewTestament(currentBook)

    let loadedChapter: BibleChapterDocumentBuilder.LoadedChapterContent?
    if let sqliteModule = activeSQLiteBibleModule {
      loadedChapter = SQLiteBibleChapterDocumentBuilder(module: sqliteModule).loadChapter(
        osisBookId: osisBookId,
        chapter: currentChapter
      )
    } else {
      loadedChapter = loadChapterFromSword(
            osisBookId: osisBookId,
            chapter: currentChapter
        )
    }
        let xml: String
        let verseCount: Int
        let addChapter: Bool
        if let loadedChapter {
            xml = loadedChapter.xml
            verseCount = loadedChapter.verseCount
            addChapter = loadedChapter.addChapter
    } else if activeModule == nil && activeSQLiteBibleModule == nil {
            let fallbackChapter = loadPlaceholderChapter(osisBookId: osisBookId, bookName: currentBook)
            xml = fallbackChapter.0
            verseCount = fallbackChapter.1
            addChapter = true
        } else {
            let renderedOsisBookId = osisBookId.isEmpty ? Self.osisBookId(for: currentBook) : osisBookId
      logger.error(
        "Failed to load active Bible chapter for \(renderedOsisBookId, privacy: .public).\(self.currentChapter)"
      )
            if let document = documentPayloadFactory().errorDocumentJSON(
                message: String(
                    localized: "error_no_content",
                    defaultValue: "No content for selected verse"
                )
            ) {
                replaceDocument(
                    documentJSON: document,
                    setup: ReaderSetupContentPayload(jumpToId: "top")
                )
            }
            setRenderedContentState(
                category: .bible,
                moduleName: activeModuleName,
                book: currentBook,
                chapter: currentChapter,
                key: "\(renderedOsisBookId).\(currentChapter)"
            )
            emitActiveState()
            bridge.clearSelection()
            applyNightModeBackground()
            return
        }

        // Query bookmarks for this chapter
        let chapterBookmarks = bookmarksForCurrentChapter(verseCount: verseCount)

    let navigationAnchorRange =
      pendingLinkNavigationOrdinalRange
            ?? navigationCoordinator.originalNavigationOrdinalRange
        pendingLinkNavigationOrdinalRange = nil
    guard
      let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: currentChapter,
            verseCount: verseCount,
            isNT: isNT,
            xml: xml,
            bookmarks: chapterBookmarks,
            addChapter: addChapter,
            originalOrdinalRange: navigationAnchorRange
      )
    else { return }

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
        let setupPayload: ReaderSetupContentPayload
        if let navigationAnchorRange,
           let anchorStart = navigationAnchorRange.first,
      let anchorEnd = navigationAnchorRange.last
    {
            setupPayload = ReaderSetupContentPayload(
                jumpToAnchor: anchorStart,
                ordinalStart: anchorStart,
                ordinalEnd: anchorEnd,
                highlight: true,
                bookInitials: activeModule?.info.name ?? activeModuleName,
                osisRef: "\(osisBookId).\(currentChapter)"
            )
        } else {
            switch restoreTarget {
            case .chapterTop:
                setupPayload = ReaderSetupContentPayload(jumpToId: "top")
            case .ordinal(let ordinal):
                setupPayload = ReaderSetupContentPayload(jumpToOrdinal: ordinal)
            }
        }

        // Send labels before Android's atomic replacement so bookmark highlights can render.
        sendLabelsToVueJS()
        replaceDocument(
            documentJSON: document,
            setup: setupPayload
        )
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
  private func loadChapterFromSword(osisBookId: String, chapter: Int) -> BibleChapterDocumentBuilder
    .LoadedChapterContent?
  {
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
    guard activeModule != nil || activeSQLiteBibleModule != nil else { return nil }

        let osisBookId = osisBookId(for: book)
        let isNT = isNewTestament(book)
    let swordModule = activeModule
        let restoreKey = "\(self.osisBookId(for: currentBook)) \(currentChapter):1"
        defer {
      swordModule?.setKey(restoreKey)
        }

    let loadedChapter: BibleChapterDocumentBuilder.LoadedChapterContent?
    if let sqliteModule = activeSQLiteBibleModule {
      loadedChapter = SQLiteBibleChapterDocumentBuilder(module: sqliteModule).loadChapter(
            osisBookId: osisBookId,
            chapter: chapter
      )
    } else {
      loadedChapter = loadChapterFromSword(osisBookId: osisBookId, chapter: chapter)
    }
    guard let loadedChapter else {
            return nil
        }

        // Query bookmarks through Android's KJVA range so restored rows with module initials or
        // NULL in `book` still highlight in infinite-scroll chapters.
    guard
      let range = bookmarkQueryOrdinalRange(
        book: book, chapter: chapter, verseCount: loadedChapter.verseCount)
    else {
      logger.error(
        "Failed to resolve bookmark range for \(osisBookId, privacy: .public).\(chapter)")
            return nil
        }
        let chapterBookmarks = bookmarkService?.bookmarks(for: range.start, endOrdinal: range.end) ?? []

    guard
      let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: book,
            chapter: chapter,
            verseCount: loadedChapter.verseCount,
            isNT: isNT,
            xml: loadedChapter.xml,
            bookmarks: chapterBookmarks,
            addChapter: loadedChapter.addChapter,
            originalOrdinalRange: nil
      )
    else { return nil }

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

  private func buildSwordChapterXML(
    osisBookId: String, bookName: String, chapter: Int, verses: [(Int, String)]
  ) -> String {
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
    let pattern =
      #"<small><em>&lt;<a href="passagestudy\.jsp\?showStrong=(\d+)#cv">\d+</a>&gt;</em></small>"#
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
      "Mic", "Nah", "Hab", "Zeph", "Hag", "Zech", "Mal",
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

    /**
     Resolves the storage-domain bookmark range for a chapter.

     Android persists Bible bookmark membership in KJVA-compatible ordinals. Prefer that range for
     highlight, My Notes, and list membership so restored Android rows with module initials or NULL
     in `BibleBookmark.book` still match the visible chapter. Source-module ordinals are never used
     as a fallback because they belong to a different coordinate domain.

     - Parameters:
       - book: Display book name for the visible chapter.
       - chapter: One-based chapter number.
       - verseCount: Optional rendered non-empty verse count, used only as a fallback when the
         active module cannot report the chapter's maximum verse number.
     - Returns: Inclusive KJVA storage range and verse count, or `nil` when the visible chapter
       cannot be mapped authoritatively.
     - Side effects: May query the active SWORD module through `chapterOrdinalRange`.
     - Failure modes: Returns `nil` for unknown books, out-of-range chapters, or unsupported
       module/canon combinations.
     */
    private func bookmarkQueryOrdinalRange(
        book: String,
        chapter: Int,
        verseCount: Int? = nil
    ) -> (start: Int, end: Int, verseCount: Int)? {
        let osisId = osisBookId(for: book)
        let sourceVersification = activeSourceVersificationName()
        // Map the visible chapter's span from the source versification into KJVA so the query covers
        // the correct KJVA ordinals even when the module's chapter numbering diverges from KJVA
        // (e.g. a merged Septuagint/Vulgate Psalm covers two KJVA chapters).
        //
        // Lower bound: the chapter's *introduction* ordinal (KJVA verse 0), matching Android's
        // whole-chapter query start `Verse(v11n, book, chapter, 0)`, so a bookmark stored on a Psalm
        // superscription (KJVA verse 0) is included when the Psalm is read in any versification,
        // including KJV-family modules where verse 1 would otherwise start one slot too high.
        //
        // Upper bound: the chapter's *maximum verse number* in the source versification, taken from
        // the active module's canon (`chapterOrdinalRange` reports `verseMax`). The caller's
        // `verseCount` counts only non-empty rendered verses, so using it would truncate the span for
        // chapters that render a verse empty (e.g. Matthew 17:21 in many modern translations) and
        // drop bookmarks on the trailing verses. Fall back to the caller's count, then the KJVA canon
        // count, only when no module can resolve the chapter.
    let sourceLastVerse =
      chapterOrdinalRange(book: book, chapter: chapter)?.verseCount
            ?? verseCount
            ?? JSwordKJVAVersification.verseCount(osisId: osisId, chapter: chapter)
        if let sourceLastVerse, sourceLastVerse > 0,
           let firstKJVA = kjvaChapterIntroOrdinal(
               osisBookId: osisId, chapter: chapter, sourceVersification: sourceVersification
           ),
           let lastKJVA = kjvaOrdinal(
        osisBookId: osisId, chapter: chapter, verse: sourceLastVerse,
        sourceVersification: sourceVersification
      )
    {
            return (
                start: min(firstKJVA, lastKJVA),
                end: max(firstKJVA, lastKJVA),
                verseCount: verseCount ?? sourceLastVerse
            )
        }
        return nil
    }

    /// Query bookmarks for the current chapter's Android-compatible KJVA ordinal range.
    private func bookmarksForCurrentChapter(verseCount: Int) -> [BibleBookmark] {
        guard let service = bookmarkService else { return [] }
    guard
      let range = bookmarkQueryOrdinalRange(
        book: currentBook, chapter: currentChapter, verseCount: verseCount)
    else {
      logger.error(
        "Failed to resolve bookmark range for \(self.currentBook, privacy: .public) \(self.currentChapter)"
      )
            return []
        }
        return service.bookmarks(for: range.start, endOrdinal: range.end)
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
     - Side effects: None during construction; factory methods may read from the bookmark's stored
       SWORD, My Documents, or EPUB source.
     - Failure modes: Missing stored sources fail closed inside the factory without substituting the
       active reader document.
     */
    private func annotationPayloadFactory() -> BibleReaderAnnotationPayloadFactory {
        let moduleResolver = installedModuleResolver()
        let readableActiveModule: SwordModule? = {
            guard case .sword(let module)? = moduleResolver.module(named: activeModuleName) else {
                return nil
            }
            return module
        }()
        return BibleReaderAnnotationPayloadFactory(
            currentBook: currentBook,
            activeModuleName: activeModuleName,
            activeModule: readableActiveModule,
            sourceModuleResolver: { initials in
                guard case .sword(let module)? = moduleResolver.module(named: initials) else {
                    return nil
                }
                return module
            },
            genericSourceResolver: { [weak self] initials, key in
                self?.genericBookmarkSourceContent(bookInitials: initials, key: key)
            },
            bookCatalog: bookCatalog,
            unlabeledLabelID: Self.unlabeledLabelId
        )
    }

    /**
     Resolves Android's emphasized Bookmark-list text for one Bible bookmark.

     The controller exposes the current reader/source boundary while the annotation factory retains
     ownership of SWORD range loading and UTF-16 selection slicing. Existing bridge payload callers
     remain unchanged.

     - Parameter bookmark: Persisted Bible bookmark displayed by the app-owned Bookmark route.
     - Returns: Prefix, selected text, suffix, and normalized full preview.
     - Side effects: May move the active SWORD module cursor while reading the bookmark range.
     - Failure modes: Missing source content returns an empty projection.
     */
    func bookmarkListTextProjection(for bookmark: BibleBookmark) -> BookmarkListTextProjection {
        annotationPayloadFactory().bookmarkListTextProjection(bookmark)
    }

    /**
     Resolves Android's emphasized Bookmark-list text for one generic bookmark.

     - Parameter bookmark: Persisted generic bookmark displayed by the app-owned Bookmark route.
     - Returns: Prefix, selected text, suffix, and normalized full preview from its stored source.
     - Side effects: May read SwiftData, EPUB, or SWORD source content for the exact stored key.
     - Failure modes: Missing or ambiguous source content returns an empty projection without using
       the active reader document as a substitute.
     */
    func bookmarkListTextProjection(for bookmark: GenericBookmark) -> BookmarkListTextProjection {
        annotationPayloadFactory().bookmarkListTextProjection(bookmark)
    }

    /**
     Resolves a generic bookmark's persisted My Documents or EPUB source without active-document
     substitution.

     - Parameters:
       - bookInitials: Exact source initials stored on the generic bookmark.
       - key: Exact persisted page or EPUB fragment key.
     - Returns: Android-shaped source metadata, visible text, and render fragment, or `nil` when the
       stored source/key is unavailable.
     - Side effects: Reads SwiftData or opens the installed EPUB index identified by the stored
       initials.
     - Failure modes: Missing documents, ambiguous EPUB identities, and stale keys return `nil`;
       no current reader source is used as a fallback.
     */
    private func genericBookmarkSourceContent(
        bookInitials: String,
        key: String
    ) -> GenericBookmarkSourceContent? {
        if let store = myDocumentStore,
           let document = store.document(initials: bookInitials),
      let page = store.page(bookInitials: bookInitials, pageKey: key)
    {
            let rawContent = page.pageContent?.content ?? ""
            let language = page.languageCode ?? Locale.current.language.languageCode?.identifier ?? "en"
            return GenericBookmarkSourceContent(
                bookName: document.name,
                bookAbbreviation: document.initials,
                keyName: page.title,
                plainText: GenericBookmarkSourceTextProjection.myDocumentText(
                    rawContent,
                    contentType: page.contentType
                ),
                osisFragment: OsisFragment(
                    xml: MyDocumentContentRenderer.render(rawContent, contentType: page.contentType),
                    key: page.pageKey,
                    keyName: page.title,
                    v11n: nil,
                    bookCategory: DocumentCategory.generalBook.rawValue,
                    bookInitials: document.initials,
                    bookAbbreviation: document.initials,
                    osisRef: page.pageKey,
                    ordinalRange: nil,
                    language: language,
                    direction: Self.annotationTextDirection(language: language),
                    isNativeHtml: true
                )
            )
        }

        let reader: EpubReader?
        if activeEpubReader?.initials == bookInitials {
            reader = activeEpubReader
        } else {
            reader = EpubReader(initials: bookInitials)
        }
        guard let reader, let content = reader.content(forKey: key) else { return nil }
        let ordinalRange = [content.ordinalRange.lowerBound, content.ordinalRange.upperBound]
        return GenericBookmarkSourceContent(
            bookName: reader.title,
            bookAbbreviation: reader.title,
            keyName: content.title,
            plainText: GenericBookmarkSourceTextProjection.xhtmlText(content.html),
            osisFragment: OsisFragment(
                xml: content.html,
                key: "\(reader.initials)--\(content.persistedKey)",
                keyName: content.title,
                v11n: nil,
                bookCategory: DocumentCategory.generalBook.rawValue,
                bookInitials: reader.initials,
                bookAbbreviation: reader.title,
                osisRef: content.persistedKey,
                ordinalRange: ordinalRange,
                language: reader.language,
                direction: Self.annotationTextDirection(language: reader.language),
                isNativeHtml: true
            )
        )
    }

    /**
     Maps a BCP-47 language identifier to the reader direction used by annotation fragments.

     - Parameter language: Source language from My Documents or EPUB metadata.
     - Returns: `rtl` for Android-supported right-to-left language families, otherwise `ltr`.
     - Side effects: None.
     - Failure modes: Missing or malformed primary subtags safely produce `ltr`.
     */
    private static func annotationTextDirection(language: String) -> String {
        let primary = language.split(separator: "-").first?.lowercased() ?? ""
        return ["ar", "fa", "he", "iw", "ps", "ur", "yi"].contains(primary) ? "rtl" : "ltr"
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
  private func buildGenericBookmarkToLabelJSON(_ gbtl: GenericBookmarkToLabel)
    -> BookmarkToLabelData?
  {
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
  private func buildGenericBookmarkJSONForStudyPad(_ bookmark: GenericBookmark)
    -> GenericBookmarkData
  {
        annotationPayloadFactory().genericBookmarkJSONForStudyPad(bookmark)
    }

  /**
   Projects persisted generic annotations for one exact Android document identity.

   - Parameters:
     - bookInitials: Source module or generated-book initials from the rendered document.
     - key: Exact source key within `bookInitials`.
   - Returns: Deterministically ordered Vue bookmark payloads for the exact identity.
   - Side effects: Reads bookmark persistence and may resolve exact source metadata for each row.
   - Failure modes: Missing bookmark services produce an empty list; the method never substitutes
     the active reader module or a nearest key.
   */
  private func genericBookmarkPayloads(
    bookInitials: String,
    key: String
  ) -> [GenericBookmarkData] {
    bookmarkService?.genericBookmarks(bookInitials: bookInitials, key: key).map {
      buildGenericBookmarkJSONForStudyPad($0)
    } ?? []
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
      let data = json.data(using: .utf8)
    else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return BridgeJSONValue(object)
        } catch {
      logger.error(
        "Failed to parse saved bridge state JSON: \(error.localizedDescription, privacy: .public)")
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
            documentReplacement: documentReplacementEmitter(),
            bookmarkService: bookmarkService,
            sendLabels: { [weak self] in
                self?.sendLabelsToVueJS()
            },
      setRenderedContentState: {
        [weak self] category, moduleName, book, chapter, key, documentKind in
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
  private func annotationBridgeCoordinator(bridge: BibleBridge)
    -> BibleReaderAnnotationBridgeCoordinator?
  {
        guard let bookmarkService else { return nil }
        return BibleReaderAnnotationBridgeCoordinator(
            bridge: bridge,
            bookmarkService: bookmarkService,
            payloadFactory: annotationPayloadFactory(),
            currentBook: currentBook,
            verifiedKJVAOrdinalRange: { [weak self] bookInitials, startOrdinal, endOrdinal in
                guard let self else { return nil }
        guard
          let range = self.bookmarkStorageKJVARange(
                    bookInitials: bookInitials,
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
          )
        else {
                    self.bridgeEventRouter.showToast(
                        String(
                            localized: "error_occurred",
                            defaultValue: "An error has occurred"
                        )
                    )
                    return nil
                }
                return range
            },
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

     - Parameter initial: Whether Vue should apply the payload as an initial/replacement config.
     - Returns: JSON string containing `config` and `appSettings` sections for the current pane.

     Side effects:
     - reads persisted settings, workspace cursor state, recent/favourite labels, and active-window
       state to compute the emitted payload

     Failure modes:
     - logs and returns `{}` if the typed bridge payload unexpectedly fails to encode
     */
    private func buildConfigJSON(initial: Bool = false) -> String {
        guard let json = configurationCoordinator.configJSON(
            context: buildConfigContext(),
            initial: initial
        ) else {
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
    let readingProgressSettings =
      readingProgressStore?.snapshot().settings ?? ReadingProgressSettingsSnapshot()
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
            llmConfigured: isAIProviderConfigured?() ?? false,
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
  private func buildChapterXML(osisBookId: String, bookName: String, chapter: Int, verseCount: Int)
    -> String
  {
        // For Genesis 1, use the real ESV-like content
        if osisBookId == "Gen" && chapter == 1 {
            var xml = genesis1OSISXML()
            for verse in stride(from: 31, through: 1, by: -1) {
        guard
          let ordinal = JSwordKJVAVersification.verseOrdinal(
                    osisId: osisBookId,
                    chapter: chapter,
                    verse: verse
          )
        else { continue }
                xml = xml.replacingOccurrences(
                    of: "verseOrdinal=\"\(verse)\"",
                    with: "verseOrdinal=\"\(ordinal)\""
                )
            }
            return xml
        }

        // For other chapters, generate placeholder OSIS XML with verse structure
        var xml = "<div>"
        xml += "<title type=\"x-gen\">\(bookName) \(chapter)</title>"
        xml += "<div sID=\"p1\" type=\"paragraph\"/>"

        for verse in 1...verseCount {
      guard
        let ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: osisBookId,
                chapter: chapter,
                verse: verse
        )
      else { continue }
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
            memorizedOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                self?.memorizedRenderedOrdinals(
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                ) ?? []
            },
            targetOrdinals: { [weak self] _, startOrdinal, endOrdinal in
                self?.targetRenderedOrdinals(
                    startOrdinal: startOrdinal,
                    endOrdinal: endOrdinal
                ) ?? []
      },
      genericBookmarks: { [weak self] bookInitials, key in
        self?.genericBookmarkPayloads(bookInitials: bookInitials, key: key) ?? []
      },
      aiDocMarkersForPage: { [weak self] bookInitials, key in
        self?.myDocumentStore?.aiDocMarkers(
          bookInitials: bookInitials,
          pageKey: key
        ) ?? []
      },
      aiDocMarkersForKJVARange: { [weak self] startOrdinal, endOrdinal in
        self?.myDocumentStore?.aiDocMarkers(
          kjvaRange: min(startOrdinal, endOrdinal)...max(startOrdinal, endOrdinal)
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
  private func buildDocumentJSON(
    osisBookId: String,
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
    ordinalRangeOverride: [Int]? = nil
  ) -> String? {
        let initials = bookInitials ?? activeModuleName
        let sourceModule: SwordModule? = {
            if activeModule?.info.name == initials { return activeModule }
            if activeCommentaryModule?.info.name == initials { return activeCommentaryModule }
            if activeGeneralBookModule?.info.name == initials { return activeGeneralBookModule }
            return swordManager?.module(named: initials)
        }()
    let sqliteSourceModule = [
      activeSQLiteBibleModule,
      activeSQLiteCommentaryModule,
      activeSQLiteDictionaryModule,
    ].compactMap { $0 }.first {
      $0.info.name.caseInsensitiveCompare(initials) == .orderedSame
    }
    let sqliteSource = sqliteSourceModule.map(BibleReaderSQLiteSourceMetadata.init(module:))
        let isBibleDocument = bookCategory == DocumentCategory.bible.rawValue
    let isSyntheticKJVA =
      isBibleDocument
      && sourceModule == nil
      && sqliteSourceModule == nil
      && activeModule == nil
      && activeSQLiteBibleModule == nil
    let sourceVersification =
      sourceModule.map(VersificationMapper.versificationName(for:))
      ?? sqliteSource?.versification
            ?? (isSyntheticKJVA ? JSwordKJVAVersification.name : nil)
    let sourceLanguage =
      sqliteSource?.language
      ?? (sourceModule?.info.language.isEmpty == false ? sourceModule?.info.language ?? "en" : "en")
    let sourceDirection =
      sqliteSource?.direction
      ?? (sourceModule?.info.isRightToLeft == true ? "rtl" : "ltr")
    let sourceDescription =
      sqliteSource?.name ?? sourceModule?.info.description
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let aiMarkerKJVAOrdinalRange = sourceVersification.flatMap { versification in
      VersificationMapper.kjvaOrdinalRange(
        start: VerseKeyReference(
          osisBookId: osisBookId,
          chapter: chapter,
          verse: 1,
          ordinal: 0
        ),
        end: VerseKeyReference(
          osisBookId: osisBookId,
          chapter: chapter,
          verse: max(1, verseCount),
          ordinal: 0
        ),
        sourceVersification: versification
      ).map { [$0.lowerBound, $0.upperBound] }
    }
        return documentPayloadFactory().documentJSON(
            BibleReaderDocumentPayloadRequest(
                osisBookId: osisBookId,
                bookName: bookName,
                chapter: chapter,
                verseCount: verseCount,
                isNewTestament: isNT,
                xml: xml,
                bookmarks: bookmarks,
                bookCategory: bookCategory,
                bookInitials: initials,
                addChapter: addChapter,
                originalOrdinalRange: originalOrdinalRange,
                documentKey: documentKey,
                keyName: keyName,
                ordinalRangeOverride: ordinalRangeOverride,
                moduleName: sourceDescription.isEmpty ? initials : sourceDescription,
        moduleAbbreviation: sqliteSource?.abbreviation
          ?? sourceModule.map(BibleReaderStrongsDocumentBuilder.moduleDisplayLabel)
                    ?? initials,
                versificationName: sourceVersification,
                language: sourceLanguage,
                direction: sourceDirection,
        sourceHasStrongs: sqliteSource?.hasStrongs
          ?? sourceModule?.info.features.contains(.strongsNumbers),
        aiMarkerKJVAOrdinalRange: aiMarkerKJVAOrdinalRange
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

  /**
   Refreshes the active Bible book list from the authoritative backend.

   - Side effects: Replaces `moduleBookList` with real serialized SQLite key metadata or SWORD
     versification books and writes diagnostics for empty/error results.
   - Failure modes: Reader failures clear the active list; no static canon is substituted while a
     backend remains active. With no backend, the list is cleared for the explicit fallback path.
   */
    private func refreshBookList() {
    if let module = activeSQLiteBibleModule {
      do {
        moduleBookList = try module.bookList()
        if moduleBookList.isEmpty {
          logger.error("SQLite module \(module.info.name, privacy: .public) returned no books")
        }
      } catch {
        moduleBookList = []
        logger.error(
          "SQLite module \(module.info.name, privacy: .public) book list failed: \(error.localizedDescription, privacy: .public)"
        )
      }
      return
    }
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
      logger.error(
        "Module \(module.info.name, privacy: .public) returned no books; refusing static canon fallback while active"
      )
        } else {
      logger.info(
        "Module \(module.info.name) has \(books.count) books (versification: \(module.configEntry("Versification") ?? "KJV"))"
      )
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

    /**
     Resolves a visible source-versification book into Android's KJVA `BibleBook.ordinal`.

     Android derives reading-progress identity from `Verse(v11n, book, 1, 1).toV11n(KJVA).book`
     rather than assuming the source and KJVA book enumerations are identical. Public-converter
     fallback remains acceptable here because Android uses the same best-effort conversion for
     reading-progress book identity.

     - Parameter bookName: Active-module display book name.
     - Returns: JSword KJVA book ordinal, or `nil` for unknown source books or versifications.
     - Side effects: Lazily reads JSword mapping resources and SWORD canon tables.
     - Failure modes: Returns `nil` when the source coordinate or resulting KJVA book is unknown.
     */
    private func kjvBookOrdinal(for bookName: String) -> Int? {
        let sourceOsisId = osisBookId(for: bookName)
        guard !sourceOsisId.isEmpty,
              let conversion = VersificationMapper.convert(
                  osisBookId: sourceOsisId,
                  chapter: 1,
                  verse: 1,
                  from: activeSourceVersificationName(),
                  to: JSwordKJVAVersification.name
      )
    else {
            return nil
        }
        return JSwordKJVAVersification.bibleBookOrdinal(
            forOsisId: conversion.reference.osisBookId
        )
    }

    /**
     Resolves the active Bible chapter into the JSword/KJVA identity used by reading progress.

     - Parameters:
       - bookInitials: Vue-provided source initials compared with Android-37 Java identity semantics.
       - startOrdinal: Rendered source ordinal that must belong to the visible chapter.
       - chapter: Visible source chapter number.
     - Returns: Verified KJVA progress identity, or `nil` when source identity or coordinates differ.
     - Side effects: Reads active canon metadata and may perform bounded versification conversion.
     - Failure modes: Locked/stale sources, Java-distinct Unicode identities, invalid ordinals, and
       mismatched chapters fail closed before reading-progress history can mutate.
     */
    private func readingProgressBridgeTarget(
        bookInitials: String,
        startOrdinal: Int,
        chapter: Int
    ) -> BibleReaderProgressBridgeCoordinator.ReadingProgressBridgeTarget? {
        let requestedInitials = bookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceModule = activeModule,
              let chapterRange = currentChapterOrdinalRange(),
              currentCategory == .bible,
              !requestedInitials.isEmpty,
              SwordJavaStringIdentity.equalsIgnoreCase(
                  requestedInitials,
                  sourceModule.info.name
              ),
              startOrdinal >= chapterRange.start,
              startOrdinal <= chapterRange.end,
              chapter == currentChapter,
              !osisBookId(for: currentBook).isEmpty,
              let sourceBookAnchorOrdinal = verseOrdinal(
                  osisBookId: osisBookId(for: currentBook),
                  chapter: 1,
                  verse: 1
              ),
              let verifiedBookAnchor = VerifiedKJVAOrdinalRange(
                  resolvingSourceBookInitials: sourceModule.info.name,
                  sourceVersification: activeSourceVersificationName(),
                  sourceOrdinalStart: sourceBookAnchorOrdinal,
                  sourceOrdinalEnd: sourceBookAnchorOrdinal
              ),
              let identity = ReadingProgressKJVAIdentity(
                  verifiedBookAnchor: verifiedBookAnchor,
                  sourceChapter: chapter
      )
    else {
            return nil
        }
        return BibleReaderProgressBridgeCoordinator.ReadingProgressBridgeTarget(
            identity: identity,
            bookName: currentBook
        )
    }

    /**
     Resolves a rendered reader bookmark selection into Android's inclusive KJVA storage span.

     Newly-created iOS bookmarks keep their source ordinals for local fidelity, but Android backup
     compatibility depends on KJVA ordinals. This uses the memorization resolver's proven
     rendered-to-KJVA path so bookmark creation, restore, and chapter queries share one durable key.

     - Parameters:
       - bookInitials: Exact source module initials supplied by the bridge event.
       - startOrdinal: First rendered ordinal reported by Vue.
       - endOrdinal: Last rendered ordinal reported by Vue.
     - Returns: Exact source coordinates and their verified inclusive KJVA span, or `nil` when the
       rendered selection cannot be represented in KJVA.
     - Side effects: May temporarily move the active SWORD module cursor through
       `memorizationOrdinalResolution`.
     - Failure modes: Returns `nil` for missing or mismatched source-module identity, invalid
       endpoints, unsupported source versification, or references without an authoritative KJVA
       mapping.
     */
    private func bookmarkStorageKJVARange(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> VerifiedKJVAOrdinalRange? {
        let effectiveEndOrdinal = endOrdinal > 0 ? endOrdinal : startOrdinal
        let lower = min(startOrdinal, effectiveEndOrdinal)
        let upper = max(startOrdinal, effectiveEndOrdinal)
        guard let resolution = memorizationOrdinalResolution(
            bookInitials: bookInitials,
            startOrdinal: lower,
            endOrdinal: upper
        ) else {
            return nil
        }
        return resolution.verifiedRange
    }

    /**
     Captures Android's immutable AI source context from one exact active backend generation.

     The bridge-supplied initials and generic key are compared byte-for-byte with pane state before
     extraction. Category, initials, key, and `contentIntentGeneration` are checked again afterward,
     so a stale callback cannot label content from a later module or page as its earlier source.

     - Parameters:
       - expectedDocumentInitials: Exact bridge initials. Omit only for native whole-window actions.
       - requestedSourceKey: Exact generic bridge key, including meaningful whitespace.
       - selectionOrdinalStart: Raw source-versification Bible start ordinal.
       - selectionOrdinalEnd: Raw source-versification Bible end ordinal.
     - Returns: Source-bound identity plus independently optional canonical text and structured OSIS.
     - Side effects: Executes read-only source queries. SWORD reads restore their prior cursor.
     - Failure modes: Stale identity/generation, partial endpoint pairs, invalid/excessive ranges,
       missing exact keys, and unreadable backends fail closed without substituting pane content.
     */
    func aiSourceContext(
        expectedDocumentInitials: String? = nil,
        requestedSourceKey: String? = nil,
        selectionOrdinalStart: Int? = nil,
        selectionOrdinalEnd: Int? = nil
    ) -> AIReaderSourceContext? {
        let selectionBounds: AIReaderSourceBounds?
        switch (selectionOrdinalStart, selectionOrdinalEnd) {
        case (nil, nil):
            selectionBounds = nil
        case (.some(let start), .some(let end)):
            guard let bounds = AIReaderSourceRange.bibleBounds(start: start, end: end) else {
                return nil
            }
            selectionBounds = bounds
        default:
            return nil
        }

        let generation = contentIntentGeneration
        let category = currentCategory
        guard let initials = aiCurrentSourceInitials(for: category), !initials.isEmpty,
              expectedDocumentInitials == nil || expectedDocumentInitials == initials,
              let pageKey = aiCurrentSourceKey(for: category),
              requestedSourceKey == nil || requestedSourceKey == pageKey else {
            return nil
        }

        let context: AIReaderSourceContext?
        switch category {
        case .bible:
            let osisBookId = osisBookId(for: currentBook)
            guard !osisBookId.isEmpty else { return nil }
            let request: AIReaderBibleSourceRequest = selectionBounds.map {
                .selection(
                    sourceBookKey: pageKey,
                    startOrdinal: $0.start,
                    endOrdinal: $0.end
                )
            } ?? .page(
                sourceBookKey: pageKey,
                osisBookId: osisBookId,
                chapter: currentChapter
            )
            if let module = activeSQLiteBibleModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.sqliteBible(
                    module: module,
                    request: request
                )
            } else if let module = activeModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.swordBible(
                    module: module,
                    request: request
                )
            } else {
                return nil
            }

        case .commentary:
            guard selectionBounds == nil else { return nil }
            let osisBookId = osisBookId(for: currentBook)
            guard !osisBookId.isEmpty else { return nil }
            if let module = activeSQLiteCommentaryModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.sqliteCommentary(
                    module: module,
                    osisBookId: osisBookId,
                    bookName: currentBook,
                    chapter: currentChapter,
                    verse: currentVerse,
                    isNewTestament: isNewTestament(currentBook)
                )
            } else if let module = activeCommentaryModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
            } else {
                return nil
            }

        case .dictionary:
            guard selectionBounds == nil else { return nil }
            if let module = activeSQLiteDictionaryModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.sqliteDictionary(module: module, key: pageKey)
            } else if let module = activeDictionaryModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
            } else {
                return nil
            }

        case .generalBook:
            guard selectionBounds == nil else { return nil }
            if let reader = activeEpubReader, reader.initials == initials {
                context = AIReaderSourceContextExtractor.epub(reader: reader, key: pageKey)
            } else if let store = myDocumentStore,
                      (try? store.exactDocument(initials: initials)) != nil {
                context = AIReaderSourceContextExtractor.myDocument(
                    store: store,
                    bookInitials: initials,
                    pageKey: pageKey
                )
            } else if let module = activeGeneralBookModule, module.info.name == initials {
                context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
            } else {
                return nil
            }

        case .map:
            guard selectionBounds == nil,
                  let module = activeMapModule,
                  module.info.name == initials else {
                return nil
            }
            context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)

        case .epub:
            guard selectionBounds == nil,
                  let reader = activeEpubReader,
                  reader.initials == initials else {
                return nil
            }
            context = AIReaderSourceContextExtractor.epub(reader: reader, key: pageKey)

        case .dailyDevotion:
            guard selectionBounds == nil,
                  let module = activeGeneralBookModule,
                  module.info.name == initials,
                  module.info.category == .dailyDevotion else {
                return nil
            }
            context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
        }

        guard let context,
              context.sourceDocumentInitials == initials,
              context.sourceBookKey == pageKey,
              contentIntentGeneration == generation,
              currentCategory == category,
              aiCurrentSourceInitials(for: category) == initials,
              aiCurrentSourceKey(for: category) == pageKey else {
            return nil
        }
        return context
    }

    /**
     Captures source context from a Bible bookmark's own installed module and source ordinals.

     - Parameters:
       - bookInitials: Exact module initials persisted by the bookmark entity.
       - startOrdinal: Inclusive source-versification start ordinal persisted by the bookmark.
       - endOrdinal: Inclusive source-versification end ordinal persisted by the bookmark.
     - Returns: Exact source context, or `nil` when the module/endpoints cannot be proven.
     - Side effects: Reads the installed SWORD or SQLite source without changing active pane state.
     - Failure modes: Missing/case-mismatched modules, invalid/excessive endpoints, and backend or
       cursor failures return `nil`; active pane content is never used as fallback.
     */
    func aiBibleSourceContext(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> AIReaderSourceContext? {
        guard !bookInitials.isEmpty,
              let bounds = AIReaderSourceRange.bibleBounds(
                  start: startOrdinal,
                  end: endOrdinal
              ) else {
            return nil
        }
        let request = AIReaderBibleSourceRequest.selection(
            sourceBookKey: nil,
            startOrdinal: bounds.start,
            endOrdinal: bounds.end
        )
        let context: AIReaderSourceContext?
        let source = installedModuleResolver().scripture(named: bookInitials)
        if case .sword(let module)? = source,
           module.info.name == bookInitials {
            context = AIReaderSourceContextExtractor.swordBible(module: module, request: request)
        } else if case .sqlite(let module)? = source,
                  module.info.name == bookInitials {
            context = AIReaderSourceContextExtractor.sqliteBible(module: module, request: request)
        } else {
            return nil
        }
        guard let context,
              context.sourceDocumentInitials == bookInitials,
              context.sourceOrdinalRange == bounds.closedRange,
              context.sourceOSISRange?.isEmpty == false else {
            return nil
        }
        return context
    }

    /** Returns exact active source initials for AI generation binding. */
    private func aiCurrentSourceInitials(for category: DocumentCategory) -> String? {
        switch category {
        case .dailyDevotion:
            return activeGeneralBookModuleName
        default:
            return activeModuleName(for: category)
        }
    }

    /** Returns the exact current source key without trimming or alias normalization. */
    private func aiCurrentSourceKey(for category: DocumentCategory) -> String? {
        switch category {
        case .bible:
            let osisBookId = osisBookId(for: currentBook)
            return osisBookId.isEmpty || currentChapter <= 0
                ? nil
                : "\(osisBookId).\(currentChapter)"
        case .commentary:
            let osisBookId = osisBookId(for: currentBook)
            return osisBookId.isEmpty || currentChapter <= 0 || currentVerse <= 0
                ? nil
                : "\(osisBookId).\(currentChapter).\(currentVerse)"
        case .dictionary:
            return currentDictionaryKey
        case .generalBook, .dailyDevotion:
            return currentGeneralBookKey
        case .map:
            return currentMapKey
        case .epub:
            return currentEpubHref ?? currentGeneralBookKey
        }
    }

    /**
     Verifies a bridge selection through the same source-to-KJVA mapping used for bookmarks.

     - Parameters:
       - bookInitials: Exact active Bible initials carried by the bridge payload.
       - startOrdinal: Inclusive rendered start ordinal.
       - endOrdinal: Inclusive rendered end ordinal.
     - Returns: Verified KJVA span, or nil when source identity or versification mapping fails.
     - Side effects: May temporarily inspect the active SWORD verse cursor and restores it before
       returning.
     - Failure modes: Fails closed; AI actions never receive unverified source ordinals as KJVA.
     */
    func aiVerifiedKJVARange(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> ClosedRange<Int>? {
        guard aiCurrentSourceInitials(for: .bible) == bookInitials,
              let sourceBounds = AIReaderSourceRange.bibleBounds(
                  start: startOrdinal,
                  end: endOrdinal
              ) else {
            return nil
        }
        if let sqliteModule = activeSQLiteBibleModule,
           sqliteModule.info.name == bookInitials,
           JSwordKJVAVersification.verseReference(ordinal: startOrdinal) != nil,
           JSwordKJVAVersification.verseReference(ordinal: endOrdinal) != nil {
            return sourceBounds.closedRange
        }
        guard let range = bookmarkStorageKJVARange(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ), let cacheBounds = AIReaderSourceRange.bibleBounds(
            start: range.kjvaOrdinalStart,
            end: range.kjvaOrdinalEnd
        ) else {
            return nil
        }
        return cacheBounds.closedRange
    }

    /**
     Resolves a rendered reader selection into Android's inclusive KJVA storage span.

     Android persists memorization rows as global KJVA ordinals. The embedded reader still reports
     ordinals in the active document's versification, so bridge mutations resolve the selected
     endpoint references first and keep the complete KJVA span, including chapter-intro ordinals
     that are not visible in Vue. Visible projections are carried alongside the storage span so
     bridge events can still update the open document using rendered ordinals.

     - Parameters:
       - bookInitials: Vue-provided source initials compared with Android-37 Java identity semantics.
       - startOrdinal: First rendered ordinal reported by Vue.
       - endOrdinal: Last rendered ordinal reported by Vue.
     - Returns: KJVA storage span plus rendered-to-KJVA projections, or `nil` if the selection
       cannot be represented in KJVA.
     - Side effects: May temporarily move the active SWORD module cursor through `verseReference`.
     - Failure modes: Returns `nil` for Java-distinct/stale source identities, invalid endpoints, or
       references outside KJVA before memorization state can mutate.
     */
    private func memorizationOrdinalResolution(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> BibleReaderProgressBridgeCoordinator.MemorizationOrdinalResolution? {
        let requestedInitials = bookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceModule = activeModule,
              !requestedInitials.isEmpty,
      SwordJavaStringIdentity.equalsIgnoreCase(requestedInitials, sourceModule.info.name)
    else {
            return nil
        }
        let sourceVersification = activeSourceVersificationName()
        guard startOrdinal > 0,
              endOrdinal >= startOrdinal,
              let startReference = memorizationVerseReference(renderedOrdinal: startOrdinal),
              let endReference = memorizationVerseReference(renderedOrdinal: endOrdinal),
              let verifiedRange = VerifiedKJVAOrdinalRange(
                  sourceBookInitials: sourceModule.info.name,
                  sourceVersification: sourceVersification,
                  sourceOrdinalStart: startOrdinal,
                  sourceOrdinalEnd: endOrdinal,
                  sourceReferenceStart: startReference,
                  sourceReferenceEnd: endReference
      )
    else {
            return nil
        }
        let projections = memorizationOrdinalProjections(
            kjvaStartOrdinal: verifiedRange.kjvaOrdinalStart,
            kjvaEndOrdinal: verifiedRange.kjvaOrdinalEnd
        )
        guard !projections.isEmpty else { return nil }
        return BibleReaderProgressBridgeCoordinator.MemorizationOrdinalResolution(
            verifiedRange: verifiedRange,
            projections: projections
        )
    }

    /**
     Resolves one rendered memorization ordinal to a verse reference.

     - Parameter ordinal: Ordinal from the currently rendered Vue document.
     - Returns: Active-module verse reference when a SWORD module is loaded, otherwise the default
       reader fallback reference for the current book.
     - Side effects: May temporarily move the active SWORD module cursor.
     - Failure modes: Returns `nil` when the active module or fallback catalog rejects the ordinal.
     */
    private func memorizationVerseReference(renderedOrdinal ordinal: Int) -> VerseKeyReference? {
    activeModule?.verseReference(ordinal: ordinal)
      ?? verseReference(book: currentBook, ordinal: ordinal)
    }

    /**
     Projects Android KJVA memorization ordinals into the active document's rendered domain.

     Android emits memorization deltas by constructing each stored ordinal as `Verse(KJVA, ordinal)`
     and converting it to the open document's versification. Enumerating the KJVA span preserves
     one-to-many and many-to-one mappings that cannot be recovered by converting rendered ordinals
     in the opposite direction. JSword can address chapter-introduction ordinals in Android's
     document model, while `SwordModule.verseOrdinal` reports ordinal `0` for the same verse-zero
     coordinate. In that one case, the target versification's canonical intro-inclusive index is
     used after an index-to-reference round trip proves that the module's declared canon owns the
     exact converted reference.

     - Parameters:
       - kjvaStartOrdinal: Inclusive first stored KJVA ordinal.
       - kjvaEndOrdinal: Inclusive last stored KJVA ordinal.
     - Returns: Android-equivalent target-versification projections in the requested span.
     - Side effects: May temporarily move the active SWORD module cursor for each mapped verse.
     - Failure modes: Invalid ranges return an empty list; unsupported target versifications omit
       projections rather than treating KJVA ordinals as target-module ordinals.
     */
    private func memorizationOrdinalProjections(
        kjvaStartOrdinal: Int,
        kjvaEndOrdinal: Int
    ) -> [BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection] {
        guard kjvaStartOrdinal > 0, kjvaEndOrdinal >= kjvaStartOrdinal else { return [] }
        return (kjvaStartOrdinal...kjvaEndOrdinal).compactMap { kjvaOrdinal in
            let renderedOrdinal: Int
            if let activeModule {
        guard
          let projection = VersificationMapper.moduleProjection(
                    forKJVAOrdinal: kjvaOrdinal,
                    targetModule: activeModule
          )
        else {
                    return nil
                }
                if projection.isAddressable {
                    renderedOrdinal = projection.ordinal
                } else {
                    let targetVersification = VersificationMapper.versificationName(for: activeModule)
                    guard projection.reference.verse == 0,
                          let canonicalOrdinal = SwordVersification.referenceIndex(
                              for: projection.reference,
                              versification: targetVersification
                          ),
                          canonicalOrdinal > 0,
                          SwordVersification.reference(
                              forIndex: canonicalOrdinal,
                              versification: targetVersification
            ) == projection.reference
          else {
                        return nil
                    }
                    renderedOrdinal = canonicalOrdinal
                }
            } else {
        guard
          JSwordKJVAVersification.referenceIncludingIntroductions(
                    ordinal: kjvaOrdinal
          ) != nil
        else {
                    return nil
                }
                renderedOrdinal = kjvaOrdinal
            }
            return BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection(
                renderedOrdinal: renderedOrdinal,
                kjvaOrdinal: kjvaOrdinal
            )
        }
    }

    private func memorizedRenderedOrdinals(startOrdinal: Int, endOrdinal: Int) -> [Int] {
    renderedMemorizationOrdinals(startOrdinal: startOrdinal, endOrdinal: endOrdinal) {
      store, range in
      store.memorizedOrdinals(
        bookInitials: "", startOrdinal: range.startOrdinal, endOrdinal: range.endOrdinal)
        }
    }

    private func targetRenderedOrdinals(startOrdinal: Int, endOrdinal: Int) -> [Int] {
    renderedMemorizationOrdinals(startOrdinal: startOrdinal, endOrdinal: endOrdinal) {
      store, range in
      store.targetOrdinals(
        bookInitials: "", startOrdinal: range.startOrdinal, endOrdinal: range.endOrdinal)
        }
    }

    private func renderedMemorizationOrdinals(
        startOrdinal: Int,
        endOrdinal: Int,
        storedOrdinals: (MemorizationProgressStore, (startOrdinal: Int, endOrdinal: Int)) -> [Int]
    ) -> [Int] {
        guard let store = memorizationProgressStore else { return [] }
    guard
      let resolution = memorizationOrdinalResolution(
            bookInitials: activeModuleName,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
      )
    else { return [] }
    let stored = Set(
      storedOrdinals(
            store,
            (startOrdinal: resolution.startOrdinal, endOrdinal: resolution.endOrdinal)
        ))
        return resolution.projections
            .filter { stored.contains($0.kjvaOrdinal) }
            .map(\.renderedOrdinal)
            .sorted()
    }

    @discardableResult
  func saveReadingProgressSettings(_ settings: ReadingProgressSettingsSnapshot)
    -> ReadingProgressSettingsSnapshot?
  {
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

   Android's passage chooser asks the current document for `getLastVerse(book, chapterNo)`. The
   iOS reader reads real SQLite rows when an Android-compatible module is active, otherwise it
   uses SWORD `VerseKey` metadata and retains the legacy static table only with no active backend.

     - Parameters:
       - book: Display book name from the active module book list.
       - chapter: One-based chapter number selected in the chooser.
     - Returns: The last selectable verse number for the chapter, or `nil` when the active module
       cannot resolve the chapter exactly.
   - Side effects: Executes serialized SQLite chapter access or may temporarily move the active
     SWORD cursor; SWORD restores the previous key before returning.
   - Failure modes: Active SQLite/SWORD read failures return nil without static fallback.
     */
    func verseCountForActiveModule(book: String, chapter: Int) -> Int? {
    if let module = activeSQLiteBibleModule {
      return SQLiteReaderNavigationResolver.verseCount(
        module: module,
        osisBookId: osisBookId(for: book),
        chapter: chapter
      )
    }
    return bookCatalog.verseCount(book: book, chapter: chapter)
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

/// One source-versification verse retained inside an Android passage/range reference.
struct OsisVerseCoordinate: Equatable {
    let osisBookId: String
    let chapter: Int
    let verse: Int
}

/**
 Parsed OSIS passage used by cross-reference resolution.

 `sourceVerses` retains the ordered source-canon expansion of one Android `BookAndKey`. This keeps
 ranges and source-only books intact until a target module performs explicit versification mapping.
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

    /// Versification that owns `osisId`, `chapter`, and `verse`.
    let sourceVersification: String

    /// Optional target module requested by an Android `doc`/specific-document link.
    let targetBookInitials: String?

    /// Ordered concrete verses owned by `sourceVersification`.
    let sourceVerses: [OsisVerseCoordinate]

    /// Normalized source key represented by this passage.
    let sourceOsisRef: String

    /// Human-readable final book name for a cross-book range.
    let endBook: String

    /** Creates one source-domain OSIS reference without inferring active-pane identity. */
    init(
        book: String,
        chapter: Int,
        verse: Int,
        osisId: String,
        sourceVersification: String = JSwordKJVAVersification.name,
        targetBookInitials: String? = nil,
        sourceVerses: [OsisVerseCoordinate]? = nil,
        sourceOsisRef: String? = nil,
        endBook: String? = nil
    ) {
        let verses: [OsisVerseCoordinate]
        if let sourceVerses, !sourceVerses.isEmpty {
            verses = sourceVerses
        } else {
            verses = [OsisVerseCoordinate(osisBookId: osisId, chapter: chapter, verse: verse)]
        }
        self.book = book
        self.chapter = chapter
        self.verse = verse
        self.osisId = osisId
        self.sourceVersification = sourceVersification
        self.targetBookInitials = targetBookInitials
        self.sourceVerses = verses
        self.sourceOsisRef = sourceOsisRef ?? Self.normalizedOsisRef(for: verses)
        self.endBook = endBook ?? book
    }

    /** Formats one ordered passage using Android/JSword full-endpoint range notation. */
    static func normalizedOsisRef(for verses: [OsisVerseCoordinate]) -> String {
        guard let first = verses.first else { return "" }
        let firstRef = "\(first.osisBookId).\(first.chapter).\(first.verse)"
        guard verses.count > 1, let last = verses.last else { return firstRef }
        return "\(firstRef)-\(last.osisBookId).\(last.chapter).\(last.verse)"
    }

    /// Human-readable display string for the reference.
    var displayName: String {
        guard let last = sourceVerses.last,
      sourceVerses.count > 1
    else {
            return "\(book) \(chapter):\(verse)"
        }
        if last.osisBookId == osisId, last.chapter == chapter {
            return "\(book) \(chapter):\(verse)-\(last.verse)"
        }
        return "\(book) \(chapter):\(verse)-\(endBook) \(last.chapter):\(last.verse)"
    }
}
