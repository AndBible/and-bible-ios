import Foundation
import BibleCore
import BibleView

/**
 Coordinates Android-compatible reading-progress and memorization bridge actions for one reader.

 Android exposes memorization and reading-progress mutations from `BibleJavascriptInterface` and
 delegates persistence to `ProgressControl`. iOS mirrors that boundary by keeping the public
 `BibleBridgeDelegate` methods on `BibleReaderController` while moving the store mutation,
 chapter-read event emission, settings refresh, and native presentation handoff into this focused
 coordinator.

 Inputs:
 - bridge callback payloads from the shared BibleView JavaScript runtime
 - local `ReadingProgressStore` and `MemorizationProgressStore` suppliers
 - resolver closure that validates the active Bible chapter and maps it to JSword/KJVA book ordinal
 - native presentation callbacks for reading progress, settings, and chapter read history

 Outputs:
 - persisted local memorization target and memorized-verse state
 - persisted local chapter-read history and reading-progress settings
 - BibleView events matching the shared Android client event names
 - native iOS presentation callbacks for progress screens

 Side effects:
 - mutates `SettingsStore`-backed progress stores
 - emits JavaScript bridge events through the injected `BibleBridge`
 - invokes native UI callbacks supplied by the owning reader

 Failure modes:
 - missing stores, invalid active chapter targets, malformed JSON settings, or invalid verse ranges
   return without side effects, matching Android's bridge guards around missing books/versifications
 */
struct BibleReaderProgressBridgeCoordinator {
    /// Resolved chapter identity used by Android-compatible reading-progress persistence.
    struct ReadingProgressBridgeTarget {
        /// JSword/KJVA `BibleBook.ordinal` persisted by Android progress rows.
        let kjvBookOrdinal: Int
        /// Human-readable book name used by native iOS read-history presentation.
        let bookName: String
    }

    /// Supplies the active memorization store.
    private let memorizationStore: () -> MemorizationProgressStore?
    /// Supplies the active reading-progress store.
    private let readingStore: () -> ReadingProgressStore?
    /// Resolves and validates a bridge chapter target against the current reader document.
    private let resolveReadingTarget: (String, Int, Int) -> ReadingProgressBridgeTarget?
    /// Opens the bundled Memorize Vue document for a selected verse range.
    private let loadMemorizeDocument: (String, Int, Int) -> Void
    /// Presents the native reading-progress UI using Android tab indexes.
    private let showReadingProgress: (Int) -> Void
    /// Presents native reading-progress settings.
    private let showReadingProgressSettings: () -> Void
    /// Presents native read-history UI for one chapter.
    private let showChapterReadHistory: (ChapterReadHistoryTarget) -> Void
    /// Emits a JavaScript bridge event to BibleView.
    private let emitEvent: (String, String) -> Void
    /// Builds the current reader config JSON for `set_config` refreshes.
    private let buildConfigJSON: () -> String

