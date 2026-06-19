// BibleReaderSpeechCoordinator.swift - Speech payload and reader highlight coordination

import Foundation
import BibleCore
import SwordKit
import os.log

private let speechLogger = Logger(subsystem: "org.andbible", category: "BibleReaderSpeechCoordinator")

/**
 Context required to build and play reader speech without coupling the speech coordinator to
 `BibleReaderController`'s full mutable state.

 The controller owns the current reader/module state and supplies this value at each speech entry
 point. The coordinator uses the closures only while building payloads and evaluating highlight
 JavaScript; it does not retain the controller or mutate reader navigation state directly.
 */
struct BibleReaderSpeechContext {
    /// Active SWORD module used to extract plain verse text.
    let module: SwordModule
    /// Active SWORD manager whose markup options may need temporary suppression for clean TTS.
    let swordManager: SwordManager?
    /// Current human-readable book name used in speech metadata.
    let currentBook: String
    /// Current one-based chapter number used for SWORD key positioning.
    let currentChapter: Int
    /// Active module initials/name used in speech metadata.
    let activeModuleName: String
    /// Display settings used to infer which global SWORD options are currently enabled.
    let displaySettings: TextDisplaySettings
    /// Resolves the current book to the active module's OSIS identifier.
    let osisBookId: (String) -> String
    /// Parses SWORD's current key string into book, chapter, and verse components.
    let parseVerseKey: (String) -> (String, Int, Int)?
    /// Resolves verse ordinals through the active module's versification.
    let verseOrdinal: (String, Int, Int) -> Int?
    /// Evaluates JavaScript in the reader web view, usually on the main queue.
    let evaluateJavaScript: (String) -> Void
}

/**
 Builds reader text-to-speech payloads and owns transient word-highlight state.

 `BibleReaderController` is responsible for bridge delegate routing and current reader state. This
 collaborator owns the speech-specific responsibility: extracting clean SWORD text, temporarily
 disabling markup options that pollute `stripText()`, mapping speech offsets back to verse ordinals,
 and emitting highlight JavaScript as `SpeakService` reports spoken words.

 Side effects:
 - mutates only speech-highlight state local to this coordinator
 - temporarily toggles SWORD global Strong's/morphology options while extracting plain text
 - configures callbacks on `SpeakService`
 - evaluates JavaScript in the reader web view through the supplied closure

 Failure modes:
 - returns without starting speech when required module text cannot be resolved
 - may speak unhighlighted partial text if verse ordinal resolution stops before the chapter ends
 - restores temporarily disabled SWORD options with `defer` before returning from extraction paths
 */
final class BibleReaderSpeechCoordinator {
    private struct VerseSpeechOffset {
        let ordinal: Int
        let startOffset: Int
        let endOffset: Int
    }

    private struct VerseRangeSpeechPayload {
        let text: String
        let language: String
    }

    /// Verse-to-character-offset mapping for the active TTS utterance.
    private var speakVerseOffsets: [VerseSpeechOffset] = []
    /// Currently highlighted verse ordinal during TTS.
    private var currentHighlightedOrdinal: Int?

    /**
     Speaks the current chapter using TTS and wires word-level highlighting.

     - Parameters:
       - service: Speech service that owns AVFoundation playback and word callbacks.
       - context: Current reader/module state needed to build text and emit highlights.
     - Side effects: Updates speech service metadata and callbacks, mutates highlight offset state,
       temporarily toggles SWORD markup options, and starts playback.
     - Failure modes: Returns without speaking when the chapter cannot produce non-empty speech text;
       if ordinal resolution stops early, any already extracted text can still be spoken without
       later verse highlights.
     */
    func speakCurrentChapter(service: SpeakService, context: BibleReaderSpeechContext) {
        let osisBookId = context.osisBookId(context.currentBook)
        let chapter = context.currentChapter

        service.currentTitle = "\(context.currentBook) \(context.currentChapter)"
        service.currentSubtitle = context.activeModuleName

        let payload = buildChapterSpeechPayload(
            context: context,
            osisBookId: osisBookId,
            chapter: chapter
        )
        guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        speakVerseOffsets = payload.offsets
        currentHighlightedOrdinal = nil

        let evaluateJavaScript = context.evaluateJavaScript
        service.onWordSpoken = { [weak self] word, range in
            self?.handleWordSpoken(word: word, range: range, evaluateJavaScript: evaluateJavaScript)
        }
        service.onSpeechStopped = { [weak self] in
            self?.clearSpeakHighlight(evaluateJavaScript: evaluateJavaScript)
        }

        service.speak(text: payload.text, language: speechLanguage(for: context.module))
    }

