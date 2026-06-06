import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testBridgeCallIdRequestMappingMatchesWebClientContract() {
        let bridge = BibleBridge()

        XCTAssertEqual(
            bridge.callIdRequest(method: "requestMoreToBeginning", args: [41]),
            .request(.requestMoreToBeginning(41))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "requestMoreToEnd", args: [42]),
            .request(.requestMoreToEnd(42))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "refChooserDialog", args: [43]),
            .request(.refChooserDialog(43))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "parseRef", args: [44, "Genesis 1:1"]),
            .request(.parseRef(callId: 44, text: "Genesis 1:1"))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "getMyDocumentPageRawContent", args: [45, "MYDOC", "intro"]),
            .request(.getMyDocumentPageRawContent(callId: 45, bookInitials: "MYDOC", pageKey: "intro"))
        )

        for malformedRequest in malformedCallIdRequests {
            XCTAssertEqual(
                bridge.callIdRequest(method: malformedRequest.method, args: malformedRequest.args),
                .malformed,
                "Expected \(malformedRequest.method) to reject malformed args"
            )
        }

        XCTAssertNil(bridge.callIdRequest(method: "helpDialog", args: [46]))
    }

    func testBridgeCallIdDispatchClassifiesKnownMalformedMessages() {
        let bridge = BibleBridge()

        XCTAssertEqual(
            bridge.dispatchCallIdRequest(method: "requestMoreToBeginning", args: [41]),
            .handled
        )

        for malformedRequest in malformedCallIdRequests {
            XCTAssertEqual(
                bridge.dispatchCallIdRequest(method: malformedRequest.method, args: malformedRequest.args),
                .malformed,
                "Expected \(malformedRequest.method) to classify malformed args"
            )
        }

        XCTAssertEqual(bridge.dispatchCallIdRequest(method: "getMyDocumentPageRawContent", args: [45, "MYDOC", "intro"]), .handled)
        XCTAssertEqual(bridge.dispatchCallIdRequest(method: "helpDialog", args: [46]), .notCallIdRequest)
    }

    func testBridgeMessageDispatchClassifiesKnownMalformedMessages() {
        let bridge = BibleBridge()

        for malformedMessage in malformedBridgeMessages {
            XCTAssertEqual(
                bridge.dispatchMessage(method: malformedMessage.method, args: malformedMessage.args),
                .malformed,
                "Expected \(malformedMessage.method) to classify malformed args"
            )
        }

        XCTAssertEqual(bridge.dispatchMessage(method: "shareBookmarkVerse", args: ["bookmark-id"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "copyMyDocumentContent", args: ["MYDOC", "intro"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "shareMyDocumentContent", args: ["MYDOC", "intro"]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "saveMyDocumentPageContent", args: ["MYDOC", "page-id", "content", NSNull()]),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(method: "saveMyDocumentPageContent", args: ["MYDOC", "page-id", "content", "Renamed"]),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "reloadMyDocumentPage", args: ["MYDOC"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "regenerateMyDocumentPage", args: ["page-id"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "deleteMyDocumentPage", args: ["page-id"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "saveBookmarkNote", args: ["bookmark-id", NSNull()]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "helpDialog", args: ["content", NSNull()]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "scrolledToOrdinal", args: ["main", 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "helpBookmarks", args: []), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "speakMemorizationLoop", args: ["KJV", "KJV", 1, -1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "memorize", args: ["KJV", 1, -1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "recordChapterRead", args: ["KJV", 1, 1, "AUTO_SCROLL"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "markChapterRead", args: ["KJV", 1, 1, "MANUAL"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openChapterReadHistory", args: ["KJV", 1, 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgress", args: [1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgressSettings", args: []), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "setReadingProgressSettings", args: [#"{"autoMarkMemorized":true}"#]),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "unmarkChapterRead", args: ["KJV", 1, 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "goToNextChapter", args: []), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "goToPreviousChapter", args: []), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "addParagraphBreakBookmark", args: ["KJV", 1, -1]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "addGenericParagraphBreakBookmark", args: ["KJV", "Gen.1.1", 1, -1]),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "missingMethod", args: []), .unhandled)
    }

    func testSpeakServiceMemorizationLoopRepeatsUntilStopped() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        service.speakMemorizationLoop(text: "In the beginning", language: "en-US")

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(synthesizer.spokenUtterances.map(\.speechString), ["In the beginning"])

        let firstUtterance = synthesizer.spokenUtterances[0]
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: firstUtterance)

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["In the beginning", "In the beginning"]
        )

        service.stop()

        XCTAssertFalse(service.isMemorizationLoop)
        XCTAssertFalse(service.isSpeaking)
        XCTAssertEqual(synthesizer.stopBoundaries.last, .immediate)
    }

    func testSpeakServiceRegularSpeechClearsMemorizationLoop() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        service.speakMemorizationLoop(text: "Remember this", language: "en-US")
        service.speak(text: "Read once", language: "en-US")

        XCTAssertFalse(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Remember this", "Read once"]
        )
    }

    func testSpeakServiceMemorizationLoopIgnoresCancelledReplacedUtterance() {
        let synthesizer = FakeSpeechSynthesizer()
        let service = SpeakService(synthesizer: synthesizer)

        service.speak(text: "Read once", language: "en-US")
        let replacedUtterance = synthesizer.spokenUtterances[0]

        service.speakMemorizationLoop(text: "Repeat this", language: "en-US")
        service.speechSynthesizer(AVSpeechSynthesizer(), didCancel: replacedUtterance)

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Read once", "Repeat this"]
        )

        let loopUtterance = synthesizer.spokenUtterances[1]
        service.speechSynthesizer(AVSpeechSynthesizer(), didFinish: loopUtterance)

        XCTAssertTrue(service.isMemorizationLoop)
        XCTAssertTrue(service.isSpeaking)
        XCTAssertEqual(
            synthesizer.spokenUtterances.map(\.speechString),
            ["Read once", "Repeat this", "Repeat this"]
        )
    }

    func testMemorizationProgressStorePersistsRangesAndSplitsTargets() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        store.addMemorizationTarget(bookInitials: "KJV", startOrdinal: 1, endOrdinal: 5)
        let rawAfterInitialTarget = try XCTUnwrap(settingsStore.getString(MemorizationProgressStore.settingsKey))
        store.addMemorizationTargetIfNeeded(bookInitials: "KJV", startOrdinal: 2, endOrdinal: 4)
        XCTAssertEqual(settingsStore.getString(MemorizationProgressStore.settingsKey), rawAfterInitialTarget)

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
        XCTAssertEqual(store.snapshot().history.last?.source, .autoScroll)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "markChapterRead", args: ["KJV", 41, 2, "not-a-source"]),
            .handled
        )
        XCTAssertEqual(store.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 2)
        XCTAssertEqual(store.snapshot().history.last?.source, .manual)

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
