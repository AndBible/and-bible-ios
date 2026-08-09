// BibleReaderSQLiteSpeechDispatchCoordinator.swift -- SQLite speech presentation and routing

import BibleCore
import SwordKit

/**
 Presentation and synchronization seams for a SQLite Bible speech session.

 The coordinator owns DOM highlight scripts and callback ordering. The controller supplies only
 bridge evaluation, the live synchronize setting, and pane navigation state application.
 */
struct BibleReaderSQLiteBibleSpeechContext {
    /// Evaluates one DOM highlight/cleanup script in the pane's reader client.
    let evaluateJavaScript: (String) -> Void

    /// Reports the live advanced synchronize setting after each spoken position.
    let shouldSynchronize: () -> Bool

    /// Applies one source-owned visible Bible position to controller/navigation state.
    let synchronize: @MainActor (
        _ module: BibleReaderSQLiteModuleHandle,
        _ position: SpeakStreamPosition
    ) -> Void
}

/**
 Resolution and pane synchronization seams for SQLite commentary/dictionary speech.

 Module resolution must enforce genuine SWORD precedence. Synchronization receives exact source
 keys and performs only controller-owned category/navigation dispatch.
 */
struct BibleReaderSQLiteGenericSpeechContext {
    /// Resolves one stable SWORD-unshadowed SQLite handle by exact category.
    let resolveModule: (
        _ name: String,
        _ category: ModuleCategory
    ) -> BibleReaderSQLiteModuleHandle?

    /// Applies one exact commentary/dictionary key to controller state and visible content.
    let synchronize: @MainActor (
        _ module: BibleReaderSQLiteModuleHandle,
        _ category: SpeakDocumentCategory,
        _ key: String
    ) -> Void
}

/**
 Builds SQLite speech sessions with source-owned presentation and synchronization behavior.

 Provider construction remains in `SQLiteReaderSpeechSessionBuilder`; this coordinator selects the
 exact auxiliary category, owns DOM highlight scripts, and invokes controller seams only after the
 generation checks enforced by the builder callbacks. It never resolves or falls back to SWORD.
 */
struct BibleReaderSQLiteSpeechDispatchCoordinator {
    /**
     Builds or reconstructs one SQLite Bible/memorization session with pane presentation callbacks.

     - Parameters:
       - module: Immutable active/requested SQLite Bible.
       - category: Bible or memorization provider behavior.
       - sourceVersification: Canon owning new-session ordinal inputs.
       - startOrdinal: Exact start ordinal for a new session.
       - endOrdinal: Exact inclusive end ordinal when bounded.
       - checkpoint: Optional persisted cursor for reconstruction.
       - service: Live speech generation/settings owner.
       - context: DOM evaluation and controller synchronization seams.
     - Returns: Complete source-owned speech session, or nil when exact construction fails.
     - Side effects: Enumerates real source verses, emits DOM scripts during playback, and invokes
       pane synchronization only when enabled.
     - Failure modes: Invalid ranges/checkpoints and unreadable source rows fail without fallback.
     - Important: Every module read owns its SQLite connection and can overlap unrelated reads.
     */
    func bibleSession(
        module: BibleReaderSQLiteModuleHandle,
        category: SpeakDocumentCategory,
        sourceVersification: String,
        startOrdinal: Int?,
        endOrdinal: Int?,
        checkpoint: SpeakProviderCheckpoint?,
        service: SpeakService,
        context: BibleReaderSQLiteBibleSpeechContext
    ) -> SpeakSessionReconstruction? {
        SQLiteReaderSpeechSessionBuilder(module: module).bibleSession(
            category: category,
            sourceVersification: sourceVersification,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            checkpoint: checkpoint,
            service: service,
            positionChanged: { position in
                guard let ordinal = position.ordinalStart else { return }
                context.evaluateJavaScript(Self.highlightScript(ordinal: ordinal))
                if context.shouldSynchronize() {
                    context.synchronize(module, position)
                }
            },
            stopped: {
                // Android leaves no playback styling in the document, so stop needs no DOM cleanup.
            }
        )
    }

