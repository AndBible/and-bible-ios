import XCTest
@testable import BibleCore

/**
 Regression contracts for stopped-reader bookmark resolution during speech-settings application.

 These tests use callback counters instead of SWORD fixtures so they deterministically prove whether
 `SpeakService` crosses the expensive reader reconstruction boundary. The in-memory settings store
 and bookmark manager have no file, network, audio, or persistent side effects.
 */
final class SpeakServiceSettingsApplicationPerformanceTests: XCTestCase {
    /**
     Verifies restore and workspace application never request a stopped reader position.

     The callback returns a valid Bible position so any accidental invocation is observable. A
     failure means reader appearance can synchronously reconstruct a default SWORD speech session
     even though neither path requested bookmark mutation.
     */
    func testRestoreAndWorkspaceApplicationDoNotResolveStoppedReaderPosition() throws {
        let service = SpeakService(synthesizer: FakeSpeechSynthesizer())
        service.settingsStore = try makeInMemorySettingsStore()
        var stoppedPositionResolutionCount = 0
        service.onRequestStoppedBibleBookmarkPosition = {
            stoppedPositionResolutionCount += 1
            return Self.visibleBiblePosition
        }

        service.restoreSettings()
        var workspaceSettings = service.settings
        workspaceSettings.playbackSettings.speed += 1
        service.applySettings(workspaceSettings, persist: false)

        XCTAssertEqual(stoppedPositionResolutionCount, 0)
    }

    /**
     Verifies one real stopped playback edit resolves and updates the bookmark exactly once.

     Reapplying the same playback value proves unchanged settings do not repeat reader
     reconstruction. A failure means either legitimate Android bookmark propagation was lost or
     lifecycle-style no-op application can still enter the expensive callback.
     */
    func testStoppedPlaybackEditResolvesAndUpdatesBookmarkExactlyOnce() {
        let service = SpeakService(synthesizer: FakeSpeechSynthesizer())
        let bookmarkManager = RecordingSpeakBookmarkManager()
        service.bookmarkManager = bookmarkManager
        var stoppedPositionResolutionCount = 0
        service.onRequestStoppedBibleBookmarkPosition = {
            stoppedPositionResolutionCount += 1
            return Self.visibleBiblePosition
        }
        var playbackSettings = service.settings.playbackSettings
        playbackSettings.speed += 1

        service.updatePlaybackSettings(playbackSettings)
        service.updatePlaybackSettings(playbackSettings)

        XCTAssertEqual(stoppedPositionResolutionCount, 1)
        XCTAssertEqual(bookmarkManager.updatedPositions, [Self.visibleBiblePosition])
        XCTAssertEqual(bookmarkManager.updatedSettings, [playbackSettings.normalized])
    }

    /// Deterministic stopped-reader Bible position returned by the reconstruction callback.
    private static let visibleBiblePosition = SpeakStreamPosition(
        id: "KJV:Gen.1.1",
        category: .bible,
        bookInitials: "KJV",
        key: "Gen.1.1",
        osisRef: "Gen.1.1",
        keyName: "Genesis 1:1",
        bookName: "Genesis",
        ordinalStart: 1,
        ordinalEnd: 1,
        chapter: 1,
        verse: 1,
        groupIdentifier: "Gen.1",
        language: "en",
        versification: "KJV"
    )
}

/**
 In-memory bookmark boundary that records playback-setting propagation without persistence.

 It intentionally omits restored settings and resume rows because the regression concerns only the
 stopped-position update decision.
 */
private final class RecordingSpeakBookmarkManager: SpeakBookmarkManaging {
    /// Positions supplied to playback-setting updates, in call order.
    private(set) var updatedPositions: [SpeakStreamPosition] = []

    /// Playback snapshots supplied to updates, in call order.
    private(set) var updatedSettings: [PlaybackSettings] = []

    /**
     Returns no restored bookmark settings.

     - Parameter position: Provider position queried by `SpeakService`.
     - Returns: Always `nil`.
     - Side effects: None.
     - Failure modes: Cannot fail.
     */
    func playbackSettingsForSpeakBookmark(at position: SpeakStreamPosition) -> PlaybackSettings? {
        _ = position
        return nil
    }

    /**
     Records one playback-setting update.

     - Parameters:
       - position: Stopped reader position selected by `SpeakService`.
       - settings: Normalized playback settings to persist.
     - Side effects: Appends both values to in-memory arrays.
     - Failure modes: Cannot fail.
     */
    func updateSpeakBookmarkPlaybackSettings(
        at position: SpeakStreamPosition,
        settings: PlaybackSettings
    ) {
        updatedPositions.append(position)
        updatedSettings.append(settings)
    }

    /**
     Accepts persistence calls without writing external state.

     - Parameters:
       - position: Provider position that would be persisted.
       - settings: Playback settings that would be persisted.
       - autoBookmark: Whether Android auto-bookmark behavior requested the write.
     - Side effects: None.
     - Failure modes: Cannot fail.
     */
    func persistSpeakBookmark(
        at position: SpeakStreamPosition,
        settings: PlaybackSettings,
        autoBookmark: Bool
    ) {
        _ = position
        _ = settings
        _ = autoBookmark
    }

    /**
     Returns an empty deterministic resume list.

     - Returns: An empty array.
     - Side effects: None.
     - Failure modes: Cannot fail.
     */
    func speakResumeBookmarks() -> [SpeakResumeBookmark] {
        []
    }
}