    /**
     Creates a progress bridge coordinator bound to reader-owned stores and callbacks.

     - Parameters:
       - memorizationStore: Supplier for local memorization persistence.
       - readingStore: Supplier for local reading-progress persistence.
       - resolveReadingTarget: Closure that validates bridge chapter identity and returns KJVA data.
       - loadMemorizeDocument: Closure opening the Memorize document for a selected range.
       - showReadingProgress: Native progress UI callback.
       - showReadingProgressSettings: Native settings UI callback.
       - showChapterReadHistory: Native read-history UI callback.
       - emit: BibleView event emitter.
       - buildConfigJSON: Config payload builder for settings changes.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        memorizationStore: @escaping () -> MemorizationProgressStore?,
        readingStore: @escaping () -> ReadingProgressStore?,
        resolveReadingTarget: @escaping (String, Int, Int) -> ReadingProgressBridgeTarget?,
        loadMemorizeDocument: @escaping (String, Int, Int) -> Void,
        showReadingProgress: @escaping (Int) -> Void,
        showReadingProgressSettings: @escaping () -> Void,
        showChapterReadHistory: @escaping (ChapterReadHistoryTarget) -> Void,
        emit: @escaping (String, String) -> Void,
        buildConfigJSON: @escaping () -> String
    ) {
        self.memorizationStore = memorizationStore
        self.readingStore = readingStore
        self.resolveReadingTarget = resolveReadingTarget
        self.loadMemorizeDocument = loadMemorizeDocument
        self.showReadingProgress = showReadingProgress
        self.showReadingProgressSettings = showReadingProgressSettings
        self.showChapterReadHistory = showChapterReadHistory
        self.emitEvent = emit
        self.buildConfigJSON = buildConfigJSON
    }

    /// Adds the selected verse range as a memorization target and opens the Memorize document.
    func memorize(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationStore()?.addMemorizationTargetIfNeeded(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
        loadMemorizeDocument(bookInitials, startOrdinal, endOrdinal)
    }

    /// Marks the selected verse range as memorized in local iOS progress state.
    func markAsMemorized(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationStore()?.markAsMemorized(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Adds the selected verse range to local memorization targets.
    func addMemorizationTarget(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationStore()?.addMemorizationTarget(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Removes the selected verse range from local memorization targets.
    func removeMemorizationTarget(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationStore()?.removeMemorizationTarget(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Removes the selected verse range from local memorized ranges.
    func unmarkMemorized(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        memorizationStore()?.unmarkMemorized(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Records one chapter-read history row and emits the new chapter-read count to BibleView.
    func recordChapterRead(bookInitials: String, startOrdinal: Int, chapter: Int, source: String) {
        guard let store = readingStore(),
              let target = resolveReadingTarget(bookInitials, startOrdinal, chapter) else {
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

    /// Opens native chapter-read history for the active Bible chapter identity.
    func openChapterReadHistory(bookInitials: String, startOrdinal: Int, chapter: Int) {
        guard readingStore() != nil,
              let target = resolveReadingTarget(bookInitials, startOrdinal, chapter) else {
            return
        }
        showChapterReadHistory(
            ChapterReadHistoryTarget(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                kjvBookOrdinal: target.kjvBookOrdinal,
                bookName: target.bookName,
                chapter: chapter
            )
        )
    }

    /// Opens native reading-progress UI using Android's numeric tab positions.
    func openReadingProgress(tab: Int) {
        showReadingProgress(tab)
    }

    /// Opens native reading-progress settings UI.
    func openReadingProgressSettings() {
        showReadingProgressSettings()
    }

    /// Persists Android-compatible reading-progress settings and notifies the embedded client.
    func setReadingProgressSettings(json: String) {
        guard readingStore()?.applySettingsBundle(json: json) == true else {
            return
        }
        emitReadingProgressSettings()
        emit(event: "set_config", data: buildConfigJSON())
    }

    /// Clears chapter-read status for the active reading-progress cycle and emits the new count.
    func unmarkChapterRead(bookInitials: String, startOrdinal: Int, chapter: Int) {
        guard let store = readingStore(),
              let target = resolveReadingTarget(bookInitials, startOrdinal, chapter) else {
            return
        }
        let count = store.clearChapterReadStatus(kjvBookOrdinal: target.kjvBookOrdinal, chapter: chapter)
        emitChapterReadStatus(chapter: chapter, count: count)
    }

    /// Builds the reading-progress settings object embedded in Memorize document payloads.
    func readingProgressSettingsPayload() -> [String: Any] {
        let bundle = readingStore()?.settingsBundle() ?? ReadingProgressSettingsBundle()
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
     Saves native reading-progress settings and refreshes Vue-side settings/config payloads.

     - Parameter settings: Complete native settings snapshot from the SwiftUI settings view.
     - Returns: Saved normalized settings, or `nil` when no reading-progress store is configured.
     - Side effects: Persists settings JSON, emits `update_reading_progress_settings`, and refreshes
       `set_config` so the embedded client observes the same values.
     - Failure modes: Returns `nil` without events when the reading store is unavailable.
     */
    @discardableResult
    func saveReadingProgressSettings(_ settings: ReadingProgressSettingsSnapshot) -> ReadingProgressSettingsSnapshot? {
        guard let store = readingStore() else { return nil }
        let savedSettings = store.saveSettings(settings)
        emitReadingProgressSettings()
        emit(event: "set_config", data: buildConfigJSON())
        return savedSettings
    }

    /// Emits a shared-client chapter-read status update for one chapter.
    private func emitChapterReadStatus(chapter: Int, count: Int) {
        emit(
            event: "update_chapter_read_status",
            data: "{\"chapter\":\(chapter),\"count\":\(count)}"
        )
    }

    /// Emits the Android-compatible reading-progress settings bundle to BibleView.
    private func emitReadingProgressSettings() {
        guard let settingsJSON = readingStore()?.settingsBundleJSON() else { return }
        emit(event: "update_reading_progress_settings", data: settingsJSON)
    }

    /// Emits a named BibleView event.
    private func emit(event: String, data: String) {
        emitEvent(event, data)
    }
}
