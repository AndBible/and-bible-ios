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
    private(set) var currentBook: String = "Genesis"
    private(set) var currentChapter: Int = 1
    private(set) var currentVerse: Int = 1
    private var clientReady = false
    private var configSent = false

    /// Whether the WebView is currently showing the My Notes document (vs Bible text).
    private(set) var showingMyNotes = false

    /// Whether the WebView is currently showing a StudyPad document.
    private(set) var showingStudyPad = false
    /// The label ID of the currently active StudyPad.
    private(set) var activeStudyPadLabelId: UUID?
    /// The name of the currently active StudyPad label (for the header).
    private(set) var activeStudyPadLabelName: String?
    /// Whether the WebView is in editing mode (Quill editor active).
    private(set) var editingInWebView = false

    /// SWORD module manager and active Bible module
    private(set) var swordManager: SwordManager?
    private(set) var activeModule: SwordModule?
    private(set) var activeModuleName: String = "KJV"
    /// All installed Bible modules (for module switching)
    private(set) var installedBibleModules: [ModuleInfo] = []

    /**
     Dynamic book list from the active module's versification.
     Populated when a Bible module is loaded. Falls back to `Self.defaultBooks` if empty.
     */
    private(set) var moduleBookList: [BookInfo] = []

    /// The active book list: uses the module's versification when available, otherwise the 66-book default.
    var bookList: [BookInfo] {
        moduleBookList.isEmpty ? Self.defaultBooks : moduleBookList
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
    static let emptyRenderedContentState = "category=none;module=none;book=none;chapter=none;key=none"
    private(set) var renderedContentState: String = BibleReaderController.emptyRenderedContentState

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

    /// Escapes semantically important content-state tokens for accessibility export and tests.
    private static func contentStateToken(_ raw: String?) -> String {
        (raw ?? "none")
            .replacingOccurrences(of: ";", with: "_")
            .replacingOccurrences(of: ",", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Records the latest content identity that native requested the reader WebView to display.
    private func setRenderedContentState(
        category: DocumentCategory,
        moduleName: String?,
        book: String,
        chapter: Int? = nil,
        key: String? = nil
    ) {
        renderedContentState = [
            "category=\(category.pageManagerKey)",
            "module=\(Self.contentStateToken(moduleName))",
            "book=\(Self.contentStateToken(book))",
            "chapter=\(chapter.map(String.init) ?? "none")",
            "key=\(Self.contentStateToken(key))",
        ].joined(separator: ";")
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
    /// TTS service
    var speakService: SpeakService?
    /// Workspace store for history recording
    var workspaceStore: WorkspaceStore?
    /// The current window (for history recording)
    var activeWindow: Window?

    /**
     Creates one controller for a single `BibleView` bridge instance.

     - Parameters:
       - bridge: Bridge used to emit events to the Vue.js reader and receive callbacks.
       - bookmarkService: Optional bookmark/studypad service used for annotation features.

     Side effects:
     - assigns itself as the bridge delegate
     - initializes SWORD state and installed-module caches
     */
    public init(bridge: BibleBridge, bookmarkService: BookmarkService? = nil) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        super.init()
        bridge.delegate = self
        initializeSword()
    }

    init(bridge: BibleBridge, bookmarkService: BookmarkService? = nil, swordManagerOverride: SwordManager) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        super.init()
        bridge.delegate = self
        configureSwordManager(swordManagerOverride)
    }

    /// Callback for showing Strong's definitions in a sheet (multiDocJSON, configJSON).
    var onShowStrongsDefinition: ((String, String) -> Void)?

    /// Callback for opening search with a Strong's number (from "Find all occurrences" links).
    var onShowStrongsSearch: ((String) -> Void)?

    /// Callback for showing cross-reference results (list of parsed references with verse text).
    var onShowCrossReferences: (([CrossReference]) -> Void)?

    /// Callback for presenting compare view (book, chapter, moduleName, startVerse?, endVerse?).
    var onCompareVerses: ((String, Int, String, Int?, Int?) -> Void)?

    /// Callback for presenting native label assignment UI (bookmarkId).
    var onAssignLabels: ((UUID) -> Void)?

    /// Settings store for reading preferred dictionary setting.
    var settingsStore: SettingsStore?

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

    /// Verse-to-character-offset mapping for TTS word highlighting.
    private var speakVerseOffsets: [(osisID: String, ordinal: Int, startOffset: Int, endOffset: Int)] = []
    /// Currently highlighted verse ordinal during TTS.
    private var currentHighlightedOrdinal: Int?
    /// The full spoken text (for word extraction).
    private var speakFullText: String = ""

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
        guard let module = activeModule, let service = speakService else { return }
        let osisBookId = osisBookId(for: currentBook)
        let chapter = currentChapter

        // Set Now Playing metadata before speaking
        service.currentTitle = "\(currentBook) \(currentChapter)"
        service.currentSubtitle = activeModuleName

        // Temporarily disable Strong's/morphology so stripText() returns clean plain text.
        // These options cause stripText() to include Strong's number tokens (e.g. "H7225")
        // which corrupt TTS output and cause premature utterance completion.
        let mgr = swordManager
        let strongsWasOn = (displaySettings.strongsMode ?? 0) > 0
        let morphWasOn = displaySettings.showMorphology ?? false
        if strongsWasOn { mgr?.setGlobalOption(.strongsNumbers, enabled: false) }
        if morphWasOn { mgr?.setGlobalOption(.morphology, enabled: false) }

        // Build text and verse offset map
        module.setKey("\(osisBookId) \(chapter):1")
        let preamble = "\(currentBook) chapter \(chapter). "
        var text = preamble
        var offsets: [(osisID: String, ordinal: Int, startOffset: Int, endOffset: Int)] = []

        while true {
            let key = module.currentKey()
            guard let (_, parsedChapter, parsedVerse) = parseVerseKey(key) else { break }
            if parsedChapter != chapter { break }

            let verseText = module.stripText()
            if !verseText.isEmpty {
                let trimmed = verseText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                let startOffset = text.utf16.count
                text += trimmed
                let endOffset = text.utf16.count
                let osisID = "\(osisBookId).\(chapter).\(parsedVerse)"
                let ordinal = (chapter - 1) * 40 + parsedVerse
                offsets.append((osisID: osisID, ordinal: ordinal, startOffset: startOffset, endOffset: endOffset))
            }
            if !module.next() { break }
        }

        // Restore Strong's/morphology options
        if strongsWasOn { mgr?.setGlobalOption(.strongsNumbers, enabled: true) }
        if morphWasOn { mgr?.setGlobalOption(.morphology, enabled: true) }

        speakVerseOffsets = offsets
        speakFullText = text
        currentHighlightedOrdinal = nil

        // Wire up word-level callback
        service.onWordSpoken = { [weak self] word, range in
            self?.handleWordSpoken(word: word, range: range)
        }
        service.onSpeechStopped = { [weak self] in
            self?.clearSpeakHighlight()
        }

        let lang = module.info.language
        let speechLang = lang.hasPrefix("en") ? "en-US" : lang
        service.speak(text: text, language: speechLang)
    }

    /**
     Speak a specific verse range using TTS.

     See `speakCurrentChapter()` for details on why Strong's/Morphology options
     are temporarily disabled during text extraction.
     */
    private func speakVerseRange(startOrdinal: Int, endOrdinal: Int) {
        guard let module = activeModule, let service = speakService else { return }
        let osisBookId = osisBookId(for: currentBook)
        let chapter = currentChapter

        // Set Now Playing metadata before speaking
        service.currentTitle = "\(currentBook) \(currentChapter)"
        service.currentSubtitle = activeModuleName

        // Temporarily disable Strong's/morphology so stripText() returns clean plain text.
        let mgr = swordManager
        let strongsWasOn = (displaySettings.strongsMode ?? 0) > 0
        let morphWasOn = displaySettings.showMorphology ?? false
        if strongsWasOn { mgr?.setGlobalOption(.strongsNumbers, enabled: false) }
        if morphWasOn { mgr?.setGlobalOption(.morphology, enabled: false) }

        // Collect text for the specified ordinal range
        module.setKey("\(osisBookId) \(chapter):1")
        var text = ""

        while true {
            let key = module.currentKey()
            guard let (_, parsedChapter, parsedVerse) = parseVerseKey(key) else { break }
            if parsedChapter != chapter { break }

            let ordinal = (chapter - 1) * 40 + parsedVerse
            if ordinal >= startOrdinal && ordinal <= endOrdinal {
                let verseText = module.stripText()
                if !verseText.isEmpty {
                    text += verseText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                }
            }
            if ordinal > endOrdinal { break }
            if !module.next() { break }
        }

        // Restore Strong's/morphology options
        if strongsWasOn { mgr?.setGlobalOption(.strongsNumbers, enabled: true) }
        if morphWasOn { mgr?.setGlobalOption(.morphology, enabled: true) }

        if !text.isEmpty {
            let lang = module.info.language
            let speechLang = lang.hasPrefix("en") ? "en-US" : lang
            service.speak(text: text, language: speechLang)
        }
    }

    // MARK: - TTS Word Highlighting

    /// Handle a word being spoken — highlight it in the WebView.
    private func handleWordSpoken(word: String, range: NSRange) {
        let charOffset = range.location
        logger.info("handleWordSpoken: '\(word)' offset=\(charOffset)")

        // Find which verse this character offset falls in
        var targetOrdinal: Int?
        var offsetInVerse: Int = 0
        for entry in speakVerseOffsets {
            if charOffset >= entry.startOffset && charOffset < entry.endOffset {
                targetOrdinal = entry.ordinal
                offsetInVerse = charOffset - entry.startOffset
                break
            }
        }

        guard let ordinal = targetOrdinal else { return }

        // Escape the word for safe JS string
        let escapedWord = word
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let scrollNeeded = ordinal != currentHighlightedOrdinal
        currentHighlightedOrdinal = ordinal

        // Use data-ordinal attribute to find verse elements (matches Vue.js Verse.vue template)
        // Pass offsetInVerse so JS can find the correct occurrence of duplicate words
        let js = """
        (function() {
            // Clean up previous word highlight (unwrap span, restore text)
            var prev = document.getElementById('speaking-word');
            if (prev) {
                var p = prev.parentNode;
                if (p) {
                    p.replaceChild(document.createTextNode(prev.textContent || ''), prev);
                    p.normalize();
                }
            }

            // Update verse highlight
            var oldVerse = document.querySelector('.speaking-verse');
            if (oldVerse) oldVerse.classList.remove('speaking-verse');

            var verse = document.querySelector('[data-ordinal="\(ordinal)"]');
            if (!verse) return;
            verse.classList.add('speaking-verse');

            // Search for the word in text nodes of this verse.
            // Use offsetInVerse to find the correct occurrence when a word
            // appears multiple times (e.g. "called" in "God called...he called").
            var word = '\(escapedWord)';
            if (!word || word.length === 0) return;
            var targetOffset = \(offsetInVerse);

            var walker = document.createTreeWalker(verse, NodeFilter.SHOW_TEXT, null);
            var node;
            var cumOffset = 0;
            var bestNode = null, bestIdx = -1, bestDist = Infinity;

            while (node = walker.nextNode()) {
                var text = node.nodeValue;
                var searchFrom = 0;
                while (true) {
                    var idx = text.indexOf(word, searchFrom);
                    if (idx === -1) break;
                    var globalPos = cumOffset + idx;
                    var dist = Math.abs(globalPos - targetOffset);
                    if (dist < bestDist) {
                        bestDist = dist;
                        bestNode = node;
                        bestIdx = idx;
                    }
                    searchFrom = idx + 1;
                }
                cumOffset += text.length;
            }

            if (bestNode && bestIdx >= 0) {
                try {
                    var range = document.createRange();
                    range.setStart(bestNode, bestIdx);
                    range.setEnd(bestNode, bestIdx + word.length);
                    var span = document.createElement('span');
                    span.id = 'speaking-word';
                    range.surroundContents(span);
                } catch(e) {}

                if (\(scrollNeeded ? "true" : "false")) {
                    var sw = document.getElementById('speaking-word');
                    if (sw) sw.scrollIntoView({behavior: 'smooth', block: 'center'});
                }
            }
        })();
        """
        DispatchQueue.main.async { [weak self] in
            self?.bridge.webView?.evaluateJavaScript(js)
        }
    }

    /// Clear all TTS highlights from the WebView.
    private func clearSpeakHighlight() {
        currentHighlightedOrdinal = nil
        let js = """
        (function() {
            var prev = document.getElementById('speaking-word');
            if (prev) {
                var p = prev.parentNode;
                if (p) {
                    p.replaceChild(document.createTextNode(prev.textContent || ''), prev);
                    p.normalize();
                }
            }
            var v = document.querySelector('.speaking-verse');
            if (v) v.classList.remove('speaking-verse');
        })();
        """
        DispatchQueue.main.async { [weak self] in
            self?.bridge.webView?.evaluateJavaScript(js)
        }
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

    /// Load commentary text for the current chapter using the active commentary module.
    private func loadCommentaryForCurrentVerse() {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        guard let module = activeCommentaryModule else {
            // No commentary module selected — show a message
            bridge.emit(event: "clear_document")
            let xml = "<div><title type=\"x-gen\">No Commentary</title><div type=\"paragraph\"><p>No commentary module is installed. Download one from the module browser.</p></div></div>"
            let osisBookId = osisBookId(for: currentBook)
            let document = buildDocumentJSON(
                osisBookId: osisBookId,
                bookName: currentBook,
                chapter: currentChapter,
                verseCount: 1,
                isNT: isNewTestament(currentBook),
                xml: xml,
                bookmarks: [],
                bookCategory: "COMMENTARY",
                bookInitials: "none"
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: """
            {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
            """)
            setRenderedContentState(
                category: .commentary,
                moduleName: activeCommentaryModuleName,
                book: currentBook,
                chapter: currentChapter,
                key: "\(osisBookId).\(currentChapter)"
            )
            applyNightModeBackground()
            return
        }

        let osisBookId = osisBookId(for: currentBook)
        let chapter = currentChapter
        let isNT = isNewTestament(currentBook)

        // Use the same setKey/rawEntry/next pattern as loadChapterFromSword
        let startKey = "\(osisBookId) \(chapter):1"
        module.setKey(startKey)

        var verses: [(Int, String)] = []
        while true {
            let key = module.currentKey()
            guard let (_, parsedChapter, parsedVerse) = parseVerseKey(key) else { break }
            if parsedChapter != chapter { break }

            let text = module.rawEntry()
            if !text.isEmpty {
                verses.append((parsedVerse, text))
            }
            if !module.next() { break }
        }

        let moduleName = activeCommentaryModuleName ?? "Commentary"
        let xml: String
        let verseCount: Int

        if verses.isEmpty {
            // Commentary may not have entries for every chapter
            xml = "<div><title type=\"x-gen\">\(currentBook) \(chapter)</title><div type=\"paragraph\"><p>No commentary available for this chapter in \(moduleName).</p></div></div>"
            verseCount = 1
        } else {
            xml = buildSwordChapterXML(osisBookId: osisBookId, bookName: currentBook, chapter: chapter, verses: verses)
            verseCount = verses.count
        }

        // Query bookmarks for this chapter
        let chapterBookmarks = bookmarksForCurrentChapter(verseCount: verseCount)

        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()

        let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: chapter,
            verseCount: verseCount,
            isNT: isNT,
            xml: xml,
            bookmarks: chapterBookmarks,
            bookCategory: "COMMENTARY",
            bookInitials: moduleName
        )
        bridge.emit(event: "add_documents", data: document)

        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
        setRenderedContentState(
            category: .commentary,
            moduleName: moduleName,
            book: currentBook,
            chapter: currentChapter,
            key: "\(osisBookId).\(currentChapter)"
        )
        emitActiveState()

        bridge.clearSelection()
        applyNightModeBackground()
    }

    // MARK: - Dictionary/GenBook/Map Content Loading

    /**
     Load a dictionary entry and display it in the WebView.
     Uses renderText() since dictionary entries are typically HTML-formatted definitions.
     */
    public func loadDictionaryEntry(key: String? = nil) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        guard let module = activeDictionaryModule else {
            bridge.emit(event: "clear_document")
            let xml = "<div><title type=\"x-gen\">No Dictionary</title><div type=\"paragraph\"><p>No dictionary module is selected. Download one from the module browser.</p></div></div>"
            let document = buildDocumentJSON(
                osisBookId: "Dict", bookName: "Dictionary", chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "DICTIONARY", bookInitials: "none"
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .dictionary,
                moduleName: activeDictionaryModuleName,
                book: "Dictionary",
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        let entryKey = key ?? currentDictionaryKey
        guard let entryKey else {
            // No key selected yet — show prompt
            bridge.emit(event: "clear_document")
            let moduleName = activeDictionaryModuleName ?? "Dictionary"
            let xml = "<div><title type=\"x-gen\">\(moduleName)</title><div type=\"paragraph\"><p>Select an entry from the key browser to view its definition.</p></div></div>"
            let document = buildDocumentJSON(
                osisBookId: "Dict", bookName: moduleName, chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "DICTIONARY", bookInitials: moduleName
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .dictionary,
                moduleName: moduleName,
                book: moduleName,
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        currentDictionaryKey = entryKey
        module.setKey(entryKey)
        let text = module.renderText()
        let moduleName = activeDictionaryModuleName ?? "Dictionary"

        // Persist key
        if let pm = activeWindow?.pageManager {
            pm.dictionaryKey = entryKey
            onPersistState?()
        }

        let xml: String
        if text.isEmpty {
            xml = "<div><title type=\"x-gen\">\(entryKey)</title><div type=\"paragraph\"><p>No definition available for \"\(entryKey)\" in \(moduleName).</p></div></div>"
        } else {
            // Wrap rendered HTML in OSIS-like structure for Vue.js
            xml = "<div><title type=\"x-gen\">\(entryKey)</title><div type=\"paragraph\">\(text)</div></div>"
        }

        bridge.emit(event: "clear_document")
        let document = buildDocumentJSON(
            osisBookId: "Dict", bookName: entryKey, chapter: 1, verseCount: 1,
            isNT: false, xml: xml, bookCategory: "DICTIONARY", bookInitials: moduleName
        )
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
        setRenderedContentState(
            category: .dictionary,
            moduleName: moduleName,
            book: entryKey,
            key: entryKey
        )
        applyNightModeBackground()
    }

    /// Load a general book entry and display it in the WebView.
    public func loadGeneralBookEntry(key: String? = nil) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        guard let module = activeGeneralBookModule else {
            bridge.emit(event: "clear_document")
            let xml = "<div><title type=\"x-gen\">No General Book</title><div type=\"paragraph\"><p>No general book module is selected. Download one from the module browser.</p></div></div>"
            let document = buildDocumentJSON(
                osisBookId: "GenBook", bookName: "General Book", chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: "none"
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .generalBook,
                moduleName: activeGeneralBookModuleName,
                book: "General Book",
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        let entryKey = key ?? currentGeneralBookKey
        guard let entryKey else {
            bridge.emit(event: "clear_document")
            let moduleName = activeGeneralBookModuleName ?? "General Book"
            let xml = "<div><title type=\"x-gen\">\(moduleName)</title><div type=\"paragraph\"><p>Select an entry from the key browser to view its content.</p></div></div>"
            let document = buildDocumentJSON(
                osisBookId: "GenBook", bookName: moduleName, chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: moduleName
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .generalBook,
                moduleName: moduleName,
                book: moduleName,
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        currentGeneralBookKey = entryKey
        module.setKey(entryKey)
        let text = module.renderText()
        let moduleName = activeGeneralBookModuleName ?? "General Book"

        if let pm = activeWindow?.pageManager {
            pm.generalBookKey = entryKey
            onPersistState?()
        }

        let xml: String
        if text.isEmpty {
            xml = "<div><title type=\"x-gen\">\(entryKey)</title><div type=\"paragraph\"><p>No content available for \"\(entryKey)\" in \(moduleName).</p></div></div>"
        } else {
            xml = "<div><title type=\"x-gen\">\(entryKey)</title><div type=\"paragraph\">\(text)</div></div>"
        }

        bridge.emit(event: "clear_document")
        let document = buildDocumentJSON(
            osisBookId: "GenBook", bookName: entryKey, chapter: 1, verseCount: 1,
            isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: moduleName
        )
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
        setRenderedContentState(
            category: .generalBook,
            moduleName: moduleName,
            book: entryKey,
            key: entryKey
        )
        applyNightModeBackground()
    }

    /// Load a map entry and display it in the WebView.
    public func loadMapEntry(key: String? = nil) {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""

        guard let module = activeMapModule else {
            bridge.emit(event: "clear_document")
            let xml = "<div><title type=\"x-gen\">No Map</title><div type=\"paragraph\"><p>No map module is selected. Download one from the module browser.</p></div></div>"
            let document = buildDocumentJSON(
                osisBookId: "Map", bookName: "Map", chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "MAP", bookInitials: "none"
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .map,
                moduleName: activeMapModuleName,
                book: "Map",
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        let entryKey = key ?? currentMapKey
        guard let entryKey else {
            bridge.emit(event: "clear_document")
            let moduleName = activeMapModuleName ?? "Map"
            let xml = "<div><title type=\"x-gen\">\(moduleName)</title><div type=\"paragraph\"><p>Select an entry from the key browser to view the map.</p></div></div>"
            let document = buildDocumentJSON(
                osisBookId: "Map", bookName: moduleName, chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "MAP", bookInitials: moduleName
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
            setRenderedContentState(
                category: .map,
                moduleName: moduleName,
                book: moduleName,
                key: "none"
            )
            applyNightModeBackground()
            return
        }

        currentMapKey = entryKey
        module.setKey(entryKey)
        let text = module.renderText()
        let moduleName = activeMapModuleName ?? "Map"

        if let pm = activeWindow?.pageManager {
            pm.mapKey = entryKey
            onPersistState?()
        }

        let xml: String
        if text.isEmpty {
            xml = "<div><title type=\"x-gen\">\(entryKey)</title><div type=\"paragraph\"><p>No content available for \"\(entryKey)\" in \(moduleName).</p></div></div>"
        } else {
            xml = "<div><title type=\"x-gen\">\(entryKey)</title><div type=\"paragraph\">\(text)</div></div>"
        }

        bridge.emit(event: "clear_document")
        let document = buildDocumentJSON(
            osisBookId: "Map", bookName: entryKey, chapter: 1, verseCount: 1,
            isNT: false, xml: xml, bookCategory: "MAP", bookInitials: moduleName
        )
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: "{\"jumpToOrdinal\":null,\"jumpToAnchor\":null,\"jumpToId\":null,\"topOffset\":0,\"bottomOffset\":0}")
        setRenderedContentState(
            category: .map,
            moduleName: moduleName,
            book: entryKey,
            key: entryKey
        )
        applyNightModeBackground()
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
            let document = buildDocumentJSON(
                osisBookId: "Epub", bookName: "EPUB", chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: "none"
            )
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
            let document = buildDocumentJSON(
                osisBookId: "Epub", bookName: title, chapter: 1, verseCount: 1,
                isNT: false, xml: xml, bookCategory: "GENERAL_BOOK", bookInitials: title
            )
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
     Uses JSONSerialization for correct escaping of all special characters in HTML content.
     IMPORTANT: Uses type "osis" (not "bible") because OsisDocument.vue passes isNativeHtml
     to OsisFragment, whereas BibleDocument.vue does not — without this, the EPUB HTML
     would go through OSIS template conversion and render as blank.
     */
    private func buildEpubDocumentJSON(bookName: String, bookInitials: String, content: String) -> String {
        let doc: [String: Any] = [
            "id": "doc-1",
            "type": "osis",
            "osisFragment": [
                "xml": content,
                "key": "epub",
                "keyName": bookName,
                "v11n": "KJVA",
                "bookCategory": "GENERAL_BOOK",
                "bookInitials": bookInitials,
                "bookAbbreviation": "Epub",
                "osisRef": "epub",
                "isNewTestament": false,
                "features": [String: Any](),
                "ordinalRange": [0, 0],
                "language": "en",
                "direction": "ltr"
            ] as [String: Any],
            "bookInitials": bookInitials,
            "bookCategory": "GENERAL_BOOK",
            "bookAbbreviation": "Epub",
            "bookName": bookName,
            "key": "epub",
            "v11n": "KJVA",
            "osisRef": "epub",
            "annotateRef": "",
            "genericBookmarks": [Any](),
            "ordinalRange": [0, 0],
            "isNativeHtml": true,
            "highlightedOrdinalRange": NSNull()
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize EPUB document JSON")
            return "{}"
        }
        return json
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
     Copy module state (SwordManager + module lists) from an existing controller.
     Avoids creating multiple C++ SWMgr instances which conflict with each other.
     Each controller still gets its own SwordModule handles for independent cursor state.
     */
    public func copyModuleState(from other: BibleReaderController) {
        guard let mgr = other.swordManager else { return }
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
        lastScrollTarget = currentVerse > 1
            ? .ordinal(ordinal(forChapter: currentChapter, verse: currentVerse))
            : .chapterTop
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
            let ordinal = ordinal(forChapter: chapter, verse: max(1, explicitVerse))
            originalNavigationOrdinalRange = [ordinal, ordinal]
        } else {
            originalNavigationOrdinalRange = nil
        }
        if resolvedVerse > 1 {
            lastScrollTarget = .ordinal(ordinal(forChapter: chapter, verse: resolvedVerse))
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
       and loads the current content into the web view
     */
    public func bridgeDidSetClientReady(_ bridge: BibleBridge) {
        logger.info("Client ready, sending initial content")
        clientReady = true
        loadRecentLabels()
        applyNightModeBackground()
        updateActiveLanguages()
        if !configSent {
            bridge.emit(event: "set_config", data: buildConfigJSON())
            configSent = true
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
     - invokes `onPersistState` so the owning view can save SwiftData changes
     */
    public func bridge(_ bridge: BibleBridge, saveState state: String) {
        activeWindow?.pageManager?.jsState = state
        onPersistState?()
    }

    /**
     Receives modal open/close notifications from the web client.

     - Parameters:
       - bridge: Bridge reporting modal visibility.
       - isOpen: Whether a modal is currently shown inside the web client.

     - Note: iOS currently does not need this signal, so the callback is intentionally a no-op.
     */
    public func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool) {}

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

     Failure modes:
     - ignores keys other than `ArrowLeft` and `ArrowRight`
     */
    public func bridge(_ bridge: BibleBridge, onKeyDown key: String) {
        switch key {
        case "ArrowLeft":
            navigatePrevious()
        case "ArrowRight":
            navigateNext()
        default:
            break
        }
    }

    // MARK: - BibleBridgeDelegate — Navigation & Scroll

    /**
     Tracks visible-verse changes reported by the web client during scrolling.

     - Parameters:
       - bridge: Bridge reporting the scroll position change.
       - ordinal: Approximate verse ordinal currently near the viewport focus.
       - key: Verse/document key string such as `Gen.1.5` used to infer chapter changes.

     Side effects:
     - marks the pane as interacted-with, updates scroll-restoration state, persists chapter/book
       changes to the page manager, and notifies the window manager for synchronized scrolling
     */
    public func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool) {
        // Focus-on-interaction: scrolling in a pane makes it the active window
        onInteraction?()
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
                    let verse = max(1, ordinal - (chapter - 1) * 40)
                    currentVerse = verse
                    pm.bibleVerseNo = verse
                    persistVisibleVerseState(immediate: true)
                }
            } else if let name = bookName(forOsisId: osisId), name != currentBook {
                currentBook = name
                if let pm = activeWindow?.pageManager {
                    if let bookIdx = bookList.firstIndex(where: { $0.name == currentBook }) {
                        pm.bibleBibleBook = bookIdx
                    }
                    let verse = max(1, ordinal - (currentChapter - 1) * 40)
                    currentVerse = verse
                    pm.bibleVerseNo = verse
                    persistVisibleVerseState(immediate: true)
                }
            } else if let pm = activeWindow?.pageManager {
                let verse = max(1, ordinal - (currentChapter - 1) * 40)
                currentVerse = verse
                pm.bibleVerseNo = verse
                persistVisibleVerseState(immediate: false)
            }
        }

        // Notify WindowManager for synchronized scrolling
        if let window = activeWindow {
            windowManagerRef?.notifyVerseChanged(sourceWindow: window, ordinal: ordinal, key: key)
        }
    }

    /// Scroll the WebView to a specific verse ordinal (for sync from another window).
    public func scrollToOrdinal(_ ordinal: Int) {
        bridge.emit(event: "scroll_to_verse", data: "{\"ordinal\":\(ordinal),\"now\":false}")
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
        guard let service = bookmarkService else {
            logger.warning("addBookmark: bookmarkService is nil")
            return
        }
        // Check for an existing bookmark at the same verse (by startOrdinal + book)
        let existing = service.bookmarks(for: startOrdinal, endOrdinal: startOrdinal, book: currentBook)
            .first(where: { $0.ordinalStart == startOrdinal })

        let bookmark: BibleBookmark
        let isNew: Bool
        if let existing {
            bookmark = existing
            isNew = false
        } else {
            bookmark = service.addBibleBookmark(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                wholeVerse: wholeVerse,
                startOffset: startOffset,
                endOffset: endOffset,
                addNote: addNote
            )
            bookmark.book = currentBook
            isNew = true

            // Auto-assign labels from workspace settings
            let autoAssignIds = activeWindow?.workspace?.workspaceSettings?.autoAssignLabels ?? []
            for labelId in autoAssignIds {
                service.toggleLabel(bookmarkId: bookmark.id, labelId: labelId)
                // Advance StudyPad cursor for this label
                if let cursor = activeWindow?.workspace?.workspaceSettings?.studyPadCursors[labelId] {
                    if let btl = service.bibleBookmarkToLabel(bookmarkId: bookmark.id, labelId: labelId) {
                        btl.orderNumber = cursor
                        activeWindow?.workspace?.workspaceSettings?.studyPadCursors[labelId] = cursor + 1
                    }
                }
            }
            if !autoAssignIds.isEmpty {
                onPersistState?()
            }
        }

        // Send the bookmark to Vue.js
        let json = buildBookmarkJSON(bookmark)
        bridge.emit(event: "add_or_update_bookmarks", data: "[\(json)]")

        // Open the bookmark modal (matching Android's makeBookmark behavior):
        // - New bookmarks always open with label assignment
        // - addNote=true opens the notes editor directly
        // - Existing bookmarks with addNote=true also open notes editor
        let bmId = bookmark.id.uuidString
        if addNote {
            bridge.emit(event: "bookmark_clicked", data: "\"\(bmId)\", {\"openLabels\":true,\"openNotes\":true}")
        } else if isNew {
            bridge.emit(event: "bookmark_clicked", data: "\"\(bmId)\", {\"openLabels\":true}")
        }
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
        guard let service = bookmarkService else { return }
        let bookmark = service.addGenericBookmark(
            bookInitials: bookInitials,
            key: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        // Send the bookmark to Vue.js and open modal
        let json = buildGenericBookmarkJSONForStudyPad(bookmark)
        bridge.emit(event: "add_or_update_bookmarks", data: "[\(json)]")

        let bmId = bookmark.id.uuidString
        if addNote {
            bridge.emit(event: "bookmark_clicked", data: "\"\(bmId)\", {\"openLabels\":true,\"openNotes\":true}")
        } else {
            bridge.emit(event: "bookmark_clicked", data: "\"\(bmId)\", {\"openLabels\":true}")
        }
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
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.removeBibleBookmark(id: uuid)
        bridge.emit(event: "delete_bookmarks", data: "[\"\(bookmarkId)\"]")
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
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.removeGenericBookmark(id: uuid)
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
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.saveBibleBookmarkNote(bookmarkId: uuid, note: note)
        let escapedNote = (note ?? "").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        bridge.emit(event: "bookmark_note_modified", data: """
        {"id":"\(bookmarkId)","notes":"\(escapedNote)","lastUpdatedOn":\(timestamp)}
        """)
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
        let json = buildBookmarkJSON(bookmark)
        bridge.emit(event: "add_or_update_bookmarks", data: "[\(json)]")
        sendLabelsToVueJS()
        // Re-send config to update favouriteLabels in Vue.js appSettings
        bridge.emit(event: "set_config", data: buildConfigJSON())
    }

    /**
     Toggles one label assignment on a bookmark and re-emits the updated bookmark state.
     */
    public func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String) {
        logger.info("Toggle label \(labelId) on bookmark \(bookmarkId)")
        guard let service = bookmarkService,
              let bmId = UUID(uuidString: bookmarkId),
              let lblId = UUID(uuidString: labelId) else { return }
        let type = service.toggleLabel(bookmarkId: bmId, labelId: lblId)
        trackRecentLabel(labelId)
        // Emit updated bookmark back to Vue.js
        emitBookmarkUpdate(bookmarkId: bmId, type: type)
        sendLabelsToVueJS()
    }

    /**
     Removes one label assignment from a bookmark and re-emits the updated bookmark state.
     */
    public func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {
        logger.info("Remove label \(labelId) from bookmark \(bookmarkId)")
        guard let service = bookmarkService,
              let bmId = UUID(uuidString: bookmarkId),
              let lblId = UUID(uuidString: labelId) else { return }
        service.removeLabel(bookmarkId: bmId, labelId: lblId)
        // Emit updated bookmark back to Vue.js
        emitBookmarkUpdate(bookmarkId: bmId)
    }

    /**
     Sets the primary label used to style a bookmark in Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {
        logger.info("Set primary label \(labelId) on bookmark \(bookmarkId)")
        guard let service = bookmarkService,
              let bmId = UUID(uuidString: bookmarkId),
              let lblId = UUID(uuidString: labelId) else { return }
        service.setPrimaryLabel(bookmarkId: bmId, labelId: lblId)
        // Emit updated bookmark back to Vue.js
        emitBookmarkUpdate(bookmarkId: bmId)
    }

    /**
     Updates whether a bookmark should highlight whole verses or a text-range selection.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {
        logger.info("Set whole verse \(value) for bookmark \(bookmarkId)")
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.setWholeVerse(bookmarkId: uuid, value: value)
    }

    /**
     Updates the custom icon attached to a bookmark.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {
        logger.info("Set custom icon for bookmark \(bookmarkId)")
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.setCustomIcon(bookmarkId: uuid, value: value)
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
        guard let service = bookmarkService,
              let lblId = UUID(uuidString: labelId) else { return }

        // Determine the order number after which to insert, based on entry type
        var afterOrder = -1
        if let afterUUID = UUID(uuidString: afterEntryId) {
            switch entryType {
            case "bookmark":
                // afterEntryId is a BibleBookmark ID — look up its BTL order
                if let btl = service.bibleBookmarkToLabel(bookmarkId: afterUUID, labelId: lblId) {
                    afterOrder = btl.orderNumber
                }
            case "generic-bookmark":
                // afterEntryId is a GenericBookmark ID — look up its BTL order
                if let gbtl = service.genericBookmarkToLabel(bookmarkId: afterUUID, labelId: lblId) {
                    afterOrder = gbtl.orderNumber
                }
            case "journal":
                // afterEntryId is a StudyPadTextEntry ID
                if let afterEntry = service.studyPadEntry(id: afterUUID) {
                    afterOrder = afterEntry.orderNumber
                }
            default:
                // "none" or unknown — insert at beginning
                afterOrder = -1
            }
        }

        guard let result = service.createStudyPadEntry(labelId: lblId, afterOrderNumber: afterOrder) else { return }
        let (entry, changedBtls, changedGbtls, changedEntries) = result

        emitStudyPadOrderEvent(
            newEntry: entry,
            changedBibleBtls: changedBtls,
            changedGenericBtls: changedGbtls,
            changedEntries: changedEntries
        )
    }

    /**
     Deletes one StudyPad text entry and emits the resulting reordered state.
     */
    public func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String) {
        logger.info("Delete StudyPad entry: \(studyPadId)")
        guard let service = bookmarkService,
              let uuid = UUID(uuidString: studyPadId) else { return }

        guard let result = service.deleteStudyPadEntry(id: uuid) else { return }
        let (deletedId, _, changedBtls, changedGbtls, changedEntries) = result

        // Emit delete event
        bridge.emit(event: "delete_study_pad_text_entry", data: "\"\(deletedId.uuidString)\"")

        // Emit reorder event with new order numbers
        emitStudyPadOrderEvent(
            newEntry: nil,
            changedBibleBtls: changedBtls,
            changedGenericBtls: changedGbtls,
            changedEntries: changedEntries
        )
    }

    /**
     Updates StudyPad entry metadata such as indent level or order number from a Vue.js payload.
     */
    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String) {
        logger.info("Update StudyPad text entry metadata")
        guard let service = bookmarkService,
              let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let idStr = dict["id"] as? String,
              let uuid = UUID(uuidString: idStr) else { return }

        let orderNumber = dict["orderNumber"] as? Int
        let indentLevel = dict["indentLevel"] as? Int
        service.updateStudyPadTextEntry(id: uuid, orderNumber: orderNumber, indentLevel: indentLevel)

        // Emit update back to Vue.js
        if let entry = service.studyPadEntry(id: uuid) {
            let entryJSON = buildStudyPadEntryJSON(entry)
            bridge.emit(event: "add_or_update_study_pad", data: """
            {"studyPadTextEntry":\(entryJSON),"bookmarkToLabelsOrdered":[],"genericBookmarkToLabelsOrdered":[],"studyPadItemsOrdered":[]}
            """)
        }
    }

    /**
     Persists edited text for one StudyPad text entry.
     */
    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {
        logger.info("Update StudyPad entry text: \(id)")
        guard let service = bookmarkService,
              let uuid = UUID(uuidString: id) else { return }
        service.updateStudyPadTextEntryText(id: uuid, text: text)
    }

    /**
     Persists reordered StudyPad rows and bookmark associations for one label.
     */
    public func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String) {
        logger.info("Update order numbers for label \(labelId)")
        guard let service = bookmarkService,
              let lblId = UUID(uuidString: labelId),
              let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        // Parse the three order arrays: {bookmarkToLabels: [{first, second}], genericBookmarkToLabels: [...], studyPadTextEntries: [...]}
        let bibleOrders = parsePairArray(dict["bookmarkToLabels"])
        let genericOrders = parsePairArray(dict["genericBookmarkToLabels"])
        let entryOrdersRaw = parsePairArray(dict["studyPadTextEntries"])
        let entryOrders = entryOrdersRaw.map { (entryId: $0.bookmarkId, orderNumber: $0.orderNumber) }

        service.updateOrderNumbers(
            labelId: lblId,
            bibleBookmarkOrders: bibleOrders,
            genericBookmarkOrders: genericOrders,
            studyPadEntryOrders: entryOrders
        )

        // Emit updated order numbers back to Vue.js
        let btls = service.bibleBookmarkToLabels(labelId: lblId)
        let gbtls = service.genericBookmarkToLabels(labelId: lblId)
        let entries = service.studyPadEntries(labelId: lblId)

        let btlsJSON = btls.compactMap { buildBibleBookmarkToLabelJSON($0) }.joined(separator: ",")
        let gbtlsJSON = gbtls.compactMap { buildGenericBookmarkToLabelJSON($0) }.joined(separator: ",")
        let entriesJSON = entries.map { buildStudyPadEntryJSON($0) }.joined(separator: ",")

        bridge.emit(event: "add_or_update_study_pad", data: """
        {"studyPadTextEntry":null,"bookmarkToLabelsOrdered":[\(btlsJSON)],"genericBookmarkToLabelsOrdered":[\(gbtlsJSON)],"studyPadItemsOrdered":[\(entriesJSON)]}
        """)
    }

    /**
     Updates one `BibleBookmarkToLabel` association from a JSON payload emitted by Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String) {
        logger.info("Update BibleBookmarkToLabel")
        guard let service = bookmarkService,
              let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let bmIdStr = dict["bookmarkId"] as? String,
              let lblIdStr = dict["labelId"] as? String,
              let bmId = UUID(uuidString: bmIdStr),
              let lblId = UUID(uuidString: lblIdStr) else { return }

        service.updateBibleBookmarkToLabel(
            bookmarkId: bmId,
            labelId: lblId,
            orderNumber: dict["orderNumber"] as? Int,
            indentLevel: dict["indentLevel"] as? Int,
            expandContent: dict["expandContent"] as? Bool
        )

        // Emit update
        if let btl = service.bibleBookmarkToLabel(bookmarkId: bmId, labelId: lblId) {
            guard let btlJSON = buildBibleBookmarkToLabelJSON(btl) else { return }
            bridge.emit(event: "add_or_update_bookmark_to_label", data: btlJSON)
        }
    }

    /**
     Updates one `GenericBookmarkToLabel` association from a JSON payload emitted by Vue.js.
     */
    public func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String) {
        logger.info("Update GenericBookmarkToLabel")
        guard let service = bookmarkService,
              let jsonData = data.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let bmIdStr = dict["bookmarkId"] as? String,
              let lblIdStr = dict["labelId"] as? String,
              let bmId = UUID(uuidString: bmIdStr),
              let lblId = UUID(uuidString: lblIdStr) else { return }

        service.updateGenericBookmarkToLabel(
            bookmarkId: bmId,
            labelId: lblId,
            orderNumber: dict["orderNumber"] as? Int,
            indentLevel: dict["indentLevel"] as? Int,
            expandContent: dict["expandContent"] as? Bool
        )

        // Emit update
        if let gbtl = service.genericBookmarkToLabel(bookmarkId: bmId, labelId: lblId) {
            guard let gbtlJSON = buildGenericBookmarkToLabelJSON(gbtl) else { return }
            bridge.emit(event: "add_or_update_bookmark_to_label", data: gbtlJSON)
        }
    }

    /**
     Persists an optional bookmark edit action configured in the web client.
     */
    public func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String) {
        logger.info("Set edit action on bookmark \(bookmarkId): \(value)")
        guard let service = bookmarkService,
              let uuid = UUID(uuidString: bookmarkId) else { return }

        // Parse the edit action JSON
        let editAction: EditAction?
        if value == "null" || value.isEmpty {
            editAction = nil
        } else if let data = value.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let mode = (dict["mode"] as? String).flatMap { EditActionMode(rawValue: $0) }
            editAction = EditAction(mode: mode, content: dict["content"] as? String)
        } else {
            editAction = nil
        }

        service.setBookmarkEditAction(bookmarkId: uuid, editAction: editAction)

        // Emit updated bookmark
        if let bookmark = service.bibleBookmark(id: uuid) {
            let json = buildBookmarkJSON(bookmark)
            bridge.emit(event: "add_or_update_bookmarks", data: "[\(json)]")
        }
    }

    /**
     Tracks whether the embedded web client is currently editing content.
     */
    public func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {
        logger.info("WebView editing mode: \(enabled)")
        editingInWebView = enabled
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
            let startOrd = sel.startOrdinal ?? ((currentChapter - 1) * 40 + 1)
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

    /// Compare translations for the selected verse(s).
    func compareSelection() {
        Task { @MainActor in
            var startVerse: Int? = nil
            var endVerse: Int? = nil
            if let sel = await bridge.querySelection() {
                startVerse = sel.startOrdinal.flatMap { ordinalToVerse($0) }
                endVerse = sel.endOrdinal.flatMap { ordinalToVerse($0) }
            }
            onCompareVerses?(currentBook, currentChapter, activeModuleName, startVerse, endVerse)
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
     Look up the currently selected text in configured plain dictionaries.
     Matches Android parity for `disabled_word_lookup_dictionaries`:
     all plain dictionaries are enabled unless explicitly disabled.
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
        let configJSON = buildConfigJSON()
        onShowStrongsDefinition?(multiDocJSON, configJSON)
        bridge.clearSelection()
    }

    // MARK: - BibleBridgeDelegate — Content Actions

    /// Callback for presenting action sheets (set by BibleReaderView)
    var onShareVerseText: ((String) -> Void)?
    var onRequestOpenDownloads: (() -> Void)?

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
     Opens the native compare flow for the selected verse range.
     */
    public func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        logger.info("Compare verses requested: \(startOrdinal)-\(endOrdinal)")
        let startVerse = ordinalToVerse(startOrdinal)
        let endVerse = ordinalToVerse(endOrdinal)
        onCompareVerses?(currentBook, currentChapter, activeModuleName, startVerse, endVerse)
    }

    /**
     Starts TTS playback for the selected verse range.
     */
    public func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {
        speakVerseRange(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    // MARK: - BibleBridgeDelegate — Navigation Actions

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
        loadMyNotesDocument()
    }

    /**
     Load the My Notes document for the current chapter into the WebView.
     Shows all bookmarks for the chapter in a personal-commentary style view.
     */
    public func loadMyNotesDocument() {
        guard clientReady else { return }
        let osisBookId = osisBookId(for: currentBook)
        let verseCount = Self.verseCount(for: currentBook, chapter: currentChapter)
        let ordinalStart = (currentChapter - 1) * 40 + 1
        let ordinalEnd = (currentChapter - 1) * 40 + verseCount

        // Get bookmarks with notes for this chapter
        guard let service = bookmarkService else { return }
        let bookmarks = service.bookmarks(for: ordinalStart, endOrdinal: ordinalEnd, book: currentBook)
            .filter { $0.notes != nil && !($0.notes!.notes.isEmpty) }

        // Build the MyNotesDocument JSON (type: "notes")
        let bookmarksJSON = bookmarks.isEmpty ? "[]" :
            "[" + bookmarks.map { buildBookmarkJSONForMyNotes($0) }.joined(separator: ",") + "]"

        let verseRange = "\(currentBook) \(currentChapter):1-\(verseCount)"
        let docId = "\(osisBookId).\(currentChapter).1-\(osisBookId).\(currentChapter).\(verseCount)"

        let document = """
        {"id":"\(docId)","type":"notes","bookmarks":\(bookmarksJSON),"verseRange":"\(verseRange)","ordinalRange":[\(ordinalStart),\(ordinalEnd)]}
        """

        // Send to Vue.js using the same sequence as loadCurrentChapter
        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)

        setRenderedContentState(
            category: .bible,
            moduleName: "My Notes",
            book: "My Notes",
            chapter: currentChapter,
            key: docId
        )

        showingMyNotes = true
    }

    /// Return from My Notes to the Bible text view.
    public func returnFromMyNotes() {
        guard showingMyNotes else { return }
        loadCurrentChapter()
    }

    /// Load a StudyPad document for a label into the WebView.
    public func loadStudyPadDocument(labelId: UUID, bookmarkId: UUID? = nil) {
        guard clientReady, let service = bookmarkService else { return }
        guard let label = service.label(id: labelId) else {
            logger.warning("loadStudyPadDocument: label not found for \(labelId)")
            return
        }

        // Fetch all data for this StudyPad
        let bibleBookmarks = service.bibleBookmarks(withLabel: labelId)
        let genericBookmarks = service.genericBookmarks(withLabel: labelId)
        let bibleBtls = service.bibleBookmarkToLabels(labelId: labelId)
        let genericBtls = service.genericBookmarkToLabels(labelId: labelId)
        let entries = service.studyPadEntries(labelId: labelId)

        // Build JSON arrays
        let bookmarksJSON = bibleBookmarks.isEmpty ? "[]" :
            "[" + bibleBookmarks.map { buildBookmarkJSONForStudyPad($0) }.joined(separator: ",") + "]"
        let genericBookmarksJSON = genericBookmarks.isEmpty ? "[]" :
            "[" + genericBookmarks.map { buildGenericBookmarkJSONForStudyPad($0) }.joined(separator: ",") + "]"
        let btlsJSON = bibleBtls.isEmpty ? "[]" :
            "[" + bibleBtls.compactMap { buildBibleBookmarkToLabelJSON($0) }.joined(separator: ",") + "]"
        let gbtlsJSON = genericBtls.isEmpty ? "[]" :
            "[" + genericBtls.compactMap { buildGenericBookmarkToLabelJSON($0) }.joined(separator: ",") + "]"
        let entriesJSON = entries.isEmpty ? "[]" :
            "[" + entries.map { buildStudyPadEntryJSON($0) }.joined(separator: ",") + "]"
        let labelJSON = buildLabelJSON(label)

        let document = """
        {"id":"journal_\(labelId.uuidString)","type":"journal","label":\(labelJSON),"bookmarks":\(bookmarksJSON),"genericBookmarks":\(genericBookmarksJSON),"bookmarkToLabels":\(btlsJSON),"genericBookmarkToLabels":\(gbtlsJSON),"journalTextEntries":\(entriesJSON)}
        """

        // Send to Vue.js
        bridge.emit(event: "clear_document")
        sendLabelsToVueJS()
        bridge.emit(event: "add_documents", data: document)

        // Setup content with optional jump target
        let jumpToId = bookmarkId.map { "\"\($0.uuidString)\"" } ?? "null"
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":\(jumpToId),"topOffset":0,"bottomOffset":0}
        """)

        setRenderedContentState(
            category: .bible,
            moduleName: "StudyPad",
            book: label.name,
            key: "journal_\(labelId.uuidString)"
        )

        showingStudyPad = true
        activeStudyPadLabelId = labelId
        activeStudyPadLabelName = label.name
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
     - may open Strong's sheets, cross-reference sheets, search, EPUB navigation, or delegate real
       URLs to the host platform

     Failure modes:
     - unrecognized schemes fall through to the platform URL-opening path
     */
    public func bridge(_ bridge: BibleBridge, openExternalLink link: String) {
        // Handle Strong's/morphology links: ab-w://?strong=H1234&robinson=...
        if link.hasPrefix("ab-w://") {
            handleStrongsLink(link)
            return
        }
        // Handle "Find all occurrences" links from FeaturesLink.vue
        if link.hasPrefix("ab-find-all://") {
            handleFindAllLink(link)
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
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Parse Strong's/morphology from ab-w:// links and show definitions in a sheet via MultiDocument.
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

        let multiDocJSON = buildStrongsMultiDocJSON(strongs: strongs, robinson: robinson)
        guard let multiDocJSON else { return }

        // Send to sheet via callback (not to the main WebView)
        let configJSON = buildConfigJSON()
        onShowStrongsDefinition?(multiDocJSON, configJSON)
    }

    /**
     Build a MultiFragmentDocument JSON from Strong's numbers and Robinson codes.
     Returns nil if no definitions were found.
     */
    func buildStrongsMultiDocJSON(strongs: [String], robinson: [String], stateJSON: String? = nil) -> String? {
        logger.info("buildStrongsMultiDocJSON: strongs=\(strongs), robinson=\(robinson), swordManager=\(self.swordManager == nil ? "nil" : "alive")")
        var fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: String)] = []

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
                    let featuresJSON = "{\"type\":\"\(featureType)\",\"keyName\":\"\(keyName)\"}"

                    fragments.append((
                        xml: xml,
                        key: "\(mod.info.name)--\(keyName)",
                        keyName: keyName,
                        bookInitials: mod.info.name,
                        bookAbbreviation: moduleDisplayLabel(mod),
                        features: featuresJSON
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
                            features: "{}"
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
    ) -> (xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: String) {
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
            features: "{\"type\":\"\(featureType)\",\"keyName\":\"\(keyName)\"}"
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

    /// Build a MultiFragmentDocument JSON string for rendering in Vue.js document views.
    private func buildMultiFragmentJSON(
        fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: String)],
        contentType: String? = nil,
        stateJSON: String? = nil
    ) -> String {
        let id = "strongs-multi-\(UUID().uuidString)"
        var osisFragmentsJSON: [String] = []

        for frag in fragments {
            let escapedXml = frag.xml
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "")
            let escapedKey = frag.key.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedKeyName = frag.keyName.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedInitials = frag.bookInitials.replacingOccurrences(of: "\"", with: "\\\"")
            let escapedAbbrev = frag.bookAbbreviation.replacingOccurrences(of: "\"", with: "\\\"")

            osisFragmentsJSON.append("""
            {"xml":"\(escapedXml)","key":"\(escapedKey)","keyName":"\(escapedKeyName)","v11n":"KJVA","bookCategory":"DICTIONARY","bookInitials":"\(escapedInitials)","bookAbbreviation":"\(escapedAbbrev)","osisRef":"\(escapedKeyName)","isNewTestament":false,"features":\(frag.features),"ordinalRange":[0,0],"language":"en","direction":"ltr"}
            """)
        }

        let escapedContentType = contentType?.replacingOccurrences(of: "\"", with: "\\\"")
        let contentTypeField = escapedContentType.map { ",\"contentType\":\"\($0)\"" } ?? ""
        let stateField = stateJSON.map { ",\"state\":\($0)" } ?? ""
        return "{\"id\":\"\(id)\",\"type\":\"multi\",\"osisFragments\":[\(osisFragmentsJSON.joined(separator: ","))],\"compare\":false\(contentTypeField)\(stateField)}"
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
        var fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: String)] = []

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
                features: "{}"
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
            let crossRefs = lookupCrossReferences(refs)
            onShowCrossReferences?(crossRefs)
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
            let crossRefs = lookupCrossReferences(allRefs)
            onShowCrossReferences?(crossRefs)
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

    /// Parse an OSIS reference string like "Matt.1.1" or "Gen.1.1-Gen.1.3" into structured refs.
    private func parseOsisReferences(_ osisString: String) -> [OsisRef] {
        // Split on "-" for ranges, but also handle comma-separated
        let parts = osisString.components(separatedBy: CharacterSet(charactersIn: ",-"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var refs: [OsisRef] = []
        for part in parts {
            if let ref = parseOsisRef(part) {
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
        onRequestOpenDownloads?()
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

    /// Try to validate/resolve an OSIS-format reference like "Gen.1.1"
    private func resolveOsisRef(_ text: String) -> String? {
        let parts = text.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        // Check if first part is a valid OSIS book ID
        guard bookName(forOsisId: parts[0]) != nil else { return nil }
        guard Int(parts[1]) != nil else { return nil }
        return text
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
            return "\(osisId).\(chapter).\(verse)"
        }
        return "\(osisId).\(chapter)"
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
        if hiddenCompareDocuments.contains(documentId) {
            hiddenCompareDocuments.remove(documentId)
        } else {
            hiddenCompareDocuments.insert(documentId)
        }
        // Notify Vue.js of updated settings
        bridge.emit(event: "set_config", data: buildConfigJSON())
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
     Ordinals use the formula: (chapter - 1) * 40 + verse.
     */
    private func ordinalToVerse(_ ordinal: Int) -> Int? {
        let verse = ordinal - (currentChapter - 1) * 40
        return verse >= 1 ? verse : nil
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

            let ordinal = (chapter - 1) * 40 + parsedVerse
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
        hasActiveSelection = false
        selectedText = ""
        let osisBookId = osisBookId(for: currentBook)
        let isNT = isNewTestament(currentBook)

        // Try loading from SWORD module first
        let loadedChapter = loadChapterFromSword(
            osisBookId: osisBookId,
            chapter: currentChapter
        )
        let fallbackChapter = loadPlaceholderChapter(osisBookId: osisBookId, bookName: currentBook)
        let xml = loadedChapter?.xml ?? fallbackChapter.0
        let verseCount = loadedChapter?.verseCount ?? fallbackChapter.1

        // Query bookmarks for this chapter
        let chapterBookmarks = bookmarksForCurrentChapter(verseCount: verseCount)

        // Clear and load new document
        bridge.emit(event: "clear_document")

        // Send bookmark labels before the document (Vue.js needs labels to render bookmark highlights)
        sendLabelsToVueJS()

        let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: currentChapter,
            verseCount: verseCount,
            isNT: isNT,
            xml: xml,
            bookmarks: chapterBookmarks,
            addChapter: loadedChapter?.addChapter ?? true,
            originalOrdinalRange: originalNavigationOrdinalRange
        )
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
        } else if currentVerse > 1 {
            restoreTarget = .ordinal(ordinal(forChapter: currentChapter, verse: currentVerse))
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

        guard let loadedChapter = loadChapterFromSword(
            osisBookId: osisBookId,
            chapter: chapter
        ) else {
            return nil
        }

        // Query bookmarks for this chapter's ordinal range
        let ordinalStart = (chapter - 1) * 40 + 1
        let ordinalEnd = (chapter - 1) * 40 + loadedChapter.verseCount
        let chapterBookmarks = bookmarkService?.bookmarks(for: ordinalStart, endOrdinal: ordinalEnd, book: book) ?? []

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

        // Restore module position to current chapter so other operations aren't affected
        let restoreKey = "\(self.osisBookId(for: currentBook)) \(currentChapter):1"
        module.setKey(restoreKey)

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

    private func ordinal(forChapter chapter: Int, verse: Int) -> Int {
        BibleChapterDocumentBuilder.ordinal(chapter: chapter, verse: verse)
    }

    private func buildSwordChapterXML(osisBookId: String, bookName: String, chapter: Int, verses: [(Int, String)]) -> String {
        var xml = "<div>"
        xml += "<title type=\"x-gen\">\(bookName) \(chapter)</title>"
        xml += "<div sID=\"p1\" type=\"paragraph\"/>"

        for (verseNum, text) in verses {
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            xml += "<verse osisID=\"\(osisBookId).\(chapter).\(verseNum)\" verseOrdinal=\"\(ordinal(forChapter: chapter, verse: verseNum))\">"
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
        let ordinalStart = (currentChapter - 1) * 40 + 1
        let ordinalEnd = (currentChapter - 1) * 40 + verseCount
        return service.bookmarks(for: ordinalStart, endOrdinal: ordinalEnd, book: currentBook)
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

    /// Send bookmark label data to Vue.js. Must be called before documents that contain bookmarks.
    private func sendLabelsToVueJS() {
        // Always include the default "Unlabeled" label
        let unlabeledJSON = """
        {"id":"\(Self.unlabeledLabelId)","name":"__UNLABELED__","isRealLabel":false,"style":{"color":\(BibleCore.Label.defaultColor),"isSpeak":false,"isParagraphBreak":false,"underline":false,"underlineWholeVerse":false,"markerStyle":false,"markerStyleWholeVerse":false,"hideStyle":false,"hideStyleWholeVerse":false,"customIcon":null}}
        """

        // Build user labels JSON
        var allLabelsJSON = [unlabeledJSON]
        if let service = bookmarkService {
            for label in service.allLabels() {
                guard let labelID = BookmarkLabelSerializationSupport.liveLabelIDString(for: label) else {
                    continue
                }
                let labelJSON = """
                {"id":"\(labelID)","name":"\(label.name.replacingOccurrences(of: "\"", with: "\\\""))","isRealLabel":\(label.isRealLabel),"style":{"color":\(label.color),"isSpeak":false,"isParagraphBreak":false,"underline":\(label.underlineStyle),"underlineWholeVerse":\(label.underlineStyleWholeVerse),"markerStyle":\(label.markerStyle),"markerStyleWholeVerse":\(label.markerStyleWholeVerse),"hideStyle":\(label.hideStyle),"hideStyleWholeVerse":\(label.hideStyleWholeVerse),"customIcon":\(label.customIcon.map { "\"\($0)\"" } ?? "null")}}
                """
                allLabelsJSON.append(labelJSON)
            }
        }

        bridge.emit(event: "update_labels", data: "[\(allLabelsJSON.joined(separator: ","))]")
    }

    /// Serialize a BibleBookmark to the JSON format Vue.js expects.
    private func buildBookmarkJSON(_ bookmark: BibleBookmark) -> String {
        let id = bookmark.id.uuidString
        let hashCode = abs(id.hashValue)
        let createdAt = Int(bookmark.createdAt.timeIntervalSince1970 * 1000)
        let lastUpdated = Int(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000)
        let noteText = bookmark.notes?.notes ?? ""
        let escapedNote = noteText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hasNote = !noteText.isEmpty
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"
        let labelPayload = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: Self.unlabeledLabelId
        )
        let primaryLabelId = BookmarkLabelSerializationSupport.primaryLabelIDJSON(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labelPayload.labelIDs
        )
        let labelsJSON = labelPayload.labelsJSON
        let btlJSON = labelPayload.relationsJSON

        // Compute verse references from ordinals
        let osisBookId = osisBookId(for: currentBook)
        let chapterBase = (currentChapter - 1) * 40
        let startVerse = max(1, bookmark.ordinalStart - chapterBase)
        let endVerse = max(startVerse, bookmark.ordinalEnd - chapterBase)

        let osisRef: String
        let verseRange: String
        let verseRangeOnlyNumber: String
        let verseRangeAbbreviated: String
        if startVerse == endVerse {
            osisRef = "\(osisBookId).\(currentChapter).\(startVerse)"
            verseRange = "\(currentBook) \(currentChapter):\(startVerse)"
            verseRangeOnlyNumber = "\(startVerse)"
            verseRangeAbbreviated = "\(osisBookId) \(currentChapter):\(startVerse)"
        } else {
            osisRef = "\(osisBookId).\(currentChapter).\(startVerse)-\(osisBookId).\(currentChapter).\(endVerse)"
            verseRange = "\(currentBook) \(currentChapter):\(startVerse)-\(endVerse)"
            verseRangeOnlyNumber = "\(startVerse)-\(endVerse)"
            verseRangeAbbreviated = "\(osisBookId) \(currentChapter):\(startVerse)-\(endVerse)"
        }

        // Load verse text from SWORD if available
        let fullText = loadVerseText(osisBookId: osisBookId, chapter: currentChapter, startVerse: startVerse, endVerse: endVerse)
        let escapedFullText = fullText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let offsetRangeJSON = jsonOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset)

        return """
        {"id":"\(id)","type":"bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"originalOrdinalRange":[\(bookmark.kjvOrdinalStart),\(bookmark.kjvOrdinalEnd)],"offsetRange":\(offsetRangeJSON),"bookInitials":"\(activeModuleName)","bookName":"\(activeModuleName)","bookAbbreviation":"\(osisBookId)","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"verseRange":"\(verseRange)","verseRangeOnlyNumber":"\(verseRangeOnlyNumber)","verseRangeAbbreviated":"\(verseRangeAbbreviated)","text":"\(escapedFullText)","fullText":"\(escapedFullText)","osisRef":"\(osisRef)","v11n":"\(bookmark.v11n)","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"osisFragment":null,"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":{"mode":null,"content":null}}
        """
    }

    /// Serialize a BibleBookmark for the MyNotes document, with populated verse references.
    private func buildBookmarkJSONForMyNotes(_ bookmark: BibleBookmark) -> String {
        let id = bookmark.id.uuidString
        let hashCode = abs(id.hashValue)
        let createdAt = Int(bookmark.createdAt.timeIntervalSince1970 * 1000)
        let lastUpdated = Int(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000)
        let noteText = bookmark.notes?.notes ?? ""
        let escapedNote = noteText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hasNote = !noteText.isEmpty
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"
        let labelPayload = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: Self.unlabeledLabelId
        )
        let primaryLabelId = BookmarkLabelSerializationSupport.primaryLabelIDJSON(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labelPayload.labelIDs
        )
        let labelsJSON = labelPayload.labelsJSON
        let btlJSON = labelPayload.relationsJSON

        // Compute verse references from ordinals
        let osisBookId = osisBookId(for: currentBook)
        let chapterBase = (currentChapter - 1) * 40
        let startVerse = max(1, bookmark.ordinalStart - chapterBase)
        let endVerse = max(startVerse, bookmark.ordinalEnd - chapterBase)

        let osisRef: String
        let verseRange: String
        let verseRangeOnlyNumber: String
        let verseRangeAbbreviated: String
        if startVerse == endVerse {
            osisRef = "\(osisBookId).\(currentChapter).\(startVerse)"
            verseRange = "\(currentBook) \(currentChapter):\(startVerse)"
            verseRangeOnlyNumber = "\(startVerse)"
            verseRangeAbbreviated = "\(osisBookId) \(currentChapter):\(startVerse)"
        } else {
            osisRef = "\(osisBookId).\(currentChapter).\(startVerse)-\(osisBookId).\(currentChapter).\(endVerse)"
            verseRange = "\(currentBook) \(currentChapter):\(startVerse)-\(endVerse)"
            verseRangeOnlyNumber = "\(startVerse)-\(endVerse)"
            verseRangeAbbreviated = "\(osisBookId) \(currentChapter):\(startVerse)-\(endVerse)"
        }

        // Load verse text from SWORD if available
        let fullText = loadVerseText(osisBookId: osisBookId, chapter: currentChapter, startVerse: startVerse, endVerse: endVerse)
        let escapedFullText = fullText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let offsetRangeJSON = jsonOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset)

        return """
        {"id":"\(id)","type":"bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"originalOrdinalRange":[\(bookmark.kjvOrdinalStart),\(bookmark.kjvOrdinalEnd)],"offsetRange":\(offsetRangeJSON),"bookInitials":"\(activeModuleName)","bookName":"\(activeModuleName)","bookAbbreviation":"\(osisBookId)","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"verseRange":"\(verseRange)","verseRangeOnlyNumber":"\(verseRangeOnlyNumber)","verseRangeAbbreviated":"\(verseRangeAbbreviated)","text":"\(escapedFullText)","fullText":"\(escapedFullText)","osisRef":"\(osisRef)","v11n":"\(bookmark.v11n)","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"osisFragment":null,"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":{"mode":null,"content":null}}
        """
    }

    /// Load plain text for a verse range from the active SWORD module.
    private func loadVerseText(osisBookId: String, chapter: Int, startVerse: Int, endVerse: Int) -> String {
        guard let module = activeModule else { return "" }
        var parts: [String] = []
        for verse in startVerse...endVerse {
            let key = "\(osisBookId) \(chapter):\(verse)"
            module.setKey(key)
            let raw = module.rawEntry()
            // Strip XML tags to get plain text
            let plain = raw
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                parts.append(plain)
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - StudyPad JSON Builders

    /// Serialize a StudyPadTextEntry to JSON for Vue.js.
    private func buildStudyPadEntryJSON(_ entry: StudyPadTextEntry) -> String {
        let id = entry.id.uuidString
        let hashCode = abs(id.hashValue)
        let labelId = BookmarkLabelSerializationSupport.liveLabelIDString(for: entry.label) ?? ""
        let text = entry.textEntry?.text ?? ""
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        {"id":"\(id)","type":"journal","hashCode":\(hashCode),"labelId":"\(labelId)","text":"\(escapedText)","orderNumber":\(entry.orderNumber),"indentLevel":\(entry.indentLevel)}
        """
    }

    /// Serialize a BibleBookmarkToLabel to JSON for Vue.js.
    private func buildBibleBookmarkToLabelJSON(_ btl: BibleBookmarkToLabel) -> String? {
        let bmId = btl.bookmark?.id.uuidString ?? ""
        guard let lblId = BookmarkLabelSerializationSupport.liveLabelIDString(for: btl.label) else {
            return nil
        }
        return """
        {"type":"BibleBookmarkToLabel","bookmarkId":"\(bmId)","labelId":"\(lblId)","orderNumber":\(btl.orderNumber),"indentLevel":\(btl.indentLevel),"expandContent":\(btl.expandContent)}
        """
    }

    /// Serialize a GenericBookmarkToLabel to JSON for Vue.js.
    private func buildGenericBookmarkToLabelJSON(_ gbtl: GenericBookmarkToLabel) -> String? {
        let bmId = gbtl.bookmark?.id.uuidString ?? ""
        guard let lblId = BookmarkLabelSerializationSupport.liveLabelIDString(for: gbtl.label) else {
            return nil
        }
        return """
        {"type":"GenericBookmarkToLabel","bookmarkId":"\(bmId)","labelId":"\(lblId)","orderNumber":\(gbtl.orderNumber),"indentLevel":\(gbtl.indentLevel),"expandContent":\(gbtl.expandContent)}
        """
    }

    /// Serialize a Label to JSON for Vue.js StudyPad document.
    private func buildLabelJSON(_ label: Label) -> String {
        guard let labelID = BookmarkLabelSerializationSupport.liveLabelIDString(for: label) else {
            return "null"
        }
        let customIcon = label.customIcon.map { "\"\($0)\"" } ?? "null"
        let escapedName = label.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"id":"\(labelID)","name":"\(escapedName)","isRealLabel":\(label.isRealLabel),"style":{"color":\(label.color),"isSpeak":false,"isParagraphBreak":false,"underline":\(label.underlineStyle),"underlineWholeVerse":\(label.underlineStyleWholeVerse),"markerStyle":\(label.markerStyle),"markerStyleWholeVerse":\(label.markerStyleWholeVerse),"hideStyle":\(label.hideStyle),"hideStyleWholeVerse":\(label.hideStyleWholeVerse),"customIcon":\(customIcon)}}
        """
    }

    /// Serialize a BibleBookmark for StudyPad document (includes "type" in BTLs).
    private func buildBookmarkJSONForStudyPad(_ bookmark: BibleBookmark) -> String {
        let id = bookmark.id.uuidString
        let hashCode = abs(id.hashValue)
        let createdAt = Int(bookmark.createdAt.timeIntervalSince1970 * 1000)
        let lastUpdated = Int(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000)
        let noteText = bookmark.notes?.notes ?? ""
        let escapedNote = noteText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hasNote = !noteText.isEmpty
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"
        let labelPayload = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: Self.unlabeledLabelId
        )
        let primaryLabelId = BookmarkLabelSerializationSupport.primaryLabelIDJSON(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labelPayload.labelIDs
        )
        let labelsJSON = labelPayload.labelsJSON
        let btlJSON = labelPayload.relationsJSON

        // Compute verse references
        let bookOsisId: String
        let bookName: String
        if let book = bookmark.book {
            bookOsisId = osisBookId(for: book)
            bookName = book
        } else {
            bookOsisId = osisBookId(for: currentBook)
            bookName = currentBook
        }
        let chapterBase = bookmark.ordinalStart / 40
        let chapter = chapterBase + 1
        let startVerse = max(1, bookmark.ordinalStart - chapterBase * 40)
        let endVerse = max(startVerse, bookmark.ordinalEnd - chapterBase * 40)

        let osisRef = startVerse == endVerse
            ? "\(bookOsisId).\(chapter).\(startVerse)"
            : "\(bookOsisId).\(chapter).\(startVerse)-\(bookOsisId).\(chapter).\(endVerse)"
        let verseRange = startVerse == endVerse
            ? "\(bookName) \(chapter):\(startVerse)"
            : "\(bookName) \(chapter):\(startVerse)-\(endVerse)"
        let verseRangeOnlyNumber = startVerse == endVerse ? "\(startVerse)" : "\(startVerse)-\(endVerse)"
        let verseRangeAbbreviated = startVerse == endVerse
            ? "\(bookOsisId) \(chapter):\(startVerse)"
            : "\(bookOsisId) \(chapter):\(startVerse)-\(endVerse)"

        let fullText = loadVerseText(osisBookId: bookOsisId, chapter: chapter, startVerse: startVerse, endVerse: endVerse)
        let escapedFullText = fullText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        // Edit action
        let editActionJSON: String
        if let ea = bookmark.editAction {
            let mode = ea.mode.map { "\"\($0.rawValue)\"" } ?? "null"
            let content = ea.content.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null"
            editActionJSON = "{\"mode\":\(mode),\"content\":\(content)}"
        } else {
            editActionJSON = "{\"mode\":null,\"content\":null}"
        }

        let offsetRangeJSON = jsonOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset)

        return """
        {"id":"\(id)","type":"bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"originalOrdinalRange":[\(bookmark.kjvOrdinalStart),\(bookmark.kjvOrdinalEnd)],"offsetRange":\(offsetRangeJSON),"bookInitials":"\(activeModuleName)","bookName":"\(activeModuleName)","bookAbbreviation":"\(bookOsisId)","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"verseRange":"\(verseRange)","verseRangeOnlyNumber":"\(verseRangeOnlyNumber)","verseRangeAbbreviated":"\(verseRangeAbbreviated)","text":"\(escapedFullText)","fullText":"\(escapedFullText)","osisRef":"\(osisRef)","v11n":"\(bookmark.v11n)","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"osisFragment":null,"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":\(editActionJSON)}
        """
    }

    /// Serialize a GenericBookmark for StudyPad document.
    private func buildGenericBookmarkJSONForStudyPad(_ bookmark: GenericBookmark) -> String {
        let id = bookmark.id.uuidString
        let hashCode = abs(id.hashValue)
        let createdAt = Int(bookmark.createdAt.timeIntervalSince1970 * 1000)
        let lastUpdated = Int(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000)
        let noteText = bookmark.notes?.notes ?? ""
        let escapedNote = noteText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hasNote = !noteText.isEmpty
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"
        let labelPayload = BookmarkLabelSerializationSupport.genericPayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: Self.unlabeledLabelId
        )
        let primaryLabelId = BookmarkLabelSerializationSupport.primaryLabelIDJSON(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labelPayload.labelIDs
        )
        let labelsJSON = labelPayload.labelsJSON
        let btlJSON = labelPayload.relationsJSON

        let escapedKey = bookmark.key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Edit action
        let editActionJSON: String
        if let ea = bookmark.editAction {
            let mode = ea.mode.map { "\"\($0.rawValue)\"" } ?? "null"
            let content = ea.content.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "null"
            editActionJSON = "{\"mode\":\(mode),\"content\":\(content)}"
        } else {
            editActionJSON = "{\"mode\":null,\"content\":null}"
        }

        let offsetRangeJSON = jsonOffsetRange(startOffset: bookmark.startOffset, endOffset: bookmark.endOffset)

        return """
        {"id":"\(id)","type":"generic-bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"offsetRange":\(offsetRangeJSON),"bookInitials":"\(bookmark.bookInitials)","bookName":"\(bookmark.bookInitials)","bookAbbreviation":"","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"text":"","fullText":"","key":"\(escapedKey)","keyName":"\(escapedKey)","highlightedText":"","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":\(editActionJSON)}
        """
    }

    /**
     Serializes optional bookmark text offsets into the JSON array form expected by Vue.js.

     - Parameters:
       - startOffset: Optional inclusive start offset inside the verse text.
       - endOffset: Optional inclusive end offset inside the verse text.

     - Returns: `null` when no start offset exists, otherwise a two-element JSON array string.
     */
    private func jsonOffsetRange(startOffset: Int?, endOffset: Int?) -> String {
        guard let startOffset else { return "null" }
        let endValue = endOffset.map(String.init) ?? "null"
        return "[\(startOffset),\(endValue)]"
    }

    // MARK: - StudyPad Event Helpers

    /// Emit a StudyPad order event to Vue.js after create/delete/reorder.
    private func emitStudyPadOrderEvent(
        newEntry: StudyPadTextEntry?,
        changedBibleBtls: [BibleBookmarkToLabel],
        changedGenericBtls: [GenericBookmarkToLabel],
        changedEntries: [StudyPadTextEntry]
    ) {
        let entryJSON = newEntry.map { buildStudyPadEntryJSON($0) } ?? "null"
        let btlsJSON = changedBibleBtls.compactMap { buildBibleBookmarkToLabelJSON($0) }.joined(separator: ",")
        let gbtlsJSON = changedGenericBtls.compactMap { buildGenericBookmarkToLabelJSON($0) }.joined(separator: ",")
        let entriesJSON = changedEntries.map { buildStudyPadEntryJSON($0) }.joined(separator: ",")

        bridge.emit(event: "add_or_update_study_pad", data: """
        {"studyPadTextEntry":\(entryJSON),"bookmarkToLabelsOrdered":[\(btlsJSON)],"genericBookmarkToLabelsOrdered":[\(gbtlsJSON)],"studyPadItemsOrdered":[\(entriesJSON)]}
        """)
    }

    /// Emit an updated bookmark (Bible or generic) back to Vue.js after label changes.
    private func emitBookmarkUpdate(bookmarkId: UUID, type: String? = nil) {
        guard let service = bookmarkService else { return }

        // Try Bible bookmark first (or if type hint says "bible")
        if type != "generic", let bookmark = service.bibleBookmark(id: bookmarkId) {
            let json = buildBookmarkJSON(bookmark)
            bridge.emit(event: "add_or_update_bookmarks", data: "[\(json)]")
            return
        }

        // Try generic bookmark
        if let bookmark = service.genericBookmark(id: bookmarkId) {
            let json = buildGenericBookmarkJSONForStudyPad(bookmark)
            bridge.emit(event: "add_or_update_bookmarks", data: "[\(json)]")
        }
    }

    /// Parse [{first: "uuid", second: orderNumber}, ...] from Vue.js updateOrderNumber data.
    private func parsePairArray(_ value: Any?) -> [(bookmarkId: UUID, orderNumber: Int)] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let first = dict["first"] as? String,
                  let second = dict["second"] as? Int,
                  let uuid = UUID(uuidString: first) else { return nil }
            return (uuid, second)
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

    /// Reads a string-set parity preference and returns an empty array when unset.
    private func appPreferenceStringSet(_ key: AppPreferenceKey) -> [String] {
        settingsStore?.getStringSet(key) ?? []
    }

    /**
     Escapes a string array into a JSON array literal without allocating an intermediate encoder.

     - Parameter values: Raw string values to escape and join.
     - Returns: JSON array literal string containing the escaped values.
     */
    private static func jsonStringArray(_ values: [String]) -> String {
        let escaped = values.map {
            $0
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "[" + escaped.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /**
     Builds the combined reader/configuration payload consumed by the Vue.js application.

     - Returns: JSON string containing `config` and `appSettings` sections for the current pane.

     Side effects:
     - reads persisted settings, workspace cursor state, recent/favourite labels, and active-window
       state to compute the emitted payload
     */
    private func buildConfigJSON() -> String {
        let s = displaySettings
        let d = TextDisplaySettings.appDefaults
        // Compute active window state (matching Android: isActive = activeWindow.id == window.id)
        let isActiveWindow = computeIsActiveWindow()
        let activeIndicatorEnabled = appPreferenceBool(.showActiveWindowIndicator)
        let hasActiveIndicator = activeIndicatorEnabled && isActiveWindow && (windowManagerRef?.visibleWindows.count ?? 0) > 1

        // Parity-managed appSettings values from persisted preferences.
        let showErrorBox = appPreferenceBool(.showErrorBox)
        let monochromeMode = appPreferenceBool(.monochromeMode)
        let disableAnimations = appPreferenceBool(.disableAnimations)
        let disableClickToEdit = appPreferenceBool(.disableClickToEdit)
        let fontSizeMultiplierPercent = max(10, appPreferenceInt(.fontSizeMultiplier))
        let fontSizeMultiplier = Double(fontSizeMultiplierPercent) / 100.0
        let disableBibleModalButtonsJSON = Self.jsonStringArray(appPreferenceStringSet(.disableBibleBookmarkModalButtons))
        let disableGenericModalButtonsJSON = Self.jsonStringArray(appPreferenceStringSet(.disableGenBookmarkModalButtons))
        let enabledExperimentalFeaturesJSON = Self.jsonStringArray(appPreferenceStringSet(.experimentalFeatures))

        // Build recent labels JSON array
        let recentJSON = "[" + recentLabelIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // Build favourite labels JSON array
        let favouriteIds: [String]
        if let service = bookmarkService {
            favouriteIds = service.allLabels().filter { $0.favourite }.map { $0.id.uuidString }
        } else {
            favouriteIds = []
        }
        let favouriteJSON = "[" + favouriteIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // Build studyPadCursors JSON: {"labelId": orderNumber, ...}
        let cursorsDict = activeWindow?.workspace?.workspaceSettings?.studyPadCursors ?? [:]
        let cursorsJSON = "{" + cursorsDict.map { "\"\($0.key.uuidString)\":\($0.value)" }.joined(separator: ",") + "}"

        // Build autoAssignLabels JSON: ["labelId", ...]
        let autoAssignSet = activeWindow?.workspace?.workspaceSettings?.autoAssignLabels ?? []
        let autoAssignJSON = "[" + autoAssignSet.map { "\"\($0.uuidString)\"" }.joined(separator: ",") + "]"

        // Build hideCompareDocuments JSON: ["docId", ...]
        let hideCompareJSON = "[" + hiddenCompareDocuments.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        return """
        {"config":{"developmentMode":false,"testMode":false,"showAnnotations":true,"showChapterNumbers":true,"showVerseNumbers":\(s.showVerseNumbers ?? d.showVerseNumbers ?? true),"strongsMode":\(s.strongsMode ?? d.strongsMode ?? 0),"showMorphology":\(s.showMorphology ?? d.showMorphology ?? false),"showRedLetters":\(s.showRedLetters ?? d.showRedLetters ?? true),"showVersePerLine":\(s.showVersePerLine ?? d.showVersePerLine ?? false),"showNonCanonical":true,"makeNonCanonicalItalic":true,"showSectionTitles":\(s.showSectionTitles ?? d.showSectionTitles ?? true),"showStrongsSeparately":false,"showFootNotes":\(s.showFootNotes ?? d.showFootNotes ?? false),"showFootNotesInline":\(s.showFootNotesInline ?? d.showFootNotesInline ?? false),"showXrefs":\(s.showXrefs ?? d.showXrefs ?? false),"expandXrefs":\(s.expandXrefs ?? d.expandXrefs ?? false),"fontFamily":"\(s.fontFamily ?? d.fontFamily ?? "sans-serif")","fontSize":\(s.fontSize ?? d.fontSize ?? 18),"disableBookmarking":false,"showBookmarks":\(s.showBookmarks ?? d.showBookmarks ?? true),"showMyNotes":\(s.showMyNotes ?? d.showMyNotes ?? true),"bookmarksHideLabels":[],"bookmarksAssignLabels":[],"colors":{"dayBackground":\(s.dayBackground ?? d.dayBackground ?? -1),"dayNoise":\(s.dayNoise ?? d.dayNoise ?? 0),"nightBackground":\(s.nightBackground ?? d.nightBackground ?? -16777216),"nightNoise":\(s.nightNoise ?? d.nightNoise ?? 0),"dayTextColor":\(s.dayTextColor ?? d.dayTextColor ?? -16777216),"nightTextColor":\(s.nightTextColor ?? d.nightTextColor ?? -1)},"hyphenation":\(s.hyphenation ?? d.hyphenation ?? true),"lineSpacing":\(s.lineSpacing ?? d.lineSpacing ?? 10),"justifyText":\(s.justifyText ?? d.justifyText ?? false),"marginSize":{"marginLeft":\(s.marginLeft ?? d.marginLeft ?? 2),"marginRight":\(s.marginRight ?? d.marginRight ?? 2),"maxWidth":\(s.maxWidth ?? d.maxWidth ?? 600)},"topMargin":\(s.topMargin ?? d.topMargin ?? 0),"showPageNumber":\(s.showPageNumber ?? d.showPageNumber ?? false)},"appSettings":{"nightMode":\(nightMode),"errorBox":\(showErrorBox),"favouriteLabels":\(favouriteJSON),"recentLabels":\(recentJSON),"studyPadCursors":\(cursorsJSON),"autoAssignLabels":\(autoAssignJSON),"hideCompareDocuments":\(hideCompareJSON),"activeWindow":\(isActiveWindow),"rightToLeft":false,"actionMode":false,"hasActiveIndicator":\(hasActiveIndicator),"activeSince":\(Int(Date().timeIntervalSince1970 * 1000) - 1000),"limitAmbiguousModalSize":false,"windowId":"","disableBibleModalButtons":\(disableBibleModalButtonsJSON),"disableGenericModalButtons":\(disableGenericModalButtonsJSON),"monochromeMode":\(monochromeMode),"disableAnimations":\(disableAnimations),"disableClickToEdit":\(disableClickToEdit),"fontSizeMultiplier":\(fontSizeMultiplier),"enabledExperimentalFeatures":\(enabledExperimentalFeaturesJSON)},"initial":false}
        """
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
            let ordinal = (chapter - 1) * 40 + verse // approximate ordinal
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

     - Returns: JSON string for one Vue.js document record.
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
                                   originalOrdinalRange: [Int]? = nil) -> String {
        let key = "\(osisBookId).\(chapter)"
        let ordinalStart = (chapter - 1) * 40 + 1
        let ordinalEnd = (chapter - 1) * 40 + verseCount
        let initials = bookInitials ?? activeModuleName

        func jsonObject(from string: String) -> Any? {
            guard let data = string.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }

        func osisFragmentObject(xml: String, ordinalRange: [Int], keySuffix: String) -> [String: Any] {
            [
                "xml": xml,
                "key": keySuffix,
                "keyName": "\(bookName) \(chapter)",
                "v11n": "KJVA",
                "bookCategory": bookCategory,
                "bookInitials": initials,
                "bookAbbreviation": osisBookId,
                "osisRef": key,
                "isNewTestament": isNT,
                "features": [String: Any](),
                "ordinalRange": ordinalRange,
                "language": "en",
                "direction": "ltr",
            ]
        }

        let bookmarkObjects = bookmarks.compactMap { jsonObject(from: buildBookmarkJSON($0)) }

        var doc: [String: Any] = [
            "id": "doc-1",
            "type": "bible",
            "osisFragment": osisFragmentObject(xml: xml, ordinalRange: [ordinalStart, ordinalEnd], keySuffix: key),
            "bookInitials": initials,
            "bookCategory": bookCategory,
            "bookAbbreviation": osisBookId,
            "bookName": bookName,
            "key": key,
            "v11n": "KJVA",
            "osisRef": key,
            "annotateRef": "",
            "genericBookmarks": [Any](),
            "ordinalRange": [ordinalStart, ordinalEnd],
            "isNativeHtml": false,
            "bookmarks": bookmarkObjects,
            "bibleBookName": bookName,
            "addChapter": addChapter,
            "chapterNumber": chapter,
            "originalOrdinalRange": originalOrdinalRange ?? NSNull(),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize document JSON for \(osisBookId, privacy: .public) \(chapter)")
            return "{}"
        }

        return json
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
            logger.info("Module \(mod.info.name) returned no books — using default 66-book list")
            moduleBookList = []
        } else {
            logger.info("Module \(mod.info.name) has \(books.count) books (versification: \(mod.configEntry("Versification") ?? "KJV"))")
            moduleBookList = books
        }
    }

    /// Chapter count for a book, using the active module's versification.
    func chapterCount(for book: String) -> Int {
        bookList.first(where: { $0.name == book })?.chapterCount ?? 1
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
        bookList.first(where: { $0.name == bookName })?.osisId ?? bookName.prefix(3).description
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
