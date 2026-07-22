import Foundation
import BibleCore
import BibleView

extension Notification.Name {
    /// Posted when a reader progress mutation cannot durably persist or journal its change.
    static let readingProgressPersistenceFailure = Notification.Name(
        "org.andbible.reading-progress-persistence-failure"
    )
}

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
 - reading-progress requests with missing stores or invalid active chapter targets return without
   side effects, matching Android's guards around missing books/versifications
 - malformed reading-progress settings JSON returns without persistence or bridge events
 - persistence and mutation-journal failures are reported through the injected failure callback
 - memorization target persistence is skipped when no memorization store exists, while `memorize`
   still opens the Memorize document to match Android's UI handoff after a guarded target insert
 */
struct BibleReaderProgressBridgeCoordinator {
    /// Resolved chapter identity used by Android-compatible reading-progress persistence.
    struct ReadingProgressBridgeTarget {
        /// Verified JSword/KJVA book identity plus Android's retained source chapter.
        let identity: ReadingProgressKJVAIdentity
        /// Human-readable book name used by native iOS read-history presentation.
        let bookName: String
    }

    /// Maps one rendered reader ordinal to Android's KJVA memorization-progress ordinal.
    struct MemorizationOrdinalProjection {
        /// Ordinal used by the current Vue document.
        let renderedOrdinal: Int
        /// Android JSword KJVA ordinal persisted in memorization progress rows.
        let kjvaOrdinal: Int
    }

    /**
     Describes one Android KJVA storage span and the visible verses it intersects.

     Android stores memorization progress as one inclusive KJVA ordinal range, including ordinals
     that do not render as selectable Bible verses, while Vue updates can only mention rendered
     ordinals. The controller supplies both pieces so persistence keeps Android parity and bridge
     events stay meaningful to the open document.
     */
    struct MemorizationOrdinalResolution {
        /// Verified KJVA range plus the exact source module, versification, and source ordinals.
        let verifiedRange: VerifiedKJVAOrdinalRange
        /// Visible rendered verses inside the selected range that can receive Vue update events.
        let projections: [MemorizationOrdinalProjection]

        /// Inclusive Android KJVA storage start ordinal.
        var startOrdinal: Int { verifiedRange.kjvaOrdinalStart }

        /// Inclusive Android KJVA storage end ordinal.
        var endOrdinal: Int { verifiedRange.kjvaOrdinalEnd }
    }

    /// Supplies the active memorization store.
    private let memorizationStore: () -> MemorizationProgressStore?
    /// Supplies the active reading-progress store.
    private let readingStore: () -> ReadingProgressStore?
    /// Resolves and validates a bridge chapter target against the current reader document.
    private let resolveReadingTarget: (String, Int, Int) -> ReadingProgressBridgeTarget?
    /// Resolves rendered verse ordinals into Android's KJVA memorization storage domain.
    private let resolveMemorizationRange: (String, Int, Int) -> MemorizationOrdinalResolution?
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
    /// Reports durable persistence failures without emitting optimistic success events.
    private let reportPersistenceFailure: (Error) -> Void

