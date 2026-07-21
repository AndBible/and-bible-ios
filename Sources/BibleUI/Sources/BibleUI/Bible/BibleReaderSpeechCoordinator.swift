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
    /// Current one-based verse used by Android's default page Speak action.
    let currentVerse: Int
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
    /// Navigates the visible Bible page when Android's speech synchronization setting is enabled.
    let synchronizePosition: @MainActor (_ book: String, _ chapter: Int, _ ordinal: Int) -> Void
}

/** Context for one SWORD-backed commentary, dictionary, or general-book speech stream. */
struct BibleReaderGenericSpeechContext {
    /// Exact Android speech-provider category.
    let category: SpeakDocumentCategory
    /// SWORD module that owns the keyed stream.
    let module: SwordModule
    /// Current persisted key.
    let currentKey: String?
    /// Stable module initials.
    let moduleName: String
    /// User-visible module name.
    let displayName: String
    /// Display settings used while stripping SWORD markup.
    let displaySettings: TextDisplaySettings
    /// SWORD manager whose global markup options are temporarily suppressed.
    let swordManager: SwordManager?
    /// Resolves an Android-compatible ordinal for a key; the enumerated index is supplied as fallback context.
    let ordinalForKey: (_ key: String, _ index: Int) -> Int
    /// Navigates the source document when speech synchronization is enabled.
    let synchronizeKey: @MainActor (_ key: String, _ ordinal: Int) -> Void
}