    /**
     Builds one ordered Daily Reading passage queue for an exact SQLite Bible handle.

     - Parameters:
       - module: Immutable active SQLite Bible that must supply every passage.
       - ranges: Independently mapped KJVA ranges in Android playback order.
       - service: Live speech generation/settings owner.
       - context: DOM evaluation and pane synchronization seams.
     - Returns: Complete source-owned passage-list session, or nil when any range fails atomically.
     - Side effects: Enumerates real source rows, emits DOM scripts during playback, and invokes pane
       synchronization only when enabled.
     - Failure modes: Invalid, unmappable, or empty ranges fail without partial speech or SWORD
       fallback; duplicate and discontiguous ranges retain their original order.
     */
    func biblePassageListSession(
        module: BibleReaderSQLiteModuleHandle,
        ranges: [SpeakVerseRange],
        service: SpeakService,
        context: BibleReaderSQLiteBibleSpeechContext
    ) -> SpeakSessionReconstruction? {
        SQLiteReaderSpeechSessionBuilder(module: module).biblePassageListSession(
            ranges: ranges,
            service: service,
            positionChanged: { position in
                guard let ordinal = position.ordinalStart else { return }
                context.evaluateJavaScript(Self.highlightScript(ordinal: ordinal))
                if context.shouldSynchronize() {
                    context.synchronize(module, position)
                }
            },
            stopped: {
                // Android leaves no playback styling in the document, so stop needs no DOM cleanup.
            }
        )
    }

    /**
     Builds or reconstructs one exact SQLite commentary/dictionary speech session.

     - Parameters mirror Android's generic source cursor plus expected category and pane context.
     - Returns: Source-owned session, or nil when SQLite does not uniquely own a matching category.
     - Side effects: Resolves stable catalog handles, performs operation-owned lazy reads, and
       invokes exact-key synchronization after builder generation checks.
     - Failure modes: SWORD-shadowed identities, category mismatches, malformed keys, and missing
       content fail closed without trying another backend.
     */
    func genericSession(
        bookInitials: String,
        key: String?,
        startOrdinal: Int?,
        endOrdinal: Int?,
        expectedCategory: SpeakDocumentCategory?,
        checkpoint: SpeakProviderCheckpoint?,
        service: SpeakService,
        context: BibleReaderSQLiteGenericSpeechContext
    ) -> SpeakSessionReconstruction? {
        let candidates: [(ModuleCategory, SpeakDocumentCategory)] = [
            (.commentary, .commentary),
            (.dictionary, .dictionary),
        ]
        guard let (module, category) = candidates.compactMap({ candidate in
            context.resolveModule(bookInitials, candidate.0).map { ($0, candidate.1) }
        }).first,
              expectedCategory == nil || expectedCategory == category else {
            return nil
        }
        return SQLiteReaderSpeechSessionBuilder(module: module).genericSession(
            category: category,
            key: key,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            checkpoint: checkpoint,
            service: service,
            synchronize: { sourceKey, _ in
                context.synchronize(module, category, sourceKey)
            }
        )
    }

    /**
     Builds the deterministic spoken-verse DOM highlight and centering script.

     - Parameter ordinal: Exact rendered KJVA verse ordinal to select.
     - Returns: Self-contained JavaScript that centers the matching `data-ordinal` element when
       present. Android tracks the spoken position by scrolling only, with no playback styling.
     - Side effects: None until the caller evaluates the returned script in the reader WebView.
     - Failure modes: The evaluated script exits without mutation when no matching verse exists.
     */
    private static func highlightScript(ordinal: Int) -> String {
        """
        (function() {
            var verse = document.querySelector('[data-ordinal="\(ordinal)"]');
            if (!verse) return;
            verse.scrollIntoView({behavior: 'smooth', block: 'center'});
        })();
        """
    }
}
