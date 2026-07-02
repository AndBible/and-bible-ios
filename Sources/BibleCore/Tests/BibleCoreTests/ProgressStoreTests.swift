import XCTest
@testable import BibleCore

/**
 BibleCore memorization and reading-progress persistence coverage.

 These tests validate native store behavior without reader controller or web bridge integration, so
 the lowest owning target is `BibleCoreTests`.
 */
final class ProgressStoreTests: XCTestCase {
    /**
     Verifies memorization targets follow Android's independent-row range semantics.

     Android skips only exact duplicate `MemorizationTarget` rows in
     `ProgressControl.addMemorizationTargetIfNeeded`; nested ranges remain independent targets and
     are later split by overlapping removals. The test persists through `SettingsStore` so it
     covers both mutation behavior and JSON reload compatibility for the native store.

     Failure means iOS has reintroduced collapsed or containment-based target behavior that changes
     Android backup rows, target totals, and removal deltas.
     */
    func testMemorizationProgressStorePersistsRangesAndSplitsTargets() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        store.addMemorizationTarget(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 5)
        let rawAfterInitialTarget = try XCTUnwrap(settingsStore.getString(MemorizationProgressStore.settingsKey))
        store.addMemorizationTargetIfNeeded(bookInitials: "KJV", startOrdinal: 2, endOrdinal: 4)
        let rawAfterNestedTarget = try XCTUnwrap(settingsStore.getString(MemorizationProgressStore.settingsKey))
        XCTAssertNotEqual(rawAfterNestedTarget, rawAfterInitialTarget)
        XCTAssertEqual(Set(store.snapshot().targetRanges), Set([
            MemorizationProgressRange(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 5),
            MemorizationProgressRange(bookInitials: "KJV", startOrdinal: 2, endOrdinal: 4),
        ]))

        store.addMemorizationTargetIfNeeded(bookInitials: "KJV", startOrdinal: 2, endOrdinal: 4)
        XCTAssertEqual(settingsStore.getString(MemorizationProgressStore.settingsKey), rawAfterNestedTarget)

        store.removeMemorizationTarget(bookInitials: "KJV", startOrdinal: 2, endOrdinal: 4)
        store.markAsMemorized(bookInitials: "KJV", startOrdinal: 3, endOrdinal: 5)
        store.unmarkMemorized(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 4)

        let reloadedStore = MemorizationProgressStore(settingsStore: settingsStore)
        XCTAssertEqual(
            reloadedStore.targetOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 5),
            [1, 5]
        )
        XCTAssertEqual(
            reloadedStore.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 5),
            [3, 5]
        )
        XCTAssertEqual(
            reloadedStore.targetOrdinals(bookInitials: "ESV", startOrdinal: 1, endOrdinal: 5),
            []
        )
    }

    func testReadingProgressStorePersistsChapterHistoryAndClearsActiveCycle() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = ReadingProgressStore(settingsStore: settingsStore)

        XCTAssertEqual(
            store.recordChapterRead(
                bookInitials: "KJV",
                startOrdinal: 41,
                kjvBookOrdinal: 3,
                chapter: 2,
                source: .autoScroll,
                readAt: 100
            ),
            1
        )
        XCTAssertEqual(
            store.recordChapterRead(
                bookInitials: "KJV",
                startOrdinal: 41,
                kjvBookOrdinal: 3,
                chapter: 2,
                source: ReadingProgressSource(bridgeValue: "AUTO_TTS"),
                readAt: 200
            ),
            2
        )
        XCTAssertEqual(ReadingProgressSource(bridgeValue: "unknown"), .manual)

        let reloadedStore = ReadingProgressStore(settingsStore: settingsStore)
        XCTAssertEqual(reloadedStore.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 2)
        XCTAssertEqual(
            reloadedStore.snapshot().history.map(\.source),
            [.autoScroll, .autoTts]
        )
        XCTAssertEqual(reloadedStore.snapshot().history.map(\.startOrdinal), [41, 41])
        let summary = reloadedStore.readingSummary(recentLimit: 1)
        XCTAssertEqual(summary.cycle, 1)
        XCTAssertEqual(summary.distinctChapterCount, 1)
        XCTAssertEqual(summary.readingCount, 2)
        XCTAssertEqual(summary.recentRows.map(\.source), [.autoTts])
        XCTAssertTrue(reloadedStore.readingSummary(recentLimit: 0).recentRows.isEmpty)

        XCTAssertEqual(reloadedStore.clearChapterReadStatus(kjvBookOrdinal: 3, chapter: 2), 0)
        XCTAssertTrue(ReadingProgressStore(settingsStore: settingsStore).snapshot().history.isEmpty)
    }

    func testReadingProgressStorePersistsSettingsBundleAndPreservesNativeFields() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = ReadingProgressStore(settingsStore: settingsStore)
        var nativeSettings = ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 4)
        nativeSettings.memorizeWordVisibility = "hidden"
        store.saveSettings(nativeSettings)

        XCTAssertTrue(store.applySettingsBundle(json: """
        {
          "autoMarkMemorized": false,
          "memorizeTypeFullWords": true,
          "memorizeWordVisibility": "dim",
          "memorizeErrorHeatmap": false,
          "memorizeScrambleHideUsed": true,
          "memorizeIncludeReference": false
        }
        """))

        let updated = store.snapshot().settings
        XCTAssertEqual(updated.autoTrackReading, true)
        XCTAssertEqual(updated.activeCycle, 4)
        XCTAssertEqual(updated.autoMarkMemorized, false)
        XCTAssertEqual(updated.memorizeTypeFullWords, true)
        XCTAssertEqual(updated.memorizeWordVisibility, "dim")
        XCTAssertEqual(updated.memorizeErrorHeatmap, false)
        XCTAssertEqual(updated.memorizeScrambleHideUsed, true)
        XCTAssertEqual(updated.memorizeIncludeReference, false)

        XCTAssertFalse(store.applySettingsBundle(json: #"{}"#))
        XCTAssertFalse(store.applySettingsBundle(json: #"{"autoMarkMemorized":true}"#))
        XCTAssertFalse(store.applySettingsBundle(json: #"{"memorizeWordVisibility":"opaque"}"#))
        XCTAssertFalse(store.applySettingsBundle(json: #"{"autoMarkMemorized":true,"unexpected":true}"#))
        XCTAssertFalse(store.applySettingsBundle(json: #"{"autoMarkMemorized":null}"#))
        XCTAssertEqual(store.snapshot().settings, updated)
    }
}