    /**
     Speaks a selected verse range once.

     - Parameters:
       - startOrdinal: First verse ordinal included in the range.
       - endOrdinal: Last verse ordinal included in the range.
       - service: Speech service that owns playback.
       - context: Current reader/module state needed to build the range payload.
     - Side effects: Updates speech service metadata, temporarily toggles SWORD markup options, and
       starts playback when text exists.
     - Failure modes: Returns without speaking when the ordinal range produces no plain text.
     */
    func speakVerseRange(
        startOrdinal: Int,
        endOrdinal: Int,
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) {
        guard let payload = speechPayloadForVerseRange(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            context: context
        ) else {
            return
        }

        service.currentTitle = "\(context.currentBook) \(context.currentChapter)"
        service.currentSubtitle = context.activeModuleName
        service.speak(text: payload.text, language: payload.language)
    }

    /**
     Speaks a selected verse range repeatedly for Android memorization-loop parity.

     - Parameters:
       - startOrdinal: First verse ordinal included in the memorization range.
       - endOrdinal: Last verse ordinal included in the memorization range.
       - service: Speech service that owns playback.
       - context: Current reader/module state needed to build the range payload.
     - Side effects: Updates speech service metadata, temporarily toggles SWORD markup options, and
       starts memorization-loop playback when text exists.
     - Failure modes: Returns without speaking when the ordinal range produces no plain text.
     */
    func speakMemorizationLoopRange(
        startOrdinal: Int,
        endOrdinal: Int,
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) {
        guard let payload = speechPayloadForVerseRange(
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            context: context
        ) else {
            return
        }

        service.currentTitle = "\(context.currentBook) \(context.currentChapter)"
        service.currentSubtitle = context.activeModuleName
        service.speakMemorizationLoop(text: payload.text, language: payload.language)
    }

    private func buildChapterSpeechPayload(
        context: BibleReaderSpeechContext,
        osisBookId: String,
        chapter: Int
    ) -> (text: String, offsets: [VerseSpeechOffset]) {
        withMarkupOptionsTemporarilyDisabled(context: context) {
            context.module.setKey("\(osisBookId) \(chapter):1")
            let preamble = "\(context.currentBook) chapter \(chapter). "
            var text = preamble
            var offsets: [VerseSpeechOffset] = []

            while true {
                let key = context.module.currentKey()
                guard let (_, parsedChapter, parsedVerse) = context.parseVerseKey(key) else { break }
                if parsedChapter != chapter { break }

                let verseText = context.module.stripText()
                if !verseText.isEmpty {
                    let trimmed = verseText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                    let startOffset = text.utf16.count
                    text += trimmed
                    let endOffset = text.utf16.count
                    guard let ordinal = context.verseOrdinal(osisBookId, chapter, parsedVerse) else {
                        break
                    }
                    offsets.append(
                        VerseSpeechOffset(
                            ordinal: ordinal,
                            startOffset: startOffset,
                            endOffset: endOffset
                        )
                    )
                }
                if !context.module.next() { break }
            }

            return (text, offsets)
        }
    }

