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

/// Manages the bridge delegate lifecycle and sends content to the Vue.js WebView.
@Observable
public final class BibleReaderController: NSObject, BibleBridgeDelegate {
    let bridge: BibleBridge
    var bookmarkService: BookmarkService?
    private(set) var currentBook: String = "Genesis"
    private(set) var currentChapter: Int = 1
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

    /// Infinite scroll: tracks the range of chapters currently loaded in the WebView.
    private var minLoadedChapter: Int = 0
    private var maxLoadedChapter: Int = 0

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

    public init(bridge: BibleBridge, bookmarkService: BookmarkService? = nil) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        super.init()
        bridge.delegate = self
        initializeSword()
    }

    /// Callback for showing Strong's definitions in a sheet (multiDocJSON, configJSON).
    var onShowStrongsDefinition: ((String, String) -> Void)?

    /// Callback for opening search with a Strong's number (from "Find all occurrences" links).
    var onShowStrongsSearch: ((String) -> Void)?

    /// Callback for showing cross-reference results (list of parsed references with verse text).
    var onShowCrossReferences: (([CrossReference]) -> Void)?

    /// Callback for presenting compare view (book, chapter, moduleName).
    var onCompareVerses: ((String, Int, String) -> Void)?

    /// Callback for presenting native label assignment UI (bookmarkId).
    var onAssignLabels: ((UUID) -> Void)?

    /// Settings store for reading preferred dictionary setting.
    var settingsStore: SettingsStore?

    /// Callback to persist SwiftData changes (called after PageManager updates).
    var onPersistState: (() -> Void)?

    /// Update display settings and re-emit config to Vue.js.
    public func updateDisplaySettings(_ settings: TextDisplaySettings, nightMode: Bool) {
        self.displaySettings = settings
        self.nightMode = nightMode
        applySwordOptions()
        applyNightModeBackground()
        guard clientReady else { return }
        bridge.emit(event: "set_config", data: buildConfigJSON())
        // Reload to re-render with new options
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
        let uint = UInt32(bitPattern: Int32(value))
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

    /// Speak the current chapter using TTS with word-level highlighting.
    ///
    /// SWORD's `stripText()` is affected by global options — when Strong's Numbers
    /// or Morphology are enabled, it includes tokens like "H7225" in the plain text
    /// output. This corrupts TTS and causes `AVSpeechSynthesizer` to finish the
    /// utterance prematurely, triggering auto-advance to the next chapter.
    /// To prevent this, Strong's and Morphology are temporarily disabled during
    /// text extraction and restored immediately after.
    public func speakCurrentChapter() {
        guard let module = activeModule, let service = speakService else { return }
        let osisBookId = Self.osisBookId(for: currentBook)
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

    /// Speak a specific verse range using TTS.
    ///
    /// See `speakCurrentChapter()` for details on why Strong's/Morphology options
    /// are temporarily disabled during text extraction.
    private func speakVerseRange(startOrdinal: Int, endOrdinal: Int) {
        guard let module = activeModule, let service = speakService else { return }
        let osisBookId = Self.osisBookId(for: currentBook)
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
        logger.info("Switched to module: \(moduleName)")

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
            let osisBookId = Self.osisBookId(for: currentBook)
            let document = buildDocumentJSON(
                osisBookId: osisBookId,
                bookName: currentBook,
                chapter: currentChapter,
                verseCount: 1,
                isNT: Self.isNewTestament(currentBook),
                xml: xml,
                bookmarks: [],
                bookCategory: "COMMENTARY",
                bookInitials: "none"
            )
            bridge.emit(event: "add_documents", data: document)
            bridge.emit(event: "setup_content", data: """
            {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
            """)
            applyNightModeBackground()
            return
        }

        let osisBookId = Self.osisBookId(for: currentBook)
        let chapter = currentChapter
        let isNT = Self.isNewTestament(currentBook)

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
        let verseSelectionEnabled = displaySettings.enableVerseSelection ?? true
        bridge.emit(event: "set_active", data: "{\"hasActiveIndicator\":false,\"isActive\":\(verseSelectionEnabled)}")

        bridge.clearSelection()
        applyNightModeBackground()
    }

    // MARK: - Dictionary/GenBook/Map Content Loading

    /// Load a dictionary entry and display it in the WebView.
    /// Uses renderText() since dictionary entries are typically HTML-formatted definitions.
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

        // Build document JSON with isEpub flag (using JSONSerialization for proper escaping)
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
        applyNightModeBackground()
    }

    /// Build document JSON for EPUB content with isEpub: true.
    /// Uses JSONSerialization for correct escaping of all special characters in HTML content.
    /// IMPORTANT: Uses type "osis" (not "bible") because OsisDocument.vue passes isEpub
    /// to OsisFragment, whereas BibleDocument.vue does not — without this, the EPUB HTML
    /// would go through OSIS template conversion and render as blank.
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
            "isEpub": true,
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

    /// Refresh the list of installed Bible modules (call after install/uninstall).
    /// Recreates the SwordManager so newly installed modules are detected.
    public func refreshInstalledModules() {
        guard let newMgr = SwordManager() else { return }
        swordManager = newMgr
        newMgr.setGlobalOption(.headings, enabled: true)
        newMgr.setGlobalOption(.redLetterWords, enabled: true)
        applySwordOptions()

        let allModules = newMgr.installedModules()
        installedBibleModules = allModules.filter { $0.category == .bible }
        installedCommentaryModules = allModules.filter { $0.category == .commentary }
        installedDictionaryModules = allModules.filter { $0.category == .dictionary }
        installedGeneralBookModules = allModules.filter { $0.category == .generalBook }
        installedMapModules = allModules.filter { $0.category == .map }

        // Re-acquire the active module handle from the new manager
        if let mod = newMgr.module(named: activeModuleName) {
            activeModule = mod
        } else if let firstBible = installedBibleModules.first {
            activeModule = newMgr.module(named: firstBible.name)
            activeModuleName = firstBible.name
        }

        // Re-acquire commentary module
        if let name = activeCommentaryModuleName, let mod = newMgr.module(named: name) {
            activeCommentaryModule = mod
        } else if let firstComm = installedCommentaryModules.first {
            activeCommentaryModule = newMgr.module(named: firstComm.name)
            activeCommentaryModuleName = firstComm.name
        }

        // Re-acquire dictionary module
        if let name = activeDictionaryModuleName, let mod = newMgr.module(named: name) {
            activeDictionaryModule = mod
        }

        // Re-acquire general book module
        if let name = activeGeneralBookModuleName, let mod = newMgr.module(named: name) {
            activeGeneralBookModule = mod
        }

        // Re-acquire map module
        if let name = activeMapModuleName, let mod = newMgr.module(named: name) {
            activeMapModule = mod
        }
    }

    /// Initialize SWORD and find the first available Bible module.
    private func initializeSword() {
        guard let mgr = SwordManager() else {
            logger.warning("Failed to create SwordManager — using placeholder text")
            return
        }
        self.swordManager = mgr

        // Enable headings and verse-level rendering
        mgr.setGlobalOption(.headings, enabled: true)
        mgr.setGlobalOption(.redLetterWords, enabled: true)
        applySwordOptions()

        // Look for a Bible module
        let modules = mgr.installedModules()
        logger.info("SWORD found \(modules.count) installed modules")
        for mod in modules {
            let hasStrongs = mod.features.contains(.strongsNumbers)
            logger.info("  Module: \(mod.name) (\(mod.description)) [\(mod.category.rawValue)] strongs=\(hasStrongs)")
        }

        // Cache module lists for the picker
        installedBibleModules = modules.filter { $0.category == .bible }
        installedCommentaryModules = modules.filter { $0.category == .commentary }
        installedDictionaryModules = modules.filter { $0.category == .dictionary }
        installedGeneralBookModules = modules.filter { $0.category == .generalBook }
        installedMapModules = modules.filter { $0.category == .map }

        // Default to KJV or first available Bible module
        if let kjv = mgr.module(named: "KJV") {
            activeModule = kjv
            activeModuleName = kjv.info.name
            logger.info("Using Bible module: \(kjv.info.name)")
        } else if let firstBible = installedBibleModules.first {
            activeModule = mgr.module(named: firstBible.name)
            activeModuleName = firstBible.name
            logger.info("Using Bible module: \(firstBible.name)")
        } else {
            logger.warning("No Bible modules installed — using placeholder text")
        }
    }

    /// Copy module state (SwordManager + module lists) from an existing controller.
    /// Avoids creating multiple C++ SWMgr instances which conflict with each other.
    /// Each controller still gets its own SwordModule handles for independent cursor state.
    public func copyModuleState(from other: BibleReaderController) {
        guard let mgr = other.swordManager else { return }
        self.swordManager = mgr
        self.installedBibleModules = other.installedBibleModules
        self.installedCommentaryModules = other.installedCommentaryModules
        self.installedDictionaryModules = other.installedDictionaryModules
        self.installedGeneralBookModules = other.installedGeneralBookModules
        self.installedMapModules = other.installedMapModules

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

    /// Restore saved module and position from PageManager.
    /// Must be called after `activeWindow` is set.
    public func restoreSavedPosition() {
        guard let pm = activeWindow?.pageManager else { return }

        // Restore saved Bible module
        if let saved = pm.bibleDocument,
           let mgr = swordManager,
           let mod = mgr.module(named: saved) {
            activeModule = mod
            activeModuleName = saved
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
           bookIndex >= 0, bookIndex < Self.allBooks.count {
            currentBook = Self.allBooks[bookIndex]
        }
        if let chapter = pm.bibleChapterNo, chapter > 0 {
            currentChapter = chapter
        }
        logger.info("Restored position: \(self.currentBook) \(self.currentChapter)")
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
    public func navigateTo(book: String, chapter: Int) {
        currentBook = book
        currentChapter = chapter

        // Record history
        if let store = workspaceStore, let window = activeWindow {
            let osisId = Self.osisBookId(for: book)
            store.addHistoryItem(to: window, document: activeModuleName, key: "\(osisId).\(chapter).1")
        }

        // Persist position to PageManager
        if let pm = activeWindow?.pageManager {
            pm.bibleBibleBook = Self.allBooks.firstIndex(of: book)
            pm.bibleChapterNo = chapter
            onPersistState?()
        }

        guard clientReady else { return }
        loadCurrentContent()
    }

    /// Navigate to the next chapter, wrapping to the next book if needed.
    public func navigateNext() {
        let maxChapter = Self.chapterCount(for: currentBook)
        if currentChapter < maxChapter {
            navigateTo(book: currentBook, chapter: currentChapter + 1)
        } else if let nextBook = Self.nextBook(after: currentBook) {
            navigateTo(book: nextBook, chapter: 1)
        }
        // At Revelation's last chapter, do nothing
    }

    /// Navigate to the previous chapter, wrapping to the previous book if needed.
    public func navigatePrevious() {
        if currentChapter > 1 {
            navigateTo(book: currentBook, chapter: currentChapter - 1)
        } else if let prevBook = Self.previousBook(before: currentBook) {
            navigateTo(book: prevBook, chapter: Self.chapterCount(for: prevBook))
        }
        // At Genesis 1, do nothing
    }

    /// Whether there's a next chapter available.
    public var hasNext: Bool {
        let maxChapter = Self.chapterCount(for: currentBook)
        return currentChapter < maxChapter || Self.nextBook(after: currentBook) != nil
    }

    /// Whether there's a previous chapter available.
    public var hasPrevious: Bool {
        return currentChapter > 1 || Self.previousBook(before: currentBook) != nil
    }

    // MARK: - BibleBridgeDelegate — State

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

    public func bridge(_ bridge: BibleBridge, saveState state: String) {}
    public func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool) {}
    public func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool) {}
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

    public func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String) {
        // Focus-on-interaction: scrolling in a pane makes it the active window
        onInteraction?()
        // Notify WindowManager for synchronized scrolling
        if let window = activeWindow {
            windowManagerRef?.notifyVerseChanged(sourceWindow: window, ordinal: ordinal, key: key)
        }
    }

    /// Scroll the WebView to a specific verse ordinal (for sync from another window).
    public func scrollToOrdinal(_ ordinal: Int) {
        bridge.emit(event: "scroll_to_verse", data: "{\"ordinal\":\(ordinal),\"now\":false}")
    }

    public func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int) {
        guard currentCategory == .bible else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        let newChapter = minLoadedChapter - 1
        if newChapter < 1 {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        minLoadedChapter = newChapter
        if let document = loadChapterJSON(book: currentBook, chapter: newChapter) {
            bridge.sendResponse(callId: callId, value: document)
        } else {
            minLoadedChapter = newChapter + 1 // revert
            bridge.sendResponse(callId: callId, value: "null")
        }
    }

    public func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int) {
        guard currentCategory == .bible else {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        let lastChapter = Self.chapterCount(for: currentBook)
        let newChapter = maxLoadedChapter + 1
        if newChapter > lastChapter {
            bridge.sendResponse(callId: callId, value: "null")
            return
        }
        maxLoadedChapter = newChapter
        if let document = loadChapterJSON(book: currentBook, chapter: newChapter) {
            bridge.sendResponse(callId: callId, value: document)
        } else {
            maxLoadedChapter = newChapter - 1 // revert
            bridge.sendResponse(callId: callId, value: "null")
        }
    }

    // MARK: - BibleBridgeDelegate — Bookmarks

    public func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {
        guard let service = bookmarkService else {
            logger.warning("addBookmark: bookmarkService is nil")
            return
        }
        // Check for an existing bookmark at the same verse (by startOrdinal)
        let existing = service.bookmarks(for: startOrdinal, endOrdinal: startOrdinal)
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

    public func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String) {
        logger.info("Remove bookmark: \(bookmarkId)")
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.removeBibleBookmark(id: uuid)
        bridge.emit(event: "delete_bookmarks", data: "[\"\(bookmarkId)\"]")
    }

    public func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String) {
        logger.info("Remove generic bookmark: \(bookmarkId)")
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.removeGenericBookmark(id: uuid)
    }

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
    }

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

    public func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {
        logger.info("Remove label \(labelId) from bookmark \(bookmarkId)")
        guard let service = bookmarkService,
              let bmId = UUID(uuidString: bookmarkId),
              let lblId = UUID(uuidString: labelId) else { return }
        service.removeLabel(bookmarkId: bmId, labelId: lblId)
        // Emit updated bookmark back to Vue.js
        emitBookmarkUpdate(bookmarkId: bmId)
    }

    public func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {
        logger.info("Set primary label \(labelId) on bookmark \(bookmarkId)")
        guard let service = bookmarkService,
              let bmId = UUID(uuidString: bookmarkId),
              let lblId = UUID(uuidString: labelId) else { return }
        service.setPrimaryLabel(bookmarkId: bmId, labelId: lblId)
        // Emit updated bookmark back to Vue.js
        emitBookmarkUpdate(bookmarkId: bmId)
    }

    public func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {
        logger.info("Set whole verse \(value) for bookmark \(bookmarkId)")
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.setWholeVerse(bookmarkId: uuid, value: value)
    }

    public func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {
        logger.info("Set custom icon for bookmark \(bookmarkId)")
        guard let service = bookmarkService, let uuid = UUID(uuidString: bookmarkId) else { return }
        service.setCustomIcon(bookmarkId: uuid, value: value)
    }

    // MARK: - BibleBridgeDelegate — StudyPad

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

    public func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {
        logger.info("Update StudyPad entry text: \(id)")
        guard let service = bookmarkService,
              let uuid = UUID(uuidString: id) else { return }
        service.updateStudyPadTextEntryText(id: uuid, text: text)
    }

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

        let btlsJSON = btls.map { buildBibleBookmarkToLabelJSON($0) }.joined(separator: ",")
        let gbtlsJSON = gbtls.map { buildGenericBookmarkToLabelJSON($0) }.joined(separator: ",")
        let entriesJSON = entries.map { buildStudyPadEntryJSON($0) }.joined(separator: ",")

        bridge.emit(event: "add_or_update_study_pad", data: """
        {"studyPadTextEntry":null,"bookmarkToLabelsOrdered":[\(btlsJSON)],"genericBookmarkToLabelsOrdered":[\(gbtlsJSON)],"studyPadItemsOrdered":[\(entriesJSON)]}
        """)
    }

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
            let btlJSON = buildBibleBookmarkToLabelJSON(btl)
            bridge.emit(event: "add_or_update_bookmark_to_label", data: btlJSON)
        }
    }

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
            let gbtlJSON = buildGenericBookmarkToLabelJSON(gbtl)
            bridge.emit(event: "add_or_update_bookmark_to_label", data: gbtlJSON)
        }
    }

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

    public func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {
        logger.info("WebView editing mode: \(enabled)")
        editingInWebView = enabled
    }

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

    public func bridge(_ bridge: BibleBridge, selectionChanged text: String) {
        hasActiveSelection = true
        selectedText = text
        bridge.emit(event: "set_action_mode", data: "true")
    }

    public func bridgeSelectionCleared(_ bridge: BibleBridge) {
        hasActiveSelection = false
        selectedText = ""
        bridge.emit(event: "set_action_mode", data: "false")
    }

    // MARK: - Selection Actions

    /// Bookmark the current selection. Queries JS for ordinal range.
    func bookmarkSelection() {
        Task { @MainActor in
            guard let sel = await bridge.querySelection() else { return }
            let startOrd = sel.startOrdinal ?? ((currentChapter - 1) * 40 + 1)
            let endOrd = sel.endOrdinal ?? startOrd
            bridge(bridge, addBookmark: activeModuleName, startOrdinal: startOrd, endOrdinal: endOrd, addNote: false)
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
        onCompareVerses?(currentBook, currentChapter, activeModuleName)
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

    public func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        let text = getVerseText(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
        guard !text.isEmpty else { return }
        let reference = "\(currentBook) \(currentChapter)"
        let shareText = "\(text)\n— \(reference) (\(activeModuleName))"
        onShareVerseText?(shareText)
    }

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

    public func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        logger.info("Compare verses requested: \(startOrdinal)-\(endOrdinal)")
        onCompareVerses?(currentBook, currentChapter, activeModuleName)
    }

    public func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {
        speakVerseRange(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    // MARK: - BibleBridgeDelegate — Navigation Actions

    public func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String) {
        logger.info("Open StudyPad for label: \(labelId)")
        guard let uuid = UUID(uuidString: labelId) else { return }
        let bmUuid = UUID(uuidString: bookmarkId)
        loadStudyPadDocument(labelId: uuid, bookmarkId: bmUuid)
    }

    public func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int) {
        loadMyNotesDocument()
    }

    /// Load the My Notes document for the current chapter into the WebView.
    /// Shows all bookmarks for the chapter in a personal-commentary style view.
    public func loadMyNotesDocument() {
        guard clientReady else { return }
        let osisBookId = Self.osisBookId(for: currentBook)
        let verseCount = Self.verseCount(for: currentBook, chapter: currentChapter)
        let ordinalStart = (currentChapter - 1) * 40 + 1
        let ordinalEnd = (currentChapter - 1) * 40 + verseCount

        // Get bookmarks with notes for this chapter
        guard let service = bookmarkService else { return }
        let bookmarks = service.bookmarks(for: ordinalStart, endOrdinal: ordinalEnd)
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
            "[" + bibleBtls.map { buildBibleBookmarkToLabelJSON($0) }.joined(separator: ",") + "]"
        let gbtlsJSON = genericBtls.isEmpty ? "[]" :
            "[" + genericBtls.map { buildGenericBookmarkToLabelJSON($0) }.joined(separator: ",") + "]"
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

    /// Build a MultiFragmentDocument JSON from Strong's numbers and Robinson codes.
    /// Returns nil if no definitions were found.
    func buildStrongsMultiDocJSON(strongs: [String], robinson: [String]) -> String? {
        var fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: String)] = []

        for num in strongs {
            let lexModules = findAllLexiconModules(for: num)
            let keyOptions = buildKeyOptions(for: num)
            for mod in lexModules {
                if let html = lookupInModule(mod, keyOptions: keyOptions) {
                    let linkifiedHtml = Self.linkifyRefTags(html)
                    let keyName = keyOptions.first ?? num
                    let escapedTitle = escapeXML(keyName)
                    let xml = "<div><title type=\"x-gen\">\(escapedTitle)</title><div type=\"paragraph\">\(linkifiedHtml)</div></div>"

                    // Determine features type for "Find all occurrences" link
                    let isHebrew = num.hasPrefix("H") || (!num.hasPrefix("G") && (Int(String(num.drop(while: { $0.isLetter || $0 == "0" }))) ?? 0) > 5624)
                    let featureType = isHebrew ? "hebrew" : "greek"
                    let prefix = isHebrew ? "H" : "G"
                    let featureKeyName = num.first?.isLetter == true ? num : "\(prefix)\(num)"
                    let featuresJSON = "{\"type\":\"\(featureType)\",\"keyName\":\"\(featureKeyName)\"}"

                    fragments.append((
                        xml: xml,
                        key: "\(mod.info.name)--\(keyName)",
                        keyName: keyName,
                        bookInitials: mod.info.name,
                        bookAbbreviation: String(mod.info.name.prefix(10)),
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
                    if let html = lookupInModule(mod, keyOptions: morphKeys) {
                        let linkifiedHtml = Self.linkifyRefTags(html)
                        let escapedTitle = escapeXML(code)
                        let xml = "<div><title type=\"x-gen\">Morphology: \(escapedTitle)</title><div type=\"paragraph\">\(linkifiedHtml)</div></div>"
                        fragments.append((
                            xml: xml,
                            key: "\(mod.info.name)--\(code)",
                            keyName: code,
                            bookInitials: mod.info.name,
                            bookAbbreviation: String(mod.info.name.prefix(10)),
                            features: "{}"
                        ))
                    }
                }
            }
        }

        if fragments.isEmpty {
            logger.info("handleStrongsLink: no definitions found")
            return nil
        }

        return buildMultiFragmentJSON(fragments: fragments)
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

    /// Transform dictionary cross-references into clickable links.
    /// Handles:
    /// 1. ThML `<ref target="StrongsHebrew/02421">text</ref>` tags
    /// 2. Plain text "see HEBREW for 05774" / "see GREEK for 01234" from StrongsHebrew/Greek modules
    /// 3. Plain text "from 05774" / "From H5774" patterns
    static func linkifyRefTags(_ html: String) -> String {
        var result = html

        // 1. Transform <ref target="ModuleName/key">text</ref> into clickable links
        let refPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="(?:Strongs(?:Hebrew|Greek|RealGreek)|BDB|OSHB|Thayer)[/:](\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        if let regex = refPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<a href=\"ab-w://?strong=$1\">$2</a>")
        }

        // Handle bare <ref target="key">text</ref> for any remaining ref tags
        let bareRefPattern = try? NSRegularExpression(
            pattern: #"<ref\s+target="[^"]*?/?(\d+)"[^>]*>(.*?)</ref>"#,
            options: [.dotMatchesLineSeparators]
        )
        if let regex = bareRefPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<a href=\"ab-w://?strong=$1\">$2</a>")
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
        if let regex = fromPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<a href=\"ab-w://?strong=$1\">$1</a>")
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

    /// Build a MultiFragmentDocument JSON string for rendering in Vue.js MultiDocument.vue.
    private func buildMultiFragmentJSON(fragments: [(xml: String, key: String, keyName: String, bookInitials: String, bookAbbreviation: String, features: String)]) -> String {
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

        return "{\"id\":\"\(id)\",\"type\":\"multi\",\"osisFragments\":[\(osisFragmentsJSON.joined(separator: ","))],\"compare\":false}"
    }

    /// Escape special XML characters in text content.
    private func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Build key variants for looking up a Strong's number in SWORD zLD modules.
    /// SWORD uses 5-digit zero-padded keys (e.g. "02532"). We try padded, stripped, and raw.
    private func buildKeyOptions(for strongsNumber: String) -> [String] {
        let numberOnly = String(strongsNumber.drop(while: { $0.isLetter }))
        let stripped = numberOnly.replacingOccurrences(of: "^0+", with: "", options: .regularExpression)
        let padded = stripped.count < 5
            ? String(repeating: "0", count: 5 - stripped.count) + stripped
            : stripped
        var keys: [String] = [padded]
        if stripped != padded { keys.append(stripped) }
        if numberOnly != padded && numberOnly != stripped { keys.append(numberOnly) }
        return keys
    }

    /// Try each key variant in a module and return the first valid renderText() result.
    private func lookupInModule(_ module: SwordModule, keyOptions: [String]) -> String? {
        for key in keyOptions {
            module.setKey(key)
            let candidate = module.renderText()
            if !candidate.isEmpty && !candidate.contains("@@@@") {
                logger.info("Lexicon hit in \(module.info.name) for key '\(key)': '\(candidate.prefix(80))'")
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// Find ALL lexicon/dictionary modules that can look up the given Strong's number.
    private func findAllLexiconModules(for strongsNumber: String) -> [SwordModule] {
        guard let mgr = swordManager else { return [] }

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
        var result: [SwordModule] = []
        var seen = Set<String>()

        // 1. User-preferred dictionary first
        let prefKey = isHebrew ? "preferred_hebrew_dict" : "preferred_greek_dict"
        if let preferred = settingsStore?.getString(prefKey), !preferred.isEmpty,
           let mod = mgr.module(named: preferred), seen.insert(preferred).inserted {
            result.append(mod)
        }

        // 2. All modules with the matching feature flag
        for info in allModules where info.features.contains(feature) {
            if seen.insert(info.name).inserted, let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        // 3. Known lexicon module names
        let lexiconNames = isHebrew
            ? ["StrongsHebrew", "OSHB", "BDB"]
            : ["StrongsGreek", "StrongsRealGreek", "Thayer", "ISBE"]
        for name in lexiconNames {
            if seen.insert(name).inserted, let mod = mgr.module(named: name) {
                result.append(mod)
            }
        }

        // 4. Any other dictionary module as fallback (only if nothing found so far)
        if result.isEmpty {
            if let info = allModules.first(where: { $0.category == .dictionary }),
               let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        return result
    }

    /// Find modules that can decode morphology (Robinson, Packard, etc.).
    private func findMorphologyModules() -> [SwordModule] {
        guard let mgr = swordManager else { return [] }
        let allModules = mgr.installedModules()
        var result: [SwordModule] = []
        var seen = Set<String>()

        // Check for modules with morphology features
        for info in allModules where info.features.contains(.greekParse) || info.features.contains(.hebrewParse) {
            if seen.insert(info.name).inserted, let mod = mgr.module(named: info.name) {
                result.append(mod)
            }
        }

        // Fallback to known morphology module names
        for name in ["Robinson", "Packard"] {
            if seen.insert(name).inserted, let mod = mgr.module(named: name) {
                result.append(mod)
            }
        }

        return result
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

        guard let bookName = Self.bookName(forOsisId: osisId) else {
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

    public func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge) {
        onRequestOpenDownloads?()
    }

    // MARK: - BibleBridgeDelegate — Dialogs

    public func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int) {
        // Return null to dismiss — full implementation would show a reference picker
        bridge.sendResponse(callId: callId, value: "null")
    }

    public func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String) {
        // Basic reference parsing — return the text as-is for now
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        bridge.sendResponse(callId: callId, value: "\"\(escaped)\"")
    }

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

    public func bridge(_ bridge: BibleBridge, showToast text: String) {
        onShowToast?(text)
    }

    public func bridge(_ bridge: BibleBridge, shareHtml html: String) {
        onShareHtml?(html)
    }

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

    public func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge) {
        onToggleFullScreen?()
    }

    // MARK: - EPUB Link Navigation

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

    /// Get plain text for a verse range using SWORD stripText.
    private func getVerseText(startOrdinal: Int, endOrdinal: Int) -> String {
        guard let module = activeModule else { return "" }
        let osisBookId = Self.osisBookId(for: currentBook)
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

    private func loadCurrentChapter() {
        showingMyNotes = false
        showingStudyPad = false
        activeStudyPadLabelId = nil
        activeStudyPadLabelName = nil
        editingInWebView = false
        hasActiveSelection = false
        selectedText = ""
        let osisBookId = Self.osisBookId(for: currentBook)
        let isNT = Self.isNewTestament(currentBook)

        // Try loading from SWORD module first
        let (xml, verseCount) = loadChapterFromSword(osisBookId: osisBookId) ??
            loadPlaceholderChapter(osisBookId: osisBookId, bookName: currentBook)

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
            bookmarks: chapterBookmarks
        )
        bridge.emit(event: "add_documents", data: document)

        // Track loaded chapter range for infinite scroll
        minLoadedChapter = currentChapter
        maxLoadedChapter = currentChapter

        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
        let verseSelectionEnabled = displaySettings.enableVerseSelection ?? true
        bridge.emit(event: "set_active", data: "{\"hasActiveIndicator\":false,\"isActive\":\(verseSelectionEnabled)}")

        // Clear any accidental text selection and re-apply background
        bridge.clearSelection()
        applyNightModeBackground()

    }

    /// Load chapter text from the active SWORD module.
    /// Returns (xml, verseCount) or nil if no module is available.
    private func loadChapterFromSword(osisBookId: String) -> (String, Int)? {
        guard let module = activeModule else { return nil }

        // Navigate to the first verse of the chapter
        let startKey = "\(osisBookId) \(currentChapter):1"
        module.setKey(startKey)

        // Check if the module has content at this position
        let firstKey = module.currentKey()
        if firstKey.isEmpty {
            logger.warning("SWORD: No content at \(startKey)")
            return nil
        }

        // Collect verses for this chapter
        var verses: [(Int, String)] = []
        let chapter = self.currentChapter

        // Read verses until we leave this chapter
        while true {
            let key = module.currentKey()

            // Parse the key to check if we're still in the same chapter
            // SWORD keys look like "Genesis 1:1" or "Gen 1:1"
            guard let (_, parsedChapter, parsedVerse) = parseVerseKey(key) else {
                break
            }

            if parsedChapter != chapter {
                break // We've moved to the next chapter
            }

            // Get the raw OSIS XML for this verse.
            // Using rawEntry() instead of renderText() preserves OSIS elements
            // (<note>, <w>, <reference>, etc.) that Vue.js components render natively.
            let text = module.rawEntry()
            if !text.isEmpty {
                verses.append((parsedVerse, text))
            }

            // Move to next verse
            if !module.next() {
                break // End of module
            }
        }

        if verses.isEmpty {
            logger.warning("SWORD: No verses found for \(osisBookId) \(chapter)")
            return nil
        }

        logger.info("SWORD: Loaded \(verses.count) verses for \(osisBookId) \(chapter)")

        // Build OSIS XML from the rendered verses
        let xml = buildSwordChapterXML(
            osisBookId: osisBookId,
            bookName: currentBook,
            chapter: currentChapter,
            verses: verses
        )

        return (xml, verses.count)
    }

    /// Load a specific chapter from the active SWORD module and return its document JSON string.
    /// Used by infinite scroll to load adjacent chapters without navigating.
    private func loadChapterJSON(book: String, chapter: Int) -> String? {
        guard let module = activeModule else { return nil }

        let osisBookId = Self.osisBookId(for: book)
        let isNT = Self.isNewTestament(book)

        // Navigate to the first verse of the target chapter
        let startKey = "\(osisBookId) \(chapter):1"
        module.setKey(startKey)

        let firstKey = module.currentKey()
        if firstKey.isEmpty { return nil }

        // Collect verses for this chapter
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

        if verses.isEmpty { return nil }

        let xml = buildSwordChapterXML(
            osisBookId: osisBookId,
            bookName: book,
            chapter: chapter,
            verses: verses
        )

        // Query bookmarks for this chapter's ordinal range
        let ordinalStart = (chapter - 1) * 40 + 1
        let ordinalEnd = (chapter - 1) * 40 + verses.count
        let chapterBookmarks = bookmarkService?.bookmarks(for: ordinalStart, endOrdinal: ordinalEnd) ?? []

        let document = buildDocumentJSON(
            osisBookId: osisBookId,
            bookName: book,
            chapter: chapter,
            verseCount: verses.count,
            isNT: isNT,
            xml: xml,
            bookmarks: chapterBookmarks
        )

        // Restore module position to current chapter so other operations aren't affected
        let restoreKey = "\(Self.osisBookId(for: currentBook)) \(currentChapter):1"
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

    /// Build OSIS XML from raw OSIS verse entries.
    private func buildSwordChapterXML(osisBookId: String, bookName: String, chapter: Int, verses: [(Int, String)]) -> String {
        var xml = "<div>"
        xml += "<title type=\"x-gen\">\(bookName) \(chapter)</title>"
        xml += "<div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv1\"/>"
        xml += "<div sID=\"sec1\" type=\"section\"/>"
        xml += "<title>\(bookName) \(chapter)</title>"
        xml += "<div sID=\"p1\" type=\"paragraph\"/>"
        xml += "<div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv1\"/>"

        for (verseNum, text) in verses {
            let ordinal = (chapter - 1) * 40 + verseNum
            let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            xml += "<verse osisID=\"\(osisBookId).\(chapter).\(verseNum)\" verseOrdinal=\"\(ordinal)\">"
            xml += "\(cleanText) "
            xml += "</verse>"
        }

        xml += "<div eID=\"p1\" type=\"paragraph\"/>"
        xml += "<div eID=\"sec1\" type=\"section\"/>"
        xml += "</div>"
        return xml
    }

    /// Transform SWORD rendered Strong's numbers into OSIS `<w>` elements.
    /// SWORD renderText outputs Strong's as:
    ///   `<small><em>&lt;<a href="passagestudy.jsp?showStrong=07225#cv">07225</a>&gt;</em></small>`
    /// Vue.js W.vue expects `<w lemma="strong:H07225"></w>` for proper rendering.
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

    /// Query bookmarks for the current chapter's ordinal range.
    private func bookmarksForCurrentChapter(verseCount: Int) -> [BibleBookmark] {
        guard let service = bookmarkService else { return [] }
        let ordinalStart = (currentChapter - 1) * 40 + 1
        let ordinalEnd = (currentChapter - 1) * 40 + verseCount
        return service.bookmarks(for: ordinalStart, endOrdinal: ordinalEnd)
    }

    // MARK: - Default Labels

    /// Fixed UUID for the "Unlabeled" system label, sent to Vue.js so bookmarks always have a valid label reference.
    private static let unlabeledLabelId = "00000000-0000-0000-0000-000000000001"

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
        // Collect user labels from the bookmark service
        var labels: [[String: Any]] = []

        // Always include the default "Unlabeled" label
        let unlabeledJSON = """
        {"id":"\(Self.unlabeledLabelId)","name":"__UNLABELED__","isRealLabel":false,"style":{"color":\(BibleCore.Label.defaultColor),"isSpeak":false,"isParagraphBreak":false,"underline":false,"underlineWholeVerse":false,"markerStyle":false,"markerStyleWholeVerse":false,"hideStyle":false,"hideStyleWholeVerse":false,"customIcon":null}}
        """

        // Build user labels JSON
        var allLabelsJSON = [unlabeledJSON]
        if let service = bookmarkService {
            for label in service.allLabels() {
                let labelJSON = """
                {"id":"\(label.id.uuidString)","name":"\(label.name.replacingOccurrences(of: "\"", with: "\\\""))","isRealLabel":\(label.isRealLabel),"style":{"color":\(label.color),"isSpeak":false,"isParagraphBreak":false,"underline":\(label.underlineStyle),"underlineWholeVerse":\(label.underlineStyleWholeVerse),"markerStyle":\(label.markerStyle),"markerStyleWholeVerse":\(label.markerStyleWholeVerse),"hideStyle":\(label.hideStyle),"hideStyleWholeVerse":\(label.hideStyleWholeVerse),"customIcon":\(label.customIcon.map { "\"\($0)\"" } ?? "null")}}
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
        let primaryLabelId = bookmark.primaryLabelId.map { "\"\($0.uuidString)\"" } ?? "null"
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"

        // Build labels array — always include at least the unlabeled label
        var labelIds = bookmark.bookmarkToLabels?.compactMap { $0.label?.id.uuidString } ?? []
        if labelIds.isEmpty {
            labelIds = [Self.unlabeledLabelId]
        }
        let labelsJSON = "[" + labelIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // Build bookmarkToLabels array
        let btlJSON: String
        if let btls = bookmark.bookmarkToLabels, !btls.isEmpty {
            let items = btls.compactMap { btl -> String? in
                guard let labelId = btl.label?.id.uuidString else { return nil }
                return """
                {"type":"BibleBookmarkToLabel","bookmarkId":"\(id)","labelId":"\(labelId)","orderNumber":\(btl.orderNumber),"indentLevel":\(btl.indentLevel),"expandContent":\(btl.expandContent)}
                """
            }
            btlJSON = "[" + items.joined(separator: ",") + "]"
        } else {
            // Default: assign to the unlabeled label
            btlJSON = "[{\"type\":\"BibleBookmarkToLabel\",\"bookmarkId\":\"\(id)\",\"labelId\":\"\(Self.unlabeledLabelId)\",\"orderNumber\":0,\"indentLevel\":0,\"expandContent\":false}]"
        }

        // Compute verse references from ordinals
        let osisBookId = Self.osisBookId(for: currentBook)
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

        return """
        {"id":"\(id)","type":"bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"originalOrdinalRange":[\(bookmark.kjvOrdinalStart),\(bookmark.kjvOrdinalEnd)],"offsetRange":null,"bookInitials":"\(activeModuleName)","bookName":"\(activeModuleName)","bookAbbreviation":"\(osisBookId)","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"verseRange":"\(verseRange)","verseRangeOnlyNumber":"\(verseRangeOnlyNumber)","verseRangeAbbreviated":"\(verseRangeAbbreviated)","text":"\(escapedFullText)","fullText":"\(escapedFullText)","osisRef":"\(osisRef)","v11n":"\(bookmark.v11n)","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"osisFragment":null,"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":{"mode":null,"content":null}}
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
        let primaryLabelId = bookmark.primaryLabelId.map { "\"\($0.uuidString)\"" } ?? "null"
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"

        // Labels
        var labelIds = bookmark.bookmarkToLabels?.compactMap { $0.label?.id.uuidString } ?? []
        if labelIds.isEmpty { labelIds = [Self.unlabeledLabelId] }
        let labelsJSON = "[" + labelIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // bookmarkToLabels
        let btlJSON: String
        if let btls = bookmark.bookmarkToLabels, !btls.isEmpty {
            let items = btls.compactMap { btl -> String? in
                guard let labelId = btl.label?.id.uuidString else { return nil }
                return "{\"type\":\"BibleBookmarkToLabel\",\"bookmarkId\":\"\(id)\",\"labelId\":\"\(labelId)\",\"orderNumber\":\(btl.orderNumber),\"indentLevel\":\(btl.indentLevel),\"expandContent\":\(btl.expandContent)}"
            }
            btlJSON = "[" + items.joined(separator: ",") + "]"
        } else {
            btlJSON = "[{\"type\":\"BibleBookmarkToLabel\",\"bookmarkId\":\"\(id)\",\"labelId\":\"\(Self.unlabeledLabelId)\",\"orderNumber\":0,\"indentLevel\":0,\"expandContent\":false}]"
        }

        // Compute verse references from ordinals
        let osisBookId = Self.osisBookId(for: currentBook)
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

        return """
        {"id":"\(id)","type":"bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"originalOrdinalRange":[\(bookmark.kjvOrdinalStart),\(bookmark.kjvOrdinalEnd)],"offsetRange":null,"bookInitials":"\(activeModuleName)","bookName":"\(activeModuleName)","bookAbbreviation":"\(osisBookId)","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"verseRange":"\(verseRange)","verseRangeOnlyNumber":"\(verseRangeOnlyNumber)","verseRangeAbbreviated":"\(verseRangeAbbreviated)","text":"\(escapedFullText)","fullText":"\(escapedFullText)","osisRef":"\(osisRef)","v11n":"\(bookmark.v11n)","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"osisFragment":null,"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":{"mode":null,"content":null}}
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
        let labelId = entry.label?.id.uuidString ?? ""
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
    private func buildBibleBookmarkToLabelJSON(_ btl: BibleBookmarkToLabel) -> String {
        let bmId = btl.bookmark?.id.uuidString ?? ""
        let lblId = btl.label?.id.uuidString ?? ""
        return """
        {"type":"BibleBookmarkToLabel","bookmarkId":"\(bmId)","labelId":"\(lblId)","orderNumber":\(btl.orderNumber),"indentLevel":\(btl.indentLevel),"expandContent":\(btl.expandContent)}
        """
    }

    /// Serialize a GenericBookmarkToLabel to JSON for Vue.js.
    private func buildGenericBookmarkToLabelJSON(_ gbtl: GenericBookmarkToLabel) -> String {
        let bmId = gbtl.bookmark?.id.uuidString ?? ""
        let lblId = gbtl.label?.id.uuidString ?? ""
        return """
        {"type":"GenericBookmarkToLabel","bookmarkId":"\(bmId)","labelId":"\(lblId)","orderNumber":\(gbtl.orderNumber),"indentLevel":\(gbtl.indentLevel),"expandContent":\(gbtl.expandContent)}
        """
    }

    /// Serialize a Label to JSON for Vue.js StudyPad document.
    private func buildLabelJSON(_ label: Label) -> String {
        let customIcon = label.customIcon.map { "\"\($0)\"" } ?? "null"
        let escapedName = label.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"id":"\(label.id.uuidString)","name":"\(escapedName)","isRealLabel":\(label.isRealLabel),"style":{"color":\(label.color),"isSpeak":false,"isParagraphBreak":false,"underline":\(label.underlineStyle),"underlineWholeVerse":\(label.underlineStyleWholeVerse),"markerStyle":\(label.markerStyle),"markerStyleWholeVerse":\(label.markerStyleWholeVerse),"hideStyle":\(label.hideStyle),"hideStyleWholeVerse":\(label.hideStyleWholeVerse),"customIcon":\(customIcon)}}
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
        let primaryLabelId = bookmark.primaryLabelId.map { "\"\($0.uuidString)\"" } ?? "null"
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"

        var labelIds = bookmark.bookmarkToLabels?.compactMap { $0.label?.id.uuidString } ?? []
        if labelIds.isEmpty { labelIds = [Self.unlabeledLabelId] }
        let labelsJSON = "[" + labelIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        // Build BTLs with type field
        let btlJSON: String
        if let btls = bookmark.bookmarkToLabels, !btls.isEmpty {
            let items = btls.compactMap { btl -> String? in
                guard let labelId = btl.label?.id.uuidString else { return nil }
                return """
                {"type":"BibleBookmarkToLabel","bookmarkId":"\(id)","labelId":"\(labelId)","orderNumber":\(btl.orderNumber),"indentLevel":\(btl.indentLevel),"expandContent":\(btl.expandContent)}
                """
            }
            btlJSON = "[" + items.joined(separator: ",") + "]"
        } else {
            btlJSON = "[{\"type\":\"BibleBookmarkToLabel\",\"bookmarkId\":\"\(id)\",\"labelId\":\"\(Self.unlabeledLabelId)\",\"orderNumber\":0,\"indentLevel\":0,\"expandContent\":false}]"
        }

        // Compute verse references
        let osisBookId: String
        let bookName: String
        if let book = bookmark.book {
            osisBookId = Self.osisBookId(for: book)
            bookName = book
        } else {
            osisBookId = Self.osisBookId(for: currentBook)
            bookName = currentBook
        }
        let chapterBase = bookmark.ordinalStart / 40
        let chapter = chapterBase + 1
        let startVerse = max(1, bookmark.ordinalStart - chapterBase * 40)
        let endVerse = max(startVerse, bookmark.ordinalEnd - chapterBase * 40)

        let osisRef = startVerse == endVerse
            ? "\(osisBookId).\(chapter).\(startVerse)"
            : "\(osisBookId).\(chapter).\(startVerse)-\(osisBookId).\(chapter).\(endVerse)"
        let verseRange = startVerse == endVerse
            ? "\(bookName) \(chapter):\(startVerse)"
            : "\(bookName) \(chapter):\(startVerse)-\(endVerse)"
        let verseRangeOnlyNumber = startVerse == endVerse ? "\(startVerse)" : "\(startVerse)-\(endVerse)"
        let verseRangeAbbreviated = startVerse == endVerse
            ? "\(osisBookId) \(chapter):\(startVerse)"
            : "\(osisBookId) \(chapter):\(startVerse)-\(endVerse)"

        let fullText = loadVerseText(osisBookId: osisBookId, chapter: chapter, startVerse: startVerse, endVerse: endVerse)
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

        return """
        {"id":"\(id)","type":"bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"originalOrdinalRange":[\(bookmark.kjvOrdinalStart),\(bookmark.kjvOrdinalEnd)],"offsetRange":null,"bookInitials":"\(activeModuleName)","bookName":"\(activeModuleName)","bookAbbreviation":"\(osisBookId)","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"verseRange":"\(verseRange)","verseRangeOnlyNumber":"\(verseRangeOnlyNumber)","verseRangeAbbreviated":"\(verseRangeAbbreviated)","text":"\(escapedFullText)","fullText":"\(escapedFullText)","osisRef":"\(osisRef)","v11n":"\(bookmark.v11n)","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"osisFragment":null,"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":\(editActionJSON)}
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
        let primaryLabelId = bookmark.primaryLabelId.map { "\"\($0.uuidString)\"" } ?? "null"
        let customIcon = bookmark.customIcon.map { "\"\($0)\"" } ?? "null"

        var labelIds = bookmark.bookmarkToLabels?.compactMap { $0.label?.id.uuidString } ?? []
        if labelIds.isEmpty { labelIds = [Self.unlabeledLabelId] }
        let labelsJSON = "[" + labelIds.map { "\"\($0)\"" }.joined(separator: ",") + "]"

        let btlJSON: String
        if let btls = bookmark.bookmarkToLabels, !btls.isEmpty {
            let items = btls.compactMap { btl -> String? in
                guard let labelId = btl.label?.id.uuidString else { return nil }
                return """
                {"type":"GenericBookmarkToLabel","bookmarkId":"\(id)","labelId":"\(labelId)","orderNumber":\(btl.orderNumber),"indentLevel":\(btl.indentLevel),"expandContent":\(btl.expandContent)}
                """
            }
            btlJSON = "[" + items.joined(separator: ",") + "]"
        } else {
            btlJSON = "[{\"type\":\"GenericBookmarkToLabel\",\"bookmarkId\":\"\(id)\",\"labelId\":\"\(Self.unlabeledLabelId)\",\"orderNumber\":0,\"indentLevel\":0,\"expandContent\":false}]"
        }

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

        return """
        {"id":"\(id)","type":"generic-bookmark","hashCode":\(hashCode),"ordinalRange":[\(bookmark.ordinalStart),\(bookmark.ordinalEnd)],"offsetRange":null,"bookInitials":"\(bookmark.bookInitials)","bookName":"\(bookmark.bookInitials)","bookAbbreviation":"","createdAt":\(createdAt),"lastUpdatedOn":\(lastUpdated),"notes":\(hasNote ? "\"\(escapedNote)\"" : "null"),"hasNote":\(hasNote),"text":"","fullText":"","key":"\(escapedKey)","keyName":"\(escapedKey)","highlightedText":"","labels":\(labelsJSON),"bookmarkToLabels":\(btlJSON),"primaryLabelId":\(primaryLabelId),"wholeVerse":\(bookmark.wholeVerse),"customIcon":\(customIcon),"editAction":\(editActionJSON)}
        """
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
        let btlsJSON = changedBibleBtls.map { buildBibleBookmarkToLabelJSON($0) }.joined(separator: ",")
        let gbtlsJSON = changedGenericBtls.map { buildGenericBookmarkToLabelJSON($0) }.joined(separator: ",")
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

    // MARK: - JSON Builders

    private func buildConfigJSON() -> String {
        let s = displaySettings
        let d = TextDisplaySettings.appDefaults
        let verseSelectionEnabled = s.enableVerseSelection ?? d.enableVerseSelection ?? true

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
        {"config":{"developmentMode":false,"testMode":false,"showAnnotations":true,"showChapterNumbers":true,"showVerseNumbers":\(s.showVerseNumbers ?? d.showVerseNumbers ?? true),"strongsMode":\(s.strongsMode ?? d.strongsMode ?? 0),"showMorphology":\(s.showMorphology ?? d.showMorphology ?? false),"showRedLetters":\(s.showRedLetters ?? d.showRedLetters ?? true),"showVersePerLine":\(s.showVersePerLine ?? d.showVersePerLine ?? false),"showNonCanonical":true,"makeNonCanonicalItalic":true,"showSectionTitles":\(s.showSectionTitles ?? d.showSectionTitles ?? true),"showStrongsSeparately":false,"showFootNotes":\(s.showFootNotes ?? d.showFootNotes ?? false),"showFootNotesInline":\(s.showFootNotesInline ?? d.showFootNotesInline ?? false),"showXrefs":\(s.showXrefs ?? d.showXrefs ?? false),"expandXrefs":\(s.expandXrefs ?? d.expandXrefs ?? false),"fontFamily":"\(s.fontFamily ?? d.fontFamily ?? "sans-serif")","fontSize":\(s.fontSize ?? d.fontSize ?? 18),"disableBookmarking":false,"showBookmarks":\(s.showBookmarks ?? d.showBookmarks ?? true),"showMyNotes":\(s.showMyNotes ?? d.showMyNotes ?? true),"bookmarksHideLabels":[],"bookmarksAssignLabels":[],"colors":{"dayBackground":\(s.dayBackground ?? d.dayBackground ?? -1),"dayNoise":\(s.dayNoise ?? d.dayNoise ?? 0),"nightBackground":\(s.nightBackground ?? d.nightBackground ?? -16777216),"nightNoise":\(s.nightNoise ?? d.nightNoise ?? 0),"dayTextColor":\(s.dayTextColor ?? d.dayTextColor ?? -16777216),"nightTextColor":\(s.nightTextColor ?? d.nightTextColor ?? -1)},"hyphenation":\(s.hyphenation ?? d.hyphenation ?? true),"lineSpacing":\(s.lineSpacing ?? d.lineSpacing ?? 10),"justifyText":\(s.justifyText ?? d.justifyText ?? false),"marginSize":{"marginLeft":\(s.marginLeft ?? d.marginLeft ?? 2),"marginRight":\(s.marginRight ?? d.marginRight ?? 2),"maxWidth":\(s.maxWidth ?? d.maxWidth ?? 600)},"topMargin":\(s.topMargin ?? d.topMargin ?? 0),"showPageNumber":\(s.showPageNumber ?? d.showPageNumber ?? false)},"appSettings":{"nightMode":\(nightMode),"errorBox":false,"favouriteLabels":\(favouriteJSON),"recentLabels":\(recentJSON),"studyPadCursors":\(cursorsJSON),"autoAssignLabels":\(autoAssignJSON),"hideCompareDocuments":\(hideCompareJSON),"activeWindow":\(verseSelectionEnabled),"rightToLeft":false,"actionMode":false,"hasActiveIndicator":false,"activeSince":\(Int(Date().timeIntervalSince1970 * 1000) - 1000),"limitAmbiguousModalSize":false,"windowId":"","disableBibleModalButtons":[],"disableGenericModalButtons":[],"monochromeMode":false,"disableAnimations":false,"disableClickToEdit":false,"fontSizeMultiplier":1.0,"enabledExperimentalFeatures":[]},"initial":false}
        """
    }

    private func buildChapterXML(osisBookId: String, bookName: String, chapter: Int, verseCount: Int) -> String {
        // For Genesis 1, use the real ESV-like content
        if osisBookId == "Gen" && chapter == 1 {
            return genesis1OSISXML()
        }

        // For other chapters, generate placeholder OSIS XML with verse structure
        var xml = "<div>"
        xml += "<title type=\"x-gen\">\(bookName) \(chapter)</title>"
        xml += "<div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv1\"/>"
        xml += "<div sID=\"sec1\" type=\"section\"/>"
        xml += "<title>\(bookName) \(chapter)</title>"
        xml += "<div sID=\"p1\" type=\"paragraph\"/>"
        xml += "<div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv1\"/>"

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

    private func buildDocumentJSON(osisBookId: String, bookName: String, chapter: Int, verseCount: Int, isNT: Bool, xml: String, bookmarks: [BibleBookmark] = [], bookCategory: String = "BIBLE", bookInitials: String? = nil) -> String {
        let escapedXml = xml
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")

        let key = "\(osisBookId).\(chapter)"
        let ordinalStart = (chapter - 1) * 40 + 1
        let ordinalEnd = (chapter - 1) * 40 + verseCount

        // Serialize bookmarks for this chapter
        let bookmarksJSON = bookmarks.isEmpty ? "[]" : "[" + bookmarks.map { buildBookmarkJSON($0) }.joined(separator: ",") + "]"

        let initials = bookInitials ?? activeModuleName

        return """
        {"id":"doc-1","type":"bible","osisFragment":{"xml":"\(escapedXml)","key":"\(key)","keyName":"\(bookName) \(chapter)","v11n":"KJVA","bookCategory":"\(bookCategory)","bookInitials":"\(initials)","bookAbbreviation":"\(osisBookId)","osisRef":"\(key)","isNewTestament":\(isNT),"features":{},"ordinalRange":[\(ordinalStart),\(ordinalEnd)],"language":"en","direction":"ltr"},"bookInitials":"\(initials)","bookCategory":"\(bookCategory)","bookAbbreviation":"\(osisBookId)","bookName":"\(bookName)","key":"\(key)","v11n":"KJVA","osisRef":"\(key)","annotateRef":"","genericBookmarks":[],"ordinalRange":[\(ordinalStart),\(ordinalEnd)],"isEpub":false,"bookmarks":\(bookmarksJSON),"bibleBookName":"\(bookName)","addChapter":true,"chapterNumber":\(chapter),"originalOrdinalRange":null}
        """
    }

    // MARK: - Genesis 1 Real Content

    private func genesis1OSISXML() -> String {
        "<div><title type=\"x-gen\">Genesis 1</title><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv1\"/><div sID=\"gen1\" type=\"section\"/><title>The Creation of the World</title><div sID=\"gen2\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv1\"/><verse osisID=\"Gen.1.1\" verseOrdinal=\"1\">In the beginning, God created the heavens and the earth. </verse><verse osisID=\"Gen.1.2\" verseOrdinal=\"2\">The earth was without form and void, and darkness was over the face of the deep. And the Spirit of God was hovering over the face of the waters. <div eID=\"gen2\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv2\"/><div sID=\"gen3\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv2\"/><verse osisID=\"Gen.1.3\" verseOrdinal=\"3\">And God said, \u{201C}Let there be light,\u{201D} and there was light. </verse><verse osisID=\"Gen.1.4\" verseOrdinal=\"4\">And God saw that the light was good. And God separated the light from the darkness. </verse><verse osisID=\"Gen.1.5\" verseOrdinal=\"5\">God called the light Day, and the darkness he called Night. And there was evening and there was morning, the first day. <div eID=\"gen3\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv3\"/><div sID=\"gen4\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv3\"/><verse osisID=\"Gen.1.6\" verseOrdinal=\"6\">And God said, \u{201C}Let there be an expanse in the midst of the waters, and let it separate the waters from the waters.\u{201D} </verse><verse osisID=\"Gen.1.7\" verseOrdinal=\"7\">And God made the expanse and separated the waters that were under the expanse from the waters that were above the expanse. And it was so. </verse><verse osisID=\"Gen.1.8\" verseOrdinal=\"8\">And God called the expanse Heaven. And there was evening and there was morning, the second day. <div eID=\"gen4\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv4\"/><div sID=\"gen5\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv4\"/><verse osisID=\"Gen.1.9\" verseOrdinal=\"9\">And God said, \u{201C}Let the waters under the heavens be gathered together into one place, and let the dry land appear.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.10\" verseOrdinal=\"10\">God called the dry land Earth, and the waters that were gathered together he called Seas. And God saw that it was good. </verse><verse osisID=\"Gen.1.11\" verseOrdinal=\"11\">And God said, \u{201C}Let the earth sprout vegetation, plants yielding seed, and fruit trees bearing fruit in which is their seed, each according to its kind, on the earth.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.12\" verseOrdinal=\"12\">The earth brought forth vegetation, plants yielding seed according to their own kinds, and trees bearing fruit in which is their seed, each according to its kind. And God saw that it was good. </verse><verse osisID=\"Gen.1.13\" verseOrdinal=\"13\">And there was evening and there was morning, the third day. <div eID=\"gen5\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv5\"/><div sID=\"gen6\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv5\"/><verse osisID=\"Gen.1.14\" verseOrdinal=\"14\">And God said, \u{201C}Let there be lights in the expanse of the heavens to separate the day from the night. And let them be for signs and for seasons, and for days and years, </verse><verse osisID=\"Gen.1.15\" verseOrdinal=\"15\">and let them be lights in the expanse of the heavens to give light upon the earth.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.16\" verseOrdinal=\"16\">And God made the two great lights\u{2014}the greater light to rule the day and the lesser light to rule the night\u{2014}and the stars. </verse><verse osisID=\"Gen.1.17\" verseOrdinal=\"17\">And God set them in the expanse of the heavens to give light on the earth, </verse><verse osisID=\"Gen.1.18\" verseOrdinal=\"18\">to rule over the day and over the night, and to separate the light from the darkness. And God saw that it was good. </verse><verse osisID=\"Gen.1.19\" verseOrdinal=\"19\">And there was evening and there was morning, the fourth day. <div eID=\"gen6\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv6\"/><div sID=\"gen7\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv6\"/><verse osisID=\"Gen.1.20\" verseOrdinal=\"20\">And God said, \u{201C}Let the waters swarm with swarms of living creatures, and let birds fly above the earth across the expanse of the heavens.\u{201D} </verse><verse osisID=\"Gen.1.21\" verseOrdinal=\"21\">So God created the great sea creatures and every living creature that moves, with which the waters swarm, according to their kinds, and every winged bird according to its kind. And God saw that it was good. </verse><verse osisID=\"Gen.1.22\" verseOrdinal=\"22\">And God blessed them, saying, \u{201C}Be fruitful and multiply and fill the waters in the seas, and let birds multiply on the earth.\u{201D} </verse><verse osisID=\"Gen.1.23\" verseOrdinal=\"23\">And there was evening and there was morning, the fifth day. <div eID=\"gen7\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv7\"/><div sID=\"gen8\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv7\"/><verse osisID=\"Gen.1.24\" verseOrdinal=\"24\">And God said, \u{201C}Let the earth bring forth living creatures according to their kinds\u{2014}livestock and creeping things and beasts of the earth according to their kinds.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.25\" verseOrdinal=\"25\">And God made the beasts of the earth according to their kinds and the livestock according to their kinds, and everything that creeps on the ground according to its kind. And God saw that it was good. <div eID=\"gen8\" type=\"paragraph\"/></verse><div type=\"x-milestone\" subType=\"x-preverse\" sID=\"pv8\"/><div sID=\"gen9\" type=\"paragraph\"/><div type=\"x-milestone\" subType=\"x-preverse\" eID=\"pv8\"/><verse osisID=\"Gen.1.26\" verseOrdinal=\"26\">Then God said, \u{201C}Let us make man in our image, after our likeness. And let them have dominion over the fish of the sea and over the birds of the heavens and over the livestock and over all the earth and over every creeping thing that creeps on the earth.\u{201D} </verse><verse osisID=\"Gen.1.27\" verseOrdinal=\"27\">So God created man in his own image, in the image of God he created him; male and female he created them. </verse><verse osisID=\"Gen.1.28\" verseOrdinal=\"28\">And God blessed them. And God said to them, \u{201C}Be fruitful and multiply and fill the earth and subdue it, and have dominion over the fish of the sea and over the birds of the heavens and over every living thing that moves on the earth.\u{201D} </verse><verse osisID=\"Gen.1.29\" verseOrdinal=\"29\">And God said, \u{201C}Behold, I have given you every plant yielding seed that is on the face of all the earth, and every tree with seed in its fruit. You shall have them for food. </verse><verse osisID=\"Gen.1.30\" verseOrdinal=\"30\">And to every beast of the earth and to every bird of the heavens and to everything that creeps on the earth, everything that has the breath of life, I have given every green plant for food.\u{201D} And it was so. </verse><verse osisID=\"Gen.1.31\" verseOrdinal=\"31\">And God saw everything that he had made, and behold, it was very good. And there was evening and there was morning, the sixth day. <div eID=\"gen9\" type=\"paragraph\"/></verse><div eID=\"gen1\" type=\"section\"/></div>"
    }

    // MARK: - Book Data

    /// Ordered list of all 66 Bible books.
    static let allBooks: [String] = [
        "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy",
        "Joshua", "Judges", "Ruth", "1 Samuel", "2 Samuel",
        "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles",
        "Ezra", "Nehemiah", "Esther", "Job", "Psalms",
        "Proverbs", "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah",
        "Lamentations", "Ezekiel", "Daniel", "Hosea", "Joel",
        "Amos", "Obadiah", "Jonah", "Micah", "Nahum",
        "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi",
        "Matthew", "Mark", "Luke", "John", "Acts",
        "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians",
        "Philippians", "Colossians", "1 Thessalonians", "2 Thessalonians",
        "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews",
        "James", "1 Peter", "2 Peter", "1 John", "2 John",
        "3 John", "Jude", "Revelation",
    ]

    /// Chapter counts for all 66 books.
    private static let chapterCounts: [String: Int] = [
        "Genesis": 50, "Exodus": 40, "Leviticus": 27, "Numbers": 36,
        "Deuteronomy": 34, "Joshua": 24, "Judges": 21, "Ruth": 4,
        "1 Samuel": 31, "2 Samuel": 24, "1 Kings": 22, "2 Kings": 25,
        "1 Chronicles": 29, "2 Chronicles": 36, "Ezra": 10, "Nehemiah": 13,
        "Esther": 10, "Job": 42, "Psalms": 150, "Proverbs": 31,
        "Ecclesiastes": 12, "Song of Solomon": 8, "Isaiah": 66,
        "Jeremiah": 52, "Lamentations": 5, "Ezekiel": 48, "Daniel": 12,
        "Hosea": 14, "Joel": 3, "Amos": 9, "Obadiah": 1, "Jonah": 4,
        "Micah": 7, "Nahum": 3, "Habakkuk": 3, "Zephaniah": 3,
        "Haggai": 2, "Zechariah": 14, "Malachi": 4,
        "Matthew": 28, "Mark": 16, "Luke": 24, "John": 21, "Acts": 28,
        "Romans": 16, "1 Corinthians": 16, "2 Corinthians": 13,
        "Galatians": 6, "Ephesians": 6, "Philippians": 4,
        "Colossians": 4, "1 Thessalonians": 5, "2 Thessalonians": 3,
        "1 Timothy": 6, "2 Timothy": 4, "Titus": 3, "Philemon": 1,
        "Hebrews": 13, "James": 5, "1 Peter": 5, "2 Peter": 3,
        "1 John": 5, "2 John": 1, "3 John": 1, "Jude": 1,
        "Revelation": 22,
    ]

    static func chapterCount(for book: String) -> Int {
        chapterCounts[book] ?? 1
    }

    static func nextBook(after book: String) -> String? {
        guard let index = allBooks.firstIndex(of: book), index + 1 < allBooks.count else { return nil }
        return allBooks[index + 1]
    }

    static func previousBook(before book: String) -> String? {
        guard let index = allBooks.firstIndex(of: book), index > 0 else { return nil }
        return allBooks[index - 1]
    }

    private static let osisBookIds: [String: String] = [
        "Genesis": "Gen", "Exodus": "Exod", "Leviticus": "Lev", "Numbers": "Num",
        "Deuteronomy": "Deut", "Joshua": "Josh", "Judges": "Judg", "Ruth": "Ruth",
        "1 Samuel": "1Sam", "2 Samuel": "2Sam", "1 Kings": "1Kgs", "2 Kings": "2Kgs",
        "1 Chronicles": "1Chr", "2 Chronicles": "2Chr", "Ezra": "Ezra", "Nehemiah": "Neh",
        "Esther": "Esth", "Job": "Job", "Psalms": "Ps", "Proverbs": "Prov",
        "Ecclesiastes": "Eccl", "Song of Solomon": "Song", "Isaiah": "Isa", "Jeremiah": "Jer",
        "Lamentations": "Lam", "Ezekiel": "Ezek", "Daniel": "Dan", "Hosea": "Hos",
        "Joel": "Joel", "Amos": "Amos", "Obadiah": "Obad", "Jonah": "Jonah",
        "Micah": "Mic", "Nahum": "Nah", "Habakkuk": "Hab", "Zephaniah": "Zeph",
        "Haggai": "Hag", "Zechariah": "Zech", "Malachi": "Mal",
        "Matthew": "Matt", "Mark": "Mark", "Luke": "Luke", "John": "John",
        "Acts": "Acts", "Romans": "Rom", "1 Corinthians": "1Cor", "2 Corinthians": "2Cor",
        "Galatians": "Gal", "Ephesians": "Eph", "Philippians": "Phil", "Colossians": "Col",
        "1 Thessalonians": "1Thess", "2 Thessalonians": "2Thess",
        "1 Timothy": "1Tim", "2 Timothy": "2Tim", "Titus": "Titus", "Philemon": "Phlm",
        "Hebrews": "Heb", "James": "Jas", "1 Peter": "1Pet", "2 Peter": "2Pet",
        "1 John": "1John", "2 John": "2John", "3 John": "3John",
        "Jude": "Jude", "Revelation": "Rev",
    ]

    private static let ntBooks: Set<String> = [
        "Matthew", "Mark", "Luke", "John", "Acts", "Romans",
        "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians",
        "Philippians", "Colossians", "1 Thessalonians", "2 Thessalonians",
        "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews",
        "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John",
        "Jude", "Revelation",
    ]

    static func osisBookId(for bookName: String) -> String {
        osisBookIds[bookName] ?? bookName.prefix(3).description
    }

    /// Reverse lookup: OSIS ID → book name. Used by HistoryView and BookmarkListView.
    static func bookName(forOsisId osisId: String) -> String? {
        osisBookIds.first(where: { $0.value == osisId })?.key
    }

    static func isNewTestament(_ bookName: String) -> Bool {
        ntBooks.contains(bookName)
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

/// A parsed OSIS reference.
struct OsisRef {
    let book: String
    let chapter: Int
    let verse: Int
    let osisId: String

    var displayName: String {
        "\(book) \(chapter):\(verse)"
    }
}

/// A cross-reference with its looked-up verse text.
public struct CrossReference: Identifiable {
    public let id = UUID()
    let ref: OsisRef
    let text: String

    var displayName: String { ref.displayName }
    var book: String { ref.book }
    var chapter: Int { ref.chapter }
}