    /**
     Creates a progress bridge coordinator bound to reader-owned stores and callbacks.

     - Parameters:
       - memorizationStore: Supplier for local memorization persistence.
       - readingStore: Supplier for local reading-progress persistence.
       - resolveReadingTarget: Closure that validates bridge chapter identity and returns KJVA data.
       - resolveMemorizationRange: Closure validating source module identity and projecting rendered
         ordinals into Android KJVA storage with durable source provenance.
       - loadMemorizeDocument: Closure opening the Memorize document for a selected range.
       - showReadingProgress: Native progress UI callback.
       - showReadingProgressSettings: Native settings UI callback.
       - showChapterReadHistory: Native read-history UI callback.
       - emit: BibleView event emitter.
       - buildConfigJSON: Config payload builder for settings changes.
       - reportPersistenceFailure: Observer for persistence and mutation-journal failures.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        memorizationStore: @escaping () -> MemorizationProgressStore?,
        readingStore: @escaping () -> ReadingProgressStore?,
        resolveReadingTarget: @escaping (String, Int, Int) -> ReadingProgressBridgeTarget?,
        resolveMemorizationRange: @escaping (String, Int, Int) -> MemorizationOrdinalResolution?,
        loadMemorizeDocument: @escaping (String, Int, Int) -> Void,
        showReadingProgress: @escaping (Int) -> Void,
        showReadingProgressSettings: @escaping () -> Void,
        showChapterReadHistory: @escaping (ChapterReadHistoryTarget) -> Void,
        emit: @escaping (String, String) -> Void,
        buildConfigJSON: @escaping () -> String,
        reportPersistenceFailure: @escaping (Error) -> Void = { error in
            NotificationCenter.default.post(
                name: .readingProgressPersistenceFailure,
                object: error
            )
        }
    ) {
        self.memorizationStore = memorizationStore
        self.readingStore = readingStore
        self.resolveReadingTarget = resolveReadingTarget
        self.resolveMemorizationRange = resolveMemorizationRange
        self.loadMemorizeDocument = loadMemorizeDocument
        self.showReadingProgress = showReadingProgress
        self.showReadingProgressSettings = showReadingProgressSettings
        self.showChapterReadHistory = showChapterReadHistory
        self.emitEvent = emit
        self.buildConfigJSON = buildConfigJSON
        self.reportPersistenceFailure = reportPersistenceFailure
    }

    /// Adds the selected verse range as a memorization target and opens the Memorize document.
    func memorize(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        mutateMemorization(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) { store, resolution in
            try store.addMemorizationTargetIfNeeded(resolution.verifiedRange)
        }
        loadMemorizeDocument(bookInitials, startOrdinal, endOrdinal)
    }

    /// Marks the selected verse range as memorized in local iOS progress state.
    func markAsMemorized(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        mutateMemorization(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) { store, resolution in
            try store.markAsMemorized(resolution.verifiedRange)
        }
    }

    /// Adds the selected verse range to local memorization targets.
    func addMemorizationTarget(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        mutateMemorization(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) { store, resolution in
            try store.addMemorizationTarget(resolution.verifiedRange)
        }
    }

    /// Removes the selected verse range from local memorization targets.
    func removeMemorizationTarget(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        mutateMemorization(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) { store, resolution in
            try store.removeMemorizationTarget(
                bookInitials: "",
                startOrdinal: resolution.startOrdinal,
                endOrdinal: resolution.endOrdinal
            )
        }
    }

    /// Removes the selected verse range from local memorized ranges.
    func unmarkMemorized(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        mutateMemorization(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) { store, resolution in
            try store.unmarkMemorized(
                bookInitials: "",
                startOrdinal: resolution.startOrdinal,
                endOrdinal: resolution.endOrdinal
            )
        }
    }

    /// Records one chapter-read history row and emits the new chapter-read count to BibleView.
    func recordChapterRead(bookInitials: String, startOrdinal: Int, chapter: Int, source: String) {
        guard let store = readingStore(),
              let target = resolveReadingTarget(bookInitials, startOrdinal, chapter) else {
            return
        }
        do {
            let count = try store.recordChapterRead(
                bookInitials: bookInitials,
                identity: target.identity,
                source: ReadingProgressSource(bridgeValue: source)
            )
            emitChapterReadStatus(chapter: chapter, count: count)
        } catch {
            reportPersistenceFailure(error)
        }
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
                kjvBookOrdinal: target.identity.kjvBookOrdinal,
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
        guard let store = readingStore() else {
            return
        }
        do {
            guard try store.applySettingsBundle(json: json) else { return }
            emitReadingProgressSettings()
            emit(event: "set_config", data: buildConfigJSON())
        } catch {
            reportPersistenceFailure(error)
        }
    }

    /// Clears chapter-read status for the active reading-progress cycle and emits the new count.
    func unmarkChapterRead(bookInitials: String, startOrdinal: Int, chapter: Int) {
        guard let store = readingStore(),
              let target = resolveReadingTarget(bookInitials, startOrdinal, chapter) else {
            return
        }
        do {
            let count = try store.clearChapterReadStatus(
                kjvBookOrdinal: target.identity.kjvBookOrdinal,
                chapter: chapter
            )
            emitChapterReadStatus(chapter: chapter, count: count)
        } catch {
            reportPersistenceFailure(error)
        }
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
     - Failure modes: Returns `nil` without events when the reading store is unavailable or the
       journaled persistence operation fails; persistence failures are reported to the observer.
     */
    @discardableResult
    func saveReadingProgressSettings(_ settings: ReadingProgressSettingsSnapshot) -> ReadingProgressSettingsSnapshot? {
        guard let store = readingStore() else { return nil }
        do {
            let savedSettings = try store.saveSettings(settings)
            emitReadingProgressSettings()
            emit(event: "set_config", data: buildConfigJSON())
            return savedSettings
        } catch {
            reportPersistenceFailure(error)
            return nil
        }
    }