/** One non-SWORD page used by My Documents and EPUB speech providers. */
struct BibleReaderSpeechPage {
    let key: String
    let title: String
    let plainText: String
    let rawMarkup: String
    let ordinalRange: ClosedRange<Int>
    let language: String
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
        let osisBookID = context.osisBookId(context.currentBook)
        guard let startOrdinal = context.module.verseOrdinal(
            osisBookId: osisBookID,
            chapter: context.currentChapter,
            verse: context.currentVerse
        ) else {
            return
        }
        speakBible(startOrdinal: startOrdinal, service: service, context: context)
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
        guard endOrdinal >= startOrdinal,
              let start = context.module.verseReference(ordinal: startOrdinal),
              let end = context.module.verseReference(ordinal: endOrdinal) else {
            return
        }
        let startOSIS = "\(start.osisBookId).\(start.chapter).\(start.verse)"
        let endOSIS = "\(end.osisBookId).\(end.chapter).\(end.verse)"
        let osisRef = startOSIS == endOSIS ? startOSIS : "\(startOSIS)-\(endOSIS)"
        guard let range = SpeakVerseRange(
            versification: VersificationMapper.versificationName(for: context.module),
            osisRef: osisRef
        ),
        let session = biblePassageListSession(
            ranges: [range],
            service: service,
            context: context
        ) else {
            return
        }
        service.currentTitle = session.title
        service.currentSubtitle = session.subtitle
        _ = service.start(provider: session.provider, callbacks: session.callbacks)
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
        guard endOrdinal >= startOrdinal else { return }
        _ = speakBibleRequest(
            SpeakSelectionRequest(
                category: .memorization,
                bookInitials: context.activeModuleName,
                key: "",
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                versification: VersificationMapper.versificationName(for: context.module)
            ),
            service: service,
            context: context
        )
    }

    /** Starts Android's unbounded Bible provider at one source-versification ordinal. */
    private func speakBible(
        startOrdinal: Int,
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) {
        _ = speakBibleRequest(
            SpeakSelectionRequest(
                category: .bible,
                bookInitials: context.activeModuleName,
                key: "",
                startOrdinal: startOrdinal,
                endOrdinal: startOrdinal,
                versification: VersificationMapper.versificationName(for: context.module)
            ),
            service: service,
            context: context
        )
    }

    /**
     Starts a typed Bible or memorization request using its requested module and source canon.

     - Parameters:
       - request: Exact Android bridge identity and source ordinals.
       - service: Provider-driven speech service.
       - context: Reader callbacks and SWORD display-option state.
     - Returns: `true` only when strict source resolution produced and started a provider.
     - Side effects: Starts speech, installs generation-scoped callbacks, and may temporarily toggle
       SWORD markup options while later units load.
     - Failure modes: Missing managers/modules, category mismatches, unknown versifications, mapping
       misses, and empty modules fail closed and are logged without using the active Bible.
     */
    @discardableResult
    func speakBibleRequest(
        _ request: SpeakSelectionRequest,
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) -> Bool {
        guard let session = bibleSession(request: request, service: service, context: context) else {
            return false
        }
        service.currentTitle = session.title
        service.currentSubtitle = session.subtitle
        return service.start(
            provider: session.provider,
            callbacks: session.callbacks
        ).succeeded
    }

    /**
     Builds a typed Bible-family session without starting synthesis.

     This is the shared construction boundary for direct bridge requests, stopped remote Play, and
     controller tests. The supplied module initials and source versification remain authoritative.

     - Parameters:
       - request: Exact Bible or memorization source identity and source ordinals.
       - service: Live settings and session-generation owner used by provider callbacks.
       - context: Reader SWORD manager, display settings, and synchronized-navigation callbacks.
     - Returns: A complete provider session, or `nil` when strict source resolution fails.
     - Side effects: Enumerates the requested module and creates callback closures; synthesis does not
       start until the caller passes the result to `SpeakService`.
     - Failure modes: Missing managers, modules, exact mappings, and addressable endpoints fail closed
       and are logged without substituting the active reader module.
     */
    func bibleSession(
        request: SpeakSelectionRequest,
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) -> SpeakSessionReconstruction? {
        guard let manager = context.swordManager else {
            speechLogger.error("Cannot build typed Bible speech without the installed-module manager")
            return nil
        }
        do {
            let build = try BibleReaderSpeechProviderFactory.bible(
                request: request,
                manager: manager,
                displaySettings: context.displaySettings,
                advancedSettings: service.advancedSettings
            )
            return SpeakSessionReconstruction(
                provider: build.provider,
                callbacks: bibleCallbacks(service: service, context: context),
                title: build.provider.currentPosition?.keyName,
                subtitle: build.module?.info.name ?? request.bookInitials
            )
        } catch {
            speechLogger.error("Typed Bible speech failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /**
     Starts Android's ordered bounded Bible key-list speech.

     - Parameters:
       - ranges: Source-versification ranges in exact playback order.
       - service: Provider-driven speech service.
       - context: Requested target Bible and reader callbacks.
     - Returns: `true` only when every range maps and the exact queue starts or appends to a
       generation whose first utterance was already accepted.
     - Side effects: Starts a new generation or appends after the remaining active passage queue.
       Queue append retains the current utterance, metadata, and generation-scoped callbacks.
     - Failure modes: Missing managers, any unmappable endpoint, or empty target content fails the
       whole request without starting a partial or widened queue.
     */
    @discardableResult
    func speakBiblePassageList(
        ranges: [SpeakVerseRange],
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) -> Bool {
        guard let session = biblePassageListSession(
            ranges: ranges,
            service: service,
            context: context
        ) else {
            return false
        }
        return service.start(
            provider: session.provider,
            callbacks: session.callbacks,
            queue: true
        ).succeeded
    }

    /**
     Builds a reconstructable bounded passage-list session without starting synthesis.

     - Parameters:
       - ranges: Exact target or source ranges in playback order.
       - service: Live speech settings and callback-generation owner.
       - context: Requested Bible module, manager, display settings, and reader callbacks.
     - Returns: Complete bounded session, or `nil` when any range cannot resolve.
     - Side effects: Enumerates target-module positions and creates lazy loader/callback closures;
       it does not start AVFoundation playback.
     - Failure modes: Missing managers, module identity mismatches, partial mappings, and empty
       passages fail the whole session without a fallback module or widened range.
     */
    func biblePassageListSession(
        ranges: [SpeakVerseRange],
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) -> SpeakSessionReconstruction? {
        guard let manager = context.swordManager else {
            speechLogger.error("Cannot build passage-list speech without the installed-module manager")
            return nil
        }
        do {
            let build = try BibleReaderSpeechProviderFactory.biblePassageList(
                bookInitials: context.module.info.name,
                ranges: ranges,
                manager: manager,
                displaySettings: context.displaySettings,
                advancedSettings: service.advancedSettings
            )
            return SpeakSessionReconstruction(
                provider: build.provider,
                callbacks: bibleCallbacks(service: service, context: context),
                title: build.provider.currentPosition?.keyName,
                subtitle: build.module?.info.name ?? context.module.info.name
            )
        } catch {
            speechLogger.error("Bible passage-list speech failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /**
     Speaks one SWORD-backed generic stream with exact key/ordinal bounds.

     - Parameters describe the category-validated source, exact Android cursor, and live service.
     - Returns: `true` only when the requested key and ordinal range resolve without snapping.
     - Side effects: Replaces active synthesis and installs generation-scoped source navigation.
     - Failure modes: Category, key, or ordinal mismatches fail closed without using Bible routing.
     */
    @discardableResult
    func speakGenericModule(
        service: SpeakService,
        context: BibleReaderGenericSpeechContext,
        requestedKey: String? = nil,
        startOrdinal: Int? = nil,
        endKey: String? = nil,
        endOrdinal: Int? = nil
    ) -> Bool {
        guard let session = genericModuleSession(
            service: service,
            context: context,
            requestedKey: requestedKey,
            startOrdinal: startOrdinal,
            endKey: endKey,
            endOrdinal: endOrdinal
        ) else {
            return false
        }
        service.currentTitle = session.title
        service.currentSubtitle = session.subtitle
        return service.start(
            provider: session.provider,
            callbacks: session.callbacks
        ).succeeded
    }

    /**
     Builds one exact SWORD-generic session without starting synthesis.

     - Parameters describe the category-validated source, exact Android cursor, and live service.
     - Returns: A complete source session, or `nil` when exact cursor resolution fails.
     - Side effects: Enumerates source keys and captures generation-scoped navigation callbacks.
     - Failure modes: Category mismatches, missing keys, and unaddressable ordinals fail closed.
     */
    func genericModuleSession(
        service: SpeakService,
        context: BibleReaderGenericSpeechContext,
        requestedKey: String? = nil,
        startOrdinal: Int? = nil,
        endKey: String? = nil,
        endOrdinal: Int? = nil
    ) -> SpeakSessionReconstruction? {
        let normalizedStart = startOrdinal.flatMap { $0 >= 0 ? $0 : nil }
        let normalizedEnd = endOrdinal.flatMap { $0 >= 0 ? $0 : nil }
        guard let build = BibleReaderSpeechProviderFactory.genericModule(
            context: context,
            requestedKey: requestedKey,
            startOrdinal: normalizedStart,
            endKey: endKey,
            endOrdinal: normalizedEnd
        ) else {
            speechLogger.error("Generic speech source could not resolve an exact key/ordinal cursor")
            return nil
        }
        return SpeakSessionReconstruction(
            provider: build.provider,
            callbacks: genericCallbacks(service: service, synchronize: context.synchronizeKey),
            title: build.provider.currentPosition?.keyName,
            subtitle: context.displayName
        )
    }

    /** Speaks My Documents or EPUB pages with category-specific generic providers. */
    @discardableResult
    func speakPages(
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        pages: [BibleReaderSpeechPage],
        currentKey: String?,
        service: SpeakService,
        startOrdinal: Int? = nil,
        endKey: String? = nil,
        endOrdinal: Int? = nil,
        synchronize: @escaping @MainActor (_ key: String, _ ordinal: Int) -> Void
    ) -> Bool {
        guard let session = pageSession(
            category: category,
            bookInitials: bookInitials,
            bookName: bookName,
            pages: pages,
            currentKey: currentKey,
            service: service,
            startOrdinal: startOrdinal,
            endKey: endKey,
            endOrdinal: endOrdinal,
            synchronize: synchronize
        ) else {
            return false
        }
        service.currentTitle = session.title
        service.currentSubtitle = session.subtitle
        return service.start(
            provider: session.provider,
            callbacks: session.callbacks
        ).succeeded
    }

    /**
     Builds one exact My Documents or EPUB session without starting synthesis.

     - Parameters describe the typed page source, exact Android cursor, live service, and navigation.
     - Returns: A complete source session, or `nil` when page-local cursor resolution fails.
     - Side effects: Projects page anchors and captures generation-scoped navigation callbacks.
     - Failure modes: Wrong categories, duplicate/missing keys, and missing BVA anchors fail closed.
     */
    func pageSession(
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        pages: [BibleReaderSpeechPage],
        currentKey: String?,
        service: SpeakService,
        startOrdinal: Int? = nil,
        endKey: String? = nil,
        endOrdinal: Int? = nil,
        synchronize: @escaping @MainActor (_ key: String, _ ordinal: Int) -> Void
    ) -> SpeakSessionReconstruction? {
        let normalizedStart = startOrdinal.flatMap { $0 >= 0 ? $0 : nil }
        let normalizedEnd = endOrdinal.flatMap { $0 >= 0 ? $0 : nil }
        guard let build = BibleReaderSpeechProviderFactory.pages(
            category: category,
            bookInitials: bookInitials,
            bookName: bookName,
            pages: pages,
            currentKey: currentKey,
            startOrdinal: normalizedStart,
            endKey: endKey,
            endOrdinal: normalizedEnd
        ) else {
            speechLogger.error("Page speech source could not resolve an exact key/ordinal cursor")
            return nil
        }
        return SpeakSessionReconstruction(
            provider: build.provider,
            callbacks: genericCallbacks(service: service, synchronize: synchronize),
            title: build.provider.currentPosition?.keyName,
            subtitle: bookName
        )
    }

    /**
     Reconstructs an exact Bible-family session with generation-scoped reader callbacks.

     - Parameters:
       - checkpoint: Persisted requested module, target versification, position, and bounds.
       - service: Live service supplying advanced settings and generation validation.
       - context: Reader SWORD manager, display settings, highlights, and synchronization callbacks.
     - Returns: Complete provider/callback metadata, or `nil` when strict reconstruction fails.
     - Side effects: Enumerates the requested module and logs strict resolution failures.
     - Failure modes: Missing managers, modules, mappings, or exact cursors fail closed.
     */
    func reconstructBibleSession(
        checkpoint: SpeakProviderCheckpoint,
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) -> SpeakSessionReconstruction? {
        guard let manager = context.swordManager else { return nil }
        do {
            let build = try BibleReaderSpeechProviderFactory.bible(
                checkpoint: checkpoint,
                manager: manager,
                displaySettings: context.displaySettings,
                advancedSettings: service.advancedSettings
            )
            return SpeakSessionReconstruction(
                provider: build.provider,
                callbacks: bibleCallbacks(service: service, context: context),
                title: build.provider.currentPosition?.keyName,
                subtitle: build.module?.info.name ?? checkpoint.current.bookInitials
            )
        } catch {
            speechLogger.error(
                "Bible speech reconstruction failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /**
     Reconstructs one SWORD generic session at its exact key and local ordinal bounds.

     - Parameters describe the persisted checkpoint, live service, category-matched source, and
       source navigation callback.
     - Returns: Complete session reconstruction, or `nil` for source/cursor mismatches.
     - Side effects: Loads only checkpoint-addressed SWORD keys.
     - Failure modes: Wrong categories/modules, snapped keys, and missing BVA anchors fail closed.
     */
    func reconstructGenericModuleSession(
        checkpoint: SpeakProviderCheckpoint,
        service: SpeakService,
        context: BibleReaderGenericSpeechContext
    ) -> SpeakSessionReconstruction? {
        guard let build = BibleReaderSpeechProviderFactory.genericModule(
            context: context,
            checkpoint: checkpoint
        ) else {
            return nil
        }
        return SpeakSessionReconstruction(
            provider: build.provider,
            callbacks: genericCallbacks(service: service, synchronize: context.synchronizeKey),
            title: build.provider.currentPosition?.keyName,
            subtitle: context.displayName
        )
    }

    /**
     Reconstructs one EPUB or My Documents session at exact page-local ordinal bounds.

     - Parameters describe the persisted checkpoint, source pages, live service, and navigation.
     - Returns: Complete session reconstruction, or `nil` when page identity no longer matches.
     - Side effects: Parses only checkpoint-addressed page markup during construction.
     - Failure modes: Category, initials, key, ordinal, or structured-anchor drift fails closed.
     */
    func reconstructPageSession(
        checkpoint: SpeakProviderCheckpoint,
        category: SpeakDocumentCategory,
        bookInitials: String,
        bookName: String,
        pages: [BibleReaderSpeechPage],
        service: SpeakService,
        synchronize: @escaping @MainActor (_ key: String, _ ordinal: Int) -> Void
    ) -> SpeakSessionReconstruction? {
        guard let build = BibleReaderSpeechProviderFactory.pages(
            category: category,
            bookInitials: bookInitials,
            bookName: bookName,
            pages: pages,
            checkpoint: checkpoint
        ) else {
            return nil
        }
        return SpeakSessionReconstruction(
            provider: build.provider,
            callbacks: genericCallbacks(service: service, synchronize: synchronize),
            title: build.provider.currentPosition?.keyName,
            subtitle: bookName
        )
    }

    /** Builds generation-scoped Bible highlighting and synchronized-navigation callbacks. */
    private func bibleCallbacks(
        service: SpeakService,
        context: BibleReaderSpeechContext
    ) -> SpeakSessionCallbacks {
        currentHighlightedOrdinal = nil
        return SpeakSessionCallbacks(
            onPositionChanged: { [weak self, weak service] position, generation in
                guard let ordinal = position.ordinalStart else { return }
                Task { @MainActor in
                    guard service?.isCurrentSession(generation) == true else { return }
                    self?.highlightVerseNow(
                        ordinal,
                        evaluateJavaScript: context.evaluateJavaScript
                    )
                    if service?.advancedSettings.synchronize == true,
                       let chapter = position.chapter {
                        context.synchronizePosition(position.bookName, chapter, ordinal)
                    }
                }
            },
            onStopped: { [weak self, weak service] generation in
                Task { @MainActor in
                    guard service?.mayApplyStoppedSessionCleanup(generation) == true else { return }
                    self?.clearSpeakHighlightNow(
                        evaluateJavaScript: context.evaluateJavaScript
                    )
                }
            }
        )
    }

    /** Builds generation-scoped generic key/ordinal synchronization callbacks. */
    private func genericCallbacks(
        service: SpeakService,
        synchronize: @escaping @MainActor (_ key: String, _ ordinal: Int) -> Void
    ) -> SpeakSessionCallbacks {
        SpeakSessionCallbacks(onPositionChanged: { [weak service] position, generation in
            guard let ordinal = position.ordinalStart else { return }
            Task { @MainActor in
                guard service?.isCurrentSession(generation) == true else { return }
                if service?.advancedSettings.synchronize == true {
                    synchronize(position.key, ordinal)
                }
            }
        })
    }

    /** Highlights one provider-owned Bible verse after the caller validates session generation. */
    private func highlightVerseNow(
        _ ordinal: Int,
        evaluateJavaScript: @escaping (String) -> Void
    ) {
        currentHighlightedOrdinal = ordinal
        let js = """
        (function() {
            var oldVerse = document.querySelector('.speaking-verse');
            if (oldVerse) oldVerse.classList.remove('speaking-verse');
            var verse = document.querySelector('[data-ordinal="\(ordinal)"]');
            if (!verse) return;
            verse.classList.add('speaking-verse');
            verse.scrollIntoView({behavior: 'smooth', block: 'center'});
        })();
        """
        evaluateJavaScript(js)
    }

    /**
     Clears speech highlights from the reader web view.

     - Parameter evaluateJavaScript: Closure used to run DOM cleanup in the reader web view.
     - Side effects: Resets the current highlighted ordinal and removes the active word/verse
       highlight DOM state. The caller owns main-actor and session-generation validation.
     */
    private func clearSpeakHighlightNow(evaluateJavaScript: @escaping (String) -> Void) {
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
        evaluateJavaScript(js)
    }
}
