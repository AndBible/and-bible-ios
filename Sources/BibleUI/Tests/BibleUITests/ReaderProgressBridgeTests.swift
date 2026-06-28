import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 BibleUI reader bridge coverage for native memorization and reading progress integration.

 These tests belong in `BibleUITests` because they validate how `BibleReaderController` wires raw
 `BibleBridge` messages to native progress stores and emitted Vue payloads. Pure bridge parsing is
 covered in `BibleViewTests`, while pure store persistence is covered in `BibleCoreTests`.
 */
final class ReaderProgressBridgeTests: BibleUISwordFixtureTestCase {
    /**
     Verifies memorization bridge messages mutate the controller-owned native store.

     Setup uses an in-memory `SettingsStore` and dispatches the same bridge messages the Vue reader
     sends. The expected result is that target and memorized ordinal sets match the requested
     add/remove/mark operations. A failure means the reader bridge accepted the message but failed to
     preserve native memorization progress state.
     */
    func testBridgeMemorizationMessagesMutateNativeStore() throws {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeInMemorySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)

        XCTAssertEqual(bridge.dispatchMessage(method: "memorize", args: ["KJV", 1, -1]), .handled)
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 3), [1])

        XCTAssertEqual(bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", 2, 3]), .handled)
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 3), [1, 2, 3])

        XCTAssertEqual(bridge.dispatchMessage(method: "markAsMemorized", args: ["KJV", 1, 3]), .handled)
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 3), [1, 2, 3])

        XCTAssertEqual(bridge.dispatchMessage(method: "removeMemorizationTarget", args: ["KJV", 2, 2]), .handled)
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 3), [1, 3])

        XCTAssertEqual(bridge.dispatchMessage(method: "unmarkMemorized", args: ["KJV", 2, 3]), .handled)
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 3), [1])
    }

    /**
     Verifies the reader's Memorize bridge action emits Android's fake-document payload.

     Android opens memorization practice as a reader document after adding the selected ordinal
     range as a target. The iOS bridge must preserve that user-visible contract when document
     assembly is tested outside the app-host bundle: the emitted document remains `type=memorize`,
     includes selected verse text, carries target ordinals, and sends a normal `setup_content`
     payload. A failure means the refactor broke Android parity by mutating progress state without
     opening the expected Memorize reader document, or by emitting a malformed document/setup
     payload.
     */
    @MainActor
    func testReaderMemorizeBridgeEmitsAndroidStyleDocumentPayload() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 2))

        controller.bridgeDidSetClientReady(bridge)
        let initialScriptCount = recordedScripts().count

        controller.bridge(
            bridge,
            memorize: "KJV",
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )

        let memorizeScripts = Array(recordedScripts().dropFirst(initialScriptCount))
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["title"] as? String, "Genesis 1:1-2")
        XCTAssertEqual(document["osisRef"] as? String, "Gen.1.1-Gen.1.2")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [startOrdinal, endOrdinal])

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(texts.map { $0["key"] }, ["Gen.1.1", "Gen.1.2"])
        XCTAssertTrue(texts.first?["text"]?.contains("In the beginning") == true)

        let setupPayload = try XCTUnwrap(
            bridgeEmissionPayload(from: memorizeScripts, event: "setup_content") as? [String: Any]
        )
        XCTAssertTrue(setupPayload["jumpToOrdinal"] is NSNull)
        XCTAssertTrue(setupPayload["jumpToAnchor"] is NSNull)
        XCTAssertTrue(setupPayload["jumpToId"] is NSNull)
        XCTAssertEqual(setupPayload["topOffset"] as? Int, 0)
        XCTAssertEqual(setupPayload["bottomOffset"] as? Int, 0)
    }

    /**
     Verifies reading-progress bridge messages update native history and emit chapter-count changes.

     The setup navigates the controller to Exodus 2, dispatches Vue bridge messages for automatic,
     manual, and clear operations, and records JavaScript emissions. The expected result is that
     invalid chapter identifiers are ignored, valid records persist with Android source mapping, and
     clearing status emits the updated count back to Vue. A failure indicates reader progress state
     and the web reader's status badges can diverge.
     */
    func testBridgeReadingProgressMessagesMutateNativeStoreAndEmitCounts() throws {
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { scripts.append($0) }
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeInMemorySettingsStore()
        let store = try XCTUnwrap(controller.readingProgressStore)
        controller.navigateTo(book: "Exodus", chapter: 2)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "recordChapterRead", args: ["KJV", 41, 0, "AUTO_SCROLL"]),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(method: "unmarkChapterRead", args: ["KJV", 41, -1]),
            .handled
        )
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertEqual(store.snapshot().history.count, 0)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "recordChapterRead", args: ["KJV", 41, 2, "AUTO_SCROLL"]),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 1)
        XCTAssertTrue(store.snapshot().history.contains { $0.source == .autoScroll })

        XCTAssertEqual(
            bridge.dispatchMessage(method: "markChapterRead", args: ["KJV", 41, 2, "not-a-source"]),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 2)
        XCTAssertTrue(store.snapshot().history.contains { $0.source == .manual })

        XCTAssertEqual(
            bridge.dispatchMessage(method: "unmarkChapterRead", args: ["KJV", 41, 2]),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 0)
        XCTAssertTrue(
            scripts.contains { script in
                script.contains("bibleView.emit('update_chapter_read_status'") &&
                    script.contains(#""chapter":2"#) &&
                    script.contains(#""count":0"#)
            }
        )
    }

    /**
     Verifies reading-progress bridge navigation and settings handoffs stay native-owned.

     The setup records reader-controller callbacks and bridge emissions for progress dialogs,
     chapter history, and memorization display settings. The expected result is that only valid
     history targets open native UI, accepted settings update both the native store and Vue config,
     and malformed bundles leave state unchanged. A failure means bridge routing can drift from the
     Android behavior where the web reader delegates progress UI and persistence to native code.
     */
    func testBridgeReadingProgressSettingsAndPresentationHandoffs() throws {
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { scripts.append($0) }
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeInMemorySettingsStore()
        controller.navigateTo(book: "Exodus", chapter: 2)

        var openedTabs: [Int] = []
        var openedSettingsCount = 0
        var historyTargets: [ChapterReadHistoryTarget] = []
        controller.onShowReadingProgress = { openedTabs.append($0) }
        controller.onShowReadingProgressSettings = { openedSettingsCount += 1 }
        controller.onShowChapterReadHistory = { historyTargets.append($0) }

        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgress", args: [1]), .handled)
        XCTAssertEqual(openedTabs, [1])

        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgressSettings", args: []), .handled)
        XCTAssertEqual(openedSettingsCount, 1)

        XCTAssertEqual(bridge.dispatchMessage(method: "openChapterReadHistory", args: ["KJV", 41, 2]), .handled)
        XCTAssertEqual(historyTargets.count, 1)
        XCTAssertEqual(historyTargets.first?.bookInitials, "KJV")
        XCTAssertEqual(historyTargets.first?.startOrdinal, 41)
        XCTAssertEqual(historyTargets.first?.kjvBookOrdinal, 3)
        XCTAssertEqual(historyTargets.first?.bookName, "Exodus")
        XCTAssertEqual(historyTargets.first?.chapter, 2)

        XCTAssertEqual(bridge.dispatchMessage(method: "openChapterReadHistory", args: ["KJV", 1, 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openChapterReadHistory", args: ["NIV", 41, 2]), .handled)
        XCTAssertEqual(historyTargets.count, 1)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "setReadingProgressSettings", args: ["""
            {
              "autoMarkMemorized": false,
              "memorizeTypeFullWords": true,
              "memorizeWordVisibility": "hidden",
              "memorizeErrorHeatmap": false,
              "memorizeScrambleHideUsed": true,
              "memorizeIncludeReference": false
            }
            """]),
            .handled
        )

        let settings = try XCTUnwrap(controller.readingProgressStore?.snapshot().settings)
        XCTAssertEqual(settings.autoMarkMemorized, false)
        XCTAssertEqual(settings.memorizeTypeFullWords, true)
        XCTAssertEqual(settings.memorizeWordVisibility, "hidden")
        XCTAssertEqual(settings.memorizeErrorHeatmap, false)
        XCTAssertEqual(settings.memorizeScrambleHideUsed, true)
        XCTAssertEqual(settings.memorizeIncludeReference, false)
        XCTAssertTrue(
            scripts.contains { script in
                script.contains("bibleView.emit('update_reading_progress_settings'") &&
                    script.contains(#""memorizeWordVisibility":"hidden""#)
            }
        )
        XCTAssertTrue(scripts.contains { $0.contains("bibleView.emit('set_config'") })

        let scriptCount = scripts.count
        XCTAssertEqual(
            bridge.dispatchMessage(method: "setReadingProgressSettings", args: [#"{"memorizeWordVisibility":"opaque"}"#]),
            .handled
        )
        XCTAssertEqual(scripts.count, scriptCount)
        XCTAssertEqual(controller.readingProgressStore?.snapshot().settings, settings)
    }
}