    /**
     Applies one Android-compatible memorization mutation and emits rendered ordinal deltas.

     The native store is KJVA-global, while the open Vue document expects update arrays in the
     currently rendered ordinal domain. The projection closure is the only boundary that knows both
     domains for the active reader. Android treats non-positive end ordinals as a single-verse
     range ending at the start ordinal.
     */
    private func mutateMemorization(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        operation: (
            MemorizationProgressStore,
            MemorizationOrdinalResolution
        ) throws -> MemorizationProgressDelta
    ) {
        guard let store = memorizationStore() else { return }
        let effectiveEnd = endOrdinal > 0 ? endOrdinal : startOrdinal
        let lower = min(startOrdinal, effectiveEnd)
        let upper = max(startOrdinal, effectiveEnd)
        guard let resolution = resolveMemorizationRange(bookInitials, lower, upper) else { return }
        let projections = resolution.projections.sorted { $0.renderedOrdinal < $1.renderedOrdinal }
        guard !projections.isEmpty else { return }

        do {
            let kjvaDelta = try operation(store, resolution)
            let renderedDelta = Self.renderedDelta(from: kjvaDelta, using: projections)
            emitMemorizationData(renderedDelta)
        } catch {
            reportPersistenceFailure(error)
        }
    }

    private static func renderedDelta(
        from delta: MemorizationProgressDelta,
        using projections: [MemorizationOrdinalProjection]
    ) -> MemorizationProgressDelta {
        let projectedOrdinals = Dictionary(grouping: projections, by: \.kjvaOrdinal)
        return MemorizationProgressDelta(
            addedMemorized: renderedOrdinals(for: delta.addedMemorized, using: projectedOrdinals),
            removedMemorized: renderedOrdinals(for: delta.removedMemorized, using: projectedOrdinals),
            addedTargets: renderedOrdinals(for: delta.addedTargets, using: projectedOrdinals),
            removedTargets: renderedOrdinals(for: delta.removedTargets, using: projectedOrdinals)
        )
    }

    private static func renderedOrdinals(
        for kjvaOrdinals: [Int],
        using projectedOrdinals: [Int: [MemorizationOrdinalProjection]]
    ) -> [Int] {
        kjvaOrdinals.flatMap { kjvaOrdinal in
            projectedOrdinals[kjvaOrdinal]?.map(\.renderedOrdinal) ?? []
        }
        .sorted()
    }

    private func emitMemorizationData(_ delta: MemorizationProgressDelta) {
        guard !delta.isEmpty else { return }
        let payload: [String: Any] = [
            "addedMemorized": delta.addedMemorized,
            "removedMemorized": delta.removedMemorized,
            "addedTargets": delta.addedTargets,
            "removedTargets": delta.removedTargets,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        emit(event: "update_memorization_data", data: json)
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