    /**
     Builds clean plain text for an ordinal range using the active module's versification.

     The range comes from Android-style bridge messages as verse ordinals. Text extraction mirrors
     full-chapter speech by suppressing Strong's/morphology markup before calling `stripText()`.
     */
    private func speechPayloadForVerseRange(
        startOrdinal: Int,
        endOrdinal: Int,
        context: BibleReaderSpeechContext
    ) -> VerseRangeSpeechPayload? {
        let osisBookId = context.osisBookId(context.currentBook)
        let chapter = context.currentChapter

        let text = withMarkupOptionsTemporarilyDisabled(context: context) {
            context.module.setKey("\(osisBookId) \(chapter):1")
            var text = ""

            while true {
                let key = context.module.currentKey()
                guard let (_, parsedChapter, parsedVerse) = context.parseVerseKey(key) else { break }
                if parsedChapter != chapter { break }

                guard let ordinal = context.verseOrdinal(osisBookId, chapter, parsedVerse) else {
                    break
                }
                if ordinal >= startOrdinal && ordinal <= endOrdinal {
                    let verseText = context.module.stripText()
                    if !verseText.isEmpty {
                        text += verseText.trimmingCharacters(in: .whitespacesAndNewlines) + " "
                    }
                }
                if ordinal > endOrdinal { break }
                if !context.module.next() { break }
            }

            return text
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        return VerseRangeSpeechPayload(text: trimmedText, language: speechLanguage(for: context.module))
    }

    /**
     Runs SWORD plain-text extraction with Strong's and morphology options temporarily suppressed.

     `stripText()` includes markup tokens when those global options are enabled. Android/JSword
     speaks plain scripture text, so iOS disables only the currently enabled markup options while
     extracting TTS payloads and restores them before returning.
     */
    private func withMarkupOptionsTemporarilyDisabled<Result>(
        context: BibleReaderSpeechContext,
        _ operation: () -> Result
    ) -> Result {
        let strongsWasOn = (context.displaySettings.strongsMode ?? 0) > 0
        let morphWasOn = context.displaySettings.showMorphology ?? false
        if strongsWasOn { context.swordManager?.setGlobalOption(.strongsNumbers, enabled: false) }
        if morphWasOn { context.swordManager?.setGlobalOption(.morphology, enabled: false) }
        defer {
            if strongsWasOn { context.swordManager?.setGlobalOption(.strongsNumbers, enabled: true) }
            if morphWasOn { context.swordManager?.setGlobalOption(.morphology, enabled: true) }
        }
        return operation()
    }

    private func speechLanguage(for module: SwordModule) -> String {
        let lang = module.info.language
        return lang.hasPrefix("en") ? "en-US" : lang
    }

    /**
     Handles a word callback from `SpeakService` by highlighting the owning verse and word.

     - Parameters:
       - word: Spoken word reported by AVFoundation.
       - range: UTF-16 range of the word in the full utterance.
       - evaluateJavaScript: Closure used to run DOM mutations in the reader web view.
     - Side effects: Updates current highlighted ordinal and asks the web view to mutate highlight
       spans/classes on the main queue.
     - Failure modes: Returns silently when the word offset cannot be mapped to a verse.
     */
    private func handleWordSpoken(
        word: String,
        range: NSRange,
        evaluateJavaScript: @escaping (String) -> Void
    ) {
        let charOffset = range.location
        speechLogger.debug("handleWordSpoken: '\(word)' offset=\(charOffset)")

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

        let escapedWord = word
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        let scrollNeeded = ordinal != currentHighlightedOrdinal
        currentHighlightedOrdinal = ordinal

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
        DispatchQueue.main.async {
            evaluateJavaScript(js)
        }
    }

    /**
     Clears speech highlights from the reader web view.

     - Parameter evaluateJavaScript: Closure used to run DOM cleanup in the reader web view.
     - Side effects: Resets the current highlighted ordinal and removes the active word/verse
       highlight DOM state on the main queue.
     */
    private func clearSpeakHighlight(evaluateJavaScript: @escaping (String) -> Void) {
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
        DispatchQueue.main.async {
            evaluateJavaScript(js)
        }
    }
}
