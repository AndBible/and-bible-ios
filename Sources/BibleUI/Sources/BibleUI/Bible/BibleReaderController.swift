// BibleReaderController.swift — Handles bridge delegate for BibleReaderView

import BibleCore
import BibleView
import Foundation
import SwiftData
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

/** Result of authorizing and validating one installed AI window-document request pre-mutation. */
enum BibleReaderInstalledWindowDocumentPreflight: Equatable {
  /// The globally selected readable source owns the request and the optional key is canonical.
  case authorized(key: String?)
  /// The installed identity is missing, locked, unreadable, or belongs to another category.
  case sourceUnavailable
  /// The readable source does not own the requested exact key/reference.
  case keyUnavailable
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

/** Immutable source capture boundary shared by Bible replacement and infinite-scroll work. */
private struct BibleReaderBibleSourcePreparation {
    let identity: BibleReaderPreparationSourceIdentity
    let provenance: BibleReaderRenderSourceProvenance
    let extractionDependency: BibleReaderRenderExtractionDependency
    let capture: @Sendable () -> BibleReaderBibleChapterSourceCapture?
    let enrichAnnotations: @Sendable (
        [BibleReaderPreparedBibleBookmarkInput]
    ) -> BibleReaderPreparedBibleAnnotations?
    let isCurrent: () -> Bool
}

/** Main-queue generation owner for routed installed-source authorization. */
private final class BibleReaderRoutedSourceAuthorizationOwner {
    var installedSourceGeneration: UInt64 = 0
}

/** Immutable SWORD capture and authorization boundary for dictionary/general/map entries. */
private struct BibleReaderAuxiliarySourcePreparation {
    let identity: BibleReaderPreparationSourceIdentity
    let capture: @Sendable () -> BibleReaderAuxiliarySourceCapture?
    let enrichAnnotations: @Sendable (
        [BibleReaderPreparedGenericBookmarkInput]
    ) -> ([GenericBookmarkData], [BibleReaderPreparationSourceDependency])?
    let isCurrent: () -> Bool
}

/** Main-owner values captured after an auxiliary fragment declares its annotation key. */
private enum BibleReaderAuxiliaryOwnerSnapshot: Sendable {
    case document(BibleReaderGenericDocumentOwnerSnapshot)
    case failure
}

/** Immutable EPUB fragment plus every backing generation read while preparing it. */
private struct BibleReaderEpubSourceCapture: Sendable {
    let content: EpubReader.Content
    let annotationSource: GenericBookmarkSourceContent
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Serialized EPUB document paired with its exact owner and immutable source generations. */
private struct BibleReaderEncodedEpubDocument: Sendable {
    let documentJSON: String
    let content: EpubReader.Content
    let ownerIdentity: BibleReaderGenericDocumentOwnerIdentity
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Detached SQLite auxiliary result that never carries a live payload request across queues. */
private enum BibleReaderSQLiteAuxiliaryCapture: Sendable {
    case fragment(BibleReaderBookmarkNavigationSQLiteFragment)
    case failure(String)
}

/** Detached SWORD commentary block and destination metadata captured in one native transaction. */
private struct BibleReaderSwordCommentaryCapture: Sendable {
    let fragment: SwordRawOSISFragment
    let renderedBook: String
    let renderedChapter: Int
    let commentaryRange: ReaderCommentaryRangePayload
    let navigation: BibleReaderCommentaryNavigationAvailability
}

/** Detached SQLite commentary fragment plus every source generation used for verse mapping. */
private struct BibleReaderSQLiteCommentaryCapture: Sendable {
    let fragment: BibleReaderBookmarkNavigationSQLiteFragment
    let renderedBook: String
    let renderedChapter: Int
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let navigation: BibleReaderCommentaryNavigationAvailability
}

/** Bridge-ready commentary document retaining selected state and its rendered annotation owner. */
private struct BibleReaderPreparedCommentaryDocument: Sendable {
    let auxiliary: BibleReaderPreparedAuxiliaryResult
    /// Exact effective key used to capture and reauthorize generic annotations.
    let annotationOwnerKey: String
    let renderedChapter: Int
    let navigation: BibleReaderCommentaryNavigationAvailability
}

/** Source-only annotation values captured after a generic document declares its owner rows. */
private struct BibleReaderGenericAnnotationSourceEnrichment: Sendable {
    let capturedSources: [BibleReaderPreparedGenericBookmarkSource]
    let authorization: SwordContentAuthorizationSnapshot
}

/** Bridge annotation rows and dependencies resolved between owner capture and pure encoding. */
private struct BibleReaderPreparedGenericAnnotationEnrichment: Sendable {
    let bookmarks: [GenericBookmarkData]
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** My Notes bookmark rows and exact source dependencies captured outside JSON encoding. */
private struct BibleReaderPreparedMyNotesEnrichment: Sendable {
    let bookmarks: [BibleBookmarkData]
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** StudyPad bookmark rows and heterogeneous source dependencies captured before encoding. */
private struct BibleReaderPreparedStudyPadEnrichment: Sendable {
    let bibleBookmarks: [BibleBookmarkData]
    let genericBookmarks: [GenericBookmarkData]
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Installed registry captured before a My Documents owner is read from SwiftData. */
private struct BibleReaderMyDocumentSourceRegistry: @unchecked Sendable {
    let installedResolver: BibleReaderInstalledModuleResolver
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Complete persistence-only My Documents page and annotation snapshot. */
private struct BibleReaderMyDocumentOwnerSnapshot: Sendable {
    let source: BibleReaderPreparedMyDocumentSource
    let metadata: MyDocumentReaderMetadata
    let genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput]
    let generatedBookLanguageCode: String
    let identity: BibleReaderPreparedMyDocumentOwnerIdentity

    init(
        source: BibleReaderPreparedMyDocumentSource,
        metadata: MyDocumentReaderMetadata,
        genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput],
        generatedBookLanguageCode: String
    ) {
        self.source = source
        self.metadata = metadata
        self.genericBookmarkInputs = genericBookmarkInputs
        self.generatedBookLanguageCode = generatedBookLanguageCode
        identity = BibleReaderPreparedMyDocumentOwnerIdentity(
            documentID: source.documentID,
            documentName: source.documentName,
            documentInitials: source.documentInitials.rawValue,
            pageID: source.pageID,
            pageTitle: source.pageTitle,
            pageKey: source.pageKey.rawValue,
            contentType: MyDocumentContentType(rawValue: source.contentTypeRawValue) ?? .markdown,
            rawContent: source.rawContent,
            pageSourcePromptID: metadata.sourcePromptId,
            metadata: metadata,
            genericBookmarks: genericBookmarkInputs,
            generatedBookLanguageCode: generatedBookLanguageCode
        )
    }
}

/** Source-enriched annotations for one immutable My Documents page. */
private struct BibleReaderPreparedMyDocumentEnrichment: Sendable {
    let genericBookmarks: [GenericBookmarkData]
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
}

/** Bridge-ready My Documents result retaining its exact owner and source authorization. */
private struct BibleReaderEncodedMyDocument: @unchecked Sendable {
    let documentJSON: String
    let prepared: BibleReaderPreparedMyDocument
    let installedResolver: BibleReaderInstalledModuleResolver
}

/** Prepared Memorize emission retaining exact source and progress publication identities. */
private struct BibleReaderEncodedMemorizeDocument: Sendable {
    let emission: MemorizeDocumentEmission
    let capture: BibleReaderMemorizeSourceCapture
    let owner: BibleReaderMemorizeOwnerSnapshot
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
    /// Exact source-domain My Notes request retained independently from the active Bible pane.
    private enum MyNotesTarget: Sendable, Equatable {
        /// One explicit source chapter selected from the current reader position.
        case chapter(
            versification: String,
            osisBookID: String,
            chapter: Int,
            jumpSourceVerse: Int?
        )
        /// One source ordinal received from a My Notes link and mapped on the worker.
        case ordinal(versification: String, ordinal: Int)
    }
    /// Authoritative mapped span and optional KJVA row jump produced on the worker.
    private struct PreparedMyNotesTarget: Sendable {
        let reference: MyNotesChapterReference
        let jumpToOrdinal: Int?
    }
    /// My Notes destination currently rendered or awaiting a client-ready replay.
    private var activeMyNotesTarget: MyNotesTarget?
    /// Last authoritative mapped span published for the active target.
    private var activeMyNotesReference: MyNotesChapterReference?
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
  /// Outlives a routed source pane while invalidating witnesses at each registry replacement.
  private let routedSourceAuthorizationOwner = BibleReaderRoutedSourceAuthorizationOwner()
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
    /// Current and adjacent source-Bible targets captured with the accepted commentary document.
    private var commentaryNavigationAvailability = BibleReaderCommentaryNavigationAvailability.empty
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
    private(set) var committedRenderState: BibleReaderCommittedRenderState = .empty
    var renderedContentState: String {
        committedRenderState.identity?.diagnosticState.encodedValue
            ?? BibleReaderController.emptyRenderedContentState
    }
    private(set) var renderedDocumentKind: ReaderRenderedDocumentKind = .standard
    /// Coordinator for Android-style transient `MultiDocument` state and fake-document identity.
    private var specialDocumentCoordinator = BibleReaderSpecialDocumentCoordinator()
    /// Typed source inputs for rebuilding the active composite after extraction-setting changes.
    private var activeCompositeRebuildRequest: BibleReaderCompositeRebuildRequest?
    /// Live Memorize fake-document payload used to replay Android's commentary `Memorize` page.
    private var activeMemorizeRequest: BibleReaderMemorizeRenderRequest?
    /// Decoded Android `BookAndKeySerialized` payload for restored Memorize source ranges.
    private struct SerializedBookAndKey: Decodable {
        let key: String
        let document: String?
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
     - Side effects: Direct accepted commentary ordinals use their immutable captured source route;
       other reader families may temporarily move the active SWORD cursor through `verseReference`.
     - Failure modes: Invalid ordinals or source books unsupported by the active module return
       `nil`.
     */
    func synchronizedVerseReference(ordinal: Int) -> VerseKeyReference? {
        if committedRenderState.identity?.category == .commentary,
           let target = commentaryNavigationAvailability.target(matchingSourceOrdinal: ordinal) {
            return VerseKeyReference(
                osisBookId: target.osisBookID,
                chapter: target.chapter,
                verse: target.verse,
                ordinal: target.sourceOrdinal
            )
        }
        return verseReference(book: currentBook, ordinal: ordinal)
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
        let normalized = Self.normalizedVersificationName(activeVersification)
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
        Self.bookmarkListActiveReference(
            kjvOrdinal: kjvOrdinal,
            activeModule: activeModule,
            bookCatalog: bookCatalog
        )
    }

    /** Worker-safe active-versification projection using only captured source owners. */
    private static func bookmarkListActiveReference(
        kjvOrdinal: Int,
        activeModule: SwordModule,
        bookCatalog: BibleReaderBookCatalog
    ) -> (bookName: String, reference: BookmarkListVerseReference)? {
    guard
      let projection = VersificationMapper.moduleProjection(
                  forKJVAOrdinal: kjvOrdinal,
                  targetModule: activeModule
      ), projection.isAddressable
    else { return nil }
        let mapped = projection.reference
    let displayName =
      bookCatalog.bookName(forOsisId: mapped.osisBookId)
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
    /** Retains one KJVA ordinal as an exact source request for worker-side mapping. */
    private func myNotesTarget(kjvaOrdinal: Int) -> MyNotesTarget? {
        guard kjvaOrdinal > 0 else { return nil }
        return .ordinal(versification: JSwordKJVAVersification.name, ordinal: kjvaOrdinal)
    }

    /** Retains an Android My Notes route for authoritative worker-side source mapping. */
    private func myNotesTarget(v11nName: String, sourceOrdinal: Int) -> MyNotesTarget? {
        guard sourceOrdinal > 0,
              let normalized = JSwordVersificationRegistry.normalizedName(v11nName)
        else { return nil }

        // Android constructs a source Verse before routing My Notes through showLink. Mirror that
        // bounded immutable-canon preflight here so an impossible ordinal never becomes selected
        // pane intent while full source-to-KJVA mapping remains in coordinator source capture.
        if normalized == JSwordKJVAVersification.name {
            guard JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: sourceOrdinal
            ) != nil else { return nil }
        } else {
            guard SwordVersification.reference(
                forIndex: sourceOrdinal,
                versification: normalized
            ) != nil else { return nil }
        }
        return .ordinal(versification: normalized, ordinal: sourceOrdinal)
    }

    /** Resolves the active pane verse into the KJVA page selected by Android's My Notes document. */
    private func currentMyNotesTarget(jumpToOrdinal: Int?) -> MyNotesTarget? {
        if let jumpToOrdinal {
            return myNotesTarget(kjvaOrdinal: jumpToOrdinal)
        }
        let sourceOSISBookID = osisBookId(for: currentBook)
        guard !sourceOSISBookID.isEmpty, currentChapter >= 0 else { return nil }
        return .chapter(
            versification: activeSourceVersificationName(),
            osisBookID: sourceOSISBookID,
            chapter: currentChapter,
            jumpSourceVerse: nil
        )
    }

    /** Resolves one exact source request into Android's authoritative mapped My Notes span. */
    private static func prepareMyNotesTarget(_ target: MyNotesTarget) -> PreparedMyNotesTarget? {
        let sourceVersification: String
        let sourceOSISBookID: String
        let sourceChapter: Int
        let jumpSourceVerse: Int?
        let exactKJVAJump: Int?

        switch target {
        case .chapter(let versification, let osisBookID, let chapter, let requestedVerse):
            sourceVersification = versification
            sourceOSISBookID = osisBookID
            sourceChapter = chapter
            jumpSourceVerse = requestedVerse
            exactKJVAJump = nil
        case .ordinal(let versification, let ordinal):
            guard let normalized = JSwordVersificationRegistry.normalizedName(versification) else {
                return nil
            }
            sourceVersification = normalized
            if normalized == JSwordKJVAVersification.name {
                guard let source = JSwordKJVAVersification.referenceIncludingIntroductions(
                    ordinal: ordinal
                ) else { return nil }
                sourceOSISBookID = source.osisId
                sourceChapter = source.chapter
                jumpSourceVerse = source.verse
                exactKJVAJump = ordinal
            } else {
                guard let source = SwordVersification.reference(
                    forIndex: ordinal,
                    versification: normalized
                ) else { return nil }
                sourceOSISBookID = source.osisBookId
                sourceChapter = source.chapter
                jumpSourceVerse = source.verse
                exactKJVAJump = nil
            }
        }

        guard let reference = MyNotesChapterReference(
            sourceVersification: sourceVersification,
            sourceOSISBookId: sourceOSISBookID,
            sourceChapter: sourceChapter
        ) else { return nil }
        let mappedJump = exactKJVAJump ?? jumpSourceVerse.flatMap { sourceVerse in
            Self.myNotesKJVAOrdinal(
                sourceVersification: reference.source.versification,
                osisBookID: reference.source.osisBookId,
                chapter: reference.effectiveSourceChapter,
                verse: max(sourceVerse, 1)
            )
        }
        return PreparedMyNotesTarget(reference: reference, jumpToOrdinal: mappedJump)
    }

    /** Maps one concrete source verse to a strict intro-inclusive KJVA ordinal. */
    private static func myNotesKJVAOrdinal(
        sourceVersification: String,
        osisBookID: String,
        chapter: Int,
        verse: Int
    ) -> Int? {
        guard let mapped = VersificationMapper.convertStrictly(
            osisBookId: osisBookID,
            chapter: chapter,
            verse: verse,
            from: sourceVersification,
            to: JSwordKJVAVersification.name
        )?.reference else { return nil }
        if mapped.verse == 0 {
            return JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: mapped.osisBookId,
                chapter: mapped.chapter
            )
        }
        return JSwordKJVAVersification.verseOrdinal(
            osisId: mapped.osisBookId,
            chapter: mapped.chapter,
            verse: mapped.verse
        )
    }

    /**
     Returns every bookmark inside one authoritative mapped My Notes span.

     Android's `CurrentMyNotePage` passes all of `bookmarksForVerseRange(...)` to the shared
     `MyNotesDocument`, including bookmarks without notes; the Vue layer then applies the
     `showBookmarks` and hidden-label display filters. iOS must not pre-filter to note-bearing
     bookmarks here, or chapters whose bookmarks have no notes render Android's empty state
     instead of their bookmark rows.
     */
    private func myNotesBookmarks(for reference: MyNotesChapterReference) -> [BibleBookmark] {
        guard let service = bookmarkService else { return [] }
        return service.bookmarks(
            for: reference.kjvaOrdinalStart,
            endOrdinal: reference.kjvaOrdinalEnd
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

    /** Returns exact request text for cancellation/coalescing without serializing document data. */
    private static func myNotesTargetIdentity(_ target: MyNotesTarget) -> String {
        switch target {
        case .chapter(let versification, let osisBookID, let chapter, let jumpSourceVerse):
            let jump = jumpSourceVerse.map(String.init) ?? ""
            return "chapter|\(versification)|\(osisBookID)|\(chapter)|\(jump)"
        case .ordinal(let versification, let ordinal):
            return "ordinal|\(versification)|\(ordinal)"
        }
    }

    /** Copies the complete mapped My Notes persistence graph on its main owner. */
    private func myNotesOwnerSnapshot(
        _ target: PreparedMyNotesTarget
    ) -> BibleReaderPreparedMyNotesOwnerSnapshot {
        let inputs = myNotesBookmarks(for: target.reference).map {
            BibleReaderPreparedBibleBookmarkInput(
                $0,
                unlabeledLabelID: Self.unlabeledLabelId
            )
        }
        return BibleReaderPreparedMyNotesOwnerSnapshot(
            reference: target.reference,
            bookmarkInputs: inputs,
            labels: labelPayloadSnapshot(),
            jumpToOrdinal: target.jumpToOrdinal
        )
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
    private static func normalizedVersificationName(_ name: String) -> String {
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
        if showingMyNotes, let activeMyNotesReference {
            return myNotesBookmarks(for: activeMyNotesReference)
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

    /// Records typed identity and source provenance after the reader bridge accepts a render.
    private func setRenderedContentState(
        category: DocumentCategory,
        moduleName: String?,
        book: String,
        chapter: Int? = nil,
        key: String? = nil,
        sourceProvenance: BibleReaderRenderSourceProvenance,
        extractionDependency: BibleReaderRenderExtractionDependency = .none,
        preserveCompositeRebuildRequest: Bool = false,
        documentKind: ReaderRenderedDocumentKind = .standard
    ) {
        myDocumentCoordinator.clearActivePageUnless(category: category, moduleName: moduleName)
        commentaryNavigationAvailability = .empty
        if !preserveCompositeRebuildRequest {
            activeCompositeRebuildRequest = nil
        }
        if documentKind != .memorize {
            activeMemorizeRequest = nil
        }
        renderedDocumentKind = documentKind
        committedRenderState = BibleReaderCommittedRenderState(
            identity: BibleReaderCommittedRenderIdentity(
                category: category,
                moduleName: moduleName,
                book: book,
                chapter: chapter,
                key: key
            ),
            sourceProvenance: sourceProvenance,
            extractionDependency: extractionDependency
        )
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
    /// Monotonic owner token for prepared payloads routed outward without replacing this pane.
    private var transientPreparationGeneration: UInt64 = 0
    /// Pane-local owner of background source capture, projection, encoding, and publication.
    @ObservationIgnored
    private let documentPreparationCoordinator: BibleReaderDocumentPreparationCoordinator
    /// Main-queue owner of destination validation and selected-versus-rendered commit order.
    @ObservationIgnored
    private lazy var preparationPublicationOwner = BibleReaderPreparationPublicationOwner {
        [weak self] in
        BibleReaderPreparationDestination(
            generation: self?.contentIntentGeneration ?? 0,
            paneID: self?.activeWindow?.id,
            workspaceID: self?.activeWindow?.workspace?.id
        )
    }
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
        self.documentPreparationCoordinator = BibleReaderDocumentPreparationCoordinator()
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
       - documentPreparationCoordinator: Injectable owner for background capture, projection,
         encoding, cancellation, and publication authorization.
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
    documentPreparationCoordinator: BibleReaderDocumentPreparationCoordinator =
      BibleReaderDocumentPreparationCoordinator(),
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
        self.documentPreparationCoordinator = documentPreparationCoordinator
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

     - Parameter cancelPreparedWork: Whether to cancel prepared work from the previous intent.
       Coordinator-backed Bible requests pass `false` so an equivalent in-flight request can
       coalesce; the coordinator still cancels different replacement keys.
     - Returns: Monotonic generation owned by the new intent.
     - Side effects: Advances controller-local replacement state and optionally cancels prepared
       document work.
     - Failure modes: None; wrapping increment preserves ordering for the practical process lifetime.
     */
    @discardableResult
    private func beginReplacingContentIntent(cancelPreparedWork: Bool = true) -> UInt64 {
        contentIntentGeneration &+= 1
        if cancelPreparedWork {
            documentPreparationCoordinator.cancelAll()
        }
        return contentIntentGeneration
    }

    /** Suspends an AI route until one asynchronous selected-intent request reaches a terminal state. */
    @MainActor
    private func awaitPreparationSelectionSettlement(
        _ start: (@escaping () -> Void) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            start {
                continuation.resume()
            }
        }
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

     The controller routes a typed source operation together with the initially built Vue
     `MultiDocument`. The owning pane decides which controller renders it, and the destination keeps
     the source operation so extraction-setting changes can rebuild current dictionary content.

     - Parameter request: Strong's or word-lookup source inputs, initial serialized payload, and
       stable synthetic display identity.
     - Returns: The closure returns no value; the owner reports completion by rendering in the
       selected target controller.
     - Side effects: None in the controller until the owning closure calls back into a target
       controller to render the payload.
     - Failure modes: If no owner installs the closure, preparation renders in the current
       controller through the same selected-intent transaction.
     */
    var onOpenDefinitionDocumentInLinksWindow: ((BibleReaderDefinitionRenderRequest) -> Void)?

    /// Callback for opening search with a Strong's number (from "Find all occurrences" links).
    var onShowStrongsSearch: ((String) -> Void)?

    /**
     Callback for opening a transient multi-reference Vue document in the Android-style links window.

     The request retains parsed OSIS references as well as the initial serialized payload. The
     owning pane decides whether to route it into a dedicated links window or render it in the
     current controller; the destination uses those references for later source reconstruction.
     */
    var onOpenMultiReferenceDocumentInLinksWindow: ((BibleReaderMultiReferenceRenderRequest) -> Void)?

    /**
     Callback for opening Android's commentary-category Memorize fake document in the links window.

     The controller builds the serialized Vue payload and Android fake-document metadata, then lets
     the owning pane choose the destination controller. When no owner installs this callback,
     Memorize renders in the current controller as Android's direct-window fallback.
     */
    var onOpenMemorizeDocumentInLinksWindow: ((BibleReaderMemorizeRenderRequest) -> Void)?

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
                        osisBookId: $0.osisBookId,
                        ordinal: $0.ordinal
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
            scrollToLoadedPosition: { [weak self] position, highlight in
                self?.scrollToLoadedBiblePosition(position, highlight: highlight) ?? false
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
     Leaves pane-local special documents after an installed or EPUB target passes preflight.

     Android changes the current page only after resolving the selected document. Applying the same
     boundary here keeps failed and locked choices on My Notes or StudyPad, while an accepted choice
     clears their replay state even when the WebView client is temporarily unavailable.

     - Side effects: Invalidates older prepared content, clears My Notes and StudyPad visibility,
       pending replay targets, editor state, and native selection state.
     - Failure modes: None. Callers must invoke this only after target authorization succeeds and
       immediately before committing the new selected document.
     */
    private func prepareForAcceptedVisibleDocumentSwitch() {
        beginReplacingContentIntent()
        clearPendingSpecialDocumentReplay()
        resetAuxiliaryContentState()
    }

    /** Clears deferred My Notes and StudyPad targets after another document selection commits. */
    private func clearPendingSpecialDocumentReplay() {
        pendingClientReadyMyNotesTarget = nil
        pendingClientReadyStudyPadBookmarkId = nil
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

    /// Update display settings using config-only or extraction-invalidating reader work.
    public func updateDisplaySettings(_ settings: TextDisplaySettings, nightMode: Bool) {
        let updateAction = BibleReaderDisplayUpdateAction.resolve(
            previousSettings: displaySettings,
            settings: settings,
            previousNightMode: self.nightMode,
            nightMode: nightMode,
            sourceUsesSwordExtraction: currentRenderedSourceUsesSwordExtraction
        )
        self.displaySettings = settings
        self.nightMode = nightMode
        guard updateAction != .none else { return }
        applySwordOptions()
        applyNightModeBackground()
        guard clientReady else { return }
        bridge.emit(event: "set_config", data: buildConfigJSON())
        guard updateAction == .replaceContent else { return }
        navigationCoordinator.prepareForContentReload()
        reloadVisibleDocumentAfterClientReady()
    }

    /// Whether the visible source was built through SWORD's extraction-time filters.
    private var currentRenderedSourceUsesSwordExtraction: Bool {
        guard committedRenderState.identity?.category == currentCategory else { return false }
        return committedRenderState.extractionDependency == .sectionTitles
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
                if !SwordJavaStringIdentity.equals(self.activeModuleName, module.info.name) {
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

    /// Controller-local spelling retained for existing speech, bookmark, and routing call sites.
    typealias LocalGeneralBookDocument = BibleReaderLocalGeneralBookDocument

    /** Builds category-correct SWORD generic context with source-owned document-switch navigation. */
    func makeGenericSpeechContext(
        module: SwordModule,
        moduleName: String,
        category: SpeakDocumentCategory,
        currentKey: String?
    ) -> BibleReaderGenericSpeechContext? {
        guard SwordJavaStringIdentity.equals(module.info.name, moduleName) else { return nil }
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
                    if self.activeCommentaryModuleName.map({
                        SwordJavaStringIdentity.equals($0, moduleName)
                    }) != true {
                        self.switchCommentaryDocument(to: moduleName)
                    }
                    if let (book, chapter, verse) = self.parseVerseKey(sourceKey) {
                        self.currentBook = book
                        self.currentChapter = chapter
                        self.currentVerse = verse
                        self.loadCommentaryForCurrentVerse()
                    }
                case .dictionary:
                    if self.activeDictionaryModuleName.map({
                        SwordJavaStringIdentity.equals($0, moduleName)
                    }) != true {
                        self.switchDictionaryDocument(to: moduleName)
                    }
                    self.loadDictionaryEntry(key: sourceKey)
                case .generalBook:
                    if module.info.category == .map {
                        if self.activeMapModuleName.map({
                            SwordJavaStringIdentity.equals($0, moduleName)
                        }) != true {
                            self.switchMapDocument(to: moduleName)
                        }
                        self.loadMapEntry(key: sourceKey)
                    } else {
                        if self.activeGeneralBookModuleName.map({
                            SwordJavaStringIdentity.equals($0, moduleName)
                        }) != true {
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
     - Failure modes: Locked native owners and registered SQLite identities fail closed. EPUB and
       My Documents follow Android registration/lookup ownership rather than forming parallel local
       candidates. Missing and wrong-category owners return nil without constructing a provider.
     */
    private func genericSpeechSource(
        bookInitials: String,
        expectedCategory: SpeakDocumentCategory?
    ) -> GenericSpeechSource? {
        guard let owner = installedOrLocalGeneralBookOwner(
            named: bookInitials,
            preferredEpub: activeEpubReader
        ) else { return nil }
        switch owner {
        case .installed(let info, let readableSource):
            guard let readableSource,
                  case .sword(let module) = readableSource,
                  let category = Self.genericSpeechCategory(for: info.category),
                  expectedCategory == nil || expectedCategory == category else {
                return nil
            }
            return .sword(module: module, category: category)
        case .local(.myDocument(let document)):
            guard expectedCategory == nil
                    || expectedCategory == .generalBook
                    || expectedCategory == .myDocument else {
                return nil
            }
            return .myDocument(document)
        case .local(.epub(let reader)):
            guard expectedCategory == nil || expectedCategory == .generalBook else { return nil }
            return .epub(reader)
        case .missing:
            return nil
        }
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
                self.withFreshAuthorizedEpubSpeechReader(reader) { admittedReader in
                    if self.currentCategory != .generalBook
                        || self.activeEpubIdentifier != admittedReader.identifier
                        || self.activeEpubReader?.generationIdentifier
                            != admittedReader.generationIdentifier {
                        self.activateEpub(
                            admittedReader,
                            identifier: admittedReader.identifier,
                            requestedKey: sourceKey
                        )
                    }
                    self.loadEpubEntry(key: sourceKey, jumpToOrdinal: ordinal)
                }
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
     Executes one deferred EPUB speech synchronization only for the current global registry owner.

     - Parameters:
       - expectedReader: Immutable EPUB generation captured when the speech session was built.
       - operation: Content/state operation to run with the freshly admitted current generation.
     - Returns: `true` only when the operation ran for the same current EPUB generation.
     - Side effects: Opens the stable EPUB pointer and replays the complete installed/SQLite/EPUB/
       My Documents registry before invoking `operation`; this method reads no EPUB fragment itself.
     - Failure modes: Rebuilt/deleted EPUB generations, installed or earlier local owners, metadata
       failures, and Java-distinct identities return `false` without invoking the operation.
     */
    @discardableResult
    func withFreshAuthorizedEpubSpeechReader(
        _ expectedReader: EpubReader,
        operation: (EpubReader) -> Void
    ) -> Bool {
        guard let currentReader = EpubReader(identifier: expectedReader.identifier),
              SwordJavaStringIdentity.equals(currentReader.initials, expectedReader.initials),
              currentReader.generationIdentifier == expectedReader.generationIdentifier,
              let owner = installedOrLocalGeneralBookOwner(
                  named: expectedReader.initials,
                  preferredEpub: currentReader
              ),
              case .local(.epub(let admittedReader)) = owner,
              admittedReader.identifier == currentReader.identifier,
              admittedReader.generationIdentifier == currentReader.generationIdentifier else {
            return false
        }
        operation(admittedReader)
        return true
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

    /**
     Reconstructs a persisted pause/last-position checkpoint from its exact authorized source.

     - Parameters:
       - checkpoint: Persisted category, source initials, key/ordinal, and playback state.
       - service: Speech service that will own a successfully reconstructed session.
     - Returns: A category-compatible reconstruction, or `nil` when the source is absent, locked,
       shadowed, stale, or belongs to a different document category.
     - Side effects: Reads only the freshly authorized source needed to rebuild page text; failure
       does not mutate reader selection, PageManager state, or the supplied speech service.
     - Failure modes: Bible/memorization checkpoints require an actual Bible backend. Generic
       checkpoints replay the combined installed/local ownership contract before any content read.
     */
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
        module.info.category == .bible,
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
        if !SwordJavaStringIdentity.equals(activeModuleName, resolvedName)
          || currentCategory != .bible {
            switchBibleDocument(to: resolvedName)
        }
        guard SwordJavaStringIdentity.equals(activeModuleName, resolvedName),
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
        guard !references.isEmpty else { return false }
        return prepareMultiReferenceDocument(
            refs: references,
            routeToLinksWindow: true
        )
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
      context: makeSQLiteModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
    ) {
      return .switched
    }
    return moduleSwitchCoordinator.switchBibleDocument(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
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
      context: makeSQLiteModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
    ) {
      return .switched
    }
    return moduleSwitchCoordinator.switchCommentaryDocument(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
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
      context: makeSQLiteModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
    ) {
      return outcome
    }
    return moduleSwitchCoordinator.switchDictionaryDocument(
      to: sqliteRuntimeCoordinator.canonicalSwordModuleName(moduleName),
      context: makeModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
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
      to: moduleName,
      context: makeModuleSwitchContext(),
      prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
    )
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
        moduleSwitchCoordinator.switchMapDocument(
            to: moduleName,
            context: makeModuleSwitchContext(),
            prepareForSwitch: { [self] in prepareForAcceptedVisibleDocumentSwitch() }
        )
    }

    /**
     Switches one Bible from Android's toolbar and records its category default only on success.

     The full document picker and direct navigation keep using `switchBibleDocument(to:)`, matching
     Android's separate `DocumentControl.changeDocument` path that does not update this preference.
     */
    @MainActor
    @discardableResult
    func switchBibleToolbarDocument(to moduleName: String) -> BibleReaderBibleModuleSwitchOutcome {
        let outcome = switchBibleDocument(to: moduleName)
        guard outcome == .switched,
              let info = registeredInstalledModuleInfo(named: moduleName),
              info.category == .bible else { return outcome }
        BibleReaderDocumentDefaultPreference.recordToolbarSelection(
            info,
            settingsStore: settingsStore
        )
        return outcome
    }

    /** Records a successful commentary toolbar switch without changing full-picker semantics. */
    @MainActor
    @discardableResult
    func switchCommentaryToolbarDocument(
        to moduleName: String
    ) -> BibleReaderCommentaryModuleSwitchOutcome {
        let outcome = switchCommentaryDocument(to: moduleName)
        guard outcome == .switched,
              let info = registeredInstalledModuleInfo(named: moduleName),
              info.category == .commentary else { return outcome }
        BibleReaderDocumentDefaultPreference.recordToolbarSelection(
            info,
            settingsStore: settingsStore
        )
        return outcome
    }

    /** Records an accepted dictionary toolbar switch, including a required-key chooser result. */
    @MainActor
    @discardableResult
    func switchDictionaryToolbarDocument(
        to moduleName: String
    ) -> BibleReaderGenericModuleSwitchOutcome {
        let outcome = switchDictionaryDocument(to: moduleName)
        if case .failed = outcome { return outcome }
        guard let info = registeredInstalledModuleInfo(named: moduleName),
              info.category == .dictionary else { return outcome }
        BibleReaderDocumentDefaultPreference.recordToolbarSelection(
            info,
            settingsStore: settingsStore
        )
        return outcome
    }

    /** Records an accepted general-book toolbar switch after its exact-key preflight. */
    @MainActor
    @discardableResult
    func switchGeneralBookToolbarDocument(
        to moduleName: String
    ) -> BibleReaderGenericModuleSwitchOutcome {
        let outcome = switchGeneralBookDocument(to: moduleName)
        if case .failed = outcome { return outcome }
        guard let info = registeredInstalledModuleInfo(named: moduleName),
              info.category == .generalBook else { return outcome }
        BibleReaderDocumentDefaultPreference.recordToolbarSelection(
            info,
            settingsStore: settingsStore
        )
        return outcome
    }

    /** Selects one authorized EPUB toolbar row and records its general-book default on success. */
    @MainActor
    @discardableResult
    func switchEpubToolbarDocument(
        identifier: String,
        expectedGenerationIdentifier: String,
        expectedInitials: String
    ) -> Bool {
        guard switchEpub(
            identifier: identifier,
            expectedGenerationIdentifier: expectedGenerationIdentifier,
            expectedInitials: expectedInitials
        ) else {
            return false
        }
        BibleReaderDocumentDefaultPreference.recordToolbarSelection(
            name: expectedInitials,
            category: .generalBook,
            settingsStore: settingsStore
        )
        return true
    }

    /**
     Selects an exact My Documents toolbar row and records its default after selected intent commits.

     A retained valid page key wins; otherwise the exact document's first Android-ordered page is
     used. The asynchronous preparation owner performs global collision and page revalidation before
     invoking the commit callback, so failed, stale, and cancelled requests never write a default.
     */
    @MainActor
    @discardableResult
    func switchMyDocumentToolbarDocument(expectedID: UUID, initials: String) -> Bool {
        guard let store = myDocumentStore,
              let localDocument = localGeneralBookDocument(named: initials),
              case .myDocument(let document) = localDocument,
              document.id == expectedID else { return false }
        let canonicalInitials = document.initials
        let retainedKey = activeWindow?.pageManager?.generalBookKey
        let pageKey = retainedKey.flatMap {
            store.page(bookInitials: canonicalInitials, pageKey: $0)?.pageKey
        } ?? store.firstPageKey(bookInitials: canonicalInitials)
        guard let pageKey else {
            return publishEmptyMyDocumentSelection(
                expectedID: expectedID,
                initials: canonicalInitials,
                name: document.name,
                recordsToolbarDefault: true
            )
        }
        return prepareMyDocumentPage(
            requestedInitials: canonicalInitials,
            requestedKey: pageKey,
            selectedOrdinalRange: nil,
            expectedFragment: nil,
            expectedDocumentID: expectedID,
            selectionCommitted: { [weak self] prepared in
                guard prepared.documentID == expectedID,
                      SwordJavaStringIdentity.equals(
                    prepared.documentInitials,
                    canonicalInitials
                ) else { return }
                BibleReaderDocumentDefaultPreference.recordToolbarSelection(
                    name: canonicalInitials,
                    category: .generalBook,
                    settingsStore: self?.settingsStore
                )
            }
        )
    }

    /**
     Selects or replays one exact page-less My Documents owner as ordinary no-content state.

     The reader's bridge and preparation-publication boundary are main-queue owned rather than
     Swift-concurrency actor isolated. Both toolbar selection and client-ready replay enter through
     that existing executor contract, which is asserted before any controller state changes.
     */
    private func publishEmptyMyDocumentSelection(
        expectedID: UUID,
        initials: String,
        name: String,
        recordsToolbarDefault: Bool
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        beginReplacingContentIntent()
        let destination = preparationPublicationOwner.captureDestination()
        let ownerIsCurrent: () -> Bool = { [weak self] in
            guard let self,
                  let localDocument = self.localGeneralBookDocument(named: initials),
                  case .myDocument(let document) = localDocument else { return false }
            return document.id == expectedID
                && SwordJavaStringIdentity.equals(document.initials, initials)
                && SwordJavaExactStringIdentity(document.name)
                    == SwordJavaExactStringIdentity(name)
                && (document.pages ?? []).isEmpty
        }
        guard ownerIsCurrent(),
              let document = documentPayloadFactory().errorDocumentJSON(
                message: String(
                    localized: "error_no_content",
                    defaultValue: "No content for this passage"
                )
              ) else { return false }
        let outcome: BibleReaderDocumentPreparationOutcome<String> = .prepared(document)
        let toolbarDefaultMutation: BibleReaderPreparationSynchronousMutation<String>? =
            recordsToolbarDefault
            ? .init(
                commit: { [weak self] _ in
                    BibleReaderDocumentDefaultPreference.recordToolbarSelection(
                        name: initials,
                        category: .generalBook,
                        settingsStore: self?.settingsStore
                    )
                },
                isCurrentAfterCommit: { _ in ownerIsCurrent() }
            )
            : nil
        let disposition = preparationPublicationOwner.publishQueuedBridge(
            outcome,
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .settle,
            isCurrent: { _ in ownerIsCurrent() },
            selectedIntent: .init(
                commit: { [weak self] _ in
                    guard let self, ownerIsCurrent() else { return }
                    self.commitEmptyMyDocumentSelectionIntent(
                        documentID: expectedID,
                        initials: initials
                    )
                },
                isCurrentAfterCommit: { _ in ownerIsCurrent() }
            ),
            postSelectionCallback: toolbarDefaultMutation,
            isSourceCurrentAroundBridge: { _ in true },
            queueBridge: { [weak self] document in
                self?.replaceDocument(
                    documentJSON: document,
                    setup: ReaderSetupContentPayload(jumpToId: "top")
                ) == true
            },
            commitAcceptedRender: { [weak self] _ in
                guard let self else { return }
                self.setRenderedContentState(
                    category: .generalBook,
                    moduleName: initials,
                    book: name,
                    sourceProvenance: .independent
                )
                self.emitActiveState()
                self.bridge.clearSelection()
                self.applyNightModeBackground()
            }
        )
        switch disposition {
        case .accepted, .bridgeRejected, .dispatchedStale:
            return true
        case .cancelled, .failed, .stale:
            return false
        }
    }

    /**
     Resolves Android's lazy installed default for a toolbar swap target without mutating the pane.

     - Parameters:
       - category: Bible or commentary category requested by the toolbar.
       - currentName: Pane-owned category identity, if one remains.
     - Returns: Current registered owner, saved registered default (locked included), then first
       readable BookSet entry; nil for unsupported categories or no installed candidate.
     - Side effects: Reads one settings row and a fresh installed registry snapshot only.
     - Failure modes: Wrong-category registered identities fail closed without substitution.
     */
    func preferredInstalledToolbarDocument(
        for category: ModuleCategory,
        currentName: String?
    ) -> ModuleInfo? {
        guard category == .bible || category == .commentary else { return nil }
        let resolver = installedModuleResolver()
        if let currentName,
           let current = resolver.registeredModuleInfo(named: currentName) {
            return current.category == category ? current : nil
        }
        return BibleReaderDocumentDefaultPreference.replacement(
            forMissing: currentName,
            category: category,
            settingsStore: settingsStore,
            resolver: resolver
        )?.installedInfo
    }

    /**
     Captures the complete Android commentary-toolbar inventory from one fresh global registry.

     Installed commentaries and dictionaries stay readable-only. General books include readable
     native/SQLite sources plus globally admitted EPUB and My Documents owners.
     */
    func commentaryQuickDocumentSelections(
        includeAuxiliaryDocuments: Bool
    ) -> [BibleReaderQuickModuleSelectorPresentation.Selection]? {
        let resolver = installedModuleResolver()
        var selections = resolver.readableModulesInBookSetOrder(
            categories: [.commentary]
        ).map { BibleReaderQuickModuleSelectorPresentation.Selection.installed($0.info) }
        guard includeAuxiliaryDocuments else { return selections }
        guard let generalBooks = documentAuthorizationService().readableGeneralBookOwners(
            resolver: resolver
        ) else { return nil }
        selections += generalBooks.map { selection in
            switch selection {
            case .installed(let info, _):
                return .installed(info)
            case .local(.epub(let reader)):
                return .epub(
                    identifier: reader.identifier,
                    generationIdentifier: reader.generationIdentifier,
                    initials: reader.initials,
                    title: reader.title,
                    language: reader.language
                )
            case .local(.myDocument(let document)):
                return .myDocument(
                    id: document.id,
                    initials: document.initials,
                    name: document.name,
                    language: Locale.current.language.languageCode?.identifier ?? "en"
                )
            }
        }
        selections += resolver.readableModulesInBookSetOrder(
            categories: [.dictionary]
        ).map { .installed($0.info) }
        return selections
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
                emitTransientMultiDocument(
                    activeRequest,
                    rebuildRequest: activeCompositeRebuildRequest
                )
                return
            }
            if loadRestoredAndroidMultiDocument() {
                return
            }
        }
        if isShowingAndroidMemorizeDocument {
            if let activeMemorizeRequest {
                renderMemorizeDocument(activeMemorizeRequest)
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
            let sourceOSISBookID = osisBookId(for: currentBook)
            let target: MyNotesTarget? = sourceOSISBookID.isEmpty ? nil : .chapter(
                versification: activeSourceVersificationName(),
                osisBookID: sourceOSISBookID,
                chapter: currentChapter,
                jumpSourceVerse: currentVerse > 1 ? currentVerse : nil
            )
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

     - Parameter documentJSON: Already-serialized multi-document payload used by focused bridge
       contract tests and trusted prepared callers.
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
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(from: documentJSON),
            sourceAuthorization: .independent
        )
    }

    /**
     Renders a typed multi-reference request and retains its passages for source reconstruction.

     - Parameter request: Ordered OSIS passages paired with their initial authorized payload.
     - Returns: No direct value; successful replacement commits Android's synthetic `Multi` page.
     - Side effects: Emits and persists the transient document and retains the passages for later
       extraction-setting invalidation.
     - Failure modes: Bridge rejection keeps the prior committed rebuild request active.
     */
    func loadMultiReferenceDocument(_ request: BibleReaderMultiReferenceRenderRequest) {
        loadTransientMultiDocument(
            request.initialDocumentJSON,
            renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            renderedKey: AndroidSpecialDocumentIdentity.multiRenderedKey,
            renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(
                from: request.initialDocumentJSON
            ),
            sourceProvenance: request.sourceProvenance,
            sourceAuthorization: request.sourceAuthorization,
            rebuildRequest: .prepared(.multiReferences(request.sourceRequest))
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
    private func loadRestoredAndroidMultiDocument(pageKey: String? = nil) -> Bool {
        guard let resolvedPageKey = pageKey ?? currentGeneralBookKey,
              !AndroidSpecialDocumentIdentity.parseBookAndKeyListReference(
                resolvedPageKey
              ).isEmpty else { return false }
        return prepareCompositeDocument(
            .restoredMulti(
                BibleReaderRestoredMultiPreparationRequest(
                    pageKey: resolvedPageKey,
                    activeModuleName: activeModuleName.isEmpty ? nil : activeModuleName
                )
            ),
            routeMultiToLinksWindow: false
        )
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
            source: MemorizeDocumentSource(bookInitials: activeModuleName, references: [reference])
        )
    }

    /**
     Reads Android's preserved Memorize source range from page-manager fidelity storage.

     - Returns: Decoded source document initials and concrete verse references, or `nil` when no
       source key is available for the active window.
     - Side effects: Reads `SettingsStore` through `RemoteSyncWorkspaceFidelityStore`.
     - Failure modes: Malformed JSON, unsupported OSIS keys, or empty ranges return `nil`.
     */
    private func restoredMemorizeSourceFromFidelity() -> MemorizeDocumentSource? {
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
  private func restoredMemorizeSource(serializedSourceBookAndKey: String) -> MemorizeDocumentSource?
  {
        let trimmed = serializedSourceBookAndKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(SerializedBookAndKey.self, from: data),
      let references = memorizeReferences(fromOsisKey: payload.key)
    {
            let document = payload.document?.isEmpty == false ? payload.document! : activeModuleName
            return MemorizeDocumentSource(bookInitials: document, references: references)
        }

        guard let references = memorizeReferences(fromOsisKey: trimmed) else { return nil }
        return MemorizeDocumentSource(bookInitials: activeModuleName, references: references)
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
    private func loadRestoredAndroidMemorizeDocument(source: MemorizeDocumentSource) -> Bool {
        guard let firstReference = source.references.first,
              let lastReference = source.references.last else { return false }
        let bookInitials = source.bookInitials.isEmpty ? activeModuleName : source.bookInitials
        return prepareMemorizeDocument(
          BibleReaderMemorizePreparationRequest(
            bookInitials: bookInitials,
            startOrdinal: firstReference.ordinal,
            endOrdinal: lastReference.ordinal,
            currentBook: Self.bookName(forOsisId: firstReference.osisBookId) ?? firstReference.osisBookId,
            currentChapter: firstReference.chapter,
            osisBookID: firstReference.osisBookId,
            stateJSON: activeWindow?.pageManager?.jsState,
            directKJVAReferences: source.references
          ),
          routeToLinksWindow: false
        )
    }

    /**
     Displays an Android-style compare `MultiDocument` for the active passage.

     - Parameters:
       - bookInitials: Optional source document owning explicit selection ordinals.
       - startOrdinal: Optional first source ordinal; omission compares the current whole chapter.
       - endOrdinal: Optional final source ordinal; omission uses `startOrdinal`.
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
        let request: BibleReaderComparePreparationRequest
        if let bookInitials, let startOrdinal {
            request = .ordinals(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal ?? startOrdinal
            )
        } else {
            guard (activeModule != nil || activeSQLiteBibleModule != nil),
                  !activeModuleName.isEmpty else { return }
            request = .chapter(
                bookInitials: activeModuleName,
                osisBookID: osisBookId(for: currentBook),
                chapter: currentChapter
            )
        }
        _ = prepareCompositeDocument(
            .compare(request),
            routeMultiToLinksWindow: false
        )
    }

    /**
     Schedules a Multi or Compare source operation through the shared preparation pipeline.

     Source registry capture and entry reads execute under one SWORD live-tree lease. The worker
     then purely encodes copied fragments before the main owner validates the pane, workspace,
     installed SQLite registry, manager generation, and exact source dependencies. A routed live
     Multi publishes only after the source pane passes that boundary; restored Multi and Compare
     publish directly into this pane.

     - Parameters:
       - request: Immutable live Multi, restored Multi, or Compare source operation.
       - routeMultiToLinksWindow: Whether a completed live Multi should use the pane owner's links
         window callback.
     - Returns: `true` when the request entered the coordinator.
     - Side effects: Cancels superseded work in the corresponding lane and may later route or
       replace one bridge document on the main actor.
     - Failure modes: Stale panes, changed registries, relocked/replaced modules, incomplete source
       passages, and encoding or bridge rejection settle without committing rendered state.
     */
    @discardableResult
    private func prepareCompositeDocument(
        _ request: BibleReaderCompositePreparationRequest,
        routeMultiToLinksWindow: Bool,
        retriesOneStaleResult: Bool = true
    ) -> Bool {
        let outwardMultiOpen = routeMultiToLinksWindow
            ? onOpenMultiReferenceDocumentInLinksWindow
            : nil
        let routesOutward: Bool
        if case .multiReferences = request {
            routesOutward = outwardMultiOpen != nil
        } else {
            routesOutward = false
        }
        if routesOutward { transientPreparationGeneration &+= 1 }
        let outwardGeneration = transientPreparationGeneration
        let generation = routesOutward
            ? contentIntentGeneration : beginReplacingContentIntent()
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let destination = preparationPublicationOwner.captureDestination()
        let manager = swordManager
        let managerGeneration = manager?.contentAuthorizationGeneration
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let sqliteModules = sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        let sqliteIdentities = sqliteModules.map {
            BibleReaderPreparationSQLiteIdentity(
                module: ObjectIdentifier($0),
                initials: BibleReaderPreparationExactText($0.info.name)
            )
        }
        let bibleModules = installedBibleModules
        let requestedModuleNames = request.requestedModuleNames(
            installedBibleModules: bibleModules
        )
        let key = BibleReaderDocumentPreparationKey(
            family: "composite",
            paneID: paneID,
            workspaceID: workspaceID,
            source: .installedRegistry(
                swordManager: manager.map(ObjectIdentifier.init),
                swordGeneration: managerGeneration,
                sqliteModules: sqliteIdentities
            ),
            contentIdentity: "composite-request",
            annotationIdentity: .compositeRequest(request.identity)
        )
        let baseAuthorization: () -> Bool = { [weak self, weak manager] in
            guard let self else { return false }
            let managerIsCurrent = manager.map {
                self.swordManager === $0
                    && $0.contentAuthorizationGeneration == managerGeneration
            } ?? (self.swordManager == nil)
            let currentSQLiteIdentities = self.sqliteRuntimeCoordinator
                .unshadowedSQLiteModules().map {
                    BibleReaderPreparationSQLiteIdentity(
                        module: ObjectIdentifier($0),
                        initials: BibleReaderPreparationExactText($0.info.name)
                    )
                }
            return self.contentIntentGeneration == generation
                && (!routesOutward
                    || self.transientPreparationGeneration == outwardGeneration)
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && managerIsCurrent
                && currentSQLiteIdentities == sqliteIdentities
        }
        documentPreparationCoordinator.submitReportingOutcome(
            scope: routesOutward ? .transient : .replacement,
            key: key,
            captureSource: { () -> BibleReaderCompositeSourceCapture? in
                let capture: () -> BibleReaderCompositeSourceCapture? = {
                    guard manager == nil
                        || manager?.contentAuthorizationGeneration == managerGeneration else {
                        return nil
                    }
                    let resolver = BibleReaderInstalledModuleResolver(
                        swordManager: manager,
                        sqliteModules: sqliteModules
                    )
                    var dependencies = sqliteModules.map {
                        BibleReaderPreparationSourceDependency.sqlite(
                            module: ObjectIdentifier($0),
                            initials: BibleReaderPreparationExactText($0.info.name)
                        )
                    }
                    if let manager {
                        dependencies.insert(
                            .sword(
                                manager: ObjectIdentifier(manager),
                                authorization: manager.contentAuthorizationSnapshot(
                                    for: requestedModuleNames
                                )
                            ),
                            at: 0
                        )
                    }
                    let captured = BibleReaderPreparedCompositeDocument.capture(
                        request: request,
                        resolver: resolver,
                        installedBibleModules: bibleModules,
                        sourceDependencies: dependencies,
                        sqliteModules: sqliteModules
                    )
                    guard manager == nil
                        || manager?.contentAuthorizationGeneration == managerGeneration else {
                        return nil
                    }
                    return captured
                }
                if let manager {
                    return manager.performRenderOperation(settings: optionSettings, capture)
                }
                return capture()
            },
            project: { (capture: BibleReaderCompositeSourceCapture) in capture },
            encode: { capture in
                BibleReaderPreparedCompositeDocument.encode(capture)
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else { return }
            let sourceAuthorization: BibleReaderRoutedSourceAuthorization?
            if case .prepared(let prepared) = outcome {
                sourceAuthorization = self.routedSourceAuthorization(
                    for: prepared.sourceDependencies
                )
            } else {
                sourceAuthorization = nil
            }
            let disposition: BibleReaderPreparationPublicationDisposition
            if routesOutward {
                disposition = self.preparationPublicationOwner.publishOutward(
                    outcome,
                    destination: destination,
                    failurePolicy: .settle,
                    stalePolicy: .requestFreshCurrent,
                    isCurrent: { [weak self] prepared in
                        self?.sourceDependenciesAreCurrent(prepared.sourceDependencies) == true
                            && sourceAuthorization?.isCurrent() == true
                    },
                    route: { [weak self] prepared in
                        guard let self,
                              case .multiReferences(let sourceRequest) = request,
                              let sourceAuthorization,
                              let open = outwardMultiOpen
                        else { return }
                        open(BibleReaderMultiReferenceRenderRequest(
                            sourceRequest: sourceRequest,
                            initialDocumentJSON: prepared.documentJSON,
                            sourceProvenance: prepared.sourceProvenance,
                            sourceAuthorization: sourceAuthorization
                        ))
                    }
                )
            } else {
                disposition = self.preparationPublicationOwner.publishQueuedBridge(
                    outcome,
                    destination: destination,
                    failurePolicy: .settle,
                    stalePolicy: .requestFreshCurrent,
                    isCurrent: { [weak self] prepared in
                        self?.sourceDependenciesAreCurrent(prepared.sourceDependencies) == true
                            && sourceAuthorization?.isCurrent() == true
                    },
                    selectedIntent: .init(
                        commit: { [weak self] prepared in
                            guard let self, let sourceAuthorization else { return }
                            self.commitTransientSelectedIntent(
                                self.transientDocumentRequest(
                                    for: prepared,
                                    sourceRequest: request,
                                    sourceAuthorization: sourceAuthorization
                                ),
                                rebuildRequest: .prepared(request)
                            )
                        },
                        isCurrentAfterCommit: { [weak self] prepared in
                            self?.sourceDependenciesAreCurrent(
                                prepared.sourceDependencies
                            ) == true && sourceAuthorization?.isCurrent() == true
                        }
                    ),
                    queueBridgePrerequisites: { [weak self] _ in self?.sendLabelsToVueJS() },
                    isSourceCurrentAroundBridge: { [weak self] prepared in
                        self?.sourceDependenciesAreCurrent(prepared.sourceDependencies) == true
                            && sourceAuthorization?.isCurrent() == true
                    },
                    queueBridge: { [weak self] prepared in
                        guard let self, let sourceAuthorization else { return false }
                        return self.dispatchTransientDocument(
                            self.transientDocumentRequest(
                                for: prepared,
                                sourceRequest: request,
                                sourceAuthorization: sourceAuthorization
                            ),
                            sendsLabels: false
                        )
                    },
                    commitAcceptedRender: { [weak self] prepared in
                        guard let self, let sourceAuthorization else { return }
                        self.commitTransientAcceptedRender(
                            self.transientDocumentRequest(
                                for: prepared,
                                sourceRequest: request,
                                sourceAuthorization: sourceAuthorization
                            ),
                            rebuildRequest: .prepared(request)
                        )
                    }
                )
            }
            if disposition == .stale(.requestFreshCurrent), retriesOneStaleResult {
                _ = self.prepareCompositeDocument(
                    request,
                    routeMultiToLinksWindow: routeMultiToLinksWindow,
                    retriesOneStaleResult: false
                )
            }
        }
        return true
    }

    /**
     Schedules Strong's, morphology, or selected-word source work through immutable preparation.

     Installed-book discovery and entry reads execute on the serialized worker under the manager's
     shared read lease. The main actor owns only copied preference, pane, and workspace identities.
     Strong's preferred-key history and selection cleanup remain deferred until the destination
     bridge accepts the complete replacement transaction.
     */
    @discardableResult
    private func prepareDefinitionDocument(
        source: BibleReaderDefinitionRenderSource,
        stateJSON: String? = nil,
        renderedBook: String,
        renderedKey: String,
        routesOutward: Bool,
        onAccepted: (() -> Void)? = nil,
        onNoResult: (() -> Void)? = nil,
        retriesOneStaleResult: Bool = true
    ) -> Bool {
        let outwardDefinitionOpen = routesOutward
            ? onOpenDefinitionDocumentInLinksWindow
            : nil
        let routesToOwner = outwardDefinitionOpen != nil
        if routesToOwner { transientPreparationGeneration &+= 1 }
        let outwardGeneration = transientPreparationGeneration
        let generation = routesToOwner
            ? contentIntentGeneration : beginReplacingContentIntent()
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let destination = preparationPublicationOwner.captureDestination()
        let manager = swordManager
        let managerGeneration = manager?.contentAuthorizationGeneration
        let sqliteModules = sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        let sqliteIdentities = sqliteModules.map {
            BibleReaderPreparationSQLiteIdentity(
                module: ObjectIdentifier($0),
                initials: BibleReaderPreparationExactText($0.info.name)
            )
        }
        let preferences = definitionPreferenceSnapshot()
        let sourceRequest = BibleReaderDefinitionPreparationRequest(
            source: source,
            stateJSON: stateJSON,
            preferences: preferences
        )
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let key = BibleReaderDocumentPreparationKey(
            family: "definition",
            paneID: paneID,
            workspaceID: workspaceID,
            source: .installedRegistry(
                swordManager: manager.map(ObjectIdentifier.init),
                swordGeneration: managerGeneration,
                sqliteModules: sqliteIdentities
            ),
            contentIdentity: BibleReaderPreparationExactText(renderedKey),
            annotationIdentity: .definitionRequest(sourceRequest.identity)
        )
        let baseAuthorization: () -> Bool = { [weak self, weak manager] in
            guard let self else { return false }
            let managerIsCurrent = manager.map {
                self.swordManager === $0
                    && $0.contentAuthorizationGeneration == managerGeneration
            } ?? (self.swordManager == nil)
            let currentSQLiteIdentities = self.sqliteRuntimeCoordinator
                .unshadowedSQLiteModules().map {
                    BibleReaderPreparationSQLiteIdentity(
                        module: ObjectIdentifier($0),
                        initials: BibleReaderPreparationExactText($0.info.name)
                    )
                }
            return self.contentIntentGeneration == generation
                && (!routesToOwner
                    || self.transientPreparationGeneration == outwardGeneration)
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && managerIsCurrent
                && currentSQLiteIdentities == sqliteIdentities
                && self.definitionPreferenceSnapshot().identity == preferences.identity
        }

        documentPreparationCoordinator.submitReportingOutcome(
            scope: routesToOwner ? .transient : .replacement,
            key: key,
            captureSource: { () -> BibleReaderDefinitionSourceCapture? in
                let capture: () -> BibleReaderDefinitionSourceCapture? = {
                    guard manager == nil
                        || manager?.contentAuthorizationGeneration == managerGeneration else {
                        return nil
                    }
                    let resolver = BibleReaderInstalledModuleResolver(
                        swordManager: manager,
                        sqliteModules: sqliteModules
                    )
                    let registeredNames = resolver.registeredBookMetadata().map(\.name)
                    var dependencies = sqliteModules.map {
                        BibleReaderPreparationSourceDependency.sqlite(
                            module: ObjectIdentifier($0),
                            initials: BibleReaderPreparationExactText($0.info.name)
                        )
                    }
                    if let manager {
                        dependencies.insert(
                            .sword(
                                manager: ObjectIdentifier(manager),
                                authorization: manager.contentAuthorizationSnapshot(
                                    for: registeredNames
                                )
                            ),
                            at: 0
                        )
                    }
                    let strongsBuilder = BibleReaderStrongsDocumentBuilder(
                        installedDictionarySources: { resolver.dictionaryKeySources() },
                        installedBookMetadata: { resolver.registeredBookMetadata() },
                        installedDictionarySourceNamed: {
                            resolver.module(named: $0)?.explicitDictionaryKeySource
                        },
                        selectedPreferenceValues: preferences.selectedValues
                    )
                    let wordBuilder = BibleReaderWordLookupDocumentBuilder(
                        installedDictionarySources: { resolver.wordLookupDictionarySources() },
                        disabledDictionaryNames: {
                            SwordJavaExactStringSet(
                                preferences.disabledWordLookupDictionaries
                            )
                        }
                    )
                    let captured = BibleReaderPreparedDefinitionDocument.capture(
                        request: sourceRequest,
                        strongsBuilder: strongsBuilder,
                        wordLookupBuilder: wordBuilder,
                        sourceDependencies: dependencies,
                        renderOptionSettings: optionSettings
                    )
                    guard manager == nil
                        || manager?.contentAuthorizationGeneration == managerGeneration else {
                        return nil
                    }
                    return captured
                }
                if let manager {
                    return manager.performRenderOperation(settings: optionSettings, capture)
                }
                return capture()
            },
            project: { (capture: BibleReaderDefinitionSourceCapture) in capture },
            encode: { capture in
                BibleReaderPreparedDefinitionDocument.encode(capture)
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else { return }
            let sourceAuthorization: BibleReaderRoutedSourceAuthorization?
            if case .prepared(.document(let prepared)) = outcome {
                sourceAuthorization = self.routedSourceAuthorization(
                    for: prepared.sourceDependencies
                )
            } else {
                sourceAuthorization = nil
            }
            let preparedOutcomeIsCurrent: (BibleReaderPreparedDefinitionOutcome) -> Bool = {
                [weak self] preparedOutcome in
                guard let self else { return false }
                switch preparedOutcome {
                case .noResult:
                    return baseAuthorization()
                case .document(let prepared):
                    guard self.sourceDependenciesAreCurrent(prepared.sourceDependencies),
                          sourceAuthorization?.isCurrent() == true else { return false }
                    return !prepared.requiresRenderOptionAuthorization
                        || self.swordCoordinator.renderOptionSettings(
                            settings: self.displaySettings
                        ) == prepared.renderOptionSettings
                }
            }
            let routesNoResult: Bool
            if case .prepared(.noResult) = outcome {
                routesNoResult = true
            } else {
                routesNoResult = false
            }
            let disposition: BibleReaderPreparationPublicationDisposition
            if routesToOwner || routesNoResult {
                disposition = self.preparationPublicationOwner.publishOutward(
                    outcome,
                    destination: destination,
                    failurePolicy: .settle,
                    stalePolicy: .requestFreshCurrent,
                    isCurrent: preparedOutcomeIsCurrent,
                    route: { [weak self] preparedOutcome in
                        guard let self else { return }
                        switch preparedOutcome {
                        case .noResult:
                            onNoResult?()
                        case .document(let prepared):
                            guard let sourceAuthorization,
                                  let open = outwardDefinitionOpen
                            else { return }
                            open(BibleReaderDefinitionRenderRequest(
                                sourceRequest: sourceRequest,
                                initialDocumentJSON: prepared.documentJSON,
                                renderedBook: renderedBook,
                                renderedKey: renderedKey,
                                sourceAuthorization: sourceAuthorization,
                                preferredFamilyUpdates: prepared.preferredFamilyUpdates,
                                onAccepted: onAccepted
                            ))
                        }
                    }
                )
            } else {
                disposition = self.preparationPublicationOwner.publishQueuedBridge(
                    outcome,
                    destination: destination,
                    failurePolicy: .settle,
                    stalePolicy: .requestFreshCurrent,
                    isCurrent: preparedOutcomeIsCurrent,
                    selectedIntent: .init(
                        commit: { [weak self] preparedOutcome in
                            guard let self,
                                  case .document(let prepared) = preparedOutcome,
                                  let sourceAuthorization else { return }
                            let renderRequest = BibleReaderDefinitionRenderRequest(
                                sourceRequest: sourceRequest,
                                initialDocumentJSON: prepared.documentJSON,
                                renderedBook: renderedBook,
                                renderedKey: renderedKey,
                                sourceAuthorization: sourceAuthorization,
                                preferredFamilyUpdates: prepared.preferredFamilyUpdates,
                                onAccepted: onAccepted
                            )
                            self.commitTransientSelectedIntent(
                                self.transientDocumentRequest(for: renderRequest),
                                rebuildRequest: .definition(renderRequest.replayRequest)
                            )
                        },
                        isCurrentAfterCommit: preparedOutcomeIsCurrent
                    ),
                    queueBridgePrerequisites: { [weak self] preparedOutcome in
                        if case .document = preparedOutcome { self?.sendLabelsToVueJS() }
                    },
                    isSourceCurrentAroundBridge: { [weak self] preparedOutcome in
                        guard let self,
                              case .document(let prepared) = preparedOutcome
                        else { return false }
                        return self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                            && sourceAuthorization?.isCurrent() == true
                    },
                    queueBridge: { [weak self] preparedOutcome in
                        guard let self,
                              case .document(let prepared) = preparedOutcome,
                              let sourceAuthorization else { return false }
                        let renderRequest = BibleReaderDefinitionRenderRequest(
                            sourceRequest: sourceRequest,
                            initialDocumentJSON: prepared.documentJSON,
                            renderedBook: renderedBook,
                            renderedKey: renderedKey,
                            sourceAuthorization: sourceAuthorization,
                            preferredFamilyUpdates: prepared.preferredFamilyUpdates,
                            onAccepted: onAccepted
                        )
                        return self.dispatchTransientDocument(
                            self.transientDocumentRequest(for: renderRequest),
                            sendsLabels: false
                        )
                    },
                    commitAcceptedRender: { [weak self] preparedOutcome in
                        guard let self,
                              case .document(let prepared) = preparedOutcome,
                              let sourceAuthorization else { return }
                        let renderRequest = BibleReaderDefinitionRenderRequest(
                            sourceRequest: sourceRequest,
                            initialDocumentJSON: prepared.documentJSON,
                            renderedBook: renderedBook,
                            renderedKey: renderedKey,
                            sourceAuthorization: sourceAuthorization,
                            preferredFamilyUpdates: prepared.preferredFamilyUpdates,
                            onAccepted: onAccepted
                        )
                        self.commitTransientAcceptedRender(
                            self.transientDocumentRequest(for: renderRequest),
                            rebuildRequest: .definition(renderRequest.replayRequest)
                        )
                        prepared.preferredFamilyUpdates.forEach {
                            AndroidStrongsKeyPreferenceCache.shared.record(
                                $0.family,
                                moduleInitials: $0.moduleInitials
                            )
                        }
                        onAccepted?()
                    }
                )
            }
            if disposition == .stale(.requestFreshCurrent), retriesOneStaleResult {
                _ = self.prepareDefinitionDocument(
                    source: source,
                    stateJSON: stateJSON,
                    renderedBook: renderedBook,
                    renderedKey: renderedKey,
                    routesOutward: routesOutward,
                    onAccepted: onAccepted,
                    onNoResult: onNoResult,
                    retriesOneStaleResult: false
                )
            }
        }
        return true
    }

    /** Copies every setting that selects one definition source. */
    private func definitionPreferenceSnapshot() -> BibleReaderDefinitionPreferenceSnapshot {
        BibleReaderDefinitionPreferenceSnapshot(
            hebrewDictionaries: settingsStore?.getStringSet(.strongsHebrewDictionary) ?? [],
            greekDictionaries: settingsStore?.getStringSet(.strongsGreekDictionary) ?? [],
            robinsonDictionaries: settingsStore?.getStringSet(.robinsonGreekMorphology) ?? [],
            disabledWordLookupDictionaries: settingsStore?.getStringSet(
                .disabledWordLookupDictionaries
            ) ?? []
        )
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
     - Returns: `true` when the bridge accepts the complete replacement event sequence.
     - Side effects: clears the current Vue document, emits labels, emits the supplied document and
       setup payload, resets selection/editing flags, updates rendered-content accessibility state,
       emits active-window state, clears the web selection, and reapplies the reader background.
     - Failure modes: assumes `documentJSON` is valid JSON; invalid payloads are still forwarded
       after transient reader state is prepared.
     */
    @discardableResult
    private func loadTransientMultiDocument(
        _ documentJSON: String,
        renderedBook: String,
        renderedKey: String,
        renderedCategory: DocumentCategory = .bible,
        renderedModuleName: String? = nil,
        pageCategory: DocumentCategory? = nil,
        pageDocumentInitials: String? = nil,
        pageKey: String? = nil,
        sourceProvenance: BibleReaderRenderSourceProvenance? = nil,
        sourceAuthorization: BibleReaderRoutedSourceAuthorization,
        rebuildRequest: BibleReaderCompositeRebuildRequest? = nil
    ) -> Bool {
        let request = BibleReaderTransientDocumentRequest(
            documentJSON: documentJSON,
            renderedBook: renderedBook,
            renderedKey: renderedKey,
            renderedCategory: renderedCategory,
            renderedModuleName: renderedModuleName,
            pageCategory: pageCategory,
            pageDocumentInitials: pageDocumentInitials,
            pageKey: pageKey,
            sourceProvenance: sourceProvenance,
            sourceAuthorization: sourceAuthorization
        )
        return emitTransientMultiDocument(request, rebuildRequest: rebuildRequest)
    }

    /**
     Emits a transient Vue `MultiDocument` request to the current bridge.

     - Parameter request: Stored transient document request with payload and native display labels.
     - Returns: `true` when the bridge accepts the complete replacement event sequence.
     - Side effects: Emits labels and one Android-parity replacement transaction, resets transient
       selection/editing state, updates rendered-content state, emits active-window state, clears
       web selection, and reapplies the reader background.
     - Failure modes: Invalid JSON is forwarded unchanged to the bridge, matching the existing
       transient document contract.
     */
    @discardableResult
    private func emitTransientMultiDocument(
        _ request: BibleReaderTransientDocumentRequest,
        rebuildRequest: BibleReaderCompositeRebuildRequest? = nil
    ) -> Bool {
        _ = beginReplacingContentIntent()
        let destination = preparationPublicationOwner.captureDestination()
        let disposition = preparationPublicationOwner.publishQueuedBridge(
            BibleReaderDocumentPreparationOutcome.prepared(request),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .settle,
            isCurrent: { $0.sourceAuthorization.isCurrent() },
            selectedIntent: .init(
                commit: { [weak self] request in
                    self?.commitTransientSelectedIntent(request, rebuildRequest: rebuildRequest)
                },
                isCurrentAfterCommit: { $0.sourceAuthorization.isCurrent() }
            ),
            queueBridgePrerequisites: { [weak self] _ in self?.sendLabelsToVueJS() },
            isSourceCurrentAroundBridge: { $0.sourceAuthorization.isCurrent() },
            queueBridge: { [weak self] request in
                self?.dispatchTransientDocument(request, sendsLabels: false) == true
            },
            commitAcceptedRender: { [weak self] request in
                self?.commitTransientAcceptedRender(request, rebuildRequest: rebuildRequest)
            }
        )
        return disposition == .accepted
    }

    /** Creates the native transient destination identity for one prepared composite result. */
    private func transientDocumentRequest(
        for prepared: BibleReaderPreparedCompositeDocument,
        sourceRequest: BibleReaderCompositePreparationRequest,
        sourceAuthorization: BibleReaderRoutedSourceAuthorization
    ) -> BibleReaderTransientDocumentRequest {
        switch sourceRequest {
        case .multiReferences:
            return BibleReaderTransientDocumentRequest(
                documentJSON: prepared.documentJSON,
                renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
                renderedKey: prepared.renderedKey,
                renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
                renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
                pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
                pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
                pageKey: prepared.pageKey,
                sourceProvenance: prepared.sourceProvenance,
                sourceAuthorization: sourceAuthorization
            )
        case .restoredMulti:
            return BibleReaderTransientDocumentRequest(
                documentJSON: prepared.documentJSON,
                renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
                renderedKey: prepared.renderedKey,
                renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
                renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
                pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
                pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
                pageKey: prepared.pageKey,
                sourceProvenance: prepared.sourceProvenance,
                sourceAuthorization: sourceAuthorization
            )
        case .compare:
            return BibleReaderTransientDocumentRequest(
                documentJSON: prepared.documentJSON,
                renderedBook: "Compare",
                renderedKey: prepared.renderedKey,
                renderedCategory: .bible,
                renderedModuleName: nil,
                pageCategory: nil,
                pageDocumentInitials: nil,
                pageKey: nil,
                sourceProvenance: prepared.sourceProvenance,
                sourceAuthorization: sourceAuthorization
            )
        }
    }

    /** Creates Android's persisted `Multi` destination for a prepared definition result. */
    private func transientDocumentRequest(
        for request: BibleReaderDefinitionRenderRequest
    ) -> BibleReaderTransientDocumentRequest {
        BibleReaderTransientDocumentRequest(
            documentJSON: request.initialDocumentJSON,
            renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            renderedKey: request.renderedKey,
            renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(
                from: request.initialDocumentJSON
            ),
            sourceProvenance: .compositeMayUseSword,
            sourceAuthorization: request.sourceAuthorization
        )
    }

    /** Commits the selected fake-document identity and client-ready replay before bridge dispatch. */
    private func commitTransientSelectedIntent(
        _ request: BibleReaderTransientDocumentRequest,
        rebuildRequest: BibleReaderCompositeRebuildRequest?
    ) {
        activeCompositeRebuildRequest = rebuildRequest
        specialDocumentCoordinator.store(request, clientReady: clientReady)
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
        applyTransientPageIdentity(request)
    }

    /** Dispatches the immutable transient document without changing selected or rendered state. */
    private func dispatchTransientDocument(
        _ request: BibleReaderTransientDocumentRequest,
        sendsLabels: Bool = true
    ) -> Bool {
        if sendsLabels { sendLabelsToVueJS() }
        return replaceDocument(
            documentJSON: request.documentJSON,
            setup: ReaderSetupContentPayload()
        )
    }

    /** Commits transient rendered identity and presentation effects after bridge acceptance. */
    private func commitTransientAcceptedRender(
        _ request: BibleReaderTransientDocumentRequest,
        rebuildRequest: BibleReaderCompositeRebuildRequest?
    ) {
        setRenderedContentState(
            category: request.renderedCategory,
            moduleName: request.renderedModuleName ?? activeModuleName,
            book: request.renderedBook,
            key: request.renderedKey,
            sourceProvenance: request.sourceProvenance
                ?? (rebuildRequest == nil ? .independent : .compositeMayUseSword),
            preserveCompositeRebuildRequest: true
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
    private func loadCommentaryForCurrentVerse(retriesOneStaleResult: Bool = true) {
        let generation = beginReplacingContentIntent()
        commentaryNavigationAvailability = .empty
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()

    if let module = activeSQLiteCommentaryModule {
      loadSQLiteCommentaryForCurrentVerse(
        module: module,
        generation: generation,
        retriesOneStaleResult: retriesOneStaleResult
      )
      return
    }

        guard let module = activeCommentaryModule else {
            emitCommentaryErrorDocument(
                key: "\(osisBookId(for: currentBook)).\(currentChapter).\(max(1, currentVerse))",
                message: "No commentary module is installed. Download one from the module browser."
            )
            return
        }
        loadPreparedSwordCommentary(
            module: module,
            generation: generation,
            retriesOneStaleResult: retriesOneStaleResult
        )
    }

    /** Captures, annotates, encodes, and publishes one exact SWORD commentary block off-main. */
    private func loadPreparedSwordCommentary(
        module: SwordModule,
        generation: UInt64,
        retriesOneStaleResult: Bool
    ) {
        guard let manager = swordManager else { return }
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let sourceBookID = osisBookId(for: currentBook)
        let sourceChapter = currentChapter
        let sourceVerse = max(1, currentVerse)
        let sourceBookName = currentBook
        let sourceBibleModule = activeModule
        let sourceSQLiteBible = activeSQLiteBibleModule
        let commentaryInitials = module.info.name
        let managerGeneration = manager.contentAuthorizationGeneration
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let capturedBookList = moduleBookList
        let sourceNames = [commentaryInitials] + (sourceBibleModule.map { [$0.info.name] } ?? [])
        let destination = preparationPublicationOwner.captureDestination()
        let key = BibleReaderDocumentPreparationKey(
            family: "sword-commentary",
            paneID: paneID,
            workspaceID: workspaceID,
            source: .sword(
                manager: ObjectIdentifier(manager),
                module: ObjectIdentifier(module),
                initials: BibleReaderPreparationExactText(commentaryInitials),
                generation: managerGeneration,
                modules: sourceNames.map { BibleReaderPreparationExactText($0) }
            ),
            contentIdentity: BibleReaderPreparationExactText(
                "\(sourceBookID).\(sourceChapter).\(sourceVerse)"
            ),
            annotationIdentity: .exactText(BibleReaderPreparationExactText(commentaryInitials))
        )
        let baseAuthorization: () -> Bool = { [weak self, weak manager, weak module] in
            guard let self, let manager, let module else { return false }
            return self.contentIntentGeneration == generation
                && self.currentCategory == .commentary
                && self.activeCommentaryModule === module
                && self.activeSQLiteCommentaryModule == nil
                && self.activeModule === sourceBibleModule
                && self.activeSQLiteBibleModule === sourceSQLiteBible
                && SwordJavaStringIdentity.equals(self.currentBook, sourceBookName)
                && self.currentChapter == sourceChapter
                && max(1, self.currentVerse) == sourceVerse
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && self.swordManager === manager
                && manager.contentAuthorizationGeneration == managerGeneration
        }
        let annotationFactory = { () -> BibleReaderAnnotationPayloadFactory in
            BibleReaderAnnotationPayloadFactory(
                currentBook: sourceBookName,
                activeModuleName: sourceBibleModule?.info.name ?? "",
                activeModule: sourceBibleModule,
                sourceModuleResolver: { manager.readableModule(named: $0) },
                bookCatalog: BibleReaderBookCatalog(
                    activeModule: sourceBibleModule,
                    moduleBookList: capturedBookList
                ),
                unlabeledLabelID: Self.unlabeledLabelId
            )
        }
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { cancellation -> BibleReaderSwordCommentaryCapture? in
                manager.performRenderOperation(settings: optionSettings) { () -> BibleReaderSwordCommentaryCapture? in
                    guard !cancellation.isCancelled else { return nil }
                    let authorization = manager.contentAuthorizationSnapshot(for: sourceNames)
                    guard authorization.generation == managerGeneration,
                          authorization.modules.first?.accessState == .readable else { return nil }
                    guard !cancellation.isCancelled else { return nil }
                    let sourceVersification: String
                    if let sourceBibleModule {
                        sourceVersification = VersificationMapper.versificationName(
                            for: sourceBibleModule
                        )
                    } else if let sourceSQLiteBible {
                        sourceVersification = BibleReaderSQLiteSourceMetadata(
                            module: sourceSQLiteBible
                        ).versification
                    } else {
                        return nil
                    }
                    guard !cancellation.isCancelled else { return nil }
                    let commentaryVersification = VersificationMapper.versificationName(for: module)
                    let walker = SwordModuleCommentaryWalker(module: module)
                    guard !cancellation.isCancelled else { return nil }
                    guard let selected = BibleReaderCommentaryVersificationRouter.resolve(
                        reference: .init(
                            osisBookId: sourceBookID,
                            chapter: sourceChapter,
                            verse: sourceVerse
                        ),
                        from: sourceVersification,
                        to: commentaryVersification,
                        resolve: { mapped -> SwordCommentaryVerseReference? in
                            guard !cancellation.isCancelled else { return nil }
                            let resolved = try? walker.reference(
                                forKey: "\(mapped.osisBookId).\(mapped.chapter).\(mapped.verse)"
                            )
                            return cancellation.isCancelled ? nil : resolved
                        }
                    ) else { return nil }
                    guard !cancellation.isCancelled else { return nil }
                    let blockResolver = SwordCommentaryBlockResolver(
                        walker: walker,
                        cancellationRequested: { cancellation.isCancelled }
                    )
                    let block = blockResolver.resolveBlock(containing: selected)
                    guard !cancellation.isCancelled,
                          let fragment = block.fragment,
                          fragment.hasRenderableContent else { return nil }
                    let renderedKey = fragment.annotateRef ?? fragment.key
                    guard !cancellation.isCancelled else { return nil }
                    let renderedReference = try? walker.reference(forKey: renderedKey)
                    let mapToSource: (
                        SwordCommentaryVerseReference?,
                        String?
                    ) -> BibleReaderCommentaryNavigationTarget? = { target, renderedKey in
                        guard !cancellation.isCancelled, let target else { return nil }
                        return BibleReaderCommentaryVersificationRouter.resolve(
                            reference: .init(
                                osisBookId: target.osisBookId,
                                chapter: target.chapter,
                                verse: target.verse
                            ),
                            from: commentaryVersification,
                            to: sourceVersification,
                            resolve: { candidate in
                                guard !cancellation.isCancelled else { return nil }
                                let sourceOrdinal: Int
                                if let sourceBibleModule {
                                    guard let ordinal = sourceBibleModule.verseOrdinal(
                                        osisBookId: candidate.osisBookId,
                                        chapter: candidate.chapter,
                                        verse: candidate.verse
                                    ) else { return nil }
                                    sourceOrdinal = ordinal
                                } else if sourceSQLiteBible != nil {
                                    guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
                                        osisBookId: candidate.osisBookId,
                                        chapter: candidate.chapter,
                                        verse: candidate.verse
                                    ) else { return nil }
                                    sourceOrdinal = coordinate.ordinal
                                } else {
                                    return nil
                                }
                                return BibleReaderCommentaryNavigationTarget(
                                    key: renderedKey ?? target.osisRef,
                                    sourceReference: candidate,
                                    sourceOrdinal: sourceOrdinal
                                )
                            }
                        )
                    }
                    let current = mapToSource(renderedReference, renderedKey)
                    guard !cancellation.isCancelled else { return nil }
                    let previous = mapToSource(
                        blockResolver.previousBlockStart(before: block.range.start),
                        nil
                    )
                    guard !cancellation.isCancelled else { return nil }
                    let next = mapToSource(
                        blockResolver.nextBlockStart(after: block.range.end),
                        nil
                    )
                    guard !cancellation.isCancelled else { return nil }
                    return BibleReaderSwordCommentaryCapture(
                        fragment: fragment,
                        renderedBook: selected.name,
                        renderedChapter: selected.chapter,
                        commentaryRange: ReaderCommentaryRangePayload(
                            startOsisRef: block.range.start.osisRef,
                            endOsisRef: block.range.end.osisRef,
                            name: block.range.name
                        ),
                        navigation: BibleReaderCommentaryNavigationAvailability(
                            current: current,
                            previous: previous,
                            next: next
                        )
                    )
                }
            },
            project: { (capture: BibleReaderSwordCommentaryCapture) in capture },
            captureOwner: { [weak self]
                (capture: BibleReaderSwordCommentaryCapture)
                    -> BibleReaderGenericDocumentOwnerSnapshot? in
                self?.genericDocumentOwnerSnapshot(
                    bookInitials: capture.fragment.source.initials,
                    key: capture.fragment.annotateRef ?? capture.fragment.key
                )
            },
            enrichSource: {
                (capture: BibleReaderSwordCommentaryCapture,
                 owner: BibleReaderGenericDocumentOwnerSnapshot)
                    -> BibleReaderGenericAnnotationSourceEnrichment? in
                let requestedNames = [commentaryInitials]
                    + owner.genericBookmarkInputs.map(\.sourceBookInitials)
                return manager.performRenderOperation(settings: optionSettings) {
                    let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
                    guard authorization.generation == managerGeneration,
                          authorization.modules.first?.accessState == .readable else { return nil }
                    let factory = annotationFactory()
                    let sources = owner.genericBookmarkInputs.map {
                        factory.captureGenericBookmarkSource(for: $0)
                    }
                    return BibleReaderGenericAnnotationSourceEnrichment(
                        capturedSources: sources,
                        authorization: authorization
                    )
                }
            },
            encode: {
                (capture: BibleReaderSwordCommentaryCapture,
                 owner: BibleReaderGenericDocumentOwnerSnapshot,
                 enrichment: BibleReaderGenericAnnotationSourceEnrichment)
                    -> BibleReaderPreparedCommentaryDocument? in
                let factory = annotationFactory()
                let bookmarks = zip(owner.genericBookmarkInputs, enrichment.capturedSources).map {
                    factory.genericBookmarkJSONForStudyPad($0.0, capturedSource: $0.1)
                }
                guard let json = owner.payload(
                    fragment: capture.fragment,
                    osisBookId: sourceBookID,
                    bookCategory: DocumentCategory.commentary.rawValue,
                    renderedGenericBookmarks: bookmarks,
                    commentaryRange: capture.commentaryRange
                ).encodedJSON() else { return nil }
                return BibleReaderPreparedCommentaryDocument(
                    auxiliary: .document(
                        json: json,
                        sourceInitials: capture.fragment.source.initials,
                        key: capture.fragment.key,
                        keyName: capture.renderedBook,
                        sourceProvenance: .swordModules([capture.fragment.source.initials]),
                        ownerIdentity: owner.identity,
                        sourceDependencies: [
                            .sword(
                                manager: ObjectIdentifier(manager),
                                authorization: enrichment.authorization
                            ),
                        ]
                    ),
                    annotationOwnerKey: capture.fragment.annotateRef ?? capture.fragment.key,
                    renderedChapter: capture.renderedChapter,
                    navigation: capture.navigation
                )
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            self?.publishPreparedCommentary(
                outcome,
                destination: destination,
                requestedKey: "\(sourceBookID).\(sourceChapter).\(sourceVerse)",
                retriesOneStaleResult: retriesOneStaleResult
            )
        }
    }

  /**
   Emits covering SQLite commentary for the selected KJVA verse.

   - Parameter module: Serialized active commentary handle.
   - Side effects: Performs one covering lookup, replaces Vue content, and updates rendered state.
   - Failure modes: Missing rows, reader errors, malformed markup, and serialization failure use
     the deterministic no-content error path; no SWORD or placeholder content is substituted.
   */
  private func loadSQLiteCommentaryForCurrentVerse(
    module: BibleReaderSQLiteModuleHandle,
    generation: UInt64,
    retriesOneStaleResult: Bool
  ) {
    let paneID = activeWindow?.id
    let workspaceID = activeWindow?.workspace?.id
    let sourceBookName = currentBook
    let sourceReference = SwordVersification.Reference(
      osisBookId: osisBookId(for: sourceBookName),
      chapter: currentChapter,
      verse: max(1, currentVerse)
    )
    let sourceKey =
      "\(sourceReference.osisBookId).\(sourceReference.chapter).\(sourceReference.verse)"
    let sourceSwordBible = activeModule
    let sourceSQLiteBible = activeSQLiteBibleModule
    let manager = swordManager
    let managerGeneration = manager?.contentAuthorizationGeneration
    let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
    let initials = module.info.name
    let destination = preparationPublicationOwner.captureDestination()
    let dependency = BibleReaderPreparationSourceDependency.sqlite(
      module: ObjectIdentifier(module),
      initials: BibleReaderPreparationExactText(initials)
    )
    let preparationKey = BibleReaderDocumentPreparationKey(
      family: "sqlite-commentary",
      paneID: paneID,
      workspaceID: workspaceID,
      source: .sqlite(
        module: ObjectIdentifier(module),
        initials: BibleReaderPreparationExactText(initials)
      ),
      contentIdentity: BibleReaderPreparationExactText(sourceKey),
      annotationIdentity: .exactText(BibleReaderPreparationExactText(initials))
    )
    let baseAuthorization: () -> Bool = { [weak self, weak module, weak manager] in
      guard let self, let module else { return false }
      let managerIsCurrent = manager.map {
        self.swordManager === $0 && $0.contentAuthorizationGeneration == managerGeneration
      } ?? (self.swordManager == nil)
      return self.contentIntentGeneration == generation
        && self.currentCategory == .commentary
        && self.activeSQLiteCommentaryModule === module
        && self.activeCommentaryModule == nil
        && self.activeModule === sourceSwordBible
        && self.activeSQLiteBibleModule === sourceSQLiteBible
        && SwordJavaStringIdentity.equals(self.currentBook, sourceBookName)
        && self.currentChapter == sourceReference.chapter
        && max(1, self.currentVerse) == sourceReference.verse
        && self.activeWindow?.id == paneID
        && self.activeWindow?.workspace?.id == workspaceID
        && managerIsCurrent
    }
    let factory = persistenceAnnotationPayloadFactory()
    documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
      scope: .replacement,
      key: preparationKey,
      captureSource: { _ -> BibleReaderSQLiteCommentaryCapture? in
        let read: () -> BibleReaderSQLiteCommentaryCapture? = {
          let sourceVersification: String
          if let sourceSwordBible {
            sourceVersification = VersificationMapper.versificationName(for: sourceSwordBible)
          } else if let sourceSQLiteBible {
            sourceVersification = BibleReaderSQLiteSourceMetadata(
              module: sourceSQLiteBible
            ).versification
          } else {
            return nil
          }
          guard let selected = SQLiteCommentaryReferenceRouter.kjvaReference(
            for: sourceReference,
            sourceVersification: sourceVersification
          ), let selectedBook = JSwordKJVAVersification.books.first(where: {
            $0.osisId == selected.osisId
          }) else { return nil }
          do {
            let navigator = SQLiteCommentaryBlockNavigator(module: module)
            let mapToSource: (
              JSwordKJVAVerseReference?,
              String?
            ) -> BibleReaderCommentaryNavigationTarget? = { target, renderedKey in
              guard let target else { return nil }
              return SQLiteCommentaryReferenceRouter.sourceReference(
                for: target,
                destinationVersification: sourceVersification,
                resolve: { candidate in
                  let sourceOrdinal: Int
                  if let sourceSwordBible {
                    guard let ordinal = sourceSwordBible.verseOrdinal(
                      osisBookId: candidate.osisBookId,
                      chapter: candidate.chapter,
                      verse: candidate.verse
                    ) else { return nil }
                    sourceOrdinal = ordinal
                  } else if sourceSQLiteBible != nil {
                    guard let coordinate = SQLiteReaderNavigationResolver.coordinate(
                      osisBookId: candidate.osisBookId,
                      chapter: candidate.chapter,
                      verse: candidate.verse
                    ) else { return nil }
                    sourceOrdinal = coordinate.ordinal
                  } else {
                    return nil
                  }
                  return BibleReaderCommentaryNavigationTarget(
                    key: renderedKey
                      ?? "\(target.osisId).\(target.chapter).\(target.verse)",
                    sourceReference: candidate,
                    sourceOrdinal: sourceOrdinal
                  )
                }
              )
            }
            let document = try SQLiteReaderDocumentContentBuilder(module: module).commentary(
              osisBookId: selected.osisId,
              bookName: selectedBook.longName,
              chapter: selected.chapter,
              verse: selected.verse,
              isNewTestament: selectedBook.isNewTestament
            )
            let fragment = try BibleReaderBookmarkNavigationSQLiteFragment(
              document: document,
              module: module
            )
            let renderedKey = fragment.renderedDocumentOsisReference
            let renderedCoordinate = SQLiteReaderNavigationResolver.commentaryCoordinate(
              for: renderedKey
            )
            let renderedReference = renderedCoordinate.map {
              JSwordKJVAVerseReference(
                osisId: $0.osisBookId,
                chapter: $0.chapter,
                verse: $0.verse,
                ordinal: $0.ordinal
              )
            }
            var dependencies = [dependency]
            if let sourceSQLiteBible {
              dependencies.append(.sqlite(
                module: ObjectIdentifier(sourceSQLiteBible),
                initials: BibleReaderPreparationExactText(sourceSQLiteBible.info.name)
              ))
            }
            if let manager {
              let names = sourceSwordBible.map { [$0.info.name] } ?? []
              dependencies.append(.sword(
                manager: ObjectIdentifier(manager),
                authorization: manager.contentAuthorizationSnapshot(for: names)
              ))
            }
            return BibleReaderSQLiteCommentaryCapture(
              fragment: fragment,
              renderedBook: selectedBook.longName,
              renderedChapter: selected.chapter,
              sourceDependencies: dependencies,
              navigation: BibleReaderCommentaryNavigationAvailability(
                current: mapToSource(
                  renderedReference,
                  renderedKey
                ),
                previous: mapToSource(
                  navigator.adjacentBlockStart(
                    osisId: selected.osisId,
                    chapter: selected.chapter,
                    verse: selected.verse,
                    forward: false
                  ),
                  nil
                ),
                next: mapToSource(
                  navigator.adjacentBlockStart(
                    osisId: selected.osisId,
                    chapter: selected.chapter,
                    verse: selected.verse,
                    forward: true
                  ),
                  nil
                )
              )
            )
          } catch {
            return nil
          }
        }
        if let manager {
          return manager.performRenderOperation(settings: optionSettings, read)
        }
        return read()
      },
      project: { (capture: BibleReaderSQLiteCommentaryCapture) in capture },
      captureOwner: { [weak self]
        (capture: BibleReaderSQLiteCommentaryCapture)
          -> BibleReaderGenericDocumentOwnerSnapshot? in
        self?.genericDocumentOwnerSnapshot(
          bookInitials: initials,
          key: capture.fragment.renderedDocumentOsisReference
        )
      },
      enrichSource: {
        (capture: BibleReaderSQLiteCommentaryCapture,
         owner: BibleReaderGenericDocumentOwnerSnapshot) -> [GenericBookmarkData]? in
        let sourceContent = Self.sqliteGenericBookmarkSourceContent(capture.fragment)
        return owner.genericBookmarkInputs.map { input in
          let captured = factory.captureGenericBookmarkSource(for: input, source: sourceContent)
          return factory.genericBookmarkJSONForStudyPad(input, capturedSource: captured)
        }
      },
      encode: {
        (capture: BibleReaderSQLiteCommentaryCapture,
         owner: BibleReaderGenericDocumentOwnerSnapshot,
         bookmarks: [GenericBookmarkData]) -> BibleReaderPreparedCommentaryDocument? in
        guard let json = owner.payload(
          request: capture.fragment.payloadRequest(selectedOrdinalRange: nil),
          renderedGenericBookmarks: bookmarks
        ).encodedJSON() else { return nil }
        return BibleReaderPreparedCommentaryDocument(
          auxiliary: .document(
            json: json,
            sourceInitials: initials,
            key: capture.fragment.key,
            keyName: capture.renderedBook,
            sourceProvenance: .sqliteModules([initials]),
            ownerIdentity: owner.identity,
            sourceDependencies: capture.sourceDependencies
          ),
          annotationOwnerKey: capture.fragment.renderedDocumentOsisReference,
          renderedChapter: capture.renderedChapter,
          navigation: capture.navigation
        )
      },
      isAuthorized: baseAuthorization
    ) { [weak self] outcome in
      self?.publishPreparedCommentary(
        outcome,
        destination: destination,
        requestedKey: sourceKey,
        retriesOneStaleResult: retriesOneStaleResult
      )
    }
  }

    /**
     Applies the common commentary destination transaction to either native source family.

     Source and annotation invalidation may request one fresh current capture. Destination
     supersession and cancellation settle without changing selection or rendered state.
     */
    private func publishPreparedCommentary(
        _ outcome: BibleReaderDocumentPreparationOutcome<BibleReaderPreparedCommentaryDocument>,
        destination: BibleReaderPreparationDestination,
        requestedKey: String,
        retriesOneStaleResult: Bool
    ) {
        let disposition = preparationPublicationOwner.publishQueuedBridge(
            outcome,
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .requestFreshCurrent,
            isCurrent: { [weak self] prepared in
                guard let self,
                      case .document(
                        _, let initials, _, _, _, let ownerIdentity, let dependencies
                      ) = prepared.auxiliary else { return false }
                return self.sourceDependenciesAreCurrent(dependencies)
                    && self.genericDocumentOwnerSnapshot(
                        bookInitials: initials,
                        key: prepared.annotationOwnerKey
                    ).identity == ownerIdentity
            },
            queueBridgePrerequisites: { [weak self] _ in
                self?.sendLabelsToVueJS()
            },
            isSourceCurrentAroundBridge: { [weak self] prepared in
                guard let self,
                      case .document(
                        _, _, _, _, _, _, let dependencies
                      ) = prepared.auxiliary else { return false }
                return self.sourceDependenciesAreCurrent(dependencies)
            },
            queueBridge: { [weak self] prepared in
                guard let self,
                      case .document(let json, _, _, _, _, _, _) = prepared.auxiliary else {
                    return false
                }
                return self.replaceDocument(
                    documentJSON: json,
                    setup: ReaderSetupContentPayload()
                )
            },
            commitAcceptedRender: { [weak self] prepared in
                guard let self,
                      case .document(
                        _, let initials, let key, let renderedBook, let provenance, _, _
                      ) = prepared.auxiliary else { return }
                self.setRenderedContentState(
                    category: .commentary,
                    moduleName: initials,
                    book: renderedBook,
                    chapter: prepared.renderedChapter,
                    key: key,
                    sourceProvenance: provenance
                )
                self.commentaryNavigationAvailability = prepared.navigation
                self.emitActiveState()
                self.bridge.clearSelection()
                self.applyNightModeBackground()
            }
        )
        switch disposition {
        case .failed(.settle):
            emitCommentaryErrorDocument(
                key: requestedKey,
                message: String(
                    localized: "error_no_content",
                    defaultValue: "No content for selected verse"
                )
            )
        case .stale(.requestFreshCurrent) where retriesOneStaleResult:
            loadCommentaryForCurrentVerse(retriesOneStaleResult: false)
        case .accepted, .bridgeRejected, .dispatchedStale, .cancelled,
             .failed(.requestFreshCurrent), .stale(.settle), .stale(.requestFreshCurrent):
            break
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
        guard replaceDocument(
            documentJSON: document,
            setup: ReaderSetupContentPayload()
        ) else { return }
        setRenderedContentState(
            category: .commentary,
            moduleName: activeCommentaryModuleName,
            book: currentBook,
            chapter: currentChapter,
            key: key,
            sourceProvenance: .independent
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
            setRenderedContentState: { [self] category, moduleName, book, key, sourceProvenance in
                setRenderedContentState(
                    category: category,
                    moduleName: moduleName,
                    book: book,
                    key: key,
                    sourceProvenance: sourceProvenance
                )
            },
            applyNightModeBackground: { [self] in
                applyNightModeBackground()
            }
        )
    }

    /** Builds one serialized SWORD entry/annotation capture without touching controller state. */
    private func auxiliarySourcePreparation(
        module: SwordModule,
        moduleName: String,
        entryKey: String,
        noContentNoun: String
    ) -> BibleReaderAuxiliarySourcePreparation? {
        guard let manager = swordManager else { return nil }
        let generation = manager.contentAuthorizationGeneration
        let settings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        return BibleReaderAuxiliarySourcePreparation(
            identity: .sword(
                manager: ObjectIdentifier(manager),
                module: ObjectIdentifier(module),
                initials: BibleReaderPreparationExactText(moduleName),
                generation: generation,
                modules: [BibleReaderPreparationExactText(moduleName)]
            ),
            capture: {
                manager.performRenderOperation(settings: settings) {
                    let authorization = manager.contentAuthorizationSnapshot(for: [moduleName])
                    guard authorization.generation == generation,
                          authorization.modules.first?.accessState == .readable else { return nil }
                    do {
                        let fragment = try module.rawOSISFragment(forKey: entryKey)
                        return fragment.hasRenderableContent
                            ? .fragment(fragment)
                            : .failure(
                                "No \(noContentNoun) available for \"\(entryKey)\" in \(moduleName)."
                            )
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            },
            enrichAnnotations: { bookmarkInputs in
                manager.performRenderOperation(settings: settings) {
                    let requestedNames = [moduleName] + bookmarkInputs.map(\.sourceBookInitials)
                    let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
                    guard authorization.generation == generation,
                          authorization.modules.first?.accessState == .readable else { return nil }
                    let factory = BibleReaderAnnotationPayloadFactory(
                        currentBook: "",
                        activeModuleName: moduleName,
                        activeModule: module,
                        sourceModuleResolver: { manager.readableModule(named: $0) },
                        bookCatalog: BibleReaderBookCatalog(
                            activeModule: nil,
                            moduleBookList: []
                        ),
                        unlabeledLabelID: Self.unlabeledLabelId
                    )
                    let capturedSources = bookmarkInputs.map {
                        factory.captureGenericBookmarkSource(for: $0)
                    }
                    let bookmarks = zip(bookmarkInputs, capturedSources).map {
                        factory.genericBookmarkJSONForStudyPad($0.0, capturedSource: $0.1)
                    }
                    return (
                        bookmarks,
                        [.sword(manager: ObjectIdentifier(manager), authorization: authorization)]
                    )
                }
            },
            isCurrent: { [weak self, weak manager] in
                guard let self, let manager else { return false }
                return self.swordManager === manager
                    && manager.contentAuthorizationGeneration == generation
            }
        )
    }

    /** Prepares one SWORD dictionary/general-book/map document and commits only current output. */
    private func loadPreparedAuxiliaryModuleEntry(
        request: BibleReaderAuxiliaryModuleEntryRequest,
        generation: UInt64,
        isSelectedSource: @escaping () -> Bool,
        retriesOneStaleResult: Bool = true,
        selectionSettlement: (() -> Void)? = nil
    ) {
        resetAuxiliaryContentState()
        let unavailableLoader = auxiliaryContentLoader()
        guard let module = request.module else {
            unavailableLoader.publishUnavailableModuleEntry(
                request,
                message: request.noModuleMessage
            )
            selectionSettlement?()
            return
        }
        guard let entryKey = request.requestedKey ?? request.currentKey else {
            unavailableLoader.publishUnavailableModuleEntry(
                request,
                message: request.noSelectionMessage
            )
            selectionSettlement?()
            return
        }
        guard let moduleName = request.moduleName,
              let sourcePreparation = auxiliarySourcePreparation(
                module: module,
                moduleName: moduleName,
                entryKey: entryKey,
                noContentNoun: request.noContentNoun
              ) else {
            unavailableLoader.publishUnavailableModuleEntry(
                request,
                message: "No \(request.noContentNoun) available for \"\(entryKey)\"."
            )
            selectionSettlement?()
            return
        }
        let destination = preparationPublicationOwner.captureDestination()
        let paneID = destination.paneID
        let workspaceID = destination.workspaceID
        let key = BibleReaderDocumentPreparationKey(
            family: BibleReaderPreparationExactText("auxiliary-\(request.category.rawValue)"),
            paneID: paneID,
            workspaceID: workspaceID,
            source: sourcePreparation.identity,
            contentIdentity: BibleReaderPreparationExactText(entryKey),
            annotationIdentity: .exactText(BibleReaderPreparationExactText(entryKey))
        )
        let baseAuthorization: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.contentIntentGeneration == generation
                && self.currentCategory == request.category
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && isSelectedSource()
                && sourcePreparation.isCurrent()
        }
        let osisBookID = request.osisBookId
        let bookCategory = request.bookCategory
        let enrichAnnotations = sourcePreparation.enrichAnnotations
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in sourcePreparation.capture() },
            project: { (capture: BibleReaderAuxiliarySourceCapture) in capture },
            captureOwner: { [weak self]
                (capture: BibleReaderAuxiliarySourceCapture) -> BibleReaderAuxiliaryOwnerSnapshot? in
                switch capture {
                case .failure:
                    return .failure
                case .fragment(let fragment):
                    return self.map {
                        .document(
                            $0.genericDocumentOwnerSnapshot(
                                bookInitials: fragment.source.initials,
                                key: fragment.annotateRef ?? fragment.key
                            )
                        )
                    }
                }
            },
            enrichSource: {
                (capture: BibleReaderAuxiliarySourceCapture,
                 owner: BibleReaderAuxiliaryOwnerSnapshot)
                    -> BibleReaderPreparedGenericAnnotationEnrichment? in
                switch (capture, owner) {
                case (.failure, .failure):
                    return BibleReaderPreparedGenericAnnotationEnrichment(
                        bookmarks: [],
                        sourceDependencies: [.independent]
                    )
                case (.fragment, .document(let snapshot)):
                    guard let annotations = enrichAnnotations(snapshot.genericBookmarkInputs) else {
                        return nil
                    }
                    return BibleReaderPreparedGenericAnnotationEnrichment(
                        bookmarks: annotations.0,
                        sourceDependencies: annotations.1
                    )
                default:
                    return nil
                }
            },
            encode: {
                (capture: BibleReaderAuxiliarySourceCapture,
                 owner: BibleReaderAuxiliaryOwnerSnapshot,
                 enrichment: BibleReaderPreparedGenericAnnotationEnrichment)
                    -> BibleReaderPreparedAuxiliaryResult? in
                switch (capture, owner) {
                case (.failure(let message), .failure):
                    return .failure(message)
                case (.fragment(let fragment), .document(let snapshot)):
                    guard let json = snapshot.payload(
                            fragment: fragment,
                            osisBookId: osisBookID,
                            bookCategory: bookCategory,
                            renderedGenericBookmarks: enrichment.bookmarks
                          ).encodedJSON() else { return nil }
                    return .document(
                        json: json,
                        sourceInitials: fragment.source.initials,
                        key: fragment.key,
                        keyName: fragment.keyName,
                        sourceProvenance: .swordModules([fragment.source.initials]),
                        ownerIdentity: snapshot.identity,
                        sourceDependencies: enrichment.sourceDependencies
                    )
                default:
                    return nil
                }
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else {
                selectionSettlement?()
                return
            }
            let loader = self.auxiliaryContentLoader()
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: .settle,
                stalePolicy: retriesOneStaleResult ? .requestFreshCurrent : .settle,
                isCurrent: { prepared in
                    guard baseAuthorization() else { return false }
                    guard case .document(
                        _, let sourceInitials, let resolvedKey, _, _, let ownerIdentity,
                        let dependencies
                    ) = prepared else { return true }
                    return self.sourceDependenciesAreCurrent(dependencies)
                        && self.genericDocumentOwnerSnapshot(
                            bookInitials: sourceInitials,
                            key: resolvedKey
                        ).identity == ownerIdentity
                },
                selectedIntent: .init(
                    commit: { prepared in
                        loader.commitPreparedSelection(prepared, request: request)
                    },
                    isCurrentAfterCommit: { prepared in
                        guard baseAuthorization() else { return false }
                        guard case .document(
                            _, let sourceInitials, let resolvedKey, _, _, let ownerIdentity,
                            let dependencies
                        ) = prepared else { return true }
                        return self.sourceDependenciesAreCurrent(dependencies)
                            && self.genericDocumentOwnerSnapshot(
                                bookInitials: sourceInitials,
                                key: resolvedKey
                            ).identity == ownerIdentity
                    }
                ),
                queueBridgePrerequisites: { prepared in
                    if case .document = prepared { self.sendLabelsToVueJS() }
                },
                isSourceCurrentAroundBridge: { prepared in
                    guard case .document(
                        _, _, _, _, _, _, let dependencies
                    ) = prepared else { return true }
                    return self.sourceDependenciesAreCurrent(dependencies)
                },
                queueBridge: { prepared in
                    return loader.dispatchPreparedModuleEntry(prepared, request: request)
                },
                commitAcceptedRender: { prepared in
                    loader.commitPreparedRender(prepared, request: request)
                }
            )
            if disposition == .stale(.requestFreshCurrent) {
                self.loadPreparedAuxiliaryModuleEntry(
                    request: request,
                    generation: self.beginReplacingContentIntent(cancelPreparedWork: false),
                    isSelectedSource: isSelectedSource,
                    retriesOneStaleResult: false,
                    selectionSettlement: selectionSettlement
                )
                return
            }
            selectionSettlement?()
        }
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
        prepareDictionaryEntry(key: key)
    }

    /** Waits until the requested dictionary key either commits or settles without selection. */
    @MainActor
    func loadDictionaryEntryAwaitingSelection(key: String) async {
        await awaitPreparationSelectionSettlement { completion in
            self.prepareDictionaryEntry(key: key, selectionSettlement: completion)
        }
    }

    /** Routes one dictionary request to its active backend with an optional causal settlement. */
    private func prepareDictionaryEntry(
        key: String?,
        selectionSettlement: (() -> Void)? = nil
    ) {
        let generation = beginReplacingContentIntent()
        if let module = activeSQLiteDictionaryModule {
            loadSQLiteDictionaryEntry(
                module: module,
                requestedKey: key,
                selectionSettlement: selectionSettlement
            )
            return
        }
        let module = activeDictionaryModule
        let request = BibleReaderAuxiliaryModuleEntryRequest(
                category: .dictionary,
                module: module,
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
        loadPreparedAuxiliaryModuleEntry(
            request: request,
            generation: generation,
            isSelectedSource: { [weak self, weak module] in
                guard let self else { return false }
                return self.activeDictionaryModule === module
                    && self.activeSQLiteDictionaryModule == nil
            },
            selectionSettlement: selectionSettlement
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
    requestedKey: String?,
    retriesOneStaleResult: Bool = true,
    selectionSettlement: (() -> Void)? = nil
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
      selectionSettlement?()
      return
    }
    let generation = contentIntentGeneration
    let destination = preparationPublicationOwner.captureDestination()
    let paneID = destination.paneID
    let workspaceID = destination.workspaceID
    let initials = module.info.name
    let dependency = BibleReaderPreparationSourceDependency.sqlite(
      module: ObjectIdentifier(module),
      initials: BibleReaderPreparationExactText(initials)
    )
    let preparationKey = BibleReaderDocumentPreparationKey(
      family: "sqlite-dictionary",
      paneID: paneID,
      workspaceID: workspaceID,
      source: .sqlite(
        module: ObjectIdentifier(module),
        initials: BibleReaderPreparationExactText(initials)
      ),
      contentIdentity: BibleReaderPreparationExactText(key),
      annotationIdentity: .exactText(BibleReaderPreparationExactText(key))
    )
    let baseAuthorization: () -> Bool = { [weak self, weak module] in
      guard let self, let module else { return false }
      return self.contentIntentGeneration == generation
        && self.activeSQLiteDictionaryModule === module
        && self.activeDictionaryModule == nil
        && self.activeWindow?.id == paneID
        && self.activeWindow?.workspace?.id == workspaceID
    }
    let factory = persistenceAnnotationPayloadFactory()
    let publicationRequest = BibleReaderAuxiliaryModuleEntryRequest(
      category: .dictionary,
      module: nil,
      moduleName: initials,
      requestedKey: key,
      currentKey: currentDictionaryKey,
      osisBookId: "Dict",
      fallbackBookName: "Dictionary",
      bookCategory: DocumentCategory.dictionary.rawValue,
      noModuleMessage: "No dictionary module is selected.",
      noSelectionMessage: "Select an entry from the key browser to view its definition.",
      noContentNoun: "definition",
      persistResolvedKey: { [weak self] resolvedKey in
        guard let self else { return }
        self.currentDictionaryKey = resolvedKey
        if let pageManager = self.activeWindow?.pageManager {
          pageManager.dictionaryKey = resolvedKey
          self.onPersistState?()
        }
      }
    )
    documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
      scope: .replacement,
      key: preparationKey,
      captureSource: { _ -> BibleReaderSQLiteAuxiliaryCapture? in
        do {
          let document = try SQLiteReaderDocumentContentBuilder(module: module).dictionary(key: key)
          return .fragment(
            try BibleReaderBookmarkNavigationSQLiteFragment(
              document: document,
              module: module
            )
          )
        } catch {
          return .failure("No definition available for \"\(key)\" in \(initials).")
        }
      },
      project: { (source: BibleReaderSQLiteAuxiliaryCapture) in source },
      captureOwner: { [weak self]
        (source: BibleReaderSQLiteAuxiliaryCapture) -> BibleReaderAuxiliaryOwnerSnapshot? in
        switch source {
        case .failure:
          return .failure
        case .fragment(let fragment):
          return self.map {
            .document(
              $0.genericDocumentOwnerSnapshot(
                bookInitials: initials,
                key: fragment.key
              )
            )
          }
        }
      },
      enrichSource: {
        (source: BibleReaderSQLiteAuxiliaryCapture,
         owner: BibleReaderAuxiliaryOwnerSnapshot)
          -> BibleReaderPreparedGenericAnnotationEnrichment? in
        switch (source, owner) {
        case (.failure, .failure):
          return BibleReaderPreparedGenericAnnotationEnrichment(
            bookmarks: [],
            sourceDependencies: [.independent]
          )
        case (.fragment(let fragment), .document(let snapshot)):
          let sourceContent = Self.sqliteGenericBookmarkSourceContent(fragment)
          let bookmarks = snapshot.genericBookmarkInputs.map { input in
            let captured = factory.captureGenericBookmarkSource(for: input, source: sourceContent)
            return factory.genericBookmarkJSONForStudyPad(input, capturedSource: captured)
          }
          return BibleReaderPreparedGenericAnnotationEnrichment(
            bookmarks: bookmarks,
            sourceDependencies: [dependency]
          )
        default:
          return nil
        }
      },
      encode: {
        (source: BibleReaderSQLiteAuxiliaryCapture,
         owner: BibleReaderAuxiliaryOwnerSnapshot,
         enrichment: BibleReaderPreparedGenericAnnotationEnrichment)
          -> BibleReaderPreparedAuxiliaryResult? in
        switch (source, owner) {
        case (.failure(let message), .failure):
          return .failure(message)
        case (.fragment(let fragment), .document(let snapshot)):
          guard let json = snapshot.payload(
            request: fragment.payloadRequest(selectedOrdinalRange: nil),
            renderedGenericBookmarks: enrichment.bookmarks
          ).encodedJSON() else { return nil }
          return .document(
            json: json,
            sourceInitials: initials,
            key: fragment.key,
            keyName: fragment.keyName,
            sourceProvenance: .sqliteModules([initials]),
            ownerIdentity: snapshot.identity,
            sourceDependencies: enrichment.sourceDependencies
          )
        default:
          return nil
        }
      },
      isAuthorized: baseAuthorization
    ) { [weak self] outcome in
      guard let self else {
        selectionSettlement?()
        return
      }
      let loader = self.auxiliaryContentLoader()
      let disposition = self.preparationPublicationOwner.publishQueuedBridge(
        outcome,
        destination: destination,
        failurePolicy: .settle,
        stalePolicy: retriesOneStaleResult ? .requestFreshCurrent : .settle,
        isCurrent: { prepared in
          guard baseAuthorization() else { return false }
          guard case .document(
            _, _, let resolvedKey, _, _, let ownerIdentity, let dependencies
          ) = prepared else { return true }
          return self.sourceDependenciesAreCurrent(dependencies)
            && self.genericDocumentOwnerSnapshot(
              bookInitials: initials,
              key: resolvedKey
            ).identity == ownerIdentity
        },
        selectedIntent: .init(
          commit: { prepared in
            loader.commitPreparedSelection(prepared, request: publicationRequest)
          },
          isCurrentAfterCommit: { prepared in
            guard baseAuthorization() else { return false }
            guard case .document(
              _, _, let resolvedKey, _, _, let ownerIdentity, let dependencies
            ) = prepared else { return true }
            return self.sourceDependenciesAreCurrent(dependencies)
              && self.genericDocumentOwnerSnapshot(
                bookInitials: initials,
                key: resolvedKey
              ).identity == ownerIdentity
          }
        ),
        queueBridgePrerequisites: { prepared in
          if case .document = prepared { self.sendLabelsToVueJS() }
        },
        isSourceCurrentAroundBridge: { prepared in
          guard case .document(
            _, _, _, _, _, _, let dependencies
          ) = prepared else { return true }
          return self.sourceDependenciesAreCurrent(dependencies)
        },
        queueBridge: { prepared in
          guard self.currentCategory == .dictionary else { return false }
          return loader.dispatchPreparedModuleEntry(prepared, request: publicationRequest)
        },
        commitAcceptedRender: { prepared in
          loader.commitPreparedRender(prepared, request: publicationRequest)
        }
      )
      if disposition == .stale(.requestFreshCurrent) {
        self.loadSQLiteDictionaryEntry(
          module: module,
          requestedKey: key,
          retriesOneStaleResult: false,
          selectionSettlement: selectionSettlement
        )
        return
      }
      selectionSettlement?()
    }
  }

  /** Builds generic annotation context from one detached exact SQLite auxiliary fragment. */
  private static func sqliteGenericBookmarkSourceContent(
    _ fragment: BibleReaderBookmarkNavigationSQLiteFragment
  ) -> GenericBookmarkSourceContent {
    GenericBookmarkSourceContent(
      bookName: fragment.moduleName ?? fragment.moduleInitials,
      bookAbbreviation: fragment.moduleAbbreviation ?? fragment.moduleInitials,
      keyName: fragment.keyName,
      plainText: GenericBookmarkSourceTextProjection.xhtmlText(fragment.xml),
      osisFragment: OsisFragment(
        xml: fragment.xml,
        key: fragment.fragmentKey ?? "\(fragment.moduleInitials)--\(fragment.key)",
        keyName: fragment.keyName,
        v11n: fragment.versificationName,
        bookCategory: fragment.category == .commentary
          ? DocumentCategory.commentary.rawValue
          : DocumentCategory.dictionary.rawValue,
        bookInitials: fragment.moduleInitials,
        bookAbbreviation: fragment.moduleAbbreviation ?? fragment.moduleInitials,
        osisRef: fragment.fragmentOsisReference ?? fragment.key,
        ordinalRange: [
          fragment.contentOrdinalRange.lowerBound,
          fragment.contentOrdinalRange.upperBound,
        ],
        language: fragment.language,
        direction: fragment.direction,
        isNativeHtml: false
      )
    )
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
    guard replaceDocument(
      documentJSON: document,
      setup: ReaderSetupContentPayload()
    ) else { return }
    setRenderedContentState(
      category: category,
      moduleName: moduleName,
      book: book,
      key: key,
      sourceProvenance: .independent
    )
    applyNightModeBackground()
  }

    /**
     Loads the selected installed or local general-book entry into the WebView.

     - Parameter key: Optional exact native key or My Documents page key.
     - Side effects: For an authorized source, may read one entry, replace Vue content, and persist
       the resolved key. EPUB dispatch delegates to its separately guarded loader.
     - Failure modes: Installed global ownership is resolved before local metadata. Locked/wrong-
       category owners cannot fall through to My Documents, and missing local keys leave the pane
       unchanged. Native failures retain the auxiliary loader's explicit error-document behavior.
     */
    public func loadGeneralBookEntry(key: String? = nil) {
        prepareGeneralBookEntry(key: key)
    }

    /** Waits until the requested general-book key either commits or settles without selection. */
    @MainActor
    func loadGeneralBookEntryAwaitingSelection(key: String) async {
        await awaitPreparationSelectionSettlement { completion in
            self.prepareGeneralBookEntry(key: key, selectionSettlement: completion)
        }
    }

    /** Routes one general-book request to its exact local or installed owner. */
    private func prepareGeneralBookEntry(
        key: String?,
        selectionSettlement: (() -> Void)? = nil
    ) {
        if activeEpubReader != nil {
            prepareEpubEntry(
                key: key,
                jumpToOrdinal: nil,
                retriesOneStaleResult: true,
                selectionSettlement: { _ in selectionSettlement?() }
            )
            return
        }
        guard let initials = activeGeneralBookModuleName else {
            beginReplacingContentIntent()
            let request = BibleReaderAuxiliaryModuleEntryRequest(
                    category: .generalBook,
                    module: nil,
                    moduleName: nil,
                    requestedKey: key,
                    currentKey: currentGeneralBookKey,
                    osisBookId: "GenBook",
                    fallbackBookName: "General Book",
                    bookCategory: DocumentCategory.generalBook.rawValue,
                    noModuleMessage:
                        "No general book module is selected. Download one from the module browser.",
                    noSelectionMessage: "Select an entry from the key browser to view its content.",
                    noContentNoun: "content",
                    persistResolvedKey: { _ in }
            )
            auxiliaryContentLoader().publishUnavailableModuleEntry(
                request,
                message: request.noModuleMessage
            )
            selectionSettlement?()
            return
        }
        guard let owner = installedOrLocalGeneralBookOwner(named: initials) else {
            selectionSettlement?()
            return
        }

        switch owner {
        case .local(.myDocument(let document)):
            let canonicalInitials = document.initials
            let retainedEmptyDocumentID = myDocumentCoordinator.activeEmptyDocumentID(
                for: canonicalInitials
            )
            let requestedKey = key ?? currentGeneralBookKey
            let resolvedKey = requestedKey.flatMap {
                myDocumentStore?.page(bookInitials: canonicalInitials, pageKey: $0)?.pageKey
            } ?? (document.pages ?? []).sorted {
                if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
                return $0.pageKey < $1.pageKey
            }.first?.pageKey
            if let resolvedKey {
                let admitted = prepareMyDocumentPage(
                    requestedInitials: canonicalInitials,
                    requestedKey: resolvedKey,
                    selectedOrdinalRange: nil,
                    expectedFragment: nil,
                    expectedDocumentID: retainedEmptyDocumentID,
                    selectionSettlement: selectionSettlement
                )
                if !admitted { selectionSettlement?() }
            } else {
                _ = publishEmptyMyDocumentSelection(
                    expectedID: retainedEmptyDocumentID ?? document.id,
                    initials: canonicalInitials,
                    name: document.name,
                    recordsToolbarDefault: false
                )
                selectionSettlement?()
            }
            return

        case .local(.epub):
            selectionSettlement?()
            return

        case .installed(let info, let readableSource):
            guard info.category == .generalBook,
                  let readableSource,
                  case .sword(let module) = readableSource else {
                selectionSettlement?()
                return
            }
            if activeGeneralBookModule.map({
              SwordJavaStringIdentity.equals($0.info.name, info.name)
            }) != true {
                if case .failed = switchGeneralBookModule(to: info.name) {
                    selectionSettlement?()
                    return
                }
            }
            loadAuthorizedGeneralBookEntry(
                module: module,
                moduleName: info.name,
                key: key,
                selectionSettlement: selectionSettlement
            )
            return

        case .missing:
            selectionSettlement?()
            return
        }
    }

    /**
     Reads one already authorized native general-book owner through the auxiliary payload contract.

     - Parameters:
       - module: Fresh readable globally selected SWORD owner.
       - moduleName: Canonical installed initials persisted/rendered for the owner.
       - key: Optional exact key; nil retains the selected exact key or requests a chooser.
     - Side effects: Begins replacement, reads the authorized entry, persists its resolved key, and
       emits reader payload/error state according to the existing auxiliary loader contract.
     - Failure modes: Loader validation/read failures emit the existing source-owned error document;
       this helper is never called for locked, wrong-category, local, or missing owners.
     */
    private func loadAuthorizedGeneralBookEntry(
        module: SwordModule,
        moduleName: String,
        key: String?,
        selectionSettlement: (() -> Void)? = nil
    ) {
        let generation = beginReplacingContentIntent()
        let request = BibleReaderAuxiliaryModuleEntryRequest(
                category: .generalBook,
                module: module,
                moduleName: moduleName,
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
        loadPreparedAuxiliaryModuleEntry(
            request: request,
            generation: generation,
            isSelectedSource: { [weak self, weak module] in
                guard let self, let module else { return false }
                return self.activeGeneralBookModule === module
                    && self.activeEpubReader == nil
            },
            selectionSettlement: selectionSettlement
        )
    }

    /// Load a map entry and display it in the WebView.
    public func loadMapEntry(key: String? = nil) {
        prepareMapEntry(key: key)
    }

    /** Waits until the requested map key either commits or settles without selection. */
    @MainActor
    func loadMapEntryAwaitingSelection(key: String) async {
        await awaitPreparationSelectionSettlement { completion in
            self.prepareMapEntry(key: key, selectionSettlement: completion)
        }
    }

    /** Prepares one map request with an optional causal selection settlement. */
    private func prepareMapEntry(
        key: String?,
        selectionSettlement: (() -> Void)? = nil
    ) {
        let generation = beginReplacingContentIntent()
        let module = activeMapModule
        let request = BibleReaderAuxiliaryModuleEntryRequest(
                category: .map,
                module: module,
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
        loadPreparedAuxiliaryModuleEntry(
            request: request,
            generation: generation,
            isSelectedSource: { [weak self, weak module] in
                guard let self else { return false }
                return self.activeMapModule === module
            },
            selectionSettlement: selectionSettlement
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
            guard activeGeneralBookModuleName.map({
              SwordJavaStringIdentity.equals($0, module.info.name)
            }) == true else { return }
            loadGeneralBookEntry(key: firstGlobalKey)
        case .map:
            guard activeMapModuleName.map({
              SwordJavaStringIdentity.equals($0, module.info.name)
            }) == true else { return }
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
     - Failure modes: An unreadable identifier or different globally registered owner is
       logged and leaves the current document unchanged without reading EPUB page content.
     */
    @discardableResult
    public func switchEpub(identifier: String) -> Bool {
        switchEpub(
            identifier: identifier,
            expectedGenerationIdentifier: nil,
            expectedInitials: nil
        )
    }

    /**
     Reopens and authorizes one EPUB generation before applying an optional exact toolbar identity.

     The toolbar supplies the captured initials so a replaced library pointer cannot mutate the pane
     to a different book before stale-row rejection.
     */
    private func switchEpub(
        identifier: String,
        expectedGenerationIdentifier: String?,
        expectedInitials: String?
    ) -> Bool {
        guard let reader = EpubReader(identifier: identifier) else {
            logger.warning("Failed to open EPUB: \(identifier)")
            return false
        }
        if let expectedGenerationIdentifier,
           reader.generationIdentifier != expectedGenerationIdentifier {
            return false
        }
        if let expectedInitials,
           !SwordJavaStringIdentity.equals(reader.initials, expectedInitials) {
            return false
        }
        guard let localDocument = localGeneralBookDocument(
            named: reader.initials,
            preferredEpub: reader
        ), case .epub = localDocument else {
            logger.warning("EPUB identity is owned by another installed document: \(reader.initials)")
            return false
        }
        prepareForAcceptedVisibleDocumentSwitch()
        activateEpub(reader, identifier: identifier, requestedKey: nil)
        if clientReady {
            loadEpubEntry()
        }
        return true
    }

    /**
     Selects one EPUB and waits for its requested key to settle in native selected state.

     This is the causal AI-routing boundary. It performs one activation and one preparation, so the
     requested key cannot race the ordinary first-entry load used by the interactive switch API.
     WebView rejection still preserves the authorized selected key for client-ready replay.
     */
    @MainActor
    func switchEpubAwaitingSelection(identifier: String, key: String?) async -> String? {
        await withCheckedContinuation { continuation in
            guard let reader = EpubReader(identifier: identifier),
                  let localDocument = self.localGeneralBookDocument(
                    named: reader.initials,
                    preferredEpub: reader
                  ), case .epub = localDocument else {
                continuation.resume(returning: nil)
                return
            }
            self.prepareEpubEntry(
                key: key,
                jumpToOrdinal: nil,
                retriesOneStaleResult: true,
                candidateReader: reader,
                activationIdentifier: identifier,
                selectionSettlement: { selectedKey in
                    continuation.resume(returning: selectedKey)
                }
            )
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
              activeEpubReader.map({
                SwordJavaStringIdentity.equals($0.initials, reader.initials)
              }) == true,
              let localDocument = localGeneralBookDocument(
                  named: reader.initials,
                  preferredEpub: reader
              ), case .epub = localDocument else {
            return false
        }
        let requestedKey = currentGeneralBookKey
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

    /**
     Applies one opened adapter as selected general-book intent without reading EPUB content.

     `loadEpubEntry` resolves a requested legacy/composite key or the first readable key inside its
     worker source-capture phase. Persisting the unresolved request here keeps Android's selected
     destination available for delayed client-ready replay while avoiding package/index reads on the
     main actor.
     */
    private func activateEpub(_ reader: EpubReader, identifier: String, requestedKey: String?) {
        activeEpubReader = reader
        activeEpubIdentifier = identifier
        activeEpubTitle = reader.title
        activeGeneralBookModule = nil
        activeGeneralBookModuleName = reader.initials
        currentGeneralBookKey = requestedKey
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
     - Failure modes: A newly installed different global owner returns before any
       content read or reader/PageManager mutation. Missing adapters or keys emit a reader error
       document instead of leaving an indefinite loading state or substituting an unrelated fragment.
     */
    public func loadEpubEntry(key: String? = nil, jumpToOrdinal: Int? = nil) {
        prepareEpubEntry(
            key: key,
            jumpToOrdinal: jumpToOrdinal,
            retriesOneStaleResult: true,
            selectionSettlement: nil
        )
    }

    /** Runs one EPUB preparation with an explicitly bounded stale-result retry policy. */
    private func prepareEpubEntry(
        key: String?,
        jumpToOrdinal: Int?,
        retriesOneStaleResult: Bool,
        candidateReader: EpubReader? = nil,
        activationIdentifier: String? = nil,
        selectionSettlement: ((String?) -> Void)? = nil
    ) {
        guard let reader = candidateReader ?? activeEpubReader else {
            selectionSettlement?(nil)
            return
        }
        beginReplacingContentIntent()
        resetAuxiliaryContentState()
        let requestedKey = key ?? currentGeneralBookKey
        let destination = preparationPublicationOwner.captureDestination()
        let paneID = destination.paneID
        let workspaceID = destination.workspaceID
        let readerIdentifier = BibleReaderPreparationExactText(reader.identifier)
        let readerGeneration = BibleReaderPreparationExactText(reader.generationIdentifier)
        let readerInitials = reader.initials
        let readerTitle = reader.title
        let readerLanguage = reader.language
        let manager = swordManager
        let managerGeneration = manager?.contentAuthorizationGeneration
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let sqliteModules = sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        let sqliteIdentities = sqliteModules.map {
            BibleReaderPreparationSQLiteIdentity(
                module: ObjectIdentifier($0),
                initials: BibleReaderPreparationExactText($0.info.name)
            )
        }
        let keyIdentity = requestedKey.map { BibleReaderPreparationExactText($0) }
            ?? BibleReaderPreparationExactText("first")
        let preparationKey = BibleReaderDocumentPreparationKey(
            family: "epub",
            paneID: paneID,
            workspaceID: workspaceID,
            source: .epub(identifier: readerIdentifier, generation: readerGeneration),
            contentIdentity: keyIdentity,
            annotationIdentity: .exactText(keyIdentity)
        )
        let registryIsCurrent: () -> Bool = { [weak self, weak manager] in
            guard let self else { return false }
            let currentSQLiteIdentities = self.sqliteRuntimeCoordinator
                .unshadowedSQLiteModules().map {
                    BibleReaderPreparationSQLiteIdentity(
                        module: ObjectIdentifier($0),
                        initials: BibleReaderPreparationExactText($0.info.name)
                    )
                }
            let managerIsCurrent = manager.map {
                self.swordManager === $0
                    && $0.contentAuthorizationGeneration == managerGeneration
            } ?? (self.swordManager == nil)
            return managerIsCurrent && currentSQLiteIdentities == sqliteIdentities
        }
        let preSelectionAuthorization: () -> Bool = { [weak self, weak reader] in
            guard let self, let reader else { return false }
            let readerIsCurrent = EpubReader.isCurrentGeneration(
                identifier: readerIdentifier.rawValue,
                generationIdentifier: readerGeneration.rawValue
            )
            let selectionIsCurrent = activationIdentifier == nil
                ? self.currentCategory == .generalBook && self.activeEpubReader === reader
                : readerIsCurrent
            return self.preparationPublicationOwner.isCurrent(destination)
                && selectionIsCurrent
                && SwordJavaExactStringIdentity(reader.identifier)
                    == SwordJavaExactStringIdentity(readerIdentifier.rawValue)
                && SwordJavaExactStringIdentity(reader.generationIdentifier)
                    == SwordJavaExactStringIdentity(readerGeneration.rawValue)
                && registryIsCurrent()
        }
        let postSelectionAuthorization: () -> Bool = { [weak self, weak reader] in
            guard let self, let reader else { return false }
            return self.preparationPublicationOwner.isCurrent(destination)
                && self.currentCategory == .generalBook
                && self.activeEpubReader === reader
                && SwordJavaExactStringIdentity(reader.identifier)
                    == SwordJavaExactStringIdentity(readerIdentifier.rawValue)
                && SwordJavaExactStringIdentity(reader.generationIdentifier)
                    == SwordJavaExactStringIdentity(readerGeneration.rawValue)
                && registryIsCurrent()
        }
        let capture: @Sendable () -> BibleReaderEpubSourceCapture? = {
            let read: () -> BibleReaderEpubSourceCapture? = {
                let resolver = BibleReaderInstalledModuleResolver(
                    swordManager: manager,
                    sqliteModules: sqliteModules
                )
                guard resolver.registeredModuleInfo(named: readerInitials) == nil,
                      let resolvedKey = requestedKey ?? reader.firstKey(),
                      let content = reader.content(forKey: resolvedKey) else { return nil }
                var dependencies: [BibleReaderPreparationSourceDependency] = [
                    .epub(identifier: readerIdentifier, generation: readerGeneration),
                ]
                if let manager {
                    dependencies.append(
                        .sword(
                            manager: ObjectIdentifier(manager),
                            authorization: manager.contentAuthorizationSnapshot(for: [])
                        )
                    )
                }
                return BibleReaderEpubSourceCapture(
                    content: content,
                    annotationSource: Self.epubGenericBookmarkSourceContent(
                        readerInitials: readerInitials,
                        readerTitle: readerTitle,
                        readerLanguage: readerLanguage,
                        content: content
                    ),
                    sourceDependencies: dependencies
                )
            }
            if let manager {
                return manager.performRenderOperation(settings: optionSettings, read)
            }
            return read()
        }
        let factory = persistenceAnnotationPayloadFactory()
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: preparationKey,
            captureSource: { _ in capture() },
            project: { (source: BibleReaderEpubSourceCapture) in source },
            captureOwner: { [weak self, weak reader]
                (source: BibleReaderEpubSourceCapture) -> BibleReaderGenericDocumentOwnerSnapshot? in
                guard let self, let reader else { return nil }
                let emptyInstalledResolver = BibleReaderInstalledModuleResolver(
                    swordManager: nil,
                    sqliteModules: []
                )
                guard case .epub(let current)? = self.localGeneralBookDocument(
                    named: readerInitials,
                    preferredEpub: reader,
                    resolver: emptyInstalledResolver
                ), current === reader,
                  current.generationIdentifier == readerGeneration.rawValue else { return nil }
                return self.genericDocumentOwnerSnapshot(
                    bookInitials: readerInitials,
                    key: source.content.persistedKey
                )
            },
            enrichSource: {
                (source: BibleReaderEpubSourceCapture,
                 owner: BibleReaderGenericDocumentOwnerSnapshot) -> [GenericBookmarkData]? in
                owner.genericBookmarkInputs.map { input in
                    let captured = factory.captureGenericBookmarkSource(
                        for: input,
                        source: source.annotationSource
                    )
                    return factory.genericBookmarkJSONForStudyPad(
                        input,
                        capturedSource: captured
                    )
                }
            },
            encode: {
                (source: BibleReaderEpubSourceCapture,
                 owner: BibleReaderGenericDocumentOwnerSnapshot,
                 renderedBookmarks: [GenericBookmarkData]) -> BibleReaderEncodedEpubDocument? in
                guard let documentJSON = owner.epubEncodedJSON(
                    bookName: readerTitle,
                    bookInitials: readerInitials,
                    content: source.content,
                    language: readerLanguage,
                    renderedGenericBookmarks: renderedBookmarks
                ) else { return nil }
                return BibleReaderEncodedEpubDocument(
                    documentJSON: documentJSON,
                    content: source.content,
                    ownerIdentity: owner.identity,
                    sourceDependencies: source.sourceDependencies
                )
            },
            isAuthorized: preSelectionAuthorization
        ) { [weak self] outcome in
            guard let self else {
                selectionSettlement?(nil)
                return
            }
            let preparedKey: String?
            if case .prepared(let prepared) = outcome {
                preparedKey = prepared.content.persistedKey
            } else {
                preparedKey = nil
            }
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: .settle,
                stalePolicy: retriesOneStaleResult ? .requestFreshCurrent : .settle,
                isCurrent: { prepared in
                    preSelectionAuthorization()
                        && self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                        && self.genericDocumentOwnerSnapshot(
                            bookInitials: readerInitials,
                            key: prepared.content.persistedKey
                        ).identity == prepared.ownerIdentity
                },
                selectedIntent: .init(
                    commit: { prepared in
                        if let activationIdentifier {
                            self.activateEpub(
                                reader,
                                identifier: activationIdentifier,
                                requestedKey: prepared.content.persistedKey
                            )
                            self.currentEpubTitle = prepared.content.title
                        } else {
                            self.currentCategory = .generalBook
                            self.activeGeneralBookModuleName = readerInitials
                            self.currentGeneralBookKey = prepared.content.persistedKey
                            self.currentEpubTitle = prepared.content.title
                            self.currentEpubHref = nil
                            if let pageManager = self.activeWindow?.pageManager {
                                pageManager.currentCategoryName =
                                    DocumentCategory.generalBook.pageManagerKey
                                pageManager.generalBookDocument = readerInitials
                                pageManager.generalBookKey = prepared.content.persistedKey
                                pageManager.epubIdentifier = nil
                                pageManager.epubHref = nil
                                self.onPersistState?()
                            }
                        }
                    },
                    isCurrentAfterCommit: { prepared in
                        postSelectionAuthorization()
                            && self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                            && self.genericDocumentOwnerSnapshot(
                                bookInitials: readerInitials,
                                key: prepared.content.persistedKey
                            ).identity == prepared.ownerIdentity
                    }
                ),
                queueBridgePrerequisites: { _ in
                    self.sendLabelsToVueJS()
                },
                isSourceCurrentAroundBridge: { prepared in
                    postSelectionAuthorization()
                        && self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                },
                queueBridge: { prepared in
                    return self.replaceDocument(
                        documentJSON: prepared.documentJSON,
                        setup: self.epubSetupContentPayload(
                            fragment: prepared.content.fragment,
                            ordinal: jumpToOrdinal
                        )
                    )
                },
                commitAcceptedRender: { prepared in
                    self.setRenderedContentState(
                        category: .generalBook,
                        moduleName: readerInitials,
                        book: prepared.content.title,
                        key: prepared.content.persistedKey,
                        sourceProvenance: .independent
                    )
                    self.emitActiveState()
                    self.bridge.clearSelection()
                    self.applyNightModeBackground()
                }
            )
            switch disposition {
            case .failed(.settle):
                if activationIdentifier == nil {
                    self.publishEpubNoContent(reader: reader)
                }
            case .stale(.requestFreshCurrent):
                self.prepareEpubEntry(
                    key: requestedKey,
                    jumpToOrdinal: jumpToOrdinal,
                    retriesOneStaleResult: false,
                    candidateReader: reader,
                    activationIdentifier: activationIdentifier,
                    selectionSettlement: selectionSettlement
                )
                return
            case .failed, .stale, .cancelled, .bridgeRejected, .dispatchedStale, .accepted:
                break
            }
            switch disposition {
            case .accepted, .bridgeRejected, .dispatchedStale:
                selectionSettlement?(preparedKey)
            case .failed, .stale, .cancelled:
                selectionSettlement?(nil)
            }
        }
    }

    /** Publishes the bounded EPUB no-content contract only for the still-current request. */
    private func publishEpubNoContent(reader: EpubReader) {
        guard let errorDocument = documentPayloadFactory().errorDocumentJSON(
            message: String(
                localized: "error_no_content",
                defaultValue: "No content for this passage"
            )
        ), replaceDocument(
            documentJSON: errorDocument,
            setup: epubSetupContentPayload(fragment: nil, ordinal: nil)
        ) else { return }
        setRenderedContentState(
            category: .generalBook,
            moduleName: reader.initials,
            book: reader.title,
            key: currentGeneralBookKey,
            sourceProvenance: .independent
        )
        applyNightModeBackground()
    }

    /** Builds one EPUB bookmark source solely from immutable reader metadata and copied content. */
    private static func epubGenericBookmarkSourceContent(
        readerInitials: String,
        readerTitle: String,
        readerLanguage: String,
        content: EpubReader.Content
    ) -> GenericBookmarkSourceContent {
        let ordinalRange = [content.ordinalRange.lowerBound, content.ordinalRange.upperBound]
        return GenericBookmarkSourceContent(
            bookName: readerTitle,
            bookAbbreviation: readerTitle,
            keyName: content.title,
            plainText: GenericBookmarkSourceTextProjection.xhtmlText(content.html),
            osisFragment: OsisFragment(
                xml: content.html,
                key: "\(readerInitials)--\(content.persistedKey)",
                keyName: content.title,
                v11n: nil,
                bookCategory: DocumentCategory.generalBook.rawValue,
                bookInitials: readerInitials,
                bookAbbreviation: readerTitle,
                osisRef: content.persistedKey,
                ordinalRange: ordinalRange,
                language: readerLanguage,
                direction: annotationTextDirection(language: readerLanguage),
                isNativeHtml: true
            )
        )
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
     Rebuilds installed inventories for a caller that will immediately select an authoritative row.

     Picker and accepted-unlock flows call this immediately before their existing exact switch.

     - Side effects: Recreates the SWORD and SQLite catalogs without loading reader content.
     - Failure modes: If manager recreation fails, existing runtime state remains unchanged; the
       authoritative caller's subsequent switch performs its normal exact-source validation.
     - Important: Lifecycle and notification callers must use `reconcileInstalledSources()` so a
       same-path replacement cannot leave accepted bytes from the previous source visible.
     */
    public func refreshInstalledSourceInventoryForAuthoritativeSelection() {
        _ = refreshInstalledSourceInventory()
    }

    /**
     Reconciles the visible selected source after an installed registry publication.

     The method rebuilds native and SQLite catalogs, restores persisted category state through the
     existing category-safe dispatcher, and then submits a fresh render through the selected
     family's preparation/publication path. A previously resolved installed document that disappears
     first uses its Android-compatible per-category default, including a registered locked owner,
     then the first readable installed BookSet entry. A registered Bible that relocks remains the
     selected identity and publishes no content. A pane with no persisted source stays on the
     source-free startup placeholder until a backend becomes readable.

     - Side effects: Recreates installed catalogs, cancels obsolete preparation, evicts invalid
       transient replay, restores selected source handles, and may prepare or publish visible content.
     - Failure modes: Manager recreation failure preserves current state. A previously resolved
       Bible with no readable default publishes no content only after exact destination revalidation;
       bridge rejection and synchronous supersession never commit accepted-render state.
     - Important: Same-path replacements always clear committed render identity before fresh source
       preparation, so loaded-range shortcuts cannot reuse bytes accepted from the old generation.
     */
    func reconcileInstalledSources() {
        dispatchPrecondition(condition: .onQueue(.main))
        let priorBibleName = activeModuleName
        let priorBibleWasReadable = activeModule != nil || activeSQLiteBibleModule != nil
        let priorBibleWasPersisted = activeWindow?.pageManager?.bibleDocument.map {
            SwordJavaStringIdentity.equals($0, priorBibleName)
        } == true
        guard refreshInstalledSourceInventory() else { return }

        _ = beginReplacingContentIntent()
        committedRenderState = .empty
        specialDocumentCoordinator.invalidatePreparedReplayForInstalledSourceChange()

        // A retained EPUB object owns one immutable generation. Release it before the shared
        // restore dispatcher replays native -> EPUB -> My Documents registration against disk.
        activeEpubReader = nil
        activeEpubIdentifier = nil
        activeEpubTitle = nil
        currentEpubTitle = nil
        currentEpubHref = nil
        restoreSavedPosition(preparesPersistedMyNotesContent: false)
        retainRelockedBibleSelection(
            named: priorBibleName,
            wasSelectedBeforeRefresh: priorBibleWasReadable || priorBibleWasPersisted
        )

        guard clientReady else { return }
        reloadVisibleDocumentAfterClientReady()
    }

    /**
     Preserves Android's current-book behavior when an installed Bible relocks in place.

     Android treats a registered locked book as present, while a removed book enters normal default
     selection. This post-restore correction therefore applies only to a source that was readable
     or persisted before refresh and remains Java-exactly registered as a locked native Bible.

     - Side effects: Clears fallback backend handles and keeps the relocked initials selected.
     - Failure modes: Removed, renamed, wrong-category, SQLite, and never-readable startup sources
       are ignored and retain the existing setup/restore decision.
     */
    private func retainRelockedBibleSelection(
        named priorName: String,
        wasSelectedBeforeRefresh: Bool
    ) {
        guard wasSelectedBeforeRefresh else { return }
        retainRegisteredLockedBibleSelection(named: priorName)
    }

    /** Keeps one exact registered locked Bible identity without exposing a content handle. */
    private func retainRegisteredLockedBibleSelection(named name: String) {
        guard let relocked = installedBibleModules.first(where: {
            !BibleReaderSQLiteModuleCatalog.isSQLiteProjection($0)
                && SwordJavaStringIdentity.equals($0.name, name)
                && $0.isEncrypted
                && !$0.isUnlocked
        }) else { return }
        activeModule = nil
        activeSQLiteBibleModule = nil
        activeModuleName = relocked.name
        refreshBookList()
    }

    /** Recreates SWORD and SQLite inventories while retaining the active manager's module root. */
    @discardableResult
    private func refreshInstalledSourceInventory() -> Bool {
        let refreshedManager: SwordManager?
        if let modulePath = swordManager?.modulePath {
            refreshedManager = SwordManager(modulePath: modulePath)
        } else {
            refreshedManager = SwordManager()
        }
        guard let newManager = refreshedManager else { return false }
        configureSwordManager(newManager)
        return true
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
        routedSourceAuthorizationOwner.installedSourceGeneration &+= 1
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
        if clientReady {
            emitAdmittedAddonReload(using: mgr, bridge: bridge)
        }
    }

    /**
     Builds the Android `reload_addons` payload from one shared admitted installed projection.

     - Parameter manager: Live manager for the pane's canonical installed-module root.
     - Returns: Exact font, feature, and style owner names in installed TreeSet order.
     - Side effects: Reads and may cache the manager's admitted add-on projection.
     - Failure modes: Rejected, shadowed, unsupported, and exact-initials-ambiguous font owners are
       absent. Android retains an admitted marker owner in this reload list even when one of its
       individual font files is unreadable; settings and CSS still omit that unreadable provider.
     */
    static func addonReloadPayload(manager: SwordManager) -> BibleReaderAddonReloadPayload {
        BibleReaderAddonReloadPayload(
            fontModuleNames: manager.admittedFontModuleNames(),
            featureModuleNames: manager.admittedWebFeatureModuleNames(),
            styleModuleNames: manager.admittedWebStyleModuleNames()
        )
    }

    /**
     Emits Android's complete admitted add-on inventory to the Vue reader.

     - Parameters:
       - manager: Live manager whose shared projection owns the payload.
       - bridge: Ready bridge receiving the typed event.
     - Side effects: Encodes and emits one `reload_addons` event.
     - Failure modes: Bridge encoding/evaluation failures are logged by `BibleBridge`.
     */
    private func emitAdmittedAddonReload(using manager: SwordManager, bridge: BibleBridge) {
        bridge.emitEncoded(
            event: "reload_addons",
            data: Self.addonReloadPayload(manager: manager)
        )
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
     opens an independent SQLite catalog/connection set, reapplies SWORD options, and reopens an
     active EPUB only when the fresh combined registry still admits that exact package.
     - Failure Modes: Returns `false` without mutation when the source controller has no
       `SwordManager`. A newly installed native/SQLite owner suppresses stale copied EPUB state.
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
           let epubReader = EpubReader(identifier: epubIdentifier),
           let localDocument = localGeneralBookDocument(
               named: epubReader.initials,
               preferredEpub: epubReader
           ),
           case .epub(let admittedReader) = localDocument,
           admittedReader.identifier == epubIdentifier {
            self.activeEpubReader = admittedReader
            self.activeEpubIdentifier = epubIdentifier
            self.activeEpubTitle = admittedReader.title
            self.activeGeneralBookModule = nil
            self.activeGeneralBookModuleName = admittedReader.initials
        }
        return true
    }

    /**
     Replaces one absent active-category selection through Android's lazy saved-default contract.

     Existing registered owners keep precedence, including locked and wrong-category rows that the
     category-safe restore layer must reject. Synthetic commentary/general-book documents and
     admitted EPUB/My Documents owners remain pane-owned and never enter installed-source fallback.

     - Parameter category: Visible category whose current document Android would now access.
     - Returns: Whether that category's PageManager document field changed.
     - Side effects: Reads local settings and installed/local registration metadata; mutates only
       category document-name fields. The caller owns the single persistence callback.
     - Failure modes: Local metadata failure preserves the existing general-book token rather than
       substituting an unrelated installed source.
     */
    private func applyAndroidDocumentDefaultPreferences(
        to pageManager: PageManager,
        category: DocumentCategory,
        resolver: BibleReaderInstalledModuleResolver
    ) -> Bool {
        var changed = false

        func apply(
            currentName: String?,
            category: ModuleCategory,
            set: (String) -> Void
        ) {
            guard let replacement = BibleReaderDocumentDefaultPreference.replacement(
                forMissing: currentName,
                category: category,
                settingsStore: settingsStore,
                resolver: resolver
            ), currentName.map({
                SwordJavaStringIdentity.equals($0, replacement.name)
            }) != true else { return }
            set(replacement.name)
            changed = true
        }

        switch category {
        case .bible:
            apply(currentName: pageManager.bibleDocument, category: .bible) {
                pageManager.bibleDocument = $0
            }

        case .commentary:
            let isSynthetic = pageManager.commentaryDocument.map {
                SwordJavaStringIdentity.equals(
                    $0,
                    AndroidSpecialDocumentIdentity.memorizeDocumentInitials
                )
            } == true
            if !isSynthetic {
                apply(currentName: pageManager.commentaryDocument, category: .commentary) {
                    pageManager.commentaryDocument = $0
                }
            }

        case .dictionary:
            apply(currentName: pageManager.dictionaryDocument, category: .dictionary) {
                pageManager.dictionaryDocument = $0
            }

        case .generalBook:
            let isSynthetic = pageManager.generalBookDocument.map {
                SwordJavaStringIdentity.equals(
                    $0,
                    AndroidSpecialDocumentIdentity.multiDocumentInitials
                )
            } == true
            if !isSynthetic,
               let replacement = BibleReaderDocumentDefaultPreference.generalBookReplacement(
                   forMissing: pageManager.generalBookDocument,
                   settingsStore: settingsStore,
                   authorizationService: documentAuthorizationService(),
                   resolver: resolver,
                   preferredEpub: activeEpubReader
               ), pageManager.generalBookDocument.map({
                   SwordJavaStringIdentity.equals($0, replacement.name)
               }) != true {
                pageManager.generalBookDocument = replacement.name
                changed = true
            }

        case .map:
            apply(currentName: pageManager.mapDocument, category: .map) {
                pageManager.mapDocument = $0
            }

        case .epub, .dailyDevotion:
            break
        }

        return changed
    }

    /** Resolves the PageManager category whose current document restore will access. */
    private func androidDefaultRestoreCategory(for rawCategoryName: String) -> DocumentCategory? {
        switch rawCategoryName {
        case "commentary": return .commentary
        case "dictionary": return .dictionary
        case "general_book": return .generalBook
        case "map": return .map
        case "epub": return nil
        default: return .bible
        }
    }

    /**
   Restores category-owned module selections, exact generic keys, and Bible position from a pane.

   - Side effects: Resolves genuine SWORD or serialized SQLite handles for Bible, commentary, and
     dictionary fields; restores other document categories; canonicalizes persisted module
     spelling; validates exact SQLite dictionary keys; refreshes books; and restores navigation.
     By default, also prepares a persisted My Notes document.
   - Parameter preparesPersistedMyNotesContent: Whether a persisted My Notes category prepares
     immediately. Reconciliation passes `false`, stages the resolved target, and owns one replay.
   - Failure modes: Locked, wrong-category, unreadable, and SWORD-shadowed SQLite selections never
     activate content handles. Missing installed selections resolve the category's Android global
     default, then its first readable BookSet entry. Invalid SQLite dictionary keys are cleared
     rather than normalized. The method is a no-op before `activeWindow` is attached.
   - Note: Canonicalized fields invoke `onPersistState` once after all restore decisions.
     */
    public func restoreSavedPosition(preparesPersistedMyNotesContent: Bool = true) {
        guard let pm = activeWindow?.pageManager else { return }
        var normalizedPersistedSelection = false
        let auxiliaryModuleResolver = installedModuleResolver()
        if let restoreCategory = androidDefaultRestoreCategory(for: pm.currentCategoryName),
           applyAndroidDocumentDefaultPreferences(
               to: pm,
               category: restoreCategory,
               resolver: auxiliaryModuleResolver
           ) {
            normalizedPersistedSelection = true
        }

        // Restore the saved Bible module only after the manager's fresh access state confirms it is
        // readable. Locked selections retain the setup choice for later lifecycle reconciliation;
        // unsupported-versification Bibles remain outside the registered inventory per ADR-0010.
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
        if pm.bibleDocument.map({
          SwordJavaStringIdentity.equals($0, canonicalSaved)
        }) != true {
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
        if pm.bibleDocument.map({
          SwordJavaStringIdentity.equals($0, mod.info.name)
        }) != true {
          pm.bibleDocument = mod.info.name
          normalizedPersistedSelection = true
        }
        refreshBookList()
        logger.info("Restored saved SQLite Bible module: \(saved)")
      }
        }
        if let savedBibleName = pm.bibleDocument {
            retainRegisteredLockedBibleSelection(named: savedBibleName)
        }

        // One fresh global registry snapshot authorizes every auxiliary restore below. Native rows
        // retain ownership while locked, so a colliding SQLite module cannot become a content
        // fallback during session restoration.
        let restoreDispatch = BibleReaderRestoreDispatchService(
            resolver: auxiliaryModuleResolver,
            orderedCommentaryModules: installedCommentaryModules,
            canonicalSwordModuleName: { [sqliteRuntimeCoordinator] name in
                sqliteRuntimeCoordinator.canonicalSwordModuleName(name)
            },
            localGeneralBookDocument: { [weak self] name in
                self?.localGeneralBookDocument(
                    named: name,
                    resolver: auxiliaryModuleResolver
                )
            }
        )
        let generalBookRestoreDecision = restoreDispatch.generalBook(
            savedName: pm.generalBookDocument
        )
        let rejectsWrongCategoryGeneralBook: Bool
        if case .rejectedWrongCategory = generalBookRestoreDecision {
            rejectsWrongCategoryGeneralBook = true
        } else {
            rejectsWrongCategoryGeneralBook = false
        }
        let mapRestoreDecision = restoreDispatch.map(savedName: pm.mapDocument)
        let rejectsWrongCategoryMap: Bool
        if case .rejectedWrongCategory = mapRestoreDecision {
            rejectsWrongCategoryMap = true
        } else {
            rejectsWrongCategoryMap = false
        }

        // Apply the operation-scoped commentary dispatch without rebuilding ownership precedence.
        switch restoreDispatch.commentary(savedName: pm.commentaryDocument) {
        case .memorize:
            activeCommentaryModule = nil
            activeSQLiteCommentaryModule = nil
            activeCommentaryModuleName = AndroidSpecialDocumentIdentity.memorizeDocumentInitials
            logger.info("Restored Android synthetic Memorize document")

        case .source(let source):
            switch source {
            case .sword(let module):
                activeCommentaryModule = module
                activeSQLiteCommentaryModule = nil
            case .sqlite(let module):
                activeCommentaryModule = nil
                activeSQLiteCommentaryModule = module
            }
            activeCommentaryModuleName = source.info.name
            if pm.commentaryDocument.map({
                SwordJavaStringIdentity.equals($0, source.info.name)
            }) != true {
                pm.commentaryDocument = activeCommentaryModuleName
                normalizedPersistedSelection = true
            }
            if let savedName = pm.commentaryDocument {
                logger.info("Restored saved commentary module: \(savedName)")
            }

        case .fallback(let source):
            switch source {
            case .sword(let module):
                activeCommentaryModule = module
                activeSQLiteCommentaryModule = nil
            case .sqlite(let module):
                activeCommentaryModule = nil
                activeSQLiteCommentaryModule = module
            }
            activeCommentaryModuleName = source.info.name

        case .unresolved(let canonicalName):
            activeCommentaryModule = nil
            activeSQLiteCommentaryModule = nil
            activeCommentaryModuleName = canonicalName

        case .none:
            break
        }
        // Apply the operation-scoped dictionary dispatch, then validate its persisted key.
        switch restoreDispatch.dictionary(savedName: pm.dictionaryDocument) {
        case .source(let source):
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
            if pm.dictionaryDocument.map({
                SwordJavaStringIdentity.equals($0, source.info.name)
            }) != true {
                pm.dictionaryDocument = activeDictionaryModuleName
                normalizedPersistedSelection = true
            }
            logger.info("Restored saved dictionary module: \(source.info.name)")

        case .unresolved(let canonicalName):
            activeDictionaryModule = nil
            activeSQLiteDictionaryModule = nil
            activeDictionaryModuleName = canonicalName
            currentDictionaryKey = nil

        case .none:
            break
        }
        var restoredEpub = false

        // Apply the complete installed/local general-book dispatch before reading local content.
        switch generalBookRestoreDecision {
        case .multi:
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = AndroidSpecialDocumentIdentity.multiDocumentInitials
            currentGeneralBookKey = pm.generalBookKey
            logger.info("Restored Android synthetic Multi document")

        case .sword(let module):
            activeEpubReader = nil
            activeEpubIdentifier = nil
            activeEpubTitle = nil
            activeGeneralBookModule = module
            activeGeneralBookModuleName = module.info.name
            currentGeneralBookKey = pm.generalBookKey
            if pm.generalBookDocument.map({
                SwordJavaStringIdentity.equals($0, module.info.name)
            }) != true {
                pm.generalBookDocument = module.info.name
                normalizedPersistedSelection = true
            }
            logger.info("Restored saved general book module: \(module.info.name)")

        case .local(.myDocument(let document)):
            activeEpubReader = nil
            activeEpubIdentifier = nil
            activeEpubTitle = nil
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = document.initials
            currentGeneralBookKey = pm.generalBookKey.flatMap {
                myDocumentStore?.page(bookInitials: document.initials, pageKey: $0)?.pageKey
            } ?? (document.pages ?? []).sorted {
                if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
                return $0.pageKey < $1.pageKey
            }.first?.pageKey
            if pm.generalBookDocument.map({
                SwordJavaStringIdentity.equals($0, document.initials)
            }) != true {
                pm.generalBookDocument = document.initials
                normalizedPersistedSelection = true
            }
            logger.info("Restored My Documents general book: \(document.initials)")

        case .local(.epub(let reader)):
            activeEpubReader = reader
            activeEpubIdentifier = reader.identifier
            activeEpubTitle = reader.title
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = reader.initials
            currentGeneralBookKey = pm.generalBookKey
            currentEpubTitle = nil
            currentEpubHref = nil
            restoredEpub = true
            if pm.generalBookDocument.map({
                SwordJavaStringIdentity.equals($0, reader.initials)
            }) != true {
                pm.generalBookDocument = reader.initials
                normalizedPersistedSelection = true
            }
            logger.info("Restored EPUB general book: \(reader.initials)")

        case .unresolved(let canonicalName):
            activeEpubReader = nil
            activeEpubIdentifier = nil
            activeEpubTitle = nil
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = canonicalName
            currentGeneralBookKey = pm.generalBookKey

        case .rejectedWrongCategory, .none:
            break
        }
        // Apply the category-safe native map dispatch without fallback.
        switch mapRestoreDecision {
        case .sword(let module):
            activeMapModule = module
            activeMapModuleName = module.info.name
            currentMapKey = pm.mapKey
            logger.info("Restored saved map module: \(module.info.name)")

        case .unresolved(let canonicalName):
            activeMapModule = nil
            activeMapModuleName = canonicalName
            currentMapKey = pm.mapKey

        case .rejectedWrongCategory, .none:
            break
        }
        // Migrate legacy iOS-only EPUB PageManager fields into Android's general-book fields.
        var migratedLegacyEpub = false
        if !restoredEpub,
           let savedEpub = pm.epubIdentifier,
           let reader = EpubReader(identifier: savedEpub),
           let localDocument = localGeneralBookDocument(
               named: reader.initials,
               preferredEpub: reader,
               resolver: auxiliaryModuleResolver
           ), case .epub = localDocument {
            activeEpubReader = reader
            activeEpubIdentifier = savedEpub
            activeEpubTitle = reader.title
            activeGeneralBookModule = nil
            activeGeneralBookModuleName = reader.initials
            currentGeneralBookKey = pm.epubHref
            currentEpubTitle = nil
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
        case "general_book" where !rejectsWrongCategoryGeneralBook:
            currentCategory = .generalBook
        case "map" where !rejectsWrongCategoryMap:
            currentCategory = .map
        case "general_book", "map":
            break
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
                if preparesPersistedMyNotesContent {
                    loadMyNotesDocument(target: target)
                } else {
                    stageMyNotesTargetForReplay(target)
                }
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
     Handles Android commentary previous/next from the last accepted document capture.

     - Parameter forward: `true` for next, `false` for previous.
     - Returns: `true` whenever a real commentary module owns the action, including boundaries;
       `false` for synthetic/non-module commentary so ordinary navigation can handle it.
     - Side effects: Performs one regular persisted reader navigation when an adjacent target was
       captured and accepted with the current commentary document.
     - Failure modes: Missing accepted availability or an unknown destination book stays on the
       current block. This method performs no native SWORD or SQLite reads on the main actor.
     */
    @discardableResult
    private func navigateCommentaryBlock(forward: Bool) -> Bool {
        guard activeCommentaryModule != nil || activeSQLiteCommentaryModule != nil else {
            return false
        }
        let target = forward
            ? commentaryNavigationAvailability.next
            : commentaryNavigationAvailability.previous
        guard let target, let bookName = bookName(forOsisId: target.osisBookID) else {
            return true
        }
        navigateTo(book: bookName, chapter: target.chapter, verse: target.verse)
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

    /**
     Scrolls to a Bible position already retained by the current Vue document generation.

     The loaded chapter set is valid only for the typed source identity committed after a successful
     replacement. Category, backing-store, and module checks keep a stale range from a prior
     document from suppressing a required replacement after source or special-document navigation.

     - Parameters:
       - position: Persisted target position chosen by the navigation coordinator.
       - highlight: Whether an explicit verse target should receive temporary Vue highlighting.
     - Returns: `true` after emitting a loaded-range scroll; `false` when content must be replaced.
     - Side effects: Emits one typed `scroll_to_verse` event when the target is already loaded.
     - Failure modes: Missing ordinals, source mismatch, and stale/unloaded chapters return `false`.
     */
    private func scrollToLoadedBiblePosition(
        _ position: BibleReaderNavigationPosition,
        highlight: Bool
    ) -> Bool {
        guard let identity = committedRenderState.identity,
              currentCategory == .bible,
              !showingMyNotes,
              !showingStudyPad,
              !isShowingAndroidMultiDocument,
              !isShowingAndroidMemorizeDocument,
              identity.category == .bible,
              SwordJavaExactStringIdentity(identity.moduleName ?? "")
                == SwordJavaExactStringIdentity(activeModuleName),
              committedRenderState.sourceProvenance.containsExactModule(activeModuleName),
              infiniteScrollCoordinator.contains(book: position.book, chapter: position.chapter) else {
            return false
        }

        let osisRef = "\(osisBookId(for: position.book)).\(position.chapter)"
        let ordinal = highlight
            ? verseOrdinal(
                osisBookId: osisBookId(for: position.book),
                chapter: position.chapter,
                verse: position.verse
            )
            : nil
        guard !highlight || ordinal != nil else { return false }
        let chapterDocumentID = BibleReaderDocumentPayloadFactory.androidDocumentID(
            bookInitials: activeModuleName,
            key: osisRef
        )
        let targetId = highlight ? nil : "doc-\(chapterDocumentID)"
        let explicitRange = pendingLinkNavigationOrdinalRange
        let payload = ReaderScrollToVersePayload(
            ordinal: ordinal,
            targetId: targetId,
            now: false,
            highlight: highlight,
            ordinalStart: highlight ? explicitRange?.first ?? ordinal : nil,
            ordinalEnd: highlight ? explicitRange?.last ?? ordinal : nil,
            bookInitials: highlight ? activeModuleName : nil,
            osisRef: highlight ? osisRef : nil
        )
        guard let payloadData = try? bridgeEncoder.encode(payload),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return false
        }
        let emitted = bridge.emit(event: "scroll_to_verse", data: payloadJSON)
        if emitted {
            pendingLinkNavigationOrdinalRange = nil
        }
        return emitted
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
        if currentCategory == .commentary,
           activeCommentaryModule != nil || activeSQLiteCommentaryModule != nil {
            return commentaryNavigationAvailability.next != nil
        }
        if currentCategory == .generalBook, let reader = activeEpubReader {
            return reader.nextKey(after: currentGeneralBookKey) != nil
        }
        return navigationCoordinator.hasNext(context: makeNavigationContext())
    }

    /// Whether there's a previous chapter available.
    public var hasPrevious: Bool {
        if currentCategory == .commentary,
           activeCommentaryModule != nil || activeSQLiteCommentaryModule != nil {
            return commentaryNavigationAvailability.previous != nil
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
        if let swordManager {
            emitAdmittedAddonReload(using: swordManager, bridge: bridge)
        }
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
            emitTransientMultiDocument(
                pendingClientReadyRequest,
                rebuildRequest: activeCompositeRebuildRequest
            )
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

        if isShowingAndroidMemorizeDocument, let activeMemorizeRequest {
            _ = loadRestoredAndroidMemorizeDocument(source: activeMemorizeRequest.emission.source)
            return
        }

        if let activeCompositeRebuildRequest {
            rebuildCompositeDocument(activeCompositeRebuildRequest)
            return
        }

        loadCurrentContent()
    }

    /**
     Reconstructs an active composite from typed source inputs after extraction settings change.

     - Parameter request: Committed source operation for Multi, Compare, or definition content.
     - Returns: No direct value; the selected builder publishes through the normal render path.
     - Side effects: Re-reads authorized modules and may replace the current Vue document. Compare
       reconstruction schedules its source projection on the background queue.
     - Failure modes: Missing modules, unresolved passages, or serialization failures leave the
       existing committed document identity intact.
     - Concurrency: Compare retains normal content-intent generation checks; synchronous families
       complete on the main-actor controller.
     */
    private func rebuildCompositeDocument(_ request: BibleReaderCompositeRebuildRequest) {
        switch request {
        case .prepared(let sourceRequest):
            _ = prepareCompositeDocument(
                sourceRequest,
                routeMultiToLinksWindow: false
            )
        case .definition(let prior):
            _ = prepareDefinitionDocument(
                source: prior.sourceRequest.source,
                stateJSON: currentStrongsDocumentStateJSON(),
                renderedBook: prior.renderedBook,
                renderedKey: prior.renderedKey,
                routesOutward: false
            )
        }
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
        guard let currentIdentity = committedRenderState.identity,
              currentIdentity.category == .dictionary,
              let moduleName = selectedDefinitionModuleName(from: state) else {
            return
        }

        setRenderedContentState(
            category: .dictionary,
            moduleName: moduleName,
            book: currentIdentity.book,
            chapter: currentIdentity.chapter,
            key: currentIdentity.key,
            sourceProvenance: committedRenderState.sourceProvenance,
            preserveCompositeRebuildRequest: true
        )
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
     - persists direct commentary anchors in their document-local ordinal space and applies only
       source references captured with an accepted commentary key transition
     - updates Bible-family scroll-restoration state and persists chapter/book changes to the page manager
     - notifies the window manager for synchronized scrolling only when this pane is already active
       from explicit user interaction, the callback did not acknowledge sync-origin feedback, and
       the visible Bible position actually changed
     */
  public func bridge(
    _ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool
  ) {
    if consumeVisibleCommentaryPosition(ordinal: ordinal, key: key) {
      return
    }

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
     Consumes visible-position telemetry for the accepted commentary document family.

     Android treats an `OsisDocument` commentary ordinal as a document-local anchor and changes the
     shared Bible position only when the visible commentary key changes. Direct SWORD and SQLite
     capture therefore retains the accepted document's exact rendered-key/source-reference pair
     off-main. Previous and next targets belong to toolbar navigation and cannot authorize a scroll
     callback because iOS does not append commentary documents through Vue infinite scroll. This
     callback never resolves a local BVA ordinal through the active Bible module. Synthetic/error
     commentary documents are consumed without mutation because Android does not treat them as
     `OsisDocument`.

     - Parameters:
       - ordinal: Nonnegative local BVA anchor reported by the accepted Vue document.
       - key: Rendered commentary OSIS key reported with the anchor.
     - Returns: `true` for every accepted commentary family so Bible ordinal routing stops.
     - Side effects: A direct, exact-owner route updates the commentary anchor and applies the
       rendered key's captured Bible position without history/reload; a changed shared position may
       broadcast synchronized state.
     - Failure modes: Missing PageManager state, negative anchors, unknown keys, stale selected
       owners, and synthetic source provenance are consumed without durable or Bible mutation.
     */
    private func consumeVisibleCommentaryPosition(ordinal: Int, key: String) -> Bool {
        guard let identity = committedRenderState.identity,
              identity.category == .commentary else { return false }

        guard let target = commentaryNavigationAvailability.target(matchingRenderedKey: key) else {
            _ = synchronizedScrollCoordinator.acknowledgeVisibleOrdinal(ordinal)
            return true
        }
        let acknowledgedSynchronizedScroll = synchronizedScrollCoordinator
            .acknowledgeVisibleOrdinal(target.sourceOrdinal)
        guard ordinal >= 0,
              renderedDocumentKind == .standard,
              let moduleName = identity.moduleName,
              committedRenderState.sourceProvenance.containsExactModule(moduleName),
              let pageManager = activeWindow?.pageManager,
              pageManager.currentCategoryName == DocumentCategory.commentary.pageManagerKey,
              let durableModuleName = pageManager.commentaryDocument,
              SwordJavaStringIdentity.equals(durableModuleName, moduleName) else {
            return true
        }

        let anchorChanged = pageManager.commentaryAnchorOrdinal != ordinal
        if anchorChanged {
            pageManager.commentaryAnchorOrdinal = ordinal
        }
        let visibleVerseChanged = navigationCoordinator.updateVisiblePosition(
            reference: target.navigationReference,
            context: makeNavigationContext()
        )
        if anchorChanged && !visibleVerseChanged {
            persistVisibleVerseState(immediate: false)
        }

        guard !acknowledgedSynchronizedScroll,
              visibleVerseChanged,
              computeIsActiveWindow(),
              let window = activeWindow else { return true }
        windowManagerRef?.notifyVerseChanged(
            sourceWindow: window,
            ordinal: target.sourceOrdinal,
            key: target.sourceKey
        )
        return true
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
        prepareAdjacentBibleChapter(candidate, scope: .prepend, callId: callId)
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
        prepareAdjacentBibleChapter(candidate, scope: .append, callId: callId)
    }

    /**
     Prepares one adjacent Bible document without moving native navigation state.

     - Parameters:
       - candidate: Exact chapter adjacent to the committed loaded range.
       - scope: Prepend or append lane owning this request.
       - callId: Vue promise identifier that must be settled exactly once.
     - Side effects: Captures source content on the preparation worker, sends one bridge response,
       and commits the corresponding loaded bound only after a current document succeeds.
     - Failure modes: Superseded, unauthorized, relocked, changed-annotation, and source failures
       settle with `null` while preserving both loaded bounds.
     */
    private func prepareAdjacentBibleChapter(
        _ candidate: BibleReaderInfiniteScrollChapter,
        scope: BibleReaderDocumentPreparationScope,
        callId: Int,
        retriesOneStaleResult: Bool = true
    ) {
        precondition(scope == .prepend || scope == .append)
        let scopeName = scope == .prepend ? "prepend" : "append"
        let generation = contentIntentGeneration
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let destination = preparationPublicationOwner.captureDestination()
        let osisBookId = osisBookId(for: candidate.book)
        let setupIdentity = "adjacent:\(scopeName)"
        guard let sourcePreparation = bibleSourcePreparation(
            osisBookId: osisBookId,
            chapter: candidate.chapter,
            bookName: candidate.book
        ) else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        let key = BibleReaderDocumentPreparationKey(
            family: BibleReaderPreparationExactText("bible-adjacent-\(scopeName)"),
            paneID: paneID,
            workspaceID: workspaceID,
            source: sourcePreparation.identity,
            contentIdentity: BibleReaderPreparationExactText(
                "\(osisBookId).\(candidate.chapter)|headings=\(shouldIncludeSwordHeadings())"
            ),
            annotationIdentity: .exactText(BibleReaderPreparationExactText(setupIdentity))
        )
        let enrichAnnotations = sourcePreparation.enrichAnnotations
        let baseAuthorization: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.contentIntentGeneration == generation
                && self.currentCategory == .bible
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && sourcePreparation.isCurrent()
        }
        let currentCandidate: () -> BibleReaderInfiniteScrollChapter? = { [weak self] in
            guard let self else { return nil }
            switch scope {
            case .prepend:
                return self.infiniteScrollCoordinator.previousCandidate(
                    previousBook: { [self] in self.previousBook(before: $0) },
                    chapterCount: { [self] in self.chapterCount(for: $0) }
                )
            case .append:
                return self.infiniteScrollCoordinator.nextCandidate(
                    nextBook: { [self] in self.nextBook(after: $0) },
                    chapterCount: { [self] in self.chapterCount(for: $0) }
                )
            case .replacement, .transient:
                return nil
            }
        }
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: scope,
            key: key,
            captureSource: { _ in sourcePreparation.capture() },
            project: { (capture: BibleReaderBibleChapterSourceCapture) in
                capture.projectedChapter()
            },
            captureOwner: { [weak self]
                (projected: BibleReaderProjectedBibleChapter) -> BibleReaderBibleDocumentOwnerSnapshot? in
                self?.bibleChapterOwnerSnapshot(
                    book: candidate.book,
                    chapter: candidate.chapter,
                    osisBookId: osisBookId,
                    structure: projected.structure,
                    navigationAnchorRange: nil,
                    setupIdentity: setupIdentity
                )
            },
            enrichSource: { _, ownerSnapshot in
                enrichAnnotations(ownerSnapshot.bookmarks)
            },
            encode: { projected, ownerSnapshot, annotations
                -> BibleReaderEncodedBibleChapter? in
                guard let json = ownerSnapshot.payload(
                    loadedChapter: projected.loadedChapter,
                    source: projected.source,
                    renderedBookmarks: annotations.bookmarks
                ).encodedJSON() else { return nil }
                return BibleReaderEncodedBibleChapter(
                    documentJSON: json,
                    loadedChapter: projected.loadedChapter,
                    structure: projected.structure,
                    ownerIdentity: ownerSnapshot.identity,
                    sourceDependencies: annotations.sourceDependencies
                )
            },
            isAuthorized: {
                baseAuthorization() && currentCandidate() == candidate
            }
        ) { [weak self] outcome in
            guard let self else { return }
            let candidateIsStillPending = currentCandidate() == candidate
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: .settle,
                stalePolicy: candidateIsStillPending && retriesOneStaleResult
                    ? .requestFreshCurrent : .settle,
                isCurrent: { [weak self] prepared in
                    guard let self,
                          currentCandidate() == candidate,
                          self.sourceDependenciesAreCurrent(prepared.sourceDependencies) else {
                        return false
                    }
                    return self.bibleChapterOwnerSnapshot(
                        book: candidate.book,
                        chapter: candidate.chapter,
                        osisBookId: osisBookId,
                        structure: prepared.structure,
                        navigationAnchorRange: nil,
                        setupIdentity: setupIdentity
                    ).identity == prepared.ownerIdentity
                },
                isSourceCurrentAroundBridge: { [weak self] prepared in
                    self?.sourceDependenciesAreCurrent(prepared.sourceDependencies) == true
                },
                queueBridge: { [weak self] prepared in
                    self?.bridge.sendResponse(callId: callId, value: prepared.documentJSON) == true
                },
                commitAcceptedRender: { [weak self] _ in
                    guard let self else { return }
                    switch scope {
                    case .prepend:
                        self.infiniteScrollCoordinator.commitPrevious(candidate)
                    case .append:
                        self.infiniteScrollCoordinator.commitNext(candidate)
                    case .replacement, .transient:
                        break
                    }
                }
            )
            switch disposition {
            case .stale(.requestFreshCurrent) where retriesOneStaleResult:
                self.prepareAdjacentBibleChapter(
                    candidate,
                    scope: scope,
                    callId: callId,
                    retriesOneStaleResult: false
                )
            case .failed, .stale, .cancelled:
                bridge.sendResponse(callId: callId, value: "null")
            case .accepted, .bridgeRejected, .dispatchedStale:
                break
            }
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
        let notFound: () -> Void = { [weak self] in
            self?.onShowToast?(
                String(
                    localized: "word_not_found_in_dictionaries",
                    defaultValue: "Word not found in any dictionary"
                )
            )
        }
        _ = prepareDefinitionDocument(
            source: .wordLookup(query: query),
            renderedBook: "Dictionary",
            renderedKey: "dictionary",
            routesOutward: true,
            onAccepted: { [weak self] in self?.bridge.clearSelection() },
            onNoResult: notFound
        )
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

     Global native/SQLite ownership is checked before local metadata or page content. A locked or
     readable installed owner therefore receives `null` rather than exposing a colliding local page.
     */
  public func bridge(
    _ bridge: BibleBridge, getMyDocumentPageRawContent callId: Int, bookInitials: String,
    pageKey: String
  ) {
    guard let payload = authorizedMyDocumentRawContentPayload(
      bookInitials: bookInitials,
      pageKey: pageKey
    ) else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }

    bridge.sendResponse(callId: callId, value: payload)
    }

    /**
     Resolves one raw My Documents page behind the complete Android registry ownership boundary.

     - Parameters:
       - bookInitials: Document token supplied by a rendered payload or direct bridge message.
       - pageKey: Exact page key scoped to the resolved local document.
     - Returns: The stored raw page payload only when the admitted owner is My Documents.
     - Side effects: Reads installed/EPUB/My Documents metadata, then reads one local page after
       ownership is proven; it performs no persistence, pasteboard, sharing, or reader mutation.
     - Failure modes: Installed owners (including locked rows), EPUB owners, missing
       metadata, and missing pages return `nil` without local page-content fallback.
     */
    func authorizedMyDocumentRawContentPayload(
      bookInitials: String,
      pageKey: String
    ) -> MyDocumentRawContentPayload? {
      guard let localDocument = localGeneralBookDocument(named: bookInitials),
        case .myDocument(let document) = localDocument else {
        return nil
      }
      return myDocumentStore?.rawContentPayload(
        bookInitials: document.initials,
        pageKey: pageKey
      )
    }

    /**
     Proves one My Documents page still belongs to Android's current combined book owner.

     - Parameter id: Stable page identity captured by a reader AI action.
     - Returns: `true` only when the page's exact parent document is the freshly admitted local My
       Documents owner for its canonical initials.
     - Side effects: Reads page/document and installed/EPUB/My Documents registration metadata only;
       it never reads page content or mutates reader/persistence state.
     - Failure modes: Missing relationships, replaced documents, native/SQLite/EPUB ownership
       (including full-name and case-tier ownership), and local metadata failure return `false`.
     */
    func isAuthorizedMyDocumentPage(id: UUID) -> Bool {
      guard let store = myDocumentStore,
        let page = store.page(pageId: id),
        let document = page.document,
        let localDocument = localGeneralBookDocument(named: document.initials),
        case .myDocument(let authorizedDocument) = localDocument,
        authorizedDocument.id == document.id,
        SwordJavaStringIdentity.equals(authorizedDocument.initials, document.initials)
      else {
        return false
      }
      return true
    }

    /**
     Renders one locally stored My Documents page into the WebView document stream.

     - Returns: `true` when the request is admitted for asynchronous preparation.
     - Side effects: After ownership, page, and serialization checks pass, persists the selected
       local page and attempts to replace reader content.
     - Failure modes: Locked/readable installed owners, another admitted local owner, missing pages,
       and serialization failures return false before reader or PageManager mutation.
     */
    @discardableResult
    public func loadMyDocumentPage(bookInitials: String, pageKey: String) -> Bool {
        prepareMyDocumentPage(
            requestedInitials: bookInitials,
            requestedKey: pageKey,
            selectedOrdinalRange: nil,
            expectedFragment: nil
        )
    }

    /**
     Waits for one admitted My Documents request to settle its selected navigation intent.

     The AI window-document router must return state observed after the asynchronous preparation
     owner has either committed the exact page selection or rejected it. This boundary does not
     wait for WebView acceptance: an authorized selection remains replayable when the client is not
     ready, while rendered state still belongs exclusively to an accepted bridge replacement.

     - Parameters:
       - bookInitials: Exact initials or Android-supported local document alias.
       - pageKey: Exact page key within the resolved document.
     - Returns: After the request settles. The caller must read exact current selection to
       distinguish a committed page from preparation failure, cancellation, or supersession.
     - Side effects: Schedules the same immutable preparation as `loadMyDocumentPage` and may persist
       the selected My Documents identity.
     - Failure modes: Settles without publishing stale state. It never retries beyond the family's
       existing single fresh-current attempt.
     */
    @MainActor
    func loadMyDocumentPageAwaitingSelection(
        bookInitials: String,
        pageKey: String
    ) async {
        await awaitPreparationSelectionSettlement { completion in
            let admitted = prepareMyDocumentPage(
                requestedInitials: bookInitials,
                requestedKey: pageKey,
                selectedOrdinalRange: nil,
                expectedFragment: nil,
                selectionSettlement: completion
            )
            if !admitted {
                completion()
            }
        }
    }

    /**
     Schedules one My Documents page through immutable source, owner, enrichment, and encoding
     phases.

     Installed ownership is captured on the worker before SwiftData values are copied on their main
     owner. Rendering, annotation source projection, and JSON serialization then run off-main.
     Selected PageManager identity is committed after the completed owner is revalidated so a
     not-yet-ready WebView can replay the intended page. Rendered bounds advance only after the
     bridge accepts the replacement.

     - Parameters:
       - requestedInitials: Exact initials or Android-supported alias used to select the document.
       - requestedKey: Exact page key.
       - selectedOrdinalRange: Optional bookmark BVA selection for the replacement setup.
       - expectedFragment: Optional detached bookmark plan that the copied page must reproduce.
       - expectedDocumentID: Optional exact toolbar-row owner retained across stale retry.
       - retriesOneStaleResult: Whether a still-current stale source may retry once.
       - selectionSettlement: Callback invoked after the request settles.
       - selectionCommitted: Callback invoked only after exact selected intent commits.
     - Returns: `true` when the request was admitted to the preparation coordinator.
     - Side effects: Cancels older replacement work and may later persist selected document state
       and replace the WebView document on the main actor.
     - Failure modes: Missing/replaced owners, collisions, stale panes, changed persisted values,
       source failures, and encoding failures settle without publishing partial state.
     */
    @discardableResult
    private func prepareMyDocumentPage(
        requestedInitials: String,
        requestedKey: String,
        selectedOrdinalRange: ClosedRange<Int>?,
        expectedFragment: BibleReaderBookmarkNavigationMyDocumentFragment?,
        expectedDocumentID: UUID? = nil,
        retriesOneStaleResult: Bool = true,
        selectionSettlement: (() -> Void)? = nil,
        selectionCommitted: ((BibleReaderPreparedMyDocument) -> Void)? = nil
    ) -> Bool {
        guard myDocumentStore != nil,
              !requestedInitials.isEmpty,
              !requestedKey.isEmpty else { return false }

        let generation = beginReplacingContentIntent()
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let destination = preparationPublicationOwner.captureDestination()
        let manager = swordManager
        let managerGeneration = manager?.contentAuthorizationGeneration
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let sqliteModules = sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        let requestIdentity = BibleReaderMyDocumentPreparationRequestIdentity(
            requestedInitials: requestedInitials,
            requestedKey: requestedKey,
            selectedOrdinalRange: selectedOrdinalRange,
            expectedFragment: expectedFragment,
            expectedDocumentID: expectedDocumentID
        )
        let key = BibleReaderDocumentPreparationKey(
            family: "my-document",
            paneID: paneID,
            workspaceID: workspaceID,
            source: .installedRegistry(
                swordManager: manager.map(ObjectIdentifier.init),
                swordGeneration: managerGeneration,
                sqliteModules: sqliteModules.map {
                    BibleReaderPreparationSQLiteIdentity(
                        module: ObjectIdentifier($0),
                        initials: BibleReaderPreparationExactText($0.info.name)
                    )
                }
            ),
            contentIdentity: "my-document-request",
            annotationIdentity: .myDocumentRequest(requestIdentity)
        )
        let baseAuthorization: () -> Bool = { [weak self, weak manager] in
            guard let self else { return false }
            let managerIsCurrent = manager.map {
                self.swordManager === $0
                    && $0.contentAuthorizationGeneration == managerGeneration
            } ?? (self.swordManager == nil)
            return self.contentIntentGeneration == generation
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && managerIsCurrent
        }
        let captureRegistry: @Sendable () -> BibleReaderMyDocumentSourceRegistry? = {
            let capture: () -> BibleReaderMyDocumentSourceRegistry? = {
                guard manager == nil
                    || manager?.contentAuthorizationGeneration == managerGeneration else {
                    return nil
                }
                let resolver = BibleReaderInstalledModuleResolver(
                    swordManager: manager,
                    sqliteModules: sqliteModules
                )
                var dependencies: [BibleReaderPreparationSourceDependency] = []
                if let manager {
                    dependencies.append(
                        .sword(
                            manager: ObjectIdentifier(manager),
                            authorization: manager.contentAuthorizationSnapshot(for: [])
                        )
                    )
                }
                return BibleReaderMyDocumentSourceRegistry(
                    installedResolver: resolver,
                    sourceDependencies: dependencies
                )
            }
            if let manager {
                return manager.performRenderOperation(settings: optionSettings, capture)
            }
            return capture()
        }
        let factory = persistenceAnnotationPayloadFactory()
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in captureRegistry() },
            project: { (registry: BibleReaderMyDocumentSourceRegistry) in registry },
            captureOwner: { [weak self]
                (registry: BibleReaderMyDocumentSourceRegistry)
                    -> BibleReaderMyDocumentOwnerSnapshot? in
                guard let owner = self?.myDocumentOwnerSnapshot(
                    requestedInitials: requestedInitials,
                    requestedKey: requestedKey,
                    installedResolver: registry.installedResolver
                ) else { return nil }
                guard expectedDocumentID.map({ $0 == owner.source.documentID }) ?? true else {
                    return nil
                }
                if let expectedFragment,
                   !Self.myDocumentOwner(owner, matches: expectedFragment) {
                    return nil
                }
                return owner
            },
            enrichSource: {
                (registry: BibleReaderMyDocumentSourceRegistry,
                 owner: BibleReaderMyDocumentOwnerSnapshot)
                    -> BibleReaderPreparedMyDocumentEnrichment? in
                let sourceContent = owner.source.genericBookmarkSourceContent()
                let bookmarks = owner.genericBookmarkInputs.map { input in
                    let captured = factory.captureGenericBookmarkSource(
                        for: input,
                        source: sourceContent
                    )
                    return factory.genericBookmarkJSONForStudyPad(
                        input,
                        capturedSource: captured
                    )
                }
                var dependencies = registry.sourceDependencies
                dependencies.append(.myDocument(owner.source))
                return BibleReaderPreparedMyDocumentEnrichment(
                    genericBookmarks: bookmarks,
                    sourceDependencies: dependencies
                )
            },
            encode: {
                (registry: BibleReaderMyDocumentSourceRegistry,
                 owner: BibleReaderMyDocumentOwnerSnapshot,
                 enrichment: BibleReaderPreparedMyDocumentEnrichment)
                    -> BibleReaderEncodedMyDocument? in
                let source = owner.source
                let prepared = BibleReaderPreparedMyDocument(
                    documentID: source.documentID,
                    documentName: source.documentName,
                    documentInitials: source.documentInitials.rawValue,
                    pageID: source.pageID,
                    pageTitle: source.pageTitle,
                    pageKey: source.pageKey.rawValue,
                    contentType: MyDocumentContentType(rawValue: source.contentTypeRawValue)
                        ?? .markdown,
                    rawContent: source.rawContent,
                    pageSourcePromptID: owner.metadata.sourcePromptId,
                    metadata: owner.metadata,
                    sourceDependencies: enrichment.sourceDependencies,
                    genericBookmarkInputs: owner.genericBookmarkInputs,
                    genericBookmarks: enrichment.genericBookmarks,
                    generatedBookLanguageCode: owner.generatedBookLanguageCode
                )
                guard prepared.ownerIdentity == owner.identity,
                      let documentJSON = prepared.encodedJSON() else { return nil }
                return BibleReaderEncodedMyDocument(
                    documentJSON: documentJSON,
                    prepared: prepared,
                    installedResolver: registry.installedResolver
                )
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else {
                selectionSettlement?()
                return
            }
            let exactOwnerIsCurrent: (BibleReaderEncodedMyDocument) -> Bool = {
                [weak self] result in
                guard let self else { return false }
                let prepared = result.prepared
                return (expectedDocumentID.map({ $0 == prepared.documentID }) ?? true)
                    && self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                    && self.myDocumentOwnerSnapshot(
                        requestedInitials: prepared.documentInitials,
                        requestedKey: prepared.pageKey,
                        installedResolver: result.installedResolver
                    )?.identity == prepared.ownerIdentity
            }
            let selectionCallbackMutation:
                BibleReaderPreparationSynchronousMutation<BibleReaderEncodedMyDocument>? =
                selectionCommitted.map { callback in
                    BibleReaderPreparationSynchronousMutation(
                        commit: { result in callback(result.prepared) },
                        isCurrentAfterCommit: exactOwnerIsCurrent
                    )
                }
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: .settle,
                stalePolicy: .requestFreshCurrent,
                isCurrent: exactOwnerIsCurrent,
                selectedIntent: .init(
                    commit: { [weak self] result in
                        guard let self else { return }
                        guard expectedDocumentID.map({
                            $0 == result.prepared.documentID
                        }) ?? true else { return }
                        self.commitMyDocumentSelectionIntent(result.prepared)
                    },
                    isCurrentAfterCommit: exactOwnerIsCurrent
                ),
                postSelectionCallback: selectionCallbackMutation,
                isSourceCurrentAroundBridge: { [weak self] result in
                    guard let self else { return false }
                    let prepared = result.prepared
                    return (expectedDocumentID.map({ $0 == prepared.documentID }) ?? true)
                        && self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                },
                queueBridge: { [weak self] result in
                    guard let self else { return false }
                    let prepared = result.prepared
                    return self.replaceDocument(
                        documentJSON: result.documentJSON,
                        setup: ReaderSetupContentPayload(
                            jumpToOrdinal: selectedOrdinalRange?.lowerBound,
                            ordinalStart: selectedOrdinalRange?.lowerBound,
                            ordinalEnd: selectedOrdinalRange?.upperBound,
                            highlight: selectedOrdinalRange != nil,
                            bookInitials: prepared.documentInitials,
                            osisRef: prepared.pageKey
                        )
                    )
                },
                commitAcceptedRender: { [weak self] result in
                    guard let self else { return }
                    let prepared = result.prepared
                    self.setRenderedContentState(
                        category: .generalBook,
                        moduleName: prepared.documentInitials,
                        book: prepared.documentName,
                        key: prepared.pageKey,
                        sourceProvenance: .independent
                    )
                    self.emitActiveState()
                    self.bridge.clearSelection()
                    self.applyNightModeBackground()
                }
            )
            if disposition == .stale(.requestFreshCurrent), retriesOneStaleResult {
                let retryAdmitted = self.prepareMyDocumentPage(
                    requestedInitials: requestedInitials,
                    requestedKey: requestedKey,
                    selectedOrdinalRange: selectedOrdinalRange,
                    expectedFragment: expectedFragment,
                    expectedDocumentID: expectedDocumentID,
                    retriesOneStaleResult: false,
                    selectionSettlement: selectionSettlement,
                    selectionCommitted: selectionCommitted
                )
                if !retryAdmitted { selectionSettlement?() }
                return
            }
            selectionSettlement?()
        }
        return true
    }

    /**
     Commits one revalidated My Documents selection independently of WebView readiness.

     Android's PageManager owns the selected document and key before rendering mediation. Keeping
     that intent in native state lets `bridgeDidSetClientReady` replay the exact authorized page,
     while `setRenderedContentState` remains exclusively owned by an accepted bridge replacement.

     - Parameter prepared: Immutable page whose source dependencies and exact owner were revalidated.
     - Side effects: Selects the My Documents page, clears incompatible auxiliary backends, and
       persists changed PageManager identity once.
     - Failure modes: None. Callers must establish current pane, workspace, source, and owner
       authorization before invoking this method.
     */
    private func commitMyDocumentSelectionIntent(_ prepared: BibleReaderPreparedMyDocument) {
        clearPendingSpecialDocumentReplay()
        resetAuxiliaryContentState()
        activeEpubReader = nil
        activeEpubIdentifier = nil
        activeEpubTitle = nil
        currentEpubTitle = nil
        currentEpubHref = nil
        activeGeneralBookModule = nil
        activeGeneralBookModuleName = prepared.documentInitials
        currentGeneralBookKey = prepared.pageKey
        currentCategory = .generalBook
        myDocumentCoordinator.setActivePage(
            documentID: prepared.documentID,
            bookInitials: prepared.documentInitials,
            pageKey: prepared.pageKey
        )
        guard let pageManager = activeWindow?.pageManager else { return }
        let pageManagerChanged =
            pageManager.currentCategoryName != DocumentCategory.generalBook.pageManagerKey
            || !SwordJavaStringIdentity.equals(
                pageManager.generalBookDocument ?? "",
                prepared.documentInitials
            )
            || !SwordJavaStringIdentity.equals(
                pageManager.generalBookKey ?? "",
                prepared.pageKey
            )
            || pageManager.epubIdentifier != nil
            || pageManager.epubHref != nil
        pageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
        pageManager.generalBookDocument = prepared.documentInitials
        pageManager.generalBookKey = prepared.pageKey
        pageManager.epubIdentifier = nil
        pageManager.epubHref = nil
        if pageManagerChanged { onPersistState?() }
    }

    /** Commits an authorized page-less My Documents owner without manufacturing a page key. */
    private func commitEmptyMyDocumentSelectionIntent(documentID: UUID, initials: String) {
        clearPendingSpecialDocumentReplay()
        resetAuxiliaryContentState()
        activeEpubReader = nil
        activeEpubIdentifier = nil
        activeEpubTitle = nil
        currentEpubTitle = nil
        currentEpubHref = nil
        activeGeneralBookModule = nil
        activeGeneralBookModuleName = initials
        currentGeneralBookKey = nil
        currentCategory = .generalBook
        myDocumentCoordinator.setActiveEmptyDocument(
            documentID: documentID,
            bookInitials: initials
        )
        guard let pageManager = activeWindow?.pageManager else { return }
        let pageManagerChanged =
            pageManager.currentCategoryName != DocumentCategory.generalBook.pageManagerKey
            || !SwordJavaStringIdentity.equals(pageManager.generalBookDocument ?? "", initials)
            || pageManager.generalBookKey != nil
            || pageManager.epubIdentifier != nil
            || pageManager.epubHref != nil
        pageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
        pageManager.generalBookDocument = initials
        pageManager.generalBookKey = nil
        pageManager.epubIdentifier = nil
        pageManager.epubHref = nil
        if pageManagerChanged { onPersistState?() }
    }

    /** Compares one copied owner with the exact detached bookmark plan using UTF-16 identity. */
    private static func myDocumentOwner(
        _ owner: BibleReaderMyDocumentOwnerSnapshot,
        matches fragment: BibleReaderBookmarkNavigationMyDocumentFragment
    ) -> Bool {
        let source = owner.source
        let effectiveLanguage = fragment.languageCode?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let expectedLanguage = effectiveLanguage?.isEmpty == false
            ? effectiveLanguage! : (Locale.current.language.languageCode?.identifier ?? "en")
        return source.documentID == fragment.documentID
            && source.pageID == fragment.pageID
            && BibleReaderPreparationExactText(source.documentInitials.rawValue)
                == BibleReaderPreparationExactText(fragment.moduleInitials)
            && BibleReaderPreparationExactText(source.documentName)
                == BibleReaderPreparationExactText(fragment.documentName)
            && source.pageKey == BibleReaderPreparationExactText(fragment.key)
            && BibleReaderPreparationExactText(source.pageTitle)
                == BibleReaderPreparationExactText(fragment.title)
            && BibleReaderPreparationExactText(source.contentTypeRawValue)
                == BibleReaderPreparationExactText(fragment.contentTypeRawValue)
            && BibleReaderPreparationExactText(source.rawContent)
                == BibleReaderPreparationExactText(fragment.rawContent)
            && BibleReaderPreparationExactText(source.language)
                == BibleReaderPreparationExactText(expectedLanguage)
    }

    /**
     Copies one globally authorized My Documents page to the platform pasteboard.

     - Parameters:
       - bridge: Reader bridge that originated the action; retained for delegate compatibility.
       - bookInitials: Document token emitted by the rendered My Documents payload.
       - pageKey: Exact page key emitted by that payload.
     - Side effects: Resolves the complete installed/EPUB/My Documents registry, reads the exact
       local page only when My Documents owns the token, then writes its raw body to the pasteboard.
     - Failure modes: Installed owners (including locked native rows), EPUB owners, missing pages,
       and local metadata failures return before either page-content or pasteboard access.
     */
  public func bridge(
    _ bridge: BibleBridge, copyMyDocumentContent bookInitials: String, pageKey: String
  ) {
    guard let payload = authorizedMyDocumentRawContentPayload(
      bookInitials: bookInitials,
      pageKey: pageKey
    ) else {
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
     Shares one globally authorized My Documents page through native sharing UI.

     - Parameters:
       - bridge: Reader bridge that originated the action; retained for delegate compatibility.
       - bookInitials: Document token emitted by the rendered My Documents payload.
       - pageKey: Exact page key emitted by that payload.
     - Side effects: Resolves the complete installed/EPUB/My Documents registry, reads the exact
       local page only when My Documents owns the token, and invokes the native share callback.
     - Failure modes: Installed owners (including locked native rows), EPUB owners, missing pages,
       and local metadata failures return before page-content access or callback invocation.
     */
  public func bridge(
    _ bridge: BibleBridge, shareMyDocumentContent bookInitials: String, pageKey: String
  ) {
    guard let payload = authorizedMyDocumentRawContentPayload(
      bookInitials: bookInitials,
      pageKey: pageKey
    ) else {
            return
        }

        onShareMyDocumentContent?(myDocumentCoordinator.sharePayload(for: payload))
    }

    /**
     Persists editor content only when My Documents owns the complete registry identity.

     - Parameters:
       - bridge: Reader bridge that originated the action; retained for delegate compatibility.
       - bookInitials: Document token emitted by the rendered editable payload.
       - pageId: Exact stable page UUID from that payload.
       - content: Replacement raw Markdown or HTML body.
       - title: Optional replacement title; `nil` preserves the stored title.
     - Side effects: Resolves installed/local metadata, then updates and saves the exact local page
       graph through `MyDocumentStore` only after My Documents ownership is proven.
     - Failure modes: Malformed UUIDs, installed or EPUB owners, local metadata failures, missing
       pages, and save failures return without mutating a local page.
     */
  public func bridge(
    _ bridge: BibleBridge, saveMyDocumentPageContent bookInitials: String, pageId: String,
    content: String, title: String?
  ) {
        guard let pageUUID = UUID(uuidString: pageId) else {
            logger.warning("saveMyDocumentPageContent: malformed page id=\(pageId, privacy: .public)")
            return
        }

    guard let localDocument = localGeneralBookDocument(named: bookInitials),
      case .myDocument(let document) = localDocument,
      myDocumentStore?.savePageContent(
            bookInitials: document.initials,
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

    private func loadMyNotesDocument(
        target: MyNotesTarget,
        retriesOneStaleResult: Bool = true
    ) {
        let generation = beginReplacingContentIntent()
        let destination = preparationPublicationOwner.captureDestination()
        persistMyNotesPageCategory(visible: true)
        guard clientReady else {
            stageMyNotesTargetForReplay(target)
            return
        }
        pendingClientReadyMyNotesTarget = nil
        activeMyNotesTarget = target
        activeMyNotesReference = nil
        showingMyNotes = true
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()

        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let manager = swordManager
        let activeSwordModule = activeModule
        let activeSwordInitials = activeSwordModule?.info.name ?? ""
        let managerGeneration = manager?.contentAuthorizationGeneration
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let capturedBookList = moduleBookList
        let targetIdentity = Self.myNotesTargetIdentity(target)
        let sourceIdentity: BibleReaderPreparationSourceIdentity
        if let manager, let activeSwordModule, let managerGeneration {
            sourceIdentity = .sword(
                manager: ObjectIdentifier(manager),
                module: ObjectIdentifier(activeSwordModule),
                initials: BibleReaderPreparationExactText(activeSwordInitials),
                generation: managerGeneration,
                modules: [BibleReaderPreparationExactText(activeSwordInitials)]
            )
        } else {
            sourceIdentity = .independent
        }
        let key = BibleReaderDocumentPreparationKey(
            family: "my-notes",
            paneID: paneID,
            workspaceID: workspaceID,
            source: sourceIdentity,
            contentIdentity: BibleReaderPreparationExactText(targetIdentity),
            annotationIdentity: .exactText(BibleReaderPreparationExactText(targetIdentity))
        )
        let baseAuthorization: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.contentIntentGeneration == generation
                && self.clientReady
                && self.showingMyNotes
                && self.activeMyNotesTarget == target
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && self.swordManager === manager
                && self.activeModule === activeSwordModule
        }
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ -> PreparedMyNotesTarget? in
                Self.prepareMyNotesTarget(target)
            },
            project: { (preparedTarget: PreparedMyNotesTarget) -> PreparedMyNotesTarget? in
                preparedTarget
            },
            captureOwner: { [weak self] preparedTarget -> BibleReaderPreparedMyNotesOwnerSnapshot? in
                guard let self else { return nil }
                return self.myNotesOwnerSnapshot(preparedTarget)
            },
            enrichSource: {
                (ownerTarget: PreparedMyNotesTarget,
                 ownerSnapshot: BibleReaderPreparedMyNotesOwnerSnapshot)
                    -> BibleReaderPreparedMyNotesEnrichment? in
                let renderedBookmarks: [BibleBookmarkData]
                let dependencies: [BibleReaderPreparationSourceDependency]
                if let manager, let managerGeneration {
                    guard let result = manager.performRenderOperation(settings: optionSettings, {
                        () -> ([BibleBookmarkData], SwordContentAuthorizationSnapshot)? in
                        let requestedNames = ([activeSwordInitials] + ownerSnapshot.bookmarkInputs.map {
                            $0.sourceBookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
                        }).filter { !$0.isEmpty }
                        let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
                        guard authorization.generation == managerGeneration else { return nil }
                        let payloadFactory = BibleReaderAnnotationPayloadFactory(
                            currentBook: ownerTarget.reference.displayHeading,
                            activeModuleName: activeSwordInitials,
                            activeModule: activeSwordModule,
                            sourceModuleResolver: { manager.readableModule(named: $0) },
                            bookCatalog: BibleReaderBookCatalog(
                                activeModule: activeSwordModule,
                                moduleBookList: capturedBookList
                            ),
                            unlabeledLabelID: Self.unlabeledLabelId
                        )
                        return (
                            ownerSnapshot.bookmarkInputs.map(payloadFactory.bookmarkJSONForMyNotes),
                            authorization
                        )
                    }) else { return nil }
                    renderedBookmarks = result.0
                    dependencies = [.sword(
                        manager: ObjectIdentifier(manager),
                        authorization: result.1
                    )]
                } else {
                    let payloadFactory = BibleReaderAnnotationPayloadFactory(
                        currentBook: ownerTarget.reference.displayHeading,
                        activeModuleName: "",
                        activeModule: nil,
                        bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
                        unlabeledLabelID: Self.unlabeledLabelId
                    )
                    renderedBookmarks = ownerSnapshot.bookmarkInputs.map(
                        payloadFactory.bookmarkJSONForMyNotes
                    )
                    dependencies = [.independent]
                }
                return BibleReaderPreparedMyNotesEnrichment(
                    bookmarks: renderedBookmarks,
                    sourceDependencies: dependencies
                )
            },
            encode: {
                (_: PreparedMyNotesTarget,
                 ownerSnapshot: BibleReaderPreparedMyNotesOwnerSnapshot,
                 enrichment: BibleReaderPreparedMyNotesEnrichment)
                    -> BibleReaderEncodedMyNotesDocument? in
                let prepared = BibleReaderPreparedMyNotesDocument(
                    reference: ownerSnapshot.reference,
                    sourceDependencies: enrichment.sourceDependencies,
                    bookmarkInputs: ownerSnapshot.bookmarkInputs,
                    bookmarks: enrichment.bookmarks,
                    labels: ownerSnapshot.labels,
                    jumpToOrdinal: ownerSnapshot.jumpToOrdinal
                )
                guard let json = prepared.encodedJSON() else { return nil }
                return BibleReaderEncodedMyNotesDocument(prepared: prepared, documentJSON: json)
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else { return }
            let sourceGenerationChanged = manager != nil
                && manager?.contentAuthorizationGeneration != managerGeneration
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: sourceGenerationChanged ? .requestFreshCurrent : .settle,
                stalePolicy: .requestFreshCurrent,
                isCurrent: { [weak self] result in
                    guard let self,
                          self.sourceDependenciesAreCurrent(result.prepared.sourceDependencies)
                    else { return false }
                    let currentOwner = self.myNotesOwnerSnapshot(
                        PreparedMyNotesTarget(
                            reference: result.prepared.reference,
                            jumpToOrdinal: result.prepared.jumpToOrdinal
                        )
                    )
                    return currentOwner.identity == result.prepared.ownerIdentity
                },
                selectedIntent: .init(
                    commit: { [weak self] result in
                        self?.activeMyNotesReference = result.prepared.reference
                    },
                    isCurrentAfterCommit: { [weak self] result in
                        guard let self,
                              self.sourceDependenciesAreCurrent(
                                result.prepared.sourceDependencies
                              ) else { return false }
                        let currentOwner = self.myNotesOwnerSnapshot(
                            PreparedMyNotesTarget(
                                reference: result.prepared.reference,
                                jumpToOrdinal: result.prepared.jumpToOrdinal
                            )
                        )
                        return currentOwner.identity == result.prepared.ownerIdentity
                    }
                ),
                queueBridgePrerequisites: { [weak self] result in
                    self?.annotationDocumentLoader().prepareMyNotesDispatch(result)
                },
                isSourceCurrentAroundBridge: { [weak self] result in
                    self?.sourceDependenciesAreCurrent(
                        result.prepared.sourceDependencies
                    ) == true
                },
                queueBridge: { [weak self] result in
                    self?.annotationDocumentLoader().dispatchMyNotesDocument(result) == true
                },
                commitAcceptedRender: { [weak self] result in
                    self?.annotationDocumentLoader().commitMyNotesRender(result)
                }
            )
            switch disposition {
            case .failed(.requestFreshCurrent) where retriesOneStaleResult,
                 .stale(.requestFreshCurrent) where retriesOneStaleResult:
                self.loadMyNotesDocument(target: target, retriesOneStaleResult: false)
            case .accepted, .bridgeRejected, .dispatchedStale, .cancelled,
                 .failed(.settle), .failed(.requestFreshCurrent),
                 .stale(.settle), .stale(.requestFreshCurrent):
                break
            }
        }
    }

    /** Retains one resolved My Notes target without starting a second visible preparation. */
    private func stageMyNotesTargetForReplay(_ target: MyNotesTarget) {
        pendingClientReadyMyNotesTarget = target
        activeMyNotesTarget = target
        showingMyNotes = true
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()
    }

    /**
     Renders a prebuilt Android Memorize fake document in this controller.

     - Parameter emission: Serialized Vue Memorize payload plus source range metadata.
     - Returns: `true` only when the bridge accepts the complete document replacement.
     - Side effects: Stores the live Memorize emission for client-ready/content replay, applies
       Android's commentary-category `Memorize` PageManager identity, emits bridge document events,
       clears selection, and reapplies reader background.
     - Failure modes: Bridge rejection returns `false` while retaining the selected emission for
       client-ready replay; accepted render identity advances only after bridge acceptance.
     */
    @discardableResult
    func renderMemorizeDocument(_ request: BibleReaderMemorizeRenderRequest) -> Bool {
        beginReplacingContentIntent()
        let destination = preparationPublicationOwner.captureDestination()
        let loader = annotationDocumentLoader()
        let disposition = preparationPublicationOwner.publishQueuedBridge(
            .prepared(request),
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .settle,
            isCurrent: { $0.sourceAuthorization.isCurrent() },
            selectedIntent: .init(
                commit: { [weak self] request in
                    self?.prepareMemorizeVisibleState(emission: request.emission)
                    self?.activeMemorizeRequest = request
                },
                isCurrentAfterCommit: { $0.sourceAuthorization.isCurrent() }
            ),
            isSourceCurrentAroundBridge: { $0.sourceAuthorization.isCurrent() },
            queueBridge: { request in
                loader.dispatchMemorizeDocument(request.emission)
            },
            commitAcceptedRender: { request in
                loader.commitMemorizeRender(request.emission)
            }
        )
        return disposition == .accepted
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

    /** Captures the persistence-owned progress state for one source-resolved Memorize range. */
    private func memorizeOwnerSnapshot(
        _ capture: BibleReaderMemorizeSourceCapture
    ) -> BibleReaderMemorizeOwnerSnapshot {
        BibleReaderMemorizeOwnerSnapshot(
            memorizedKJVAOrdinals: memorizationProgressStore?.memorizedOrdinals(
                bookInitials: "",
                startOrdinal: capture.kjvaOrdinalStart,
                endOrdinal: capture.kjvaOrdinalEnd
            ) ?? [],
            targetKJVAOrdinals: memorizationProgressStore?.targetOrdinals(
                bookInitials: "",
                startOrdinal: capture.kjvaOrdinalStart,
                endOrdinal: capture.kjvaOrdinalEnd
            ) ?? [],
            settings: BibleReaderMemorizeSettings(
                payload: progressBridgeCoordinator.readingProgressSettingsPayload()
            )
        )
    }

    /**
     Prepares one Memorize document through the shared immutable coordinator.

     Source resolution, canonical text extraction, versification projection, and JSON encoding run
     off-main. Only bounded progress/settings capture and final pane publication run on the owner.
     A configured links-window callback receives the same prebuilt emission without changing this
     pane's selected or rendered document.
     */
    @discardableResult
    private func prepareMemorizeDocument(
        _ request: BibleReaderMemorizePreparationRequest,
        routeToLinksWindow: Bool,
        retriesOneStaleResult: Bool = true
    ) -> Bool {
        guard let manager = swordManager else { return false }
        let outwardMemorizeOpen = routeToLinksWindow
            ? onOpenMemorizeDocumentInLinksWindow
            : nil
        let routesOutward = outwardMemorizeOpen != nil
        if routesOutward {
            transientPreparationGeneration &+= 1
        }
        let outwardGeneration = transientPreparationGeneration
        let generation = routesOutward
            ? contentIntentGeneration : beginReplacingContentIntent()
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let destination = preparationPublicationOwner.captureDestination()
        let managerGeneration = manager.contentAuthorizationGeneration
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let key = BibleReaderDocumentPreparationKey(
            family: "memorize",
            paneID: paneID,
            workspaceID: workspaceID,
            source: .swordManager(
                manager: ObjectIdentifier(manager),
                generation: managerGeneration,
                requestedModules: [BibleReaderPreparationExactText(request.bookInitials)]
            ),
            contentIdentity: "memorize-request",
            annotationIdentity: .memorizeRequest(request.identity)
        )
        let baseAuthorization: () -> Bool = { [weak self, weak manager] in
            guard let self, let manager else { return false }
            return self.contentIntentGeneration == generation
                && (!routesOutward
                    || self.transientPreparationGeneration == outwardGeneration)
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && self.swordManager === manager
                && manager.contentAuthorizationGeneration == managerGeneration
        }
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: routesOutward ? .transient : .replacement,
            key: key,
            captureSource: { _ in
                BibleReaderPreparedMemorizeDocument.capture(
                    request: request,
                    manager: manager,
                    managerGeneration: managerGeneration,
                    optionSettings: optionSettings
                )
            },
            project: { (capture: BibleReaderMemorizeSourceCapture) in capture },
            captureOwner: { [weak self]
                (capture: BibleReaderMemorizeSourceCapture)
                    -> BibleReaderMemorizeOwnerSnapshot? in
                self?.memorizeOwnerSnapshot(capture)
            },
            enrichSource: {
                (_: BibleReaderMemorizeSourceCapture,
                 owner: BibleReaderMemorizeOwnerSnapshot) in owner
            },
            encode: {
                (capture: BibleReaderMemorizeSourceCapture,
                 owner: BibleReaderMemorizeOwnerSnapshot,
                 _: BibleReaderMemorizeOwnerSnapshot) -> BibleReaderEncodedMemorizeDocument? in
                guard let emission = BibleReaderPreparedMemorizeDocument.encode(
                    capture: capture,
                    owner: owner,
                    stateJSON: request.stateJSON
                ) else { return nil }
                return BibleReaderEncodedMemorizeDocument(
                    emission: emission,
                    capture: capture,
                    owner: owner
                )
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else { return }
            let routedAuthorization: BibleReaderRoutedSourceAuthorization?
            if case .prepared(let result) = outcome {
                routedAuthorization = self.routedSourceAuthorization(
                    for: result.capture.sourceDependencies
                )
            } else {
                routedAuthorization = nil
            }
            let memorizeIsCurrent: (BibleReaderEncodedMemorizeDocument) -> Bool = {
                [weak self] result in
                guard let self else { return false }
                return self.sourceDependenciesAreCurrent(result.capture.sourceDependencies)
                    && self.memorizeOwnerSnapshot(result.capture) == result.owner
                    && routedAuthorization?.isCurrent() == true
            }
            let disposition: BibleReaderPreparationPublicationDisposition
            if routesOutward {
                disposition = self.preparationPublicationOwner.publishOutward(
                    outcome,
                    destination: destination,
                    failurePolicy: .settle,
                    stalePolicy: .requestFreshCurrent,
                    isCurrent: memorizeIsCurrent,
                    route: { [weak self] result in
                        guard let self,
                              let routedAuthorization,
                              let open = outwardMemorizeOpen
                        else { return }
                        open(result.emission.authorized(by: routedAuthorization))
                    }
                )
            } else {
                disposition = self.preparationPublicationOwner.publishQueuedBridge(
                    outcome,
                    destination: destination,
                    failurePolicy: .settle,
                    stalePolicy: .requestFreshCurrent,
                    isCurrent: memorizeIsCurrent,
                    selectedIntent: .init(
                        commit: { [weak self] result in
                            guard let self, let routedAuthorization else { return }
                            self.prepareMemorizeVisibleState(emission: result.emission)
                            self.activeMemorizeRequest = result.emission.authorized(
                                by: routedAuthorization
                            )
                        },
                        isCurrentAfterCommit: memorizeIsCurrent
                    ),
                    isSourceCurrentAroundBridge: { [weak self] result in
                        self?.sourceDependenciesAreCurrent(
                            result.capture.sourceDependencies
                        ) == true && routedAuthorization?.isCurrent() == true
                    },
                    queueBridge: { [weak self] result in
                        self?.annotationDocumentLoader()
                            .dispatchMemorizeDocument(result.emission) == true
                    },
                    commitAcceptedRender: { [weak self] result in
                        self?.annotationDocumentLoader().commitMemorizeRender(result.emission)
                    }
                )
            }
            if disposition == .stale(.requestFreshCurrent), retriesOneStaleResult {
                _ = self.prepareMemorizeDocument(
                    request,
                    routeToLinksWindow: routeToLinksWindow,
                    retriesOneStaleResult: false
                )
            }
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
        prepareMemorizeDocument(
            BibleReaderMemorizePreparationRequest(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                currentBook: currentBook,
                currentChapter: currentChapter,
                osisBookID: osisBookId(for: currentBook),
                stateJSON: activeWindow?.pageManager?.jsState,
                directKJVAReferences: nil
            ),
            routeToLinksWindow: true
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
            guard let reference = JSwordKJVAVersification.referenceIncludingIntroductions(
                ordinal: ordinal
            ) else {
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
        return prepareMemorizeDocument(
            BibleReaderMemorizePreparationRequest(
                bookInitials: activeModuleName,
                startOrdinal: effectiveStart,
                endOrdinal: effectiveEnd,
                currentBook: Self.bookName(forOsisId: firstReference.osisBookId)
                    ?? firstReference.osisBookId,
                currentChapter: firstReference.chapter,
                osisBookID: firstReference.osisBookId,
                stateJSON: activeWindow?.pageManager?.jsState,
                directKJVAReferences: references
            ),
            routeToLinksWindow: true
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
        prepareStudyPadDocument(
            labelId: labelId,
            bookmarkId: bookmarkId,
            retriesOneStaleResult: true
        )
    }

    /** Prepares one exact StudyPad owner snapshot with at most one current-source refresh. */
    private func prepareStudyPadDocument(
        labelId: UUID,
        bookmarkId: UUID?,
        retriesOneStaleResult: Bool
    ) {
        let generation = beginReplacingContentIntent()
        let destination = preparationPublicationOwner.captureDestination()
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
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let manager = swordManager
        let managerGeneration = manager?.contentAuthorizationGeneration
        let activeSwordModule = activeModule
        let activeSwordInitials = activeSwordModule?.info.name ?? ""
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let capturedBookList = moduleBookList
        let capturedSQLiteModules = sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        let capturedCurrentBook = currentBook
        let key = BibleReaderDocumentPreparationKey(
            family: "study-pad",
            paneID: paneID,
            workspaceID: workspaceID,
            source: {
                guard let manager, let activeSwordModule else { return .independent }
                return .sword(
                    manager: ObjectIdentifier(manager),
                    module: ObjectIdentifier(activeSwordModule),
                    initials: BibleReaderPreparationExactText(activeSwordInitials),
                    generation: manager.contentAuthorizationGeneration,
                    modules: [BibleReaderPreparationExactText(activeSwordInitials)]
                )
            }(),
            contentIdentity: BibleReaderPreparationExactText(
                "\(labelId.uuidString)|\(bookmarkId?.uuidString ?? "")|\(generation)"
            ),
            annotationIdentity: .exactText(BibleReaderPreparationExactText(labelId.uuidString))
        )
        let baseAuthorization: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.contentIntentGeneration == generation
                && self.clientReady
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && self.swordManager === manager
                && self.activeModule === activeSwordModule
        }
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ -> BibleReaderPreparedStudyPadSourceRegistry? in
                let resolver = BibleReaderInstalledModuleResolver(
                    swordManager: manager,
                    sqliteModules: capturedSQLiteModules
                )
                guard manager == nil
                    || manager?.contentAuthorizationGeneration == managerGeneration else {
                    return nil
                }
                return BibleReaderPreparedStudyPadSourceRegistry(
                    installedResolver: resolver
                )
            },
            project: {
                (sourceRegistry: BibleReaderPreparedStudyPadSourceRegistry)
                    -> BibleReaderPreparedStudyPadSourceRegistry? in
                sourceRegistry
            },
            captureOwner: {
                [weak self] sourceRegistry -> BibleReaderPreparedStudyPadOwnerSnapshot? in
                guard let self, baseAuthorization(),
                      let snapshot = self.studyPadOwnerSnapshot(
                        labelID: labelId,
                        bookmarkID: bookmarkId,
                        installedResolver: sourceRegistry.installedResolver
                      ) else { return nil }
                return snapshot
            },
            enrichSource: {
                (sourceRegistry: BibleReaderPreparedStudyPadSourceRegistry,
                 owner: BibleReaderPreparedStudyPadOwnerSnapshot)
                    -> BibleReaderPreparedStudyPadEnrichment? in
                let renderedBible: [BibleBookmarkData]
                let renderedGeneric: [GenericBookmarkData]
                let nonSwordSources = Self.studyPadNonSwordGenericSources(
                    owner,
                    installedResolver: sourceRegistry.installedResolver
                )
                var dependencies = nonSwordSources.dependencies
                let makePayloadFactory = {
                    BibleReaderAnnotationPayloadFactory(
                        currentBook: capturedCurrentBook,
                        activeModuleName: activeSwordInitials,
                        activeModule: activeSwordModule,
                        sourceModuleResolver: { initials in
                            guard case .sword(let module)? = sourceRegistry.installedResolver.module(
                                named: initials
                            ) else { return nil }
                            return module
                        },
                        genericSourceResolver: { initials, key in
                            nonSwordSources.contents[
                                BibleReaderPreparedGenericBookmarkSourceKey(
                                    bookInitials: initials,
                                    key: key
                                )
                            ]
                        },
                        bookCatalog: BibleReaderBookCatalog(
                            activeModule: activeSwordModule,
                            moduleBookList: capturedBookList
                        ),
                        unlabeledLabelID: Self.unlabeledLabelId
                    )
                }
                if let manager, let managerGeneration {
                    guard let result = manager.performRenderOperation(settings: optionSettings, {
                        () -> (
                            [BibleBookmarkData],
                            [BibleReaderPreparedGenericBookmarkSource],
                            SwordContentAuthorizationSnapshot
                        )? in
                        let requestedNames = ([activeSwordInitials]
                            + owner.bookmarkInputs.map(\.sourceBookInitials)
                            + owner.genericBookmarkInputs.map(\.sourceBookInitials))
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
                        guard authorization.generation == managerGeneration else { return nil }
                        let payloadFactory = makePayloadFactory()
                        return (
                            owner.bookmarkInputs.map(payloadFactory.bookmarkJSONForStudyPad),
                            owner.genericBookmarkInputs.map {
                                payloadFactory.captureGenericBookmarkSource(for: $0)
                            },
                            authorization
                        )
                    }) else { return nil }
                    renderedBible = result.0
                    let purePayloadFactory = makePayloadFactory()
                    renderedGeneric = zip(owner.genericBookmarkInputs, result.1).map {
                        purePayloadFactory.genericBookmarkJSONForStudyPad(
                            $0.0,
                            capturedSource: $0.1
                        )
                    }
                    dependencies.insert(.sword(
                        manager: ObjectIdentifier(manager),
                        authorization: result.2
                    ), at: 0)
                } else {
                    let payloadFactory = makePayloadFactory()
                    renderedBible = owner.bookmarkInputs.map(payloadFactory.bookmarkJSONForStudyPad)
                    let capturedSources = owner.genericBookmarkInputs.map {
                        payloadFactory.captureGenericBookmarkSource(for: $0)
                    }
                    renderedGeneric = zip(owner.genericBookmarkInputs, capturedSources).map {
                        payloadFactory.genericBookmarkJSONForStudyPad(
                            $0.0,
                            capturedSource: $0.1
                        )
                    }
                    if dependencies.isEmpty {
                        dependencies = [.independent]
                    }
                }
                return BibleReaderPreparedStudyPadEnrichment(
                    bibleBookmarks: renderedBible,
                    genericBookmarks: renderedGeneric,
                    sourceDependencies: dependencies
                )
            },
            encode: {
                (sourceRegistry: BibleReaderPreparedStudyPadSourceRegistry,
                 owner: BibleReaderPreparedStudyPadOwnerSnapshot,
                 enrichment: BibleReaderPreparedStudyPadEnrichment)
                    -> BibleReaderEncodedStudyPadDocument? in
                let prepared = BibleReaderPreparedStudyPadDocument(
                    labelID: owner.labelID,
                    displayName: owner.displayName,
                    jumpToID: owner.jumpToID,
                    sourceDependencies: enrichment.sourceDependencies,
                    label: owner.label,
                    bookmarkInputs: owner.bookmarkInputs,
                    bookmarks: enrichment.bibleBookmarks,
                    genericBookmarkInputs: owner.genericBookmarkInputs,
                    genericBookmarks: enrichment.genericBookmarks,
                    bookmarkToLabels: owner.bookmarkToLabels,
                    genericBookmarkToLabels: owner.genericBookmarkToLabels,
                    journalTextEntries: owner.journalTextEntries,
                    labels: owner.labels
                )
                guard let json = prepared.encodedJSON() else { return nil }
                return BibleReaderEncodedStudyPadDocument(
                    prepared: prepared,
                    documentJSON: json,
                    sourceRegistry: sourceRegistry
                )
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else { return }
            let sourceGenerationChanged = manager != nil
                && manager?.contentAuthorizationGeneration != managerGeneration
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: sourceGenerationChanged ? .requestFreshCurrent : .settle,
                stalePolicy: .requestFreshCurrent,
                isCurrent: { [weak self] result in
                    guard let self,
                          self.sourceDependenciesAreCurrent(result.prepared.sourceDependencies),
                          let current = self.studyPadOwnerSnapshot(
                            labelID: labelId,
                            bookmarkID: bookmarkId,
                            installedResolver: result.sourceRegistry.installedResolver
                          ) else { return false }
                    return current.identity == result.prepared.ownerIdentity
                },
                selectedIntent: .init(
                    commit: { [weak self] result in
                        guard let self else { return }
                        self.showingMyNotes = false
                        self.activeMyNotesReference = nil
                        self.showingStudyPad = true
                        self.activeStudyPadLabelId = labelId
                        self.activeStudyPadLabelName = result.prepared.displayName
                        self.editingInWebView = false
                        self.clearNativeSelectionState()
                    },
                    isCurrentAfterCommit: { [weak self] result in
                        guard let self,
                              self.sourceDependenciesAreCurrent(
                                result.prepared.sourceDependencies
                              ),
                              let current = self.studyPadOwnerSnapshot(
                                labelID: labelId,
                                bookmarkID: bookmarkId,
                                installedResolver: result.sourceRegistry.installedResolver
                              ) else { return false }
                        return current.identity == result.prepared.ownerIdentity
                    }
                ),
                queueBridgePrerequisites: { [weak self] result in
                    self?.annotationDocumentLoader().prepareStudyPadDispatch(result)
                },
                isSourceCurrentAroundBridge: { [weak self] result in
                    self?.sourceDependenciesAreCurrent(
                        result.prepared.sourceDependencies
                    ) == true
                },
                queueBridge: { [weak self] result in
                    self?.annotationDocumentLoader().dispatchStudyPadDocument(result) == true
                },
                commitAcceptedRender: { [weak self] result in
                    self?.annotationDocumentLoader().commitStudyPadRender(result)
                }
            )
            switch disposition {
            case .failed(.requestFreshCurrent) where retriesOneStaleResult,
                 .stale(.requestFreshCurrent) where retriesOneStaleResult:
                self.prepareStudyPadDocument(
                    labelId: labelId,
                    bookmarkId: bookmarkId,
                    retriesOneStaleResult: false
                )
            case .accepted, .bridgeRejected, .dispatchedStale, .cancelled,
                 .failed(.settle), .failed(.requestFreshCurrent),
                 .stale(.settle), .stale(.requestFreshCurrent):
                break
            }
        }
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
    case .definition(let items),
         .multiDefinition(let items):
            let emitsEmptyMultiOnMiss: Bool
            if case .multiDefinition = route {
                emitsEmptyMultiOnMiss = true
            } else {
                emitsEmptyMultiOnMiss = false
            }
            logger.info("handleExternalLinkRoute.definition: items=\(String(describing: items))")
            _ = prepareDefinitionDocument(
                source: .strongs(
                    items: items,
                    emitsEmptyMultiOnMiss: emitsEmptyMultiOnMiss
                ),
                stateJSON: currentStrongsDocumentStateJSON(),
                renderedBook: "Strongs",
                renderedKey: "strongs",
                routesOutward: true
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
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(from: documentJSON),
            sourceAuthorization: .independent
        )
    }

    /**
     Renders a typed definition request and retains its source operation for reconstruction.

     - Parameter request: Strong's or word-lookup inputs paired with the initial authorized payload.
     - Returns: No direct value; successful replacement commits Android's `Multi` identity.
     - Side effects: Emits a transient Vue document, persists fake-document page state, and retains
       the source operation for extraction-setting invalidation.
     - Failure modes: Bridge rejection leaves the prior committed source operation in place.
     */
    func loadDefinitionDocument(_ request: BibleReaderDefinitionRenderRequest) {
        guard request.sourceAuthorization.isCurrent() else { return }
        let accepted = loadTransientMultiDocument(
            request.initialDocumentJSON,
            renderedBook: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            renderedKey: request.renderedKey,
            renderedCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            renderedModuleName: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageCategory: AndroidSpecialDocumentIdentity.multiDocumentCategory,
            pageDocumentInitials: AndroidSpecialDocumentIdentity.multiDocumentInitials,
            pageKey: AndroidSpecialDocumentIdentity.bookAndKeyListReference(
                from: request.initialDocumentJSON
            ),
            sourceAuthorization: request.sourceAuthorization,
            rebuildRequest: .definition(request.replayRequest)
        )
        guard accepted else { return }
        request.preferredFamilyUpdates.forEach {
            AndroidStrongsKeyPreferenceCache.shared.record(
                $0.family,
                moduleInitials: $0.moduleInitials
            )
        }
        request.onAccepted?()
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
     - Side effects: None; this reads the committed typed render identity and active page-manager
       state.
     - Failure modes: Missing saved state produces `nil`, which lets Vue choose its default tab.
     */
    private func currentStrongsDocumentStateJSON() -> String? {
        guard committedRenderState.identity?.key == "strongs" else { return nil }
        return activeWindow?.pageManager?.jsState
    }

    /**
     Builds the Android-style Strong's `MultiDocument` payload for ordered bridge routing.

     The controller only supplies pane dependencies; lookup, module selection, linkification, and
     fallback-document construction are owned by `BibleReaderStrongsDocumentBuilder`. Multi-link
     dispatch remains explicit because Android opens an empty `MultiDocument` when every child
     misses, while a single missing Strong's entry leaves the current page unchanged.

     - Parameters:
       - items: Ordered Strong's and morphology children collected from the route.
       - stateJSON: Optional Vue tab state restored into the destination document.
       - emitsEmptyMultiOnMiss: Whether the source route used Android's `openMulti` branch.
     - Returns: Serialized definition document, or `nil` for a single unresolved Strong's link.
     - Side effects: Reads installed dictionary sources and their current settings-backed selection.
     - Failure modes: Backend misses and serialization failures follow the delegated builder rules.
     */
    private func buildStrongsMultiDocJSON(
        items: [BibleReaderDefinitionItem],
        stateJSON: String? = nil,
        emitsEmptyMultiOnMiss: Bool
    ) -> String? {
        strongsDocumentBuilder().buildStrongsMultiDocumentJSON(
            items: items,
            stateJSON: stateJSON,
            emitsEmptyMultiOnMiss: emitsEmptyMultiOnMiss
        )
    }

    /**
     Builds a Strong's document from the compatibility array API used by direct controller tests.

     - Parameters:
       - strongs: Ordered Strong's values placed before morphology values in the result.
       - robinson: Ordered Robinson morphology values placed after Strong's values in the result.
       - stateJSON: Optional Vue tab state restored into the destination document.
     - Returns: Serialized definition document, or `nil` for a single unresolved Strong's link.
     - Side effects: Reads installed dictionary sources and their current settings-backed selection.
     - Failure modes: Backend misses and serialization failures follow the delegated builder rules.
     */
    func buildStrongsMultiDocJSON(
        strongs: [String],
        robinson: [String],
        stateJSON: String? = nil
    ) -> String? {
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
                SwordJavaExactStringSet(
                    self?.settingsStore?.getStringSet(.disabledWordLookupDictionaries) ?? []
                )
            }
        )
    }

    /**
     Schedules source-aware Bible references without reading installed entries on the main owner.

     - Parameters:
       - refs: Ordered source-domain passages from Search, OSIS, or Multi link parsing.
       - routeToLinksWindow: Whether a completed payload should use the configured links pane.
     - Returns: `true` when non-empty references entered the preparation coordinator.
     - Side effects: Captures and encodes the complete document off-main, then may route or publish
       it after exact source and pane authorization.
     - Failure modes: Empty inputs fail immediately; unresolved or stale sources settle without a
       routed payload.
     */
    @discardableResult
    private func prepareMultiReferenceDocument(
        refs: [OsisRef],
        routeToLinksWindow: Bool
    ) -> Bool {
        guard !refs.isEmpty else { return false }
        return prepareCompositeDocument(
            .multiReferences(
                BibleReaderMultiReferencePreparationRequest(
                    references: refs,
                    activeModuleName: activeModuleName
                )
            ),
            routeMultiToLinksWindow: routeToLinksWindow
        )
    }

    /**
     Builds the operation-scoped installed/local document authorization service for this pane.

     - Returns: A service bound to the current native/SQLite registrations, persisted My Documents
       store, active immutable EPUB generation, and active-versification commentary resolver.
     - Side effects: Captures the current SQLite registration array; no content or local metadata is
       read until a service operation is invoked.
     - Failure modes: Missing optional backends remain nil and cause the corresponding authorization
       operation to fail closed.
     */
    private func documentAuthorizationService() -> BibleReaderDocumentAuthorizationService {
        BibleReaderDocumentAuthorizationService(
            swordManager: swordManager,
            sqliteModules: sqliteRuntimeCoordinator.unshadowedSQLiteModules(),
            myDocumentStore: myDocumentStore,
            activeEpubReader: activeEpubReader,
            resolveCommentaryReference: { [weak self] key in
                self?.referenceResolver().resolveReference(key)
            }
        )
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
        documentAuthorizationService().installedModuleResolver()
    }

    /**
     Returns the inclusive global owner selected for one installed-document token.

     - Parameter name: Initials or full-name token from persisted state, bridge input, or AI routing.
     - Returns: Canonical admitted metadata, including a currently locked native owner, or nil when
       Android's installed registry does not own the token.
     - Side effects: Captures fresh native access metadata and replays immutable custom admission;
       no installed or local content is read.
     - Failure modes: Missing and Java-distinct identities return nil without normalization.
     */
    func registeredInstalledModuleInfo(named name: String) -> ModuleInfo? {
        installedModuleResolver().registeredModuleInfo(named: name)
    }

    /**
     Returns installed document-picker rows with Android's exact display abbreviations.

     - Returns: Globally admitted native and SQLite books preserving final JSword TreeSet ownership
       metadata; the chooser applies its visible category filter.
     - Side effects: Captures one fresh installed resolver; no content is read and reader state is
       unchanged.
     - Failure modes: Missing, unsupported, and shadowed rows are omitted by registry admission
       rather than reconstructed from stale controller arrays.
     */
    func installedBookPresentationsForDocumentPicker() -> [BibleReaderInstalledBookPresentation] {
        installedModuleResolver().registeredBookPresentations()
    }

    /**
     Authorizes one installed AI window-document request and validates its optional key atomically.

     - Parameters:
       - name: Initials or full-name token resolved through the global JSword registry tiers.
       - category: Exact category reported by the inclusive installed-owner lookup.
       - key: Optional non-empty Bible/commentary reference or generic source key.
     - Returns: A readable-source authorization containing the canonical source key/reference, or a
       typed source/key rejection that the live-window router can report before switching panes.
     - Side effects: Captures fresh installed ownership and may enumerate exact generic keys or
       inspect cursor-restoring SWORD reference metadata; it never mutates controller, pane,
       persistence, navigation, or rendered-content state.
     - Failure modes: Locked, replaced, missing, and wrong-category owners return
       `.sourceUnavailable`. Invalid references, absent exact Java keys, SQLite query failures, and
       unsupported installed backend/category pairs return `.keyUnavailable`.
     */
    func preflightInstalledWindowDocument(
      named name: String,
      category: ModuleCategory,
      key: String?
    ) -> BibleReaderInstalledWindowDocumentPreflight {
      documentAuthorizationService().preflightInstalledWindowDocument(
        named: name,
        category: category,
        key: key
      )
    }

    /**
     Reports whether Android's complete installed/local registry owns a proposed document token.

     - Parameter name: Candidate My Documents initials generated or explicitly restored by a caller.
     - Returns: True for exact initials, exact full-name, or Java case-tier ownership. Local metadata
       failures also return true so creation fails closed rather than publishing a colliding book.
     - Side effects: Reads installed/local metadata and opens immutable EPUB generations only.
     - Failure modes: None exposed; metadata errors conservatively reserve the candidate.
     */
    func hasRegisteredDocument(named name: String) -> Bool {
        documentAuthorizationService().hasRegisteredDocument(named: name)
    }

    /**
     Resolves a My Documents or EPUB source only after the global registry declines ownership.

     - Parameters:
       - name: Exact local initials token, also checked against installed initials/full-name/case tiers.
       - preferredEpub: Already retained EPUB generation to reuse without opening another generation.
       - resolver: Optional operation-owned installed snapshot; restore supplies one shared snapshot.
     - Returns: The owner selected after Android's EPUB-then-My Documents registration and global
       exact-initials, exact-name, then case-insensitive TreeSet lookup tiers.
     - Side effects: Captures installed metadata, reads ordered local document/EPUB metadata, and
       opens immutable EPUB generations; it never reads a My Documents page or EPUB fragment.
     - Failure modes: Candidate initials owned by an earlier installed/local book are rejected.
       My Documents metadata failures and absent owners fail closed without state mutation.
     */
    func localGeneralBookDocument(
        named name: String,
        preferredEpub: EpubReader? = nil,
        resolver: BibleReaderInstalledModuleResolver? = nil
    ) -> LocalGeneralBookDocument? {
        documentAuthorizationService().localDocument(
            named: name,
            preferredEpub: preferredEpub,
            resolver: resolver
        )
    }

    /**
     Captures the complete installed/EPUB/My Documents owner for one Android book token.

     - Parameters mirror `localGeneralBookDocument`; local metadata remains entry-content-free.
     - Returns: Deterministic JSword owner, or nil when My Documents metadata cannot be read.
     - Side effects: Reads installed/local metadata and opens immutable EPUB generations only.
     - Failure modes: Local metadata failure returns nil so callers fail before content or state.
     */
    private func installedOrLocalGeneralBookOwner(
        named name: String,
        preferredEpub: EpubReader? = nil,
        resolver: BibleReaderInstalledModuleResolver? = nil
    ) -> BibleReaderInstalledOrLocalDocumentOwner<LocalGeneralBookDocument>? {
        documentAuthorizationService().owner(
            named: name,
            preferredEpub: preferredEpub,
            resolver: resolver
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
        _ = prepareMultiReferenceDocument(refs: refs, routeToLinksWindow: true)
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
           Self.normalizedVersificationName(VersificationMapper.versificationName(for: activeModule))
        == Self.normalizedVersificationName(sourceVersification)
    {
            return activeModule
        }
        for info in installedBibleModules {
            guard let module = swordManager?.module(named: info.name) else { continue }
            if Self.normalizedVersificationName(VersificationMapper.versificationName(for: module))
        == Self.normalizedVersificationName(sourceVersification)
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

    if activeInstalledScriptureSource().map({
      SwordJavaStringIdentity.equals($0.info.name, target.moduleName)
    }) != true
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
    guard activeInstalledScriptureSource().map({
      SwordJavaStringIdentity.equals($0.info.name, target.moduleName)
    }) == true,
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
      if let module = activeSQLiteBibleModule,
        SwordJavaStringIdentity.equals(module.info.name, initials) {
        sourceVersification = BibleReaderSQLiteSourceMetadata(module: module).versification
        sourceOrdinal = JSwordKJVAVersification.verseOrdinal(
          osisId: osisBookID,
          chapter: currentChapter,
          verse: verse
        )
      } else if let module = activeModule,
        SwordJavaStringIdentity.equals(module.info.name, initials) {
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
    case .sqlite(let sqlitePlan):
      try commitSQLiteBookmarkNavigation(sqlitePlan)
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
   - Side effects: Enumerates installed source registries and local EPUB/My Documents registration
     metadata in Android add order; no page, EPUB fragment, reader, or WebView state is read.
   - Throws: A typed lookup failure when local registration metadata cannot be captured. Locked
     native and registered SQLite owners suppress colliding EPUB and My Documents candidates.
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
    let genericInstalledSources = resolver.modules(categories: genericSwordCategories)
    let genericSwordCandidates = genericInstalledSources
      .compactMap { source -> SwordModule? in
        guard case .sword(let module) = source else { return nil }
        return module
      }
      .map(BibleReaderBookmarkNavigationSwordCandidate.init(module:))
    let genericSQLiteCandidates = genericInstalledSources
      .compactMap { source -> BibleReaderSQLiteModuleHandle? in
        guard case .sqlite(let module) = source else { return nil }
        return module
      }
      .map(BibleReaderBookmarkNavigationSQLiteCandidate.init(module:))
    let destinationCandidate = activeInstalledScriptureSource().map(
      BibleReaderBookmarkNavigationSwordCandidate.init(source:)
    )

    guard case .generic(let genericTarget) = target else {
      return BibleReaderBookmarkNavigationInventory(
        destinationBible: destinationCandidate,
        swordCandidates: scriptureCandidates
      )
    }

    guard let owner = installedOrLocalGeneralBookOwner(
      named: genericTarget.moduleInitials,
      resolver: resolver
    ) else {
      throw BibleReaderBookmarkNavigationFailure.genericKeyLookupFailed(
        moduleInitials: genericTarget.moduleInitials,
        key: genericTarget.key
      )
    }
    let documentCandidates: [MyDocument]
    let epubReaders: [EpubReader]
    switch owner {
    case .local(.myDocument(let document)):
      documentCandidates = [document]
      epubReaders = []
    case .local(.epub(let reader)):
      documentCandidates = []
      epubReaders = [reader]
    case .installed, .missing:
      documentCandidates = []
      epubReaders = []
    }
    return BibleReaderBookmarkNavigationInventory(
      destinationBible: destinationCandidate,
      swordCandidates: scriptureCandidates + genericSwordCandidates,
      sqliteCandidates: genericSQLiteCandidates,
      myDocumentCandidates: myDocumentStore.map { store in
        documentCandidates.map {
          BibleReaderBookmarkNavigationMyDocumentCandidate(document: $0, store: store)
        }
      } ?? [],
      epubCandidates: epubReaders.map(BibleReaderBookmarkNavigationEpubCandidate.init(reader:))
    )
  }

  /**
   Builds the operation-scoped bookmark commit preflight service for this pane.

   - Returns: A service bound to fresh installed/local ownership and the persisted My Documents
     store; the controller remains the sole owner of visible commit mutation.
   - Side effects: Captures the current SQLite registration array only.
   - Failure modes: Missing optional persistence is retained as nil and fails closed only when a My
     Documents plan is reauthorized.
   */
  private func bookmarkCommitPreflightService() -> BibleReaderBookmarkCommitPreflightService {
    BibleReaderBookmarkCommitPreflightService(
      authorization: documentAuthorizationService(),
      myDocumentStore: myDocumentStore
    )
  }

  /** Commits one fully mapped Bible range into the already-selected destination module. */
  @MainActor
  func commitBibleBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationBiblePlan
  ) throws {
    guard let source = activeInstalledScriptureSource(),
      source.info.category == .bible,
      SwordJavaStringIdentity.equals(source.info.name, plan.destinationModuleInitials),
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
      guard activeInstalledScriptureSource().map({
        SwordJavaStringIdentity.equals($0.info.name, source.info.name)
      }) == true,
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
    let destination = try bookmarkCommitPreflightService().swordDestination(for: plan)
    let module = destination.module
    let currentFragment = destination.fragment
    guard let category = Self.bookmarkDocumentCategory(for: plan.category) else {
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
      sourceProvenance: .swordModules([plan.moduleInitials]),
      selectedOrdinalRange: plan.selectedOrdinalRange,
      jumpToID: nil
    )
  }

  /**
   Reauthorizes and commits one exact Android SQLite commentary or dictionary bookmark.

   - Parameter plan: Detached structural fragment produced by the exact bookmark planner.
   - Side effects: Re-resolves global ownership, re-reads the exact key, serializes it, then updates
     category-owned backend/pane state and replaces Vue content only after every proof succeeds.
   - Throws: Typed lookup failures for removed/unreadable keys, `destinationChanged` when source
     metadata or content changed, and `serializationFailed` before any reader mutation.
   */
  @MainActor
  func commitSQLiteBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationSQLitePlan
  ) throws {
    let destination = try bookmarkCommitPreflightService().sqliteDestination(for: plan)
    let module = destination.module
    let currentFragment = destination.fragment
    guard let category = Self.bookmarkDocumentCategory(for: currentFragment.category),
      let documentJSON = documentPayloadFactory().documentJSON(
        currentFragment.payloadRequest(
          selectedOrdinalRange: plan.selectedOrdinalRange
        )
      )
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.serializationFailed
    }

    beginReplacingContentIntent()
    resetAuxiliaryContentState()
    applyExactSQLiteBookmarkState(
      module: module,
      category: category,
      key: currentFragment.key
    )
    emitExactGenericBookmarkDocument(
      documentJSON: documentJSON,
      category: category,
      moduleName: currentFragment.moduleInitials,
      bookName: currentFragment.keyName,
      key: currentFragment.key,
      sourceProvenance: .sqliteModules([currentFragment.moduleInitials]),
      selectedOrdinalRange: plan.selectedOrdinalRange,
      jumpToID: nil
    )
  }

  /**
   Reauthorizes and commits one exact My Documents page without permissive fetch fallback.

   - Parameter plan: Detached local-page identity and content captured by bookmark planning.
   - Side effects: Replays fresh combined registry ownership before reading the exact page; after
     every identity/content proof succeeds, updates pane state, persists once, and emits one Vue
     document.
   - Throws: `destinationChanged` when another installed/local registration now owns the token or
     the selected document changed; typed exact-key failures and serialization failures occur before
     any reader mutation.
   */
  @MainActor
  func commitMyDocumentBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationMyDocumentPlan
  ) throws {
    let plannedPage: MyDocumentPage? = try? myDocumentStore?.exactPage(
      bookInitials: plan.fragment.moduleInitials,
      pageKey: plan.fragment.key
    )
    guard let page = plannedPage,
          let document = page.document,
          document.id == plan.fragment.documentID,
          page.id == plan.fragment.pageID,
          BibleReaderPreparationExactText(document.name)
            == BibleReaderPreparationExactText(plan.fragment.documentName),
          BibleReaderPreparationExactText(page.title)
            == BibleReaderPreparationExactText(plan.fragment.title),
          BibleReaderPreparationExactText(page.contentTypeRawValue)
            == BibleReaderPreparationExactText(plan.fragment.contentTypeRawValue),
          BibleReaderPreparationExactText(page.pageContent?.content ?? "")
            == BibleReaderPreparationExactText(plan.fragment.rawContent)
    else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }
    let actualLanguage = page.languageCode.map { BibleReaderPreparationExactText($0) }
    let expectedLanguage = plan.fragment.languageCode.map {
      BibleReaderPreparationExactText($0)
    }
    guard actualLanguage == expectedLanguage else {
      throw BibleReaderBookmarkNavigationCommitFailure.destinationChanged
    }
    guard prepareMyDocumentPage(
      requestedInitials: plan.fragment.moduleInitials,
      requestedKey: plan.fragment.key,
      selectedOrdinalRange: plan.selectedOrdinalRange,
      expectedFragment: plan.fragment
    ) else {
      throw BibleReaderBookmarkNavigationCommitFailure.readerUnavailable
    }
  }

  /**
   Reauthorizes and commits one exact immutable EPUB generation and numeric key.

   - Parameter plan: Detached EPUB generation/content identity captured by bookmark planning.
   - Side effects: Replays fresh combined registry ownership before opening the exact fragment; after
     every generation/content proof succeeds, updates pane state, persists once, and emits one Vue
     document.
   - Throws: `destinationChanged` when an installed/local collision or replacement now owns the
     token; typed exact-key and serialization failures occur before any reader mutation.
   */
  @MainActor
  func commitEpubBookmarkNavigation(
    _ plan: BibleReaderBookmarkNavigationEpubPlan
  ) throws {
    let destination = try bookmarkCommitPreflightService().epubDestination(for: plan)
    let reader = destination.reader
    let content = destination.content
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
      sourceProvenance: .independent,
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

  /**
   Applies category-owned Android SQLite state after exact bookmark content is fully revalidated.

   - Parameters:
     - module: Fresh globally authorized SQLite owner.
     - category: Executable commentary or dictionary reader category.
     - key: Exact persisted source key.
   - Side effects: Clears the counterpart SWORD/local backend, updates observable category state,
     persists the module/key selection, and invokes the pane persistence callback once.
   - Failure modes: Unsupported categories return without mutation; callers validate the category
     before invoking this helper.
   */
  @MainActor
  private func applyExactSQLiteBookmarkState(
    module: BibleReaderSQLiteModuleHandle,
    category: DocumentCategory,
    key: String
  ) {
    guard category == .commentary || category == .dictionary else { return }
    activeEpubReader = nil
    activeEpubIdentifier = nil
    activeEpubTitle = nil
    currentEpubTitle = nil
    currentEpubHref = nil
    switch category {
    case .commentary:
      activeCommentaryModule = nil
      activeSQLiteCommentaryModule = module
      activeCommentaryModuleName = module.info.name
    case .dictionary:
      activeDictionaryModule = nil
      activeSQLiteDictionaryModule = module
      activeDictionaryModuleName = module.info.name
      currentDictionaryKey = key
    case .bible, .generalBook, .map, .epub, .dailyDevotion:
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
    sourceProvenance: BibleReaderRenderSourceProvenance,
    selectedOrdinalRange: ClosedRange<Int>?,
    jumpToID: String?
  ) {
    guard replaceDocument(
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
    ) else { return }
    setRenderedContentState(
      category: category,
      moduleName: moduleName,
      book: bookName,
      key: key,
      sourceProvenance: sourceProvenance
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

    return prepareMultiReferenceDocument(refs: references, routeToLinksWindow: false)
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
     - Side effects: After fresh combined-owner and immutable-generation authorization, loads the
       resolved numeric EPUB fragment or emits an in-page setup request.
     - Failure modes: Ignores links whose Java-exact initials do not match the active EPUB, whose
       generation was replaced, or whose identity gained an installed/earlier-local owner. Missing
       manifest keys fail without navigation; element ids are forwarded to the renderer and may be
       absent from the target document.
     */
  public func bridge(
    _ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String
  ) {
    guard let expectedReader = activeEpubReader,
      SwordJavaStringIdentity.equals(bookInitials, expectedReader.initials),
      let localDocument = localGeneralBookDocument(
        named: expectedReader.initials,
        preferredEpub: expectedReader
      ),
      case .epub(let reader) = localDocument,
      reader.identifier == expectedReader.identifier,
      reader.generationIdentifier == expectedReader.generationIdentifier,
      SwordJavaStringIdentity.equals(reader.initials, expectedReader.initials)
    else {
      return
    }
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
     - Returns: `true` when the bridge accepts the complete replacement event sequence.
     - Failure modes: Logs and returns `false` when setup encoding or bridge dispatch fails.
     */
    @discardableResult
    private func replaceDocument(
        documentJSON: String,
        setup: ReaderSetupContentPayload
    ) -> Bool {
        guard documentReplacementEmitter().replace(
            documentJSON: documentJSON,
            setup: setup
        ) else {
            logger.error("Failed to emit atomic Vue document replacement")
            return false
        }
        return true
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
    private func loadCurrentChapter(retriesOneStaleResult: Bool = true) {
        guard activeModule != nil || activeSQLiteBibleModule != nil else {
            loadCurrentChapterSynchronously()
            return
        }

        let generation = beginReplacingContentIntent(cancelPreparedWork: false)
        persistMyNotesPageCategory(visible: false)
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        clearNativeSelectionState()

        let book = currentBook
        let chapter = currentChapter
        let osisBookId = osisBookId(for: book)
        let navigationAnchorRange = pendingLinkNavigationOrdinalRange
            ?? navigationCoordinator.originalNavigationOrdinalRange
        let preliminarySetupIdentity: String
        if let navigationAnchorRange {
            preliminarySetupIdentity =
                "anchor:\(navigationAnchorRange.map(String.init).joined(separator: ","))"
        } else {
            let preliminaryRestoreTarget = navigationCoordinator.contentRestoreTarget(
                currentPosition: BibleReaderNavigationPosition(
                    book: book,
                    chapter: chapter,
                    verse: currentVerse
                )
            ) { _, _, verse in verse }
            switch preliminaryRestoreTarget {
            case .chapterTop:
                preliminarySetupIdentity = "top"
            case .ordinal(let ordinal):
                preliminarySetupIdentity = "ordinal-or-verse:\(ordinal)"
            }
        }
        let paneID = activeWindow?.id
        let workspaceID = activeWindow?.workspace?.id
        let destination = preparationPublicationOwner.captureDestination()
        let contentIdentity = BibleReaderPreparationExactText(
            "\(osisBookId).\(chapter)|headings=\(shouldIncludeSwordHeadings())|setup=\(preliminarySetupIdentity)"
        )

        guard let sourcePreparation = bibleSourcePreparation(
            osisBookId: osisBookId,
            chapter: chapter,
            bookName: book
        ) else { return }

        let key = BibleReaderDocumentPreparationKey(
            family: "bible",
            paneID: paneID,
            workspaceID: workspaceID,
            source: sourcePreparation.identity,
            contentIdentity: contentIdentity,
            annotationIdentity: .exactText(BibleReaderPreparationExactText(preliminarySetupIdentity))
        )
        let enrichAnnotations = sourcePreparation.enrichAnnotations
        let baseAuthorization: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.contentIntentGeneration == generation
                && self.currentCategory == .bible
                && SwordJavaStringIdentity.equals(self.currentBook, book)
                && self.currentChapter == chapter
                && self.activeWindow?.id == paneID
                && self.activeWindow?.workspace?.id == workspaceID
                && sourcePreparation.isCurrent()
        }
        documentPreparationCoordinator.submitWithOwnerCaptureReportingOutcome(
            scope: .replacement,
            key: key,
            captureSource: { _ in sourcePreparation.capture() },
            project: { (capture: BibleReaderBibleChapterSourceCapture) in
                capture.projectedChapter()
            },
            captureOwner: { [weak self]
                (projected: BibleReaderProjectedBibleChapter) -> BibleReaderBibleDocumentOwnerSnapshot? in
                guard let self else { return nil }
                let setupIdentity = self.bibleChapterSetupIdentity(
                    book: book,
                    chapter: chapter,
                    navigationAnchorRange: navigationAnchorRange,
                    structure: projected.structure
                )
                return self.bibleChapterOwnerSnapshot(
                    book: book,
                    chapter: chapter,
                    osisBookId: osisBookId,
                    structure: projected.structure,
                    navigationAnchorRange: navigationAnchorRange,
                    setupIdentity: setupIdentity
                )
            },
            enrichSource: { _, ownerSnapshot in
                enrichAnnotations(ownerSnapshot.bookmarks)
            },
            encode: {
                (projected: BibleReaderProjectedBibleChapter,
                 ownerSnapshot: BibleReaderBibleDocumentOwnerSnapshot,
                 annotations: BibleReaderPreparedBibleAnnotations)
                    -> BibleReaderEncodedBibleChapter? in
                guard let documentJSON = ownerSnapshot.payload(
                    loadedChapter: projected.loadedChapter,
                    source: projected.source,
                    renderedBookmarks: annotations.bookmarks
                ).encodedJSON() else { return nil }
                return BibleReaderEncodedBibleChapter(
                    documentJSON: documentJSON,
                    loadedChapter: projected.loadedChapter,
                    structure: projected.structure,
                    ownerIdentity: ownerSnapshot.identity,
                    sourceDependencies: annotations.sourceDependencies
                )
            },
            isAuthorized: baseAuthorization
        ) { [weak self] outcome in
            guard let self else { return }
            let disposition = self.preparationPublicationOwner.publishQueuedBridge(
                outcome,
                destination: destination,
                failurePolicy: .settle,
                stalePolicy: .requestFreshCurrent,
                isCurrent: { [weak self] prepared in
                    guard let self,
                          self.sourceDependenciesAreCurrent(prepared.sourceDependencies)
                    else { return false }
                    let currentNavigationAnchor = self.pendingLinkNavigationOrdinalRange
                        ?? self.navigationCoordinator.originalNavigationOrdinalRange
                    let currentSetupIdentity = self.bibleChapterSetupIdentity(
                        book: book,
                        chapter: chapter,
                        navigationAnchorRange: currentNavigationAnchor,
                        structure: prepared.structure
                    )
                    let currentOwnerIdentity = self.bibleChapterOwnerSnapshot(
                        book: book,
                        chapter: chapter,
                        osisBookId: osisBookId,
                        structure: prepared.structure,
                        navigationAnchorRange: currentNavigationAnchor,
                        setupIdentity: currentSetupIdentity
                    ).identity
                    return currentNavigationAnchor == navigationAnchorRange
                        && BibleReaderPreparationExactText(currentSetupIdentity)
                            == prepared.ownerIdentity.setupIdentity
                        && currentOwnerIdentity == prepared.ownerIdentity
                },
                queueBridgePrerequisites: { [weak self] _ in
                    self?.sendLabelsToVueJS()
                },
                isSourceCurrentAroundBridge: { [weak self] prepared in
                    self?.sourceDependenciesAreCurrent(prepared.sourceDependencies) == true
                },
                queueBridge: { [weak self] prepared in
                    guard let self else { return false }
                    let setupPayload = self.bibleChapterSetupPayload(
                        book: book,
                        chapter: chapter,
                        osisBookId: osisBookId,
                        navigationAnchorRange: navigationAnchorRange,
                        structure: prepared.structure
                    )
                    return self.replaceDocument(
                        documentJSON: prepared.documentJSON,
                        setup: setupPayload
                    )
                },
                commitAcceptedRender: { [weak self] _ in
                    guard let self else { return }
                    if self.pendingLinkNavigationOrdinalRange == navigationAnchorRange {
                        self.pendingLinkNavigationOrdinalRange = nil
                    }
                    self.navigationCoordinator.commitAcceptedContentRestore(
                        originalOrdinalRange: navigationAnchorRange
                    )
                    self.infiniteScrollCoordinator.reset(book: book, chapter: chapter)
                    self.setRenderedContentState(
                        category: .bible,
                        moduleName: self.activeModuleName,
                        book: book,
                        chapter: chapter,
                        key: "\(osisBookId).\(chapter)",
                        sourceProvenance: sourcePreparation.provenance,
                        extractionDependency: sourcePreparation.extractionDependency
                    )
                    self.emitActiveState()
                    self.bridge.clearSelection()
                    self.applyNightModeBackground()
                }
            )
            switch disposition {
            case .failed(.settle):
                self.publishCurrentBibleNoContent(
                    generation: generation,
                    osisBookId: osisBookId,
                    book: book,
                    chapter: chapter
                )
            case .stale(.requestFreshCurrent) where retriesOneStaleResult:
                self.loadCurrentChapter(retriesOneStaleResult: false)
            case .bridgeRejected:
                self.navigationCoordinator.prepareForContentReload()
            case .accepted, .dispatchedStale, .cancelled, .failed(.requestFreshCurrent),
                 .stale(.settle), .stale(.requestFreshCurrent):
                break
            }
        }
    }

    /**
     Captures the exact active Bible backend and builds one bounded native read transaction.

     - Parameters:
       - osisBookId: Source-versification book identifier to capture.
       - chapter: One-based chapter to capture.
       - bookmarks: Persistence-only bookmark inputs to enrich inside the source transaction.
     - Returns: Immutable source identity, provenance, authorization, and capture closure, or nil
       when no readable Bible backend is active.
     - Side effects: The returned closure performs one serialized SWORD option/read transaction or
       one SQLite chapter read when the preparation coordinator invokes it.
     - Failure modes: Missing, relocked, or unreadable sources make capture or authorization fail.
     */
    private func bibleSourcePreparation(
        osisBookId: String,
        chapter: Int,
        bookName: String
    ) -> BibleReaderBibleSourcePreparation? {
        if let module = activeModule, let manager = swordManager {
            let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
            let includeHeadings = shouldIncludeSwordHeadings()
            let capturedBookList = moduleBookList
            let generation = manager.contentAuthorizationGeneration
            let primaryInitials = module.info.name
            return BibleReaderBibleSourcePreparation(
                identity: .sword(
                    manager: ObjectIdentifier(manager),
                    module: ObjectIdentifier(module),
                    initials: BibleReaderPreparationExactText(primaryInitials),
                    generation: generation,
                    modules: [BibleReaderPreparationExactText(primaryInitials)]
                ),
                provenance: .swordModules([primaryInitials]),
                extractionDependency: .sectionTitles,
                capture: {
                    manager.performRenderOperation(settings: optionSettings) {
                        guard manager.contentAuthorizationGeneration == generation,
                              manager.moduleAccessState(named: primaryInitials) == .readable else {
                            return nil
                        }
                        let builder = BibleChapterDocumentBuilder(
                            module: module,
                            includeHeadings: includeHeadings
                        )
                        guard let captured = builder.captureChapter(
                            osisBookId: osisBookId,
                            chapter: chapter
                        ) else { return nil }
                        let info = module.info
                        let sourceVersification = VersificationMapper.versificationName(for: module)
                        guard let firstReference = captured.sourceRange.entries.first?.reference,
                              let lastReference = captured.sourceRange.entries.last?.reference,
                              let structure = Self.preparedBibleChapterStructure(
                                osisBookId: osisBookId,
                                chapter: chapter,
                                firstReference: firstReference,
                                lastReference: lastReference,
                                sourceOrdinalStart: captured.sourceRange.sourceOrdinalStart,
                                sourceOrdinalEnd: captured.sourceRange.sourceOrdinalEnd,
                                sourceVersification: sourceVersification,
                                module: module,
                                ordinalByVerse: Dictionary(
                                    uniqueKeysWithValues: captured.sourceRange.entries.map {
                                        ($0.reference.verse, $0.reference.ordinal)
                                    }
                                )
                              ) else {
                            return nil
                        }
                        let description = info.description.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        let abbreviation = BibleReaderJSwordConfigValue.abbreviation(
                            module.configEntry("Abbreviation"),
                            initials: info.name
                        )
                        return .sword(
                            captured,
                            BibleReaderPreparedSourceMetadata(
                                initials: info.name,
                                name: description.isEmpty ? info.name : description,
                                abbreviation: abbreviation,
                                versificationName: sourceVersification,
                                language: info.language.isEmpty ? "en" : info.language,
                                direction: info.isRightToLeft ? "rtl" : "ltr",
                                hasStrongs: info.features.contains(.strongsNumbers)
                            ),
                            structure
                        )
                    }
                },
                enrichAnnotations: { bookmarks in
                    manager.performRenderOperation(settings: optionSettings) {
                        let requestedNames = [primaryInitials] + bookmarks.compactMap { bookmark in
                            let initials = bookmark.sourceBookInitials.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            return initials.isEmpty ? nil : initials
                        }
                        let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
                        guard authorization.generation == generation,
                              authorization.modules.first?.accessState == .readable else {
                            return nil
                        }
                        let annotationFactory = BibleReaderAnnotationPayloadFactory(
                            currentBook: bookName,
                            activeModuleName: primaryInitials,
                            activeModule: module,
                            sourceModuleResolver: { manager.readableModule(named: $0) },
                            bookCatalog: BibleReaderBookCatalog(
                                activeModule: module,
                                moduleBookList: capturedBookList
                            ),
                            unlabeledLabelID: Self.unlabeledLabelId
                        )
                        let renderedBookmarks = bookmarks.map(annotationFactory.bookmarkJSON)
                        return BibleReaderPreparedBibleAnnotations(
                            bookmarks: renderedBookmarks,
                            sourceDependencies: [
                                .sword(
                                    manager: ObjectIdentifier(manager),
                                    authorization: authorization
                                ),
                            ]
                        )
                    }
                },
                isCurrent: { [weak self, weak module, weak manager] in
                    guard let self, let module, let manager else { return false }
                    return self.activeModule === module
                        && self.swordManager === manager
                        && self.activeSQLiteBibleModule == nil
                        && manager.contentAuthorizationGeneration == generation
                }
            )
        }

        if let module = activeSQLiteBibleModule {
            let source = BibleReaderSQLiteSourceMetadata(module: module)
            let manager = swordManager
            let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
            let managerGeneration = manager?.contentAuthorizationGeneration
            return BibleReaderBibleSourcePreparation(
                identity: .sqlite(
                    module: ObjectIdentifier(module),
                    initials: BibleReaderPreparationExactText(source.initials)
                ),
                provenance: .sqliteModules([source.initials]),
                extractionDependency: .none,
                capture: {
                    let builder = SQLiteBibleChapterDocumentBuilder(module: module)
                    guard let captured = builder.captureChapter(
                        osisBookId: osisBookId,
                        chapter: chapter
                    ) else { return nil }
                    let sourceLastVerse = captured.verses.map(\.verse).max() ?? 0
                    guard sourceLastVerse > 0,
                          let firstOrdinal = JSwordKJVAVersification.verseOrdinal(
                            osisId: osisBookId,
                            chapter: chapter,
                            verse: 1
                          ),
                          let lastOrdinal = JSwordKJVAVersification.verseOrdinal(
                            osisId: osisBookId,
                            chapter: chapter,
                            verse: sourceLastVerse
                          ),
                          let introOrdinal = JSwordKJVAVersification.chapterIntroOrdinal(
                            osisId: osisBookId,
                            chapter: chapter
                          ) else { return nil }
                    let structure = BibleReaderPreparedBibleChapterStructure(
                        sourceOrdinalStart: firstOrdinal,
                        sourceOrdinalEnd: lastOrdinal,
                        sourceVerseCount: sourceLastVerse,
                        bookmarkKJVAOrdinalStart: introOrdinal,
                        bookmarkKJVAOrdinalEnd: lastOrdinal,
                        markerKJVAOrdinalStart: firstOrdinal,
                        markerKJVAOrdinalEnd: lastOrdinal,
                        readingProgressKJVABookOrdinal:
                            JSwordKJVAVersification.bibleBookOrdinal(forOsisId: osisBookId),
                        sourceVersification: JSwordKJVAVersification.name,
                        ordinalByVerse: Dictionary(
                            uniqueKeysWithValues: (1...sourceLastVerse).compactMap { verse in
                                JSwordKJVAVersification.verseOrdinal(
                                    osisId: osisBookId,
                                    chapter: chapter,
                                    verse: verse
                                ).map { (verse, $0) }
                            }
                        ),
                        memorizationProjections: (firstOrdinal...lastOrdinal).map {
                            BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection(
                                renderedOrdinal: $0,
                                kjvaOrdinal: $0
                            )
                        }
                    )
                    return .sqlite(
                        captured,
                        BibleReaderPreparedSourceMetadata(
                            initials: source.initials,
                            name: source.name,
                            abbreviation: source.abbreviation,
                            versificationName: source.versification,
                            language: source.language,
                            direction: source.direction,
                            hasStrongs: source.hasStrongs
                        ),
                        structure
                    )
                },
                enrichAnnotations: { bookmarks in
                    let primaryDependency = BibleReaderPreparationSourceDependency.sqlite(
                        module: ObjectIdentifier(module),
                        initials: BibleReaderPreparationExactText(source.initials)
                    )
                    let makeRenderedBookmarks = {
                        let annotationFactory = BibleReaderAnnotationPayloadFactory(
                            currentBook: bookName,
                            activeModuleName: source.initials,
                            activeModule: nil,
                            sourceModuleResolver: { manager?.readableModule(named: $0) },
                            bookCatalog: BibleReaderBookCatalog(
                                activeModule: nil,
                                moduleBookList: [],
                                usesExactKJVAOrdinals: true
                            ),
                            unlabeledLabelID: Self.unlabeledLabelId
                        )
                        return bookmarks.map(annotationFactory.bookmarkJSON)
                    }
                    guard let manager else {
                        return BibleReaderPreparedBibleAnnotations(
                            bookmarks: makeRenderedBookmarks(),
                            sourceDependencies: [primaryDependency]
                        )
                    }
                    return manager.performRenderOperation(settings: optionSettings) {
                        guard manager.contentAuthorizationGeneration == managerGeneration else {
                            return nil
                        }
                        let requestedNames = bookmarks.compactMap { bookmark in
                            let initials = bookmark.sourceBookInitials.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                            return initials.isEmpty ? nil : initials
                        }
                        let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
                        guard authorization.generation == managerGeneration else { return nil }
                        return BibleReaderPreparedBibleAnnotations(
                            bookmarks: makeRenderedBookmarks(),
                            sourceDependencies: [
                                primaryDependency,
                                .sword(
                                    manager: ObjectIdentifier(manager),
                                    authorization: authorization
                                ),
                            ]
                        )
                    }
                },
                isCurrent: { [weak self, weak module, weak manager] in
                    guard let self, let module else { return false }
                    return self.activeSQLiteBibleModule === module
                        && self.activeModule == nil
                        && (manager == nil
                            || manager?.contentAuthorizationGeneration == managerGeneration)
                }
            )
        }

        return nil
    }

    /**
     Validates copied source dependencies at the single main publication boundary.

     SWORD validation reads only the manager/root generation token; native registry and module
     access were captured under the worker's shared module-store lease. EPUB validation compares
     its already-retained immutable generation. Persisted source rows require a family-specific
     exact validator because their revision shape belongs to that prepared document.
     */
    func sourceDependenciesAreCurrent(
        _ dependencies: [BibleReaderPreparationSourceDependency],
        persisted: (
            (_ kind: BibleReaderPreparationExactText,
             _ identity: BibleReaderPreparationExactText,
             _ revision: BibleReaderPreparationExactText) -> Bool
        )? = nil
    ) -> Bool {
        dependencies.allSatisfy { dependency in
            switch dependency {
            case .sword(let managerIdentity, let authorization):
                guard let manager = swordManager,
                      ObjectIdentifier(manager) == managerIdentity else { return false }
                return manager.isContentAuthorizationCurrent(authorization)
            case .sqlite(let moduleIdentity, let initials):
                return sqliteRuntimeCoordinator.unshadowedSQLiteModules().contains { module in
                    ObjectIdentifier(module) == moduleIdentity
                        && SwordJavaExactStringIdentity(module.info.name)
                            == SwordJavaExactStringIdentity(initials.rawValue)
                }
            case .epub(let identifier, let generation):
                return EpubReader.isCurrentGeneration(
                    identifier: identifier.rawValue,
                    generationIdentifier: generation.rawValue
                )
            case .persisted(let kind, let identity, let revision):
                return persisted?(kind, identity, revision) ?? false
            case .myDocument(let source):
                guard let store = myDocumentStore,
                      let page = try? store.exactPage(
                        bookInitials: source.documentInitials.rawValue,
                        pageKey: source.pageKey.rawValue
                      ),
                      let document = page.document else { return false }
                let fallbackLanguage = Locale.current.language.languageCode?.identifier ?? "en"
                return source.matches(
                    document: document,
                    page: page,
                    fallbackLanguage: fallbackLanguage
                )
            case .independent:
                return true
            }
        }
    }

    /**
     Retains source-owned backing authorization for a payload routed to another controller.

     The witness captures the concrete manager and immutable SQLite handles rather than this
     controller's selected pane. A later source-pane navigation therefore does not invalidate an
     already handed-off payload, while manager mutation and SQLite registry replacement do.
     */
    private func routedSourceAuthorization(
        for dependencies: [BibleReaderPreparationSourceDependency]
    ) -> BibleReaderRoutedSourceAuthorization {
        let owner = routedSourceAuthorizationOwner
        let installedSourceGeneration = owner.installedSourceGeneration
        let manager = swordManager
        let sqliteIdentities = Set(
            sqliteRuntimeCoordinator.unshadowedSQLiteModules().map {
                BibleReaderPreparationSourceDependency.sqlite(
                    module: ObjectIdentifier($0),
                    initials: BibleReaderPreparationExactText($0.info.name)
                )
            }
        )
        return BibleReaderRoutedSourceAuthorization(
            sourceOwner: owner,
            sourceGeneration: installedSourceGeneration,
            dependencies: dependencies
        ) {
            guard owner.installedSourceGeneration == installedSourceGeneration else {
                return false
            }
            return dependencies.allSatisfy { dependency in
                switch dependency {
                case .sword(let managerIdentity, let authorization):
                    guard let manager,
                          ObjectIdentifier(manager) == managerIdentity else { return false }
                    return manager.isContentAuthorizationCurrent(authorization)
                case .sqlite:
                    return sqliteIdentities.contains(dependency)
                case .epub(let identifier, let generation):
                    return EpubReader.isCurrentGeneration(
                        identifier: identifier.rawValue,
                        generationIdentifier: generation.rawValue
                    )
                case .independent:
                    return true
                case .persisted, .myDocument:
                    return false
                }
            }
        }
    }

    /** Maps captured source chapter bounds into exact rendered and KJVA owner-query ranges. */
    private static func preparedBibleChapterStructure(
        osisBookId: String,
        chapter: Int,
        firstReference: VerseKeyReference,
        lastReference: VerseKeyReference,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int,
        sourceVersification: String,
        module: SwordModule,
        ordinalByVerse: [Int: Int]
    ) -> BibleReaderPreparedBibleChapterStructure? {
        guard firstReference.osisBookId == osisBookId,
              firstReference.chapter == chapter,
              lastReference.osisBookId == osisBookId,
              lastReference.chapter == chapter,
              firstReference.verse == 1,
              lastReference.verse > 0,
              let markerRange = VersificationMapper.kjvaOrdinalRange(
                start: firstReference,
                end: lastReference,
                sourceVersification: sourceVersification
              ),
              let mappedFirst = VersificationMapper.convertStrictly(
                osisBookId: osisBookId,
                chapter: chapter,
                verse: 1,
                from: sourceVersification,
                to: JSwordKJVAVersification.name
              )?.reference,
              let bookmarkStart = JSwordKJVAVersification.chapterIntroOrdinal(
                osisId: mappedFirst.osisBookId,
                chapter: mappedFirst.chapter
              ) else { return nil }
        return BibleReaderPreparedBibleChapterStructure(
            sourceOrdinalStart: sourceOrdinalStart,
            sourceOrdinalEnd: sourceOrdinalEnd,
            sourceVerseCount: lastReference.verse,
            bookmarkKJVAOrdinalStart: min(bookmarkStart, markerRange.upperBound),
            bookmarkKJVAOrdinalEnd: max(bookmarkStart, markerRange.upperBound),
            markerKJVAOrdinalStart: markerRange.lowerBound,
            markerKJVAOrdinalEnd: markerRange.upperBound,
            readingProgressKJVABookOrdinal:
                JSwordKJVAVersification.bibleBookOrdinal(forOsisId: mappedFirst.osisBookId),
            sourceVersification: sourceVersification,
            ordinalByVerse: ordinalByVerse,
            memorizationProjections: preparedMemorizationOrdinalProjections(
                kjvaStartOrdinal: markerRange.lowerBound,
                kjvaEndOrdinal: markerRange.upperBound,
                targetModule: module
            )
        )
    }

    /** Captures KJVA-to-rendered memorization projections under the source's native lease. */
    private static func preparedMemorizationOrdinalProjections(
        kjvaStartOrdinal: Int,
        kjvaEndOrdinal: Int,
        targetModule: SwordModule
    ) -> [BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection] {
        guard kjvaStartOrdinal > 0, kjvaEndOrdinal >= kjvaStartOrdinal else { return [] }
        return (kjvaStartOrdinal...kjvaEndOrdinal).compactMap { kjvaOrdinal in
            guard let projection = VersificationMapper.moduleProjection(
                forKJVAOrdinal: kjvaOrdinal,
                targetModule: targetModule
            ) else { return nil }
            let renderedOrdinal: Int
            if projection.isAddressable {
                renderedOrdinal = projection.ordinal
            } else {
                let targetVersification = VersificationMapper.versificationName(for: targetModule)
                guard projection.reference.verse == 0,
                      let canonicalOrdinal = SwordVersification.referenceIndex(
                        for: projection.reference,
                        versification: targetVersification
                      ),
                      canonicalOrdinal > 0,
                      SwordVersification.reference(
                        forIndex: canonicalOrdinal,
                        versification: targetVersification
                      ) == projection.reference else { return nil }
                renderedOrdinal = canonicalOrdinal
            }
            return BibleReaderProgressBridgeCoordinator.MemorizationOrdinalProjection(
                renderedOrdinal: renderedOrdinal,
                kjvaOrdinal: kjvaOrdinal
            )
        }
    }

    /** Freezes every owner-supplied Bible payload value and its exact typed identity. */
    private func bibleChapterOwnerSnapshot(
        book: String,
        chapter: Int,
        osisBookId: String,
        structure: BibleReaderPreparedBibleChapterStructure,
        navigationAnchorRange: [Int]?,
        setupIdentity: String
    ) -> BibleReaderBibleDocumentOwnerSnapshot {
        let bookmarks = (bookmarkService?.bookmarks(
            for: structure.bookmarkKJVAOrdinalStart,
            endOrdinal: structure.bookmarkKJVAOrdinalEnd
        ) ?? [])
            .map {
                BibleReaderPreparedBibleBookmarkInput(
                    $0,
                    unlabeledLabelID: Self.unlabeledLabelId
                )
            }
        let markers = myDocumentStore?.aiDocMarkers(
            kjvaRange: structure.markerKJVAOrdinalStart...structure.markerKJVAOrdinalEnd
        ) ?? []
        let memorized = preparedRenderedMemorizationOrdinals(
            structure: structure,
            target: false
        )
        let targets = preparedRenderedMemorizationOrdinals(
            structure: structure,
            target: true
        )
        let readCount = structure.readingProgressKJVABookOrdinal.flatMap { ordinal in
            readingProgressStore?.chapterReadCount(
                kjvBookOrdinal: ordinal,
                chapter: chapter
            )
        }
        let isNewTestament = isNewTestament(book)
        let ordinalRange = [structure.sourceOrdinalStart, structure.sourceOrdinalEnd]
        let identity = BibleReaderBibleDocumentOwnerIdentity(
            osisBookID: osisBookId,
            bookName: book,
            chapter: chapter,
            isNewTestament: isNewTestament,
            ordinalRange: ordinalRange,
            originalOrdinalRange: navigationAnchorRange,
            bookmarks: bookmarks,
            aiDocMarkers: markers,
            memorizedOrdinals: memorized,
            targetOrdinals: targets,
            chapterReadCount: readCount,
            setupIdentity: setupIdentity
        )

        return BibleReaderBibleDocumentOwnerSnapshot(
            osisBookId: osisBookId,
            bookName: book,
            chapter: chapter,
            isNewTestament: isNewTestament,
            ordinalRange: ordinalRange,
            originalOrdinalRange: navigationAnchorRange,
            bookmarks: bookmarks,
            aiDocMarkers: markers,
            memorizedOrdinals: memorized,
            targetOrdinals: targets,
            chapterReadCount: readCount,
            identity: identity
        )
    }

    /** Filters copied source projections through persistence-only memorization state. */
    private func preparedRenderedMemorizationOrdinals(
        structure: BibleReaderPreparedBibleChapterStructure,
        target: Bool
    ) -> [Int] {
        guard let store = memorizationProgressStore else { return [] }
        let stored = Set(
            target
                ? store.targetOrdinals(
                    bookInitials: "",
                    startOrdinal: structure.markerKJVAOrdinalStart,
                    endOrdinal: structure.markerKJVAOrdinalEnd
                )
                : store.memorizedOrdinals(
                    bookInitials: "",
                    startOrdinal: structure.markerKJVAOrdinalStart,
                    endOrdinal: structure.markerKJVAOrdinalEnd
                )
        )
        return structure.memorizationProjections
            .filter { stored.contains($0.kjvaOrdinal) }
            .map(\.renderedOrdinal)
            .sorted()
    }

    /** Returns the non-consuming setup identity included in coalescing and publication checks. */
    private func bibleChapterSetupIdentity(
        book: String,
        chapter: Int,
        navigationAnchorRange: [Int]?,
        structure: BibleReaderPreparedBibleChapterStructure
    ) -> String {
        if let navigationAnchorRange {
            return "anchor:\(navigationAnchorRange.map(String.init).joined(separator: ","))"
        }
        let target = navigationCoordinator.contentRestoreTarget(
            currentPosition: BibleReaderNavigationPosition(
                book: book,
                chapter: chapter,
                verse: currentVerse
            )
        ) { targetBook, targetChapter, targetVerse in
            guard SwordJavaStringIdentity.equals(targetBook, book),
                  targetChapter == chapter else { return nil }
            return structure.ordinalByVerse[targetVerse]
        }
        switch target {
        case .chapterTop: return "top"
        case .ordinal(let ordinal): return "ordinal:\(ordinal)"
        }
    }

    /** Builds the setup payload without consuming restore state before bridge acceptance. */
    private func bibleChapterSetupPayload(
        book: String,
        chapter: Int,
        osisBookId: String,
        navigationAnchorRange: [Int]?,
        structure: BibleReaderPreparedBibleChapterStructure
    ) -> ReaderSetupContentPayload {
        if let navigationAnchorRange,
           let anchorStart = navigationAnchorRange.first,
           let anchorEnd = navigationAnchorRange.last {
            return ReaderSetupContentPayload(
                jumpToAnchor: anchorStart,
                ordinalStart: anchorStart,
                ordinalEnd: anchorEnd,
                highlight: true,
                bookInitials: activeModule?.info.name ?? activeModuleName,
                osisRef: "\(osisBookId).\(chapter)"
            )
        }
        let restoreTarget = navigationCoordinator.contentRestoreTarget(
            currentPosition: BibleReaderNavigationPosition(
                book: book,
                chapter: chapter,
                verse: currentVerse
            )
        ) { targetBook, targetChapter, targetVerse in
            guard SwordJavaStringIdentity.equals(targetBook, book),
                  targetChapter == chapter else { return nil }
            return structure.ordinalByVerse[targetVerse]
        }
        switch restoreTarget {
        case .chapterTop:
            return ReaderSetupContentPayload(jumpToId: "top")
        case .ordinal(let ordinal):
            return ReaderSetupContentPayload(jumpToOrdinal: ordinal)
        }
    }

    /**
     Publishes the no-content document through the shared selected-destination owner.

     - Parameters identify the exact failed Bible request and its content-intent generation.
     - Side effects: Replaces Vue content and commits rendered state only after bridge acceptance.
     - Failure modes: Serialization or bridge rejection leaves rendered state empty. A synchronous
       destination supersession after dispatch settles without committing this request as rendered.
     */
    private func publishCurrentBibleNoContent(
        generation: UInt64,
        osisBookId: String,
        book: String,
        chapter: Int
    ) {
        let destination = BibleReaderPreparationDestination(
            generation: generation,
            paneID: activeWindow?.id,
            workspaceID: activeWindow?.workspace?.id
        )
        let expectedModuleName = BibleReaderPreparationExactText(activeModuleName)
        let isCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.currentCategory == .bible
                && SwordJavaStringIdentity.equals(self.activeModuleName, expectedModuleName.rawValue)
                && SwordJavaStringIdentity.equals(self.currentBook, book)
                && self.currentChapter == chapter
        }
        guard preparationPublicationOwner.isCurrent(destination), isCurrent() else { return }
        let renderedOsisBookId = osisBookId.isEmpty ? Self.osisBookId(for: book) : osisBookId
        logger.error(
            "Failed to load active Bible chapter for \(renderedOsisBookId, privacy: .public).\(chapter)"
        )
        guard let document = documentPayloadFactory().errorDocumentJSON(
            message: String(
                localized: "error_no_content",
                defaultValue: "No content for selected verse"
            )
        ) else { return }
        let outcome: BibleReaderDocumentPreparationOutcome<String> = .prepared(document)
        let disposition = preparationPublicationOwner.publishQueuedBridge(
            outcome,
            destination: destination,
            failurePolicy: .settle,
            stalePolicy: .settle,
            isCurrent: { _ in isCurrent() },
            isSourceCurrentAroundBridge: { _ in true },
            queueBridge: { [weak self] document in
                self?.replaceDocument(
                    documentJSON: document,
                    setup: ReaderSetupContentPayload(jumpToId: "top")
                ) == true
            },
            commitAcceptedRender: { [weak self] _ in
                guard let self else { return }
                self.setRenderedContentState(
                    category: .bible,
                    moduleName: expectedModuleName.rawValue,
                    book: book,
                    chapter: chapter,
                    key: "\(renderedOsisBookId).\(chapter)",
                    sourceProvenance: .independent
                )
                self.emitActiveState()
                self.bridge.clearSelection()
                self.applyNightModeBackground()
            }
        )
        if disposition == .bridgeRejected {
            navigationCoordinator.prepareForContentReload()
        }
    }

    /** Keeps the source-free static placeholder route bounded and synchronous. */
    private func loadCurrentChapterSynchronously() {
        let generation = beginReplacingContentIntent()
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
    } else if activeModule == nil && activeSQLiteBibleModule == nil
                && activeWindow?.pageManager?.bibleDocument == nil {
            let fallbackChapter = loadPlaceholderChapter(osisBookId: osisBookId, bookName: currentBook)
            xml = fallbackChapter.0
            verseCount = fallbackChapter.1
            addChapter = true
        } else {
            publishCurrentBibleNoContent(
                generation: generation,
                osisBookId: osisBookId,
                book: currentBook,
                chapter: currentChapter
            )
            return
        }

        // Query bookmarks for this chapter
        let chapterBookmarks = bookmarksForChapter(
            book: currentBook,
            chapter: currentChapter,
            verseCount: verseCount
        )

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
        guard replaceDocument(
            documentJSON: document,
            setup: setupPayload
        ) else {
            navigationCoordinator.prepareForContentReload()
            return
        }
        infiniteScrollCoordinator.reset(book: currentBook, chapter: currentChapter)
        setRenderedContentState(
            category: .bible,
            moduleName: activeModuleName,
            book: currentBook,
            chapter: currentChapter,
            key: "\(osisBookId).\(currentChapter)",
            sourceProvenance: activeSQLiteBibleModule.map {
                .sqliteModules([$0.info.name])
            } ?? activeModule.map {
                .swordModules([$0.info.name])
            } ?? .independent,
            extractionDependency: activeModule == nil ? .none : .sectionTitles
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

    /// Queries bookmarks for one chapter's Android-compatible KJVA ordinal range.
    private func bookmarksForChapter(
        book: String,
        chapter: Int,
        verseCount: Int
    ) -> [BibleBookmark] {
        guard let service = bookmarkService else { return [] }
        guard let range = bookmarkQueryOrdinalRange(
            book: book,
            chapter: chapter,
            verseCount: verseCount
        ) else {
            logger.error(
                "Failed to resolve bookmark range for \(book, privacy: .public) \(chapter)"
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
        bridge.emit(event: "update_labels", data: labelPayloadSnapshot())
    }

    /** Freezes every bridge-visible label while the bookmark graph remains on its owner. */
    private func labelPayloadSnapshot() -> [LabelData] {
        let payloadFactory = persistenceAnnotationPayloadFactory()
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
                guard let labelData = payloadFactory.labelData(label) else {
                    continue
                }
                allLabels.append(labelData)
            }
        }

        return allLabels
    }

    /**
     Copies one complete StudyPad persistence graph while every SwiftData value is still on its
     main owner.

     Android derives junction rows from the bookmark rows selected for the label. This snapshot
     preserves that relationship boundary, the persisted StudyPad ordering, and the independent
     label event as immutable values before source enrichment moves to the worker.

     - Parameters:
       - labelID: Exact StudyPad label whose journal is being prepared.
       - bookmarkID: Optional row requested as the post-render jump target.
     - Returns: Complete copied owner state, or `nil` when the label disappeared or was deleted.
     - Side effects: Performs bounded label-scoped persistence reads; no source content is opened.
     - Failure modes: Deleted labels and relationships are omitted by the existing payload factory;
       an invalid label fails the whole snapshot before visible publication.
     */
    private func studyPadOwnerSnapshot(
        labelID: UUID,
        bookmarkID: UUID?,
        installedResolver: BibleReaderInstalledModuleResolver
    ) -> BibleReaderPreparedStudyPadOwnerSnapshot? {
        guard let service = bookmarkService,
              let label = service.label(id: labelID) else { return nil }
        let factory = persistenceAnnotationPayloadFactory()
        guard let labelData = factory.labelData(label) else { return nil }

        let bibleRows = service.bibleBookmarks(withLabel: labelID)
        let genericRows = service.genericBookmarks(withLabel: labelID)
        let bookmarkInputs = bibleRows.map {
            BibleReaderPreparedBibleBookmarkInput(
                $0,
                unlabeledLabelID: Self.unlabeledLabelId
            )
        }
        let genericBookmarkInputs = genericRows.map {
            BibleReaderPreparedGenericBookmarkInput(
                $0,
                unlabeledLabelID: Self.unlabeledLabelId
            )
        }
        let bookmarkToLabels = bibleRows.flatMap { bookmark in
            (bookmark.bookmarkToLabels ?? []).filter { $0.label?.id == labelID }
        }.compactMap(factory.bibleBookmarkToLabelJSON)
        let genericBookmarkToLabels = genericRows.flatMap { bookmark in
            (bookmark.bookmarkToLabels ?? []).filter { $0.label?.id == labelID }
        }.compactMap(factory.genericBookmarkToLabelJSON)
        let journalTextEntries = service.studyPadEntries(labelId: labelID).map(
            factory.studyPadEntryJSON
        )
        let jumpToID = bookmarkID.map {
            "o-\(BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(from: $0.uuidString.hashValue))"
        }
        let fallbackLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        var localGenericSources: [
            BibleReaderPreparedGenericBookmarkSourceKey: BibleReaderPreparedGenericLocalSource
        ] = [:]
        var resolvedSourceKeys: Set<BibleReaderPreparedGenericBookmarkSourceKey> = []
        for input in genericBookmarkInputs {
            let sourceKey = BibleReaderPreparedGenericBookmarkSourceKey(
                bookInitials: input.sourceBookInitials,
                key: input.key
            )
            guard resolvedSourceKeys.insert(sourceKey).inserted,
                  let localDocument = localGeneralBookDocument(
                    named: input.sourceBookInitials,
                    preferredEpub: activeEpubReader,
                    resolver: installedResolver
                  ) else { continue }
            switch localDocument {
            case .myDocument(let document):
                guard let store = myDocumentStore,
                      let page = try? store.exactPage(
                        bookInitials: document.initials,
                        pageKey: input.key
                      ),
                      let pageDocument = page.document,
                      pageDocument.id == document.id else { continue }
                localGenericSources[sourceKey] = .myDocument(
                    BibleReaderPreparedMyDocumentSource(
                        document: pageDocument,
                        page: page,
                        fallbackLanguage: fallbackLanguage
                    )
                )
            case .epub(let reader):
                localGenericSources[sourceKey] = .epub(reader)
            }
        }

        return BibleReaderPreparedStudyPadOwnerSnapshot(
            labelID: labelID,
            displayName: AndroidLabelPresentation.displayName(for: label),
            jumpToID: jumpToID,
            label: labelData,
            bookmarkInputs: bookmarkInputs,
            genericBookmarkInputs: genericBookmarkInputs,
            bookmarkToLabels: bookmarkToLabels,
            genericBookmarkToLabels: genericBookmarkToLabels,
            journalTextEntries: journalTextEntries,
            labels: labelPayloadSnapshot(),
            localGenericSources: localGenericSources
        )
    }

    /**
     Captures non-SWORD generic bookmark content from authorized immutable owners on the worker.

     SQLite handles come from the captured installed registry, My Documents values were copied
     during owner capture, and EPUB values retain one immutable generation for exact-key reads.
     Dependencies follow first bookmark occurrence order and retain their typed owner identity.

     - Parameter owner: Complete StudyPad persistence snapshot with resolved local source owners.
     - Returns: Exact source content keyed by persisted initials/key plus typed publication checks.
     - Side effects: Reads exact EPUB content from retained immutable generations; performs no
       SwiftData or installed-module lookup.
     - Failure modes: Missing EPUB keys retain their generation dependency and yield no source
       content, so the bookmark projection fails closed without borrowing another document.
     */
    private static func studyPadNonSwordGenericSources(
        _ owner: BibleReaderPreparedStudyPadOwnerSnapshot,
        installedResolver: BibleReaderInstalledModuleResolver
    ) -> (
        contents: [BibleReaderPreparedGenericBookmarkSourceKey: GenericBookmarkSourceContent],
        dependencies: [BibleReaderPreparationSourceDependency]
    ) {
        var contents: [
            BibleReaderPreparedGenericBookmarkSourceKey: GenericBookmarkSourceContent
        ] = [:]
        var dependencies: [BibleReaderPreparationSourceDependency] = []
        var seenDependencies: Set<BibleReaderPreparationSourceDependency> = []

        for input in owner.genericBookmarkInputs {
            let sourceKey = BibleReaderPreparedGenericBookmarkSourceKey(
                bookInitials: input.sourceBookInitials,
                key: input.key
            )
            if case .sqlite(let module)? = installedResolver.module(
                named: input.sourceBookInitials
            ) {
                if let content = bookmarkListSQLiteGenericSourceContent(
                    module: module,
                    key: input.key
                ) {
                    contents[sourceKey] = content
                }
                let dependency = BibleReaderPreparationSourceDependency.sqlite(
                    module: ObjectIdentifier(module),
                    initials: BibleReaderPreparationExactText(module.info.name)
                )
                if seenDependencies.insert(dependency).inserted {
                    dependencies.append(dependency)
                }
                continue
            }
            guard let source = owner.localGenericSources[sourceKey] else { continue }
            switch source {
            case .myDocument(let page):
                contents[sourceKey] = page.genericBookmarkSourceContent()
                let dependency = BibleReaderPreparationSourceDependency.myDocument(page)
                if seenDependencies.insert(dependency).inserted {
                    dependencies.append(dependency)
                }
            case .epub(let reader):
                let dependency = BibleReaderPreparationSourceDependency.epub(
                    identifier: BibleReaderPreparationExactText(reader.identifier),
                    generation: BibleReaderPreparationExactText(reader.generationIdentifier)
                )
                if seenDependencies.insert(dependency).inserted {
                    dependencies.append(dependency)
                }
                guard let content = reader.content(forKey: input.key) else { continue }
                let ordinalRange = [
                    content.ordinalRange.lowerBound,
                    content.ordinalRange.upperBound,
                ]
                contents[sourceKey] = GenericBookmarkSourceContent(
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
                        direction: annotationTextDirection(language: reader.language),
                        isNativeHtml: true
                    )
                )
            }
        }

        return (contents, dependencies)
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

    /** Builds source-independent label, relationship, and StudyPad-entry projections. */
    private func persistenceAnnotationPayloadFactory() -> BibleReaderAnnotationPayloadFactory {
        BibleReaderAnnotationPayloadFactory(
            currentBook: "",
            activeModuleName: "",
            activeModule: nil,
            bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
            unlabeledLabelID: Self.unlabeledLabelId
        )
    }

    /** Copied or immutable local source admitted after the installed registry declines ownership. */
    private enum BookmarkListLocalGenericSource: @unchecked Sendable {
        /// Exact persisted My Documents page values copied on the model owner.
        case myDocument(BibleReaderPreparedMyDocumentSource)

        /// Immutable EPUB generation retained for one exact-key worker read.
        case epub(EpubReader)
    }

    /** Metadata-only My Documents registration copied before worker-side owner resolution. */
    private struct BookmarkListMyDocumentRegistration: Sendable {
        let id: UUID
        let initials: BibleReaderPreparationExactText
        let name: BibleReaderPreparationExactText
    }

    /** Local owner selected from one strict EPUB/My Documents registration snapshot. */
    private enum BookmarkListLocalGenericOwner: @unchecked Sendable {
        case myDocument(UUID)
        case epub(EpubReader)
    }

    /** Installed registry captured once for one visible-row projection attempt. */
    private struct BookmarkListSourceRegistry: @unchecked Sendable {
        let installedResolver: BibleReaderInstalledModuleResolver
        let localOwner: BookmarkListLocalGenericOwner?
    }

    /** Worker result plus exact source dependencies required before visible publication. */
    private struct BookmarkListPreparedRowProjection: Sendable {
        let projection: BookmarkListResolvedRowProjection
        let sourceDependencies: [BibleReaderPreparationSourceDependency]
    }

    /** Captures exact family-specific row state without performing source-content reads. */
    @MainActor
    var bookmarkListProjectionContexts: BookmarkListProjectionContexts {
        let managerIdentity = swordManager.map(ObjectIdentifier.init)
        let managerGeneration = swordManager?.contentAuthorizationGeneration
        let optionIdentities = swordCoordinator.renderOptionSettings(settings: displaySettings).map {
            BookmarkListRowProjectionContext.Option(
                name: BibleReaderPreparationExactText($0.option.rawValue),
                enabled: $0.enabled
            )
        }
        let sqliteSources = sqliteRuntimeCoordinator.unshadowedSQLiteModules().map {
            BookmarkListRowProjectionContext.Source(
                owner: ObjectIdentifier($0),
                initials: BibleReaderPreparationExactText($0.info.name)
            )
        }
        let activeSource: BookmarkListRowProjectionContext.Source? = {
            if let activeModule {
                return BookmarkListRowProjectionContext.Source(
                    owner: ObjectIdentifier(activeModule),
                    initials: BibleReaderPreparationExactText(activeModule.info.name)
                )
            }
            if let activeSQLiteBibleModule {
                return BookmarkListRowProjectionContext.Source(
                    owner: ObjectIdentifier(activeSQLiteBibleModule),
                    initials: BibleReaderPreparationExactText(activeSQLiteBibleModule.info.name)
                )
            }
            return nil
        }()
        let generic = BookmarkListRowProjectionContext(
            manager: managerIdentity,
            managerGeneration: managerGeneration,
            activeSource: nil,
            activeInitials: nil,
            currentBook: nil,
            books: [],
            sqliteSources: sqliteSources,
            options: optionIdentities
        )
        let bible = BookmarkListRowProjectionContext(
            manager: managerIdentity,
            managerGeneration: managerGeneration,
            activeSource: activeSource,
            activeInitials: BibleReaderPreparationExactText(activeModuleName),
            currentBook: BibleReaderPreparationExactText(currentBook),
            books: moduleBookList.map {
                BookmarkListRowProjectionContext.Book(
                    name: BibleReaderPreparationExactText($0.name),
                    osisID: BibleReaderPreparationExactText($0.osisId),
                    abbreviation: BibleReaderPreparationExactText($0.abbreviation),
                    chapterCount: $0.chapterCount,
                    testament: $0.testament
                )
            },
            sqliteSources: sqliteSources,
            options: optionIdentities
        )
        return BookmarkListProjectionContexts(bible: bible, generic: generic)
    }

    /**
     Resolves source-derived content for one copied Bookmark-list row.

     SwiftUI invokes this only from a visible `LazyVStack` row. Installed ownership and native
     text reads run off the main actor under the SWORD shared render lease. My Documents values are
     copied on their SwiftData owner and EPUB retains one immutable generation before worker-side
     text projection. Publication checks source generations and a freshly copied bookmark identity.

     - Parameter request: Complete persistence-only row identity captured by `BookmarkListView`.
     - Returns: Current reference and emphasized source text, or nil for cancellation/stale owners.
     - Side effects: Performs bounded installed/source reads for one visible row.
     - Failure modes: Deleted bookmarks, relocked/replaced sources, and malformed keys fail closed.
     */
    @MainActor
    func bookmarkListRowProjection(
        for request: BookmarkListRowProjectionRequest,
        expectedContext: BookmarkListRowProjectionContext
    ) async -> BookmarkListResolvedRowProjection? {
        guard bookmarkListProjectionContexts.context(for: request) == expectedContext else {
            return nil
        }
        let manager = swordManager
        let managerGeneration = manager?.contentAuthorizationGeneration
        let activeSwordModule = activeModule
        let activeSQLiteModule = activeSQLiteBibleModule
        let activeInitials = activeModuleName
        let capturedCurrentBook = currentBook
        let capturedBookList = moduleBookList
        let capturedSQLiteModules = sqliteRuntimeCoordinator.unshadowedSQLiteModules()
        let optionSettings = swordCoordinator.renderOptionSettings(settings: displaySettings)
        let myDocumentRegistrations: [BookmarkListMyDocumentRegistration]
        if case .generic = request, let myDocumentStore {
            guard let documents = try? myDocumentStore.documentsInRegistrationOrder() else {
                return nil
            }
            myDocumentRegistrations = documents.map {
                BookmarkListMyDocumentRegistration(
                    id: $0.id,
                    initials: BibleReaderPreparationExactText($0.initials),
                    name: BibleReaderPreparationExactText($0.name)
                )
            }
        } else {
            myDocumentRegistrations = []
        }

        let registry = await BookmarkListProjectionWorker.run {
            () -> BookmarkListSourceRegistry? in
            let capture: () -> BookmarkListSourceRegistry? = {
                guard !Task.isCancelled else { return nil }
                guard manager == nil
                    || manager?.contentAuthorizationGeneration == managerGeneration else {
                    return nil
                }
                let installedResolver = BibleReaderInstalledModuleResolver(
                    swordManager: manager,
                    sqliteModules: capturedSQLiteModules
                )
                let localOwner = Self.bookmarkListLocalGenericOwner(
                    for: request,
                    installedResolver: installedResolver,
                    myDocumentRegistrations: myDocumentRegistrations
                )
                guard !Task.isCancelled else { return nil }
                return BookmarkListSourceRegistry(
                    installedResolver: installedResolver,
                    localOwner: localOwner
                )
            }
            if let manager {
                return manager.performRenderOperation(settings: optionSettings) {
                    guard !Task.isCancelled else { return nil }
                    return capture()
                }
            }
            return capture()
        }
        guard !Task.isCancelled, let registry else { return nil }

        let localSource = bookmarkListLocalGenericSource(
            for: request,
            selectedOwner: registry.localOwner
        )
        let prepared = await BookmarkListProjectionWorker.run {
            () -> BookmarkListPreparedRowProjection? in
            let project: () -> BookmarkListPreparedRowProjection? = {
                guard !Task.isCancelled else { return nil }
                return Self.prepareBookmarkListRowProjection(
                    request: request,
                    registry: registry,
                    localSource: localSource,
                    manager: manager,
                    expectedManagerGeneration: managerGeneration,
                    activeSwordModule: activeSwordModule,
                    activeSQLiteModule: activeSQLiteModule,
                    activeInitials: activeInitials,
                    currentBook: capturedCurrentBook,
                    moduleBookList: capturedBookList
                )
            }
            if let manager {
                return manager.performRenderOperation(settings: optionSettings) {
                    guard !Task.isCancelled else { return nil }
                    return project()
                }
            }
            return project()
        }
        guard !Task.isCancelled,
              let prepared,
              sourceDependenciesAreCurrent(prepared.sourceDependencies),
              bookmarkListRowRequestIsCurrent(request),
              bookmarkListProjectionContexts.context(for: request) == expectedContext else {
            return nil
        }

        if case .bible = request {
            guard swordManager === manager,
                  activeModule === activeSwordModule,
                  activeSQLiteBibleModule === activeSQLiteModule else { return nil }
        }
        return prepared.projection
    }

    /** Resolves EPUB/My Documents ownership on the worker without opening EPUBs on the main actor. */
    private static func bookmarkListLocalGenericOwner(
        for request: BookmarkListRowProjectionRequest,
        installedResolver: BibleReaderInstalledModuleResolver,
        myDocumentRegistrations: [BookmarkListMyDocumentRegistration]
    ) -> BookmarkListLocalGenericOwner? {
        guard case .generic(let input) = request,
              installedResolver.registeredModuleInfo(named: input.sourceBookInitials) == nil,
              let epubInfos = try? EpubReader.registrationSnapshot() else { return nil }

        enum Candidate {
            case epub(EpubInfo)
            case myDocument(BookmarkListMyDocumentRegistration)
        }
        let registrations = epubInfos.map { info in
            BibleReaderLocalDocumentRegistration(
                document: Candidate.epub(info),
                initials: info.initials,
                fullName: info.title,
                abbreviation: info.title,
                category: .generalBook
            )
        } + myDocumentRegistrations.map { document in
            BibleReaderLocalDocumentRegistration(
                document: Candidate.myDocument(document),
                initials: document.initials.rawValue,
                fullName: document.name.rawValue,
                abbreviation: document.initials.rawValue,
                category: .generalBook
            )
        }
        switch installedResolver.resolveDocumentOwner(
            named: input.sourceBookInitials,
            localRegistrations: { registrations }
        ) {
        case .installed, .missing:
            return nil
        case .local(.myDocument(let document)):
            return .myDocument(document.id)
        case .local(.epub(let info)):
            guard let reader = EpubReader(identifier: info.identifier),
                  BibleReaderPreparationExactText(reader.initials)
                    == BibleReaderPreparationExactText(info.initials),
                  BibleReaderPreparationExactText(reader.title)
                    == BibleReaderPreparationExactText(info.title) else { return nil }
            return .epub(reader)
        }
    }

    /** Copies one selected local generic source without moving SwiftData off-owner. */
    @MainActor
    private func bookmarkListLocalGenericSource(
        for request: BookmarkListRowProjectionRequest,
        selectedOwner: BookmarkListLocalGenericOwner?
    ) -> BookmarkListLocalGenericSource? {
        guard case .generic(let input) = request,
              let selectedOwner else { return nil }
        switch selectedOwner {
        case .myDocument(let documentID):
            guard let store = myDocumentStore,
                  let page = try? store.exactPage(
                    bookInitials: input.sourceBookInitials,
                    pageKey: input.key
                  ),
                  let pageDocument = page.document,
                  pageDocument.id == documentID else { return nil }
            return .myDocument(
                BibleReaderPreparedMyDocumentSource(
                    document: pageDocument,
                    page: page,
                    fallbackLanguage: Locale.current.language.languageCode?.identifier ?? "en"
                )
            )
        case .epub(let reader):
            return .epub(reader)
        }
    }

    /** Rechecks every persisted scalar used by a completed row before accepting it. */
    @MainActor
    private func bookmarkListRowRequestIsCurrent(
        _ request: BookmarkListRowProjectionRequest
    ) -> Bool {
        switch request {
        case .bible(let input):
            guard let bookmark = bookmarkService?.bibleBookmark(id: input.id) else { return false }
            return BibleReaderPreparedBibleBookmarkInput(
                bookmark,
                unlabeledLabelID: Self.unlabeledLabelId
            ) == input
        case .generic(let input):
            guard let bookmark = bookmarkService?.genericBookmark(id: input.id) else { return false }
            return BibleReaderPreparedGenericBookmarkInput(
                bookmark,
                unlabeledLabelID: Self.unlabeledLabelId
            ) == input
        }
    }

    /** Performs source enrichment from copied inputs and operation-scoped source owners. */
    private static func prepareBookmarkListRowProjection(
        request: BookmarkListRowProjectionRequest,
        registry: BookmarkListSourceRegistry,
        localSource: BookmarkListLocalGenericSource?,
        manager: SwordManager?,
        expectedManagerGeneration: SwordContentAuthorizationGeneration?,
        activeSwordModule: SwordModule?,
        activeSQLiteModule: BibleReaderSQLiteModuleHandle?,
        activeInitials: String,
        currentBook: String,
        moduleBookList: [BookInfo]
    ) -> BookmarkListPreparedRowProjection? {
        let requestedNames: [String]
        switch request {
        case .bible(let input):
            requestedNames = [activeInitials, input.sourceBookInitials]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        case .generic(let input):
            let initials = input.sourceBookInitials.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            requestedNames = initials.isEmpty ? [] : [initials]
        }

        var dependencies: [BibleReaderPreparationSourceDependency] = []
        if let manager, let expectedManagerGeneration {
            let authorization = manager.contentAuthorizationSnapshot(for: requestedNames)
            guard authorization.generation == expectedManagerGeneration else { return nil }
            dependencies.append(
                .sword(manager: ObjectIdentifier(manager), authorization: authorization)
            )
        }

        let activeModule: SwordModule? = {
            guard let activeSwordModule,
                  case .sword(let authorized)? = registry.installedResolver.module(
                    named: activeInitials
                  ), authorized === activeSwordModule else { return nil }
            return authorized
        }()
        let bookCatalog = BibleReaderBookCatalog(
            activeModule: activeModule,
            moduleBookList: moduleBookList
        )
        let factory = BibleReaderAnnotationPayloadFactory(
            currentBook: currentBook,
            activeModuleName: activeInitials,
            activeModule: activeModule,
            sourceModuleResolver: { initials in
                guard case .sword(let module)? = registry.installedResolver.module(
                    named: initials
                ) else { return nil }
                return module
            },
            bookCatalog: bookCatalog,
            unlabeledLabelID: Self.unlabeledLabelId
        )

        let projection: BookmarkListResolvedRowProjection
        switch request {
        case .bible(let input):
            if let activeSQLiteModule {
                dependencies.append(
                    .sqlite(
                        module: ObjectIdentifier(activeSQLiteModule),
                        initials: BibleReaderPreparationExactText(activeSQLiteModule.info.name)
                    )
                )
            }
            let normalizedActiveVersification = activeModule.map {
                Self.normalizedVersificationName(VersificationMapper.versificationName(for: $0))
            }
            let usesMappedReference = normalizedActiveVersification.map {
                $0 != JSwordKJVAVersification.name && $0 != "KJV"
            } ?? false
            let activeReferenceResolver: (
                (Int) -> (bookName: String, reference: BookmarkListVerseReference)?
            )?
            if usesMappedReference, let activeModule {
                activeReferenceResolver = { ordinal in
                    Self.bookmarkListActiveReference(
                        kjvOrdinal: ordinal,
                        activeModule: activeModule,
                        bookCatalog: bookCatalog
                    )
                }
            } else {
                activeReferenceResolver = nil
            }
            let reference = BookmarkListReferenceProjection.verseReference(
                kjvaStartOrdinal: input.kjvaOrdinalStart,
                kjvaEndOrdinal: input.kjvaOrdinalEnd,
                legacyBookName: input.sourceBookName,
                sourceStartOrdinal: input.sourceOrdinalStart,
                sourceEndOrdinal: input.sourceOrdinalEnd,
                ordinalResolver: { bookName, ordinal in
                    guard let reference = bookCatalog.verseReference(
                        book: bookName,
                        ordinal: ordinal
                    ) else { return nil }
                    return BookmarkListVerseReference(
                        chapter: reference.chapter,
                        verse: reference.verse
                    )
                },
                activeReferenceResolver: activeReferenceResolver
            )
            projection = BookmarkListResolvedRowProjection(
                request: request,
                reference: reference,
                textProjection: factory.bookmarkListTextProjection(input)
            )

        case .generic(let input):
            let capturedSource: BibleReaderPreparedGenericBookmarkSource
            if let installed = registry.installedResolver.module(named: input.sourceBookInitials) {
                switch installed {
                case .sword:
                    capturedSource = factory.captureGenericBookmarkSource(for: input)
                case .sqlite(let module):
                    dependencies.append(
                        .sqlite(
                            module: ObjectIdentifier(module),
                            initials: BibleReaderPreparationExactText(module.info.name)
                        )
                    )
                    capturedSource = factory.captureGenericBookmarkSource(
                        for: input,
                        source: bookmarkListSQLiteGenericSourceContent(
                            module: module,
                            key: input.key
                        )
                    )
                }
            } else {
                switch localSource {
                case .myDocument(let source):
                    dependencies.append(.myDocument(source))
                    capturedSource = factory.captureGenericBookmarkSource(
                        for: input,
                        source: source.genericBookmarkSourceContent()
                    )
                case .epub(let reader):
                    dependencies.append(
                        .epub(
                            identifier: BibleReaderPreparationExactText(reader.identifier),
                            generation: BibleReaderPreparationExactText(reader.generationIdentifier)
                        )
                    )
                    let content = reader.content(forKey: input.key).map {
                        epubGenericBookmarkSourceContent(
                            readerInitials: reader.initials,
                            readerTitle: reader.title,
                            readerLanguage: reader.language,
                            content: $0
                        )
                    }
                    capturedSource = factory.captureGenericBookmarkSource(
                        for: input,
                        source: content
                    )
                case nil:
                    capturedSource = factory.captureGenericBookmarkSource(for: input, source: nil)
                }
            }
            projection = BookmarkListResolvedRowProjection(
                request: request,
                reference: BookmarkListReferenceProjection.genericReference(for: input),
                textProjection: factory.bookmarkListTextProjection(
                    input,
                    capturedSource: capturedSource
                )
            )
        }

        if dependencies.isEmpty { dependencies = [.independent] }
        return BookmarkListPreparedRowProjection(
            projection: projection,
            sourceDependencies: dependencies
        )
    }

    /** Reads one exact SQLite generic key and converts it to the shared bookmark source shape. */
    private static func bookmarkListSQLiteGenericSourceContent(
        module: BibleReaderSQLiteModuleHandle,
        key: String
    ) -> GenericBookmarkSourceContent? {
        let builder = SQLiteReaderDocumentContentBuilder(module: module)
        let document: BibleReaderSQLiteAuxiliaryDocument
        do {
            switch module.info.category {
            case .dictionary, .glossary:
                document = try builder.dictionary(key: key)
            case .commentary:
                guard let coordinate = SQLiteReaderNavigationResolver.commentaryCoordinate(
                    for: key
                ) else { return nil }
                let book = JSwordKJVAVersification.books.first {
                    $0.osisId == coordinate.osisBookId
                }
                document = try builder.commentary(
                    osisBookId: coordinate.osisBookId,
                    bookName: book?.longName ?? coordinate.osisBookId,
                    chapter: coordinate.chapter,
                    verse: coordinate.verse,
                    isNewTestament: book?.isNewTestament ?? false
                )
            default:
                return nil
            }
            return sqliteGenericBookmarkSourceContent(
                try BibleReaderBookmarkNavigationSQLiteFragment(
                    document: document,
                    module: module
                )
            )
        } catch {
            return nil
        }
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
     - Failure modes: Missing or unauthorized source content returns an empty projection without using
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
     - Side effects: Resolves installed ownership first, then reads SwiftData or the exact EPUB
       fragment only for one globally unowned local source.
     - Failure modes: Installed owners (including locked native rows), missing local
       documents, and stale keys return `nil`; no current reader source is used as a fallback.
     */
    private func genericBookmarkSourceContent(
        bookInitials: String,
        key: String
    ) -> GenericBookmarkSourceContent? {
        guard let localDocument = localGeneralBookDocument(named: bookInitials) else {
            return nil
        }
        if case .myDocument(let document) = localDocument,
           let store = myDocumentStore,
           let page = store.page(bookInitials: bookInitials, pageKey: key) {
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

        guard case .epub(let reader) = localDocument,
              let content = reader.content(forKey: key) else { return nil }
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
        persistenceAnnotationPayloadFactory().studyPadEntryJSON(entry)
    }

    /**
     Builds a typed Bible bookmark-to-label payload for Vue.js.
     */
    private func buildBibleBookmarkToLabelJSON(_ btl: BibleBookmarkToLabel) -> BookmarkToLabelData? {
        persistenceAnnotationPayloadFactory().bibleBookmarkToLabelJSON(btl)
    }

    /**
     Builds a typed generic bookmark-to-label payload for Vue.js.
     */
  private func buildGenericBookmarkToLabelJSON(_ gbtl: GenericBookmarkToLabel)
    -> BookmarkToLabelData?
  {
    persistenceAnnotationPayloadFactory().genericBookmarkToLabelJSON(gbtl)
    }

    /**
     Builds a typed label payload for bridge documents and label update events.
     */
    private func buildLabelData(_ label: Label) -> LabelData? {
        persistenceAnnotationPayloadFactory().labelData(label)
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

    /** Freezes persistence-only generic annotations for worker-side source enrichment. */
    private func genericDocumentOwnerSnapshot(
        bookInitials: String,
        key: String
    ) -> BibleReaderGenericDocumentOwnerSnapshot {
        let bookmarks = (bookmarkService?.genericBookmarks(
            bookInitials: bookInitials,
            key: key
        ) ?? []).map {
            BibleReaderPreparedGenericBookmarkInput(
                $0,
                unlabeledLabelID: Self.unlabeledLabelId
            )
        }
        let markers = myDocumentStore?.aiDocMarkers(
            bookInitials: bookInitials,
            pageKey: key
        ) ?? []
        return BibleReaderGenericDocumentOwnerSnapshot(
            genericBookmarkInputs: bookmarks,
            aiDocMarkers: markers,
            identity: BibleReaderGenericDocumentOwnerIdentity(
                genericBookmarks: bookmarks,
                aiDocMarkers: markers
            )
        )
    }

    /**
     Copies one globally authorized My Documents page and its exact annotation inputs.

     The supplied installed resolver comes from the operation's worker-side registry capture. This
     method performs only local owner selection and SwiftData reads on the main owner; it does not
     query native source content or render JSON.

     - Parameters:
       - requestedInitials: Exact initials or Android-supported alias selecting the local document.
       - requestedKey: Exact page key.
       - installedResolver: Operation-scoped installed registry captured under the source lease.
     - Returns: Complete copied values used by both source enrichment and publication validation.
     - Side effects: Reads local registration metadata, one page graph, annotations, and AI markers.
     - Failure modes: Installed/EPUB collisions, missing exact pages, replaced parents, and metadata
       failures return nil without controller mutation.
     */
    private func myDocumentOwnerSnapshot(
        requestedInitials: String,
        requestedKey: String,
        installedResolver: BibleReaderInstalledModuleResolver
    ) -> BibleReaderMyDocumentOwnerSnapshot? {
        guard let store = myDocumentStore,
              let localDocument = localGeneralBookDocument(
                named: requestedInitials,
                resolver: installedResolver
              ),
              case .myDocument(let authorizedDocument) = localDocument,
              let page = try? store.exactPage(
                bookInitials: authorizedDocument.initials,
                pageKey: requestedKey
              ),
              let document = page.document,
              document.id == authorizedDocument.id,
              SwordJavaStringIdentity.equals(document.initials, authorizedDocument.initials)
        else { return nil }

        let metadata = store.readerMetadata(
            for: page,
            bookInitials: document.initials,
            pageKey: page.pageKey,
            unknownPromptName: String(localized: "ai_unknown_prompt", defaultValue: "AI")
        )
        let inputs = (bookmarkService?.genericBookmarks(
            bookInitials: document.initials,
            key: page.pageKey
        ) ?? []).map {
            BibleReaderPreparedGenericBookmarkInput(
                $0,
                unlabeledLabelID: Self.unlabeledLabelId
            )
        }
        let fallbackLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        return BibleReaderMyDocumentOwnerSnapshot(
            source: BibleReaderPreparedMyDocumentSource(
                document: document,
                page: page,
                fallbackLanguage: fallbackLanguage
            ),
            metadata: metadata,
            genericBookmarkInputs: inputs,
            generatedBookLanguageCode: fallbackLanguage
        )
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
            sendLabels: { [weak self] labels in
                self?.bridge.emit(event: "update_labels", data: labels)
            },
      setRenderedContentState: {
        [weak self] category, moduleName, book, chapter, key, sourceProvenance, documentKind in
                self?.setRenderedContentState(
                    category: category,
                    moduleName: moduleName,
                    book: book,
                    chapter: chapter,
                    key: key,
                    sourceProvenance: sourceProvenance,
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
            if activeModule.map({
              SwordJavaStringIdentity.equals($0.info.name, initials)
            }) == true { return activeModule }
            if activeCommentaryModule.map({
              SwordJavaStringIdentity.equals($0.info.name, initials)
            }) == true { return activeCommentaryModule }
            if activeGeneralBookModule.map({
              SwordJavaStringIdentity.equals($0.info.name, initials)
            }) == true { return activeGeneralBookModule }
            return swordManager?.module(named: initials)
        }()
    let sqliteSourceModule = [
      activeSQLiteBibleModule,
      activeSQLiteCommentaryModule,
      activeSQLiteDictionaryModule,
    ].compactMap { $0 }.first {
      SwordJavaStringIdentity.equals($0.info.name, initials)
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
     - Side effects: Resolves one fresh global/local owner snapshot, then executes read-only source
       queries. SWORD reads restore their prior cursor.
     - Failure modes: Stale identity/generation, partial endpoint pairs, invalid/excessive ranges,
       missing exact keys, locked/wrong-category installed owners, and unreadable backends fail
       closed without substituting pane content or falling through to a colliding local document.
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
              expectedDocumentInitials.map({
                  SwordJavaStringIdentity.equals($0, initials)
              }) ?? true,
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
            if let module = activeSQLiteBibleModule,
               SwordJavaStringIdentity.equals(module.info.name, initials) {
                context = AIReaderSourceContextExtractor.sqliteBible(
                    module: module,
                    request: request
                )
            } else if let module = activeModule,
                      SwordJavaStringIdentity.equals(module.info.name, initials) {
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
            if let module = activeSQLiteCommentaryModule,
               SwordJavaStringIdentity.equals(module.info.name, initials) {
                context = AIReaderSourceContextExtractor.sqliteCommentary(
                    module: module,
                    osisBookId: osisBookId,
                    bookName: currentBook,
                    chapter: currentChapter,
                    verse: currentVerse,
                    isNewTestament: isNewTestament(currentBook)
                )
            } else if let module = activeCommentaryModule,
                      SwordJavaStringIdentity.equals(module.info.name, initials) {
                context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
            } else {
                return nil
            }

        case .dictionary:
            guard selectionBounds == nil else { return nil }
            if let module = activeSQLiteDictionaryModule,
               SwordJavaStringIdentity.equals(module.info.name, initials) {
                context = AIReaderSourceContextExtractor.sqliteDictionary(module: module, key: pageKey)
            } else if let module = activeDictionaryModule,
                      SwordJavaStringIdentity.equals(module.info.name, initials) {
                context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
            } else {
                return nil
            }

        case .generalBook:
            guard selectionBounds == nil else { return nil }
            guard let owner = installedOrLocalGeneralBookOwner(
                named: initials,
                preferredEpub: activeEpubReader
            ) else { return nil }
            switch owner {
            case .installed(let info, let readableSource):
                guard SwordJavaStringIdentity.equals(info.name, initials),
                      info.category == .generalBook,
                      activeGeneralBookModule.map({
                        SwordJavaStringIdentity.equals($0.info.name, info.name)
                      }) == true,
                      let readableSource,
                      case .sword(let module) = readableSource else {
                    return nil
                }
                context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)

            case .local(.myDocument(let document)):
                guard SwordJavaStringIdentity.equals(document.initials, initials),
                      activeGeneralBookModule == nil,
                      activeEpubReader == nil,
                      let store = myDocumentStore else {
                    return nil
                }
                context = AIReaderSourceContextExtractor.myDocument(
                    store: store,
                    bookInitials: document.initials,
                    pageKey: pageKey
                )

            case .local(.epub(let reader)):
                guard SwordJavaStringIdentity.equals(reader.initials, initials),
                      activeGeneralBookModule == nil,
                      activeEpubReader?.generationIdentifier == reader.generationIdentifier else {
                    return nil
                }
                context = AIReaderSourceContextExtractor.epub(reader: reader, key: pageKey)

            case .missing:
                return nil
            }

        case .map:
            guard selectionBounds == nil,
                  let module = activeMapModule,
                  SwordJavaStringIdentity.equals(module.info.name, initials) else {
                return nil
            }
            context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)

        case .epub:
            guard selectionBounds == nil,
                  let owner = installedOrLocalGeneralBookOwner(
                      named: initials,
                      preferredEpub: activeEpubReader
                  ), case .local(.epub(let reader)) = owner,
                  SwordJavaStringIdentity.equals(reader.initials, initials),
                  activeGeneralBookModule == nil,
                  activeEpubReader?.generationIdentifier == reader.generationIdentifier else {
                return nil
            }
            context = AIReaderSourceContextExtractor.epub(reader: reader, key: pageKey)

        case .dailyDevotion:
            guard selectionBounds == nil,
                  let module = activeGeneralBookModule,
                  SwordJavaStringIdentity.equals(module.info.name, initials),
                  module.info.category == .dailyDevotion else {
                return nil
            }
            context = AIReaderSourceContextExtractor.swordDocument(module: module, key: pageKey)
        }

        guard let context,
              SwordJavaStringIdentity.equals(context.sourceDocumentInitials, initials),
              context.sourceBookKey == pageKey,
              contentIntentGeneration == generation,
              currentCategory == category,
              aiCurrentSourceInitials(for: category).map({
                SwordJavaStringIdentity.equals($0, initials)
              }) == true,
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
           SwordJavaStringIdentity.equals(module.info.name, bookInitials) {
            context = AIReaderSourceContextExtractor.swordBible(module: module, request: request)
        } else if case .sqlite(let module)? = source,
                  SwordJavaStringIdentity.equals(module.info.name, bookInitials) {
            context = AIReaderSourceContextExtractor.sqliteBible(module: module, request: request)
        } else {
            return nil
        }
        guard let context,
              SwordJavaStringIdentity.equals(context.sourceDocumentInitials, bookInitials),
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
        guard aiCurrentSourceInitials(for: .bible).map({
                  SwordJavaStringIdentity.equals($0, bookInitials)
              }) == true,
              let sourceBounds = AIReaderSourceRange.bibleBounds(
                  start: startOrdinal,
                  end: endOrdinal
              ) else {
            return nil
        }
        if let sqliteModule = activeSQLiteBibleModule,
           SwordJavaStringIdentity.equals(sqliteModule.info.name, bookInitials),
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
struct OsisVerseCoordinate: Hashable, Sendable {
    let osisBookId: String
    let chapter: Int
    let verse: Int
}

/**
 Parsed OSIS passage used by cross-reference resolution.

 `sourceVerses` retains the ordered source-canon expansion of one Android `BookAndKey`. This keeps
 ranges and source-only books intact until a target module performs explicit versification mapping.
 */
struct OsisRef: Sendable {
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
