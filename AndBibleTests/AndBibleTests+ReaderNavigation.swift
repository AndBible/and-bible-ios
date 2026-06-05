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
    func testReaderCompareBridgeRequestEmitsVueCompareDocument() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let secondCorinthians = try XCTUnwrap(
            controller.bookList.first(where: { $0.osisId == "2Cor" })?.name
        )
        let chapter = 2
        let startVerse = 5
        let endVerse = 7
        let activeModuleName = controller.activeModuleName

        func ordinal(for verse: Int) -> Int {
            (chapter - 1) * 40 + verse
        }

        controller.navigateTo(book: secondCorinthians, chapter: chapter, verse: 1)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "compare",
                args: [activeModuleName, ordinal(for: startVerse), ordinal(for: endVerse)]
            ),
            .handled
        )
        let deadline = Date(timeIntervalSinceNow: 2.0)
        var emittedAddDocumentsScript: String?
        while emittedAddDocumentsScript == nil && Date() < deadline {
            emittedAddDocumentsScript = recordedScripts().first(where: { $0.contains("emit('add_documents'") })
            if emittedAddDocumentsScript == nil {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        let addDocumentsScript = try XCTUnwrap(
            emittedAddDocumentsScript,
            "Expected compare to emit an add_documents script after background payload creation"
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected compare to render through Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""compare":true"#))
        XCTAssertTrue(addDocumentsScript.contains(#""bookCategory":"BIBLE""#))
        XCTAssertTrue(addDocumentsScript.contains(#""bookInitials":"\#(activeModuleName)""#))
        XCTAssertTrue(addDocumentsScript.contains(#""bookAbbreviation":"\#(activeModuleName)""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"2Cor.2.5-2Cor.2.7""#))
        XCTAssertTrue(addDocumentsScript.contains(#""keyName":"\#(secondCorinthians) 2:5-7""#))
    }

    func testDoubleTapFullscreenPreferenceGateControlsNativeToggleRequest() throws {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let settingsStore = try makeInMemorySettingsStore()
        controller.settingsStore = settingsStore

        var toggleCount = 0
        controller.onToggleFullScreen = { toggleCount += 1 }

        XCTAssertEqual(bridge.dispatchMessage(method: "toggleFullScreen", args: []), .handled)
        XCTAssertEqual(toggleCount, 1)

        settingsStore.setBool(.doubleTapToFullscreen, value: false)
        XCTAssertEqual(bridge.dispatchMessage(method: "toggleFullScreen", args: []), .handled)
        XCTAssertEqual(toggleCount, 1)

        settingsStore.setBool(.doubleTapToFullscreen, value: true)
        XCTAssertEqual(bridge.dispatchMessage(method: "toggleFullScreen", args: []), .handled)
        XCTAssertEqual(toggleCount, 2)
    }

    func testReaderHorizontalSwipePolicyMapsConfiguredModes() {
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "CHAPTER",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .navigateNextChapter
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "CHAPTER",
                direction: .right,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .navigatePreviousChapter
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "PAGE",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .scrollPageDown
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "PAGE",
                direction: .right,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .scrollPageUp
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "NONE",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .none
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "PAGE",
                direction: .left,
                hasActiveSelection: true,
                hasOpenModal: false
            ),
            .none
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "CHAPTER",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: true
            ),
            .none
        )
        XCTAssertEqual(
            ReaderHorizontalSwipePolicy.action(
                modeRawValue: "unexpected",
                direction: .left,
                hasActiveSelection: false,
                hasOpenModal: false
            ),
            .navigateNextChapter
        )
    }

    func testAutoFullscreenPolicyAccumulatesThresholdByDirection() {
        var tracking = ReaderAutoFullscreenTracking()

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: 20,
                isEnabled: true,
                isFullScreen: false,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking.directionDown, true)
        XCTAssertEqual(tracking.distance, 20)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: 36,
                isEnabled: true,
                isFullScreen: false,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .enterFullscreen
        )
        XCTAssertEqual(tracking.directionDown, true)
        XCTAssertEqual(tracking.distance, 0)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: -10,
                isEnabled: true,
                isFullScreen: true,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking.directionDown, false)
        XCTAssertEqual(tracking.distance, 10)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: -46,
                isEnabled: true,
                isFullScreen: true,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .exitFullscreen
        )
        XCTAssertEqual(tracking.distance, 0)
    }

    func testAutoFullscreenPolicyHonorsDisabledAndDoubleTapLock() {
        var tracking = ReaderAutoFullscreenTracking(directionDown: true, distance: 24)

        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: 10,
                isEnabled: false,
                isFullScreen: false,
                fullscreenLockedByDoubleTap: false,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking, ReaderAutoFullscreenTracking())

        tracking = ReaderAutoFullscreenTracking()
        XCTAssertEqual(
            ReaderAutoFullscreenPolicy.action(
                deltaY: -56,
                isEnabled: true,
                isFullScreen: true,
                fullscreenLockedByDoubleTap: true,
                tracking: &tracking
            ),
            .none
        )
        XCTAssertEqual(tracking.directionDown, false)
        XCTAssertEqual(tracking.distance, 0)
    }

    @MainActor
    func testBridgeSendResponseEmitsCallIdResponseJavaScript() {
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { script in
            scripts.append(script)
        }

        bridge.sendResponse(callId: 54, value: "null")
        bridge.sendResponse(callId: 55, value: ["osisRef": "Gen.1.1"])

        XCTAssertEqual(
            scripts,
            [
                "bibleView.response(54, null);",
                #"bibleView.response(55, {"osisRef":"Gen.1.1"});"#,
            ]
        )
    }

    /**
     Protects the Swift-to-Vue bridge payload key contract for core client objects.

     The OSIS fragment fixture mirrors `bibleview-js/src/types/client-objects.ts` so
     regressions in required web-client fields, including Strong's-capability metadata,
     fail in unit tests before malformed bridge JSON reaches the reader.
     */
    func testBridgePayloadKeysMatchWebClientContracts() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1",
            keyName: "Genesis 1",
            v11n: "KJVA",
            bookCategory: "BIBLE",
            bookInitials: "KJV",
            bookAbbreviation: "Gen",
            osisRef: "Gen.1",
            isNewTestament: false,
            features: OsisFeatures(type: "hebrew", keyName: "H00430"),
            hasStrongs: true,
            ordinalRange: [1, 31],
            language: "en",
            direction: "ltr"
        )
        let fragmentObject = try bridgeJSONObject(fragment)
        assertJSONKeys(
            fragmentObject,
            [
                "xml",
                "key",
                "keyName",
                "v11n",
                "bookCategory",
                "bookInitials",
                "bookAbbreviation",
                "osisRef",
                "isNewTestament",
                "features",
                "hasStrongs",
                "ordinalRange",
                "language",
                "direction",
            ]
        )
        XCTAssertEqual(fragmentObject["hasStrongs"] as? Bool, true)
        let features = try XCTUnwrap(fragmentObject["features"] as? [String: Any])
        assertJSONKeys(features, ["type", "keyName"])

        let label = LabelData(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Important",
            style: BookmarkStyleData(
                color: 0xFFFF0000,
                isSpeak: true,
                isParagraphBreak: true,
                underline: true,
                underlineWholeVerse: true,
                markerStyle: true,
                markerStyleWholeVerse: true,
                hideStyle: true,
                hideStyleWholeVerse: true,
                customIcon: "star"
            ),
            isRealLabel: true
        )
        let labelObject = try bridgeJSONObject(label)
        assertJSONKeys(labelObject, ["id", "name", "style", "isRealLabel"])

        let style = try XCTUnwrap(labelObject["style"] as? [String: Any])
        assertJSONKeys(
            style,
            [
                "color",
                "isSpeak",
                "isParagraphBreak",
                "underline",
                "underlineWholeVerse",
                "markerStyle",
                "markerStyleWholeVerse",
                "hideStyle",
                "hideStyleWholeVerse",
                "customIcon",
            ]
        )

        let query = SelectionQuery(
            bookInitials: "KJV",
            osisRef: "Gen.1.1-Gen.1.3",
            startOrdinal: 0,
            startOffset: 1,
            endOrdinal: 2,
            endOffset: 50,
            bookmarks: ["id1", "id2"],
            text: "In the beginning God created..."
        )
        let queryObject = try bridgeJSONObject(query)
        assertJSONKeys(
            queryObject,
            [
                "bookInitials",
                "osisRef",
                "startOrdinal",
                "startOffset",
                "endOrdinal",
                "endOffset",
                "bookmarks",
                "text",
            ]
        )
    }

    /**
     Protects the Swift-to-Vue bridge payload key contract for plain OSIS fragments.

     Plain Bible fragments often omit an explicit `features` argument because no Strong's or
     morphology metadata is available. A passing test proves those fragments still emit the
     TypeScript-required `features` object as `{}` rather than omitting the key from bridge JSON.
     */
    func testBridgePayloadIncludesEmptyFeaturesObjectByDefault() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1",
            keyName: "Genesis 1",
            bookInitials: "KJV"
        )

        let fragmentObject = try bridgeJSONObject(fragment)

        let features = try XCTUnwrap(fragmentObject["features"] as? [String: Any])
        XCTAssertTrue(features.isEmpty)
    }

    #if os(iOS)
    func testDownloadLinkInitialsAreParsedForDownloadsSearch() {
        XCTAssertEqual(
            BibleReaderController.downloadSearchText(from: "download://?initials=KJV"),
            "KJV"
        )
        XCTAssertEqual(
            BibleReaderController.downloadSearchText(from: "download://?initials=StrongsHebrew%20"),
            "StrongsHebrew"
        )
        XCTAssertNil(BibleReaderController.downloadSearchText(from: "download://"))
        XCTAssertNil(BibleReaderController.downloadSearchText(from: "download://?initials="))
    }

    @MainActor
    func testDownloadLinkRoutesInitialsToDownloadsPresentation() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var requestedSearchText: String?
        controller.onRequestOpenDownloads = { requestedSearchText = $0 }

        controller.bridge(bridge, openExternalLink: "download://?initials=KJV")

        XCTAssertEqual(requestedSearchText, "KJV")

        requestedSearchText = "stale"
        controller.bridge(bridge, openExternalLink: "download://")

        XCTAssertNil(requestedSearchText)
    }

    func testBuildStrongsMultiDocJSONReturnsInstallFallbackWhenNoStrongsDictionaryIsInstalled() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        let multiDocJSON = try XCTUnwrap(
            controller.buildStrongsMultiDocJSON(strongs: ["H00430"], robinson: []),
            "Expected Android-style missing-document fallback when no Strong's dictionary is installed"
        )
        let payloadData = try XCTUnwrap(multiDocJSON.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
        XCTAssertEqual(fragment["bookCategory"] as? String, "DICTIONARY")
        XCTAssertEqual(fragment["keyName"] as? String, "00430")
        XCTAssertEqual(features["type"] as? String, "hebrew")
        XCTAssertEqual(features["keyName"] as? String, "00430")
        XCTAssertTrue((fragment["xml"] as? String)?.contains("No dictionary module installed") == true)
        XCTAssertTrue((fragment["xml"] as? String)?.contains("download://") == true)
        XCTAssertFalse((fragment["xml"] as? String)?.contains("initials=") == true)
    }

    @MainActor
    func testStrongsLinkEmitsVueDocumentInsteadOfNativeSheet() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(bridge, openExternalLink: "ab-w://?strong=H00430")

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
        XCTAssertEqual(fragment["bookCategory"] as? String, "DICTIONARY")
        XCTAssertEqual(features["type"] as? String, "hebrew")
        XCTAssertEqual(features["keyName"] as? String, "00430")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=dictionary;module=StrongsHebrew;book=H00430;chapter=none;key=H00430"
        )
    }

    @MainActor
    func testStrongsLinkUsesLinksWindowRoutingCallbackWhenAvailable() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var routedPayload: (json: String, book: String, key: String)?
        controller.onOpenDefinitionDocumentInLinksWindow = { documentJSON, renderedBook, renderedKey in
            routedPayload = (json: documentJSON, book: renderedBook, key: renderedKey)
        }

        controller.bridge(bridge, openExternalLink: "ab-w://?strong=H00430")

        let payload = try XCTUnwrap(routedPayload)
        XCTAssertTrue(payload.json.contains(#""contentType":"strongs""#))
        XCTAssertEqual(payload.book, "Strongs")
        XCTAssertEqual(payload.key, "strongs")
        XCTAssertEqual(controller.renderedContentState, BibleReaderController.emptyRenderedContentState)

        let targetController = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        targetController.loadDefinitionDocument(
            payload.json,
            renderedBook: payload.book,
            renderedKey: payload.key
        )
        XCTAssertEqual(
            targetController.renderedContentState,
            "category=dictionary;module=StrongsHebrew;book=H00430;chapter=none;key=H00430"
        )

        targetController.bridge(BibleBridge(), saveState: #"{"selectedStrongsDict":"HebrewGreek"}"#)
        XCTAssertEqual(
            targetController.renderedContentState,
            "category=dictionary;module=HebrewGreek;book=H00430;chapter=none;key=H00430"
        )
    }

    @MainActor
    func testDefinitionDocumentRequestedBeforeClientReadyReplaysAfterClientReady() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let documentJSON = try XCTUnwrap(
            controller.buildStrongsMultiDocJSON(strongs: ["H00430"], robinson: [])
        )

        controller.loadDefinitionDocument(
            documentJSON,
            renderedBook: "Strongs",
            renderedKey: "strongs"
        )
        let scriptCountBeforeClientReady = recordedScripts().count

        controller.bridgeDidSetClientReady(bridge)

        let clientReadyScripts = Array(recordedScripts().dropFirst(scriptCountBeforeClientReady))
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: clientReadyScripts, event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(payload["contentType"] as? String, "strongs")
        XCTAssertEqual(features["type"] as? String, "hebrew")
        XCTAssertEqual(features["keyName"] as? String, "00430")
        XCTAssertNotEqual(fragment["osisRef"] as? String, "Gen.1")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=dictionary;module=StrongsHebrew;book=H00430;chapter=none;key=H00430"
        )
    }

    @MainActor
    func testLoadCurrentContentEmitsBookIntroAndChapterMarkerForSecondCorinthiansOne() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let secondCorinthians = try XCTUnwrap(
            controller.bookList.first(where: { $0.osisId == "2Cor" })?.name
        )

        controller.navigateTo(book: secondCorinthians, chapter: 1, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        let hasSecondCorinthiansChapterMarker = addDocumentsScript.range(
            of: #"osisID=\\"2Cor\.1\\""#,
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            addDocumentsScript.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"),
            "Expected emitted payload to contain the book intro title. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(
            hasSecondCorinthiansChapterMarker,
            "Expected emitted payload to contain a chapter-start marker for 2Cor.1. Script: \(addDocumentsScript)"
        )
    }

    @MainActor
    func testLoadCurrentContentEmitsRenderableChapterMarkerForSecondCorinthiansTwo() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let secondCorinthians = try XCTUnwrap(
            controller.bookList.first(where: { $0.osisId == "2Cor" })?.name
        )

        controller.navigateTo(book: secondCorinthians, chapter: 2, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        let hasSecondCorinthiansChapterMarker = addDocumentsScript.range(
            of: #"osisID=\\"2Cor\.2\\""#,
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            hasSecondCorinthiansChapterMarker,
            "Expected emitted payload to contain a chapter-start marker for 2Cor.2. Script: \(addDocumentsScript)"
        )
        XCTAssertFalse(
            addDocumentsScript.contains("eID\\\":\\\"gen1794") && !addDocumentsScript.contains("sID\\\":\\\"gen1794"),
            "Expected an opening chapter marker in the emitted document payload, not only a closing tag. Script: \(addDocumentsScript)"
        )
    }
    @MainActor
    func testLoadCurrentContentDoesNotHighlightRestoredReadingPosition() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 5
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.restoreSavedPosition()
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )

        XCTAssertTrue(
            addDocumentsScript.contains("\"originalOrdinalRange\":null"),
            "Expected restored reading position to avoid verse highlighting. Script: \(addDocumentsScript)"
        )
    }

    @MainActor
    func testLoadCurrentContentHighlightsExplicitVerseNavigationTarget() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )

        XCTAssertTrue(
            addDocumentsScript.contains("\"originalOrdinalRange\":[5,5]"),
            "Expected explicit verse navigation to preserve the original highlighted target. Script: \(addDocumentsScript)"
        )
    }

    @MainActor
    func testMultiReferenceLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var showedCrossReferences = false
        controller.onShowCrossReferences = { _ in showedCrossReferences = true }

        controller.bridge(bridge, openExternalLink: "multi://?osis=Gen.1.1&osis=Exod.2.1&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertFalse(showedCrossReferences)
        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected multi:// to render a Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""bookCategory":"BIBLE""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Exod.2.1""#))
    }

    @MainActor
    func testMultiReferenceOsisLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var showedCrossReferences = false
        controller.onShowCrossReferences = { _ in showedCrossReferences = true }

        controller.bridge(bridge, openExternalLink: "osis://?osis=Gen.1.1,Exod.2.1&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertFalse(showedCrossReferences)
        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected multi-reference osis:// to render a Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Exod.2.1""#))
    }

    @MainActor
    func testSingleOsisReferenceStillNavigatesWithoutMultiDocument() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        var showedCrossReferences = false
        controller.onShowCrossReferences = { _ in showedCrossReferences = true }

        controller.bridge(bridge, openExternalLink: "osis://?osis=Exod.2.1&v11n=KJVA")

        XCTAssertFalse(showedCrossReferences)
        XCTAssertEqual(controller.currentBook, "Exodus")
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertFalse(recordedScripts().contains { $0.contains(#""type":"multi""#) })
    }

    /**
     Validates the native-to-WebView reader configuration contract for Android parity fields.

     The setup writes pane text-display settings, app settings, workspace state, and reading
     progress settings before the client-ready handshake. The expected result is a `set_config`
     payload whose `config` object includes every renderer field consumed by bibleview-js; a failure
     means the native settings model can drift from the shared Android renderer contract.
     */
    @MainActor
    func testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Reader Config")
        let studyPadCursorId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let autoAssignLabelId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let hiddenLabelId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        workspace.workspaceSettings = WorkspaceSettings(
            autoAssignLabels: [autoAssignLabelId],
            studyPadCursors: [studyPadCursorId: 7],
            hideCompareDocuments: ["KJV", "ESV"]
        )
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        _ = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow

        settingsStore.setBool(.showActiveWindowIndicator, value: true)
        settingsStore.setBool(.showErrorBox, value: true)
        settingsStore.setBool(.monochromeMode, value: true)
        settingsStore.setBool(.disableAnimations, value: true)
        settingsStore.setBool(.disableClickToEdit, value: true)
        settingsStore.setInt(.fontSizeMultiplier, value: 125)
        settingsStore.setString(.notesContentType, value: "PLAINTEXT")
        settingsStore.setStringSet(.disableBibleBookmarkModalButtons, values: ["speak", "bookmark"])
        settingsStore.setStringSet(.disableGenBookmarkModalButtons, values: ["generic-note"])
        settingsStore.setStringSet(
            .experimentalFeatures,
            values: ["bookmark_edit_actions", "add_paragraph_break"]
        )

        var display = TextDisplaySettings()
        display.showVerseNumbers = false
        display.strongsMode = 2
        display.showMorphology = true
        display.showRedLetters = false
        display.showVersePerLine = true
        display.showSectionTitles = false
        display.showFootNotes = true
        display.showFootNotesInline = true
        display.showXrefs = true
        display.expandXrefs = true
        display.fontFamily = "Georgia"
        display.fontSize = 21
        display.showBookmarks = false
        display.showMyNotes = false
        display.hyphenation = false
        display.lineSpacing = 14
        display.justifyText = true
        display.marginLeft = 5
        display.marginRight = 6
        display.maxWidth = 410
        display.topMargin = 12
        display.showPageNumber = true
        display.infiniteScroll = false
        display.nonStrongsWordItalic = true
        display.showMarkAsReadButton = false
        display.showTitleScrollButton = true
        display.showMemorizationIndicators = true
        display.showAiDocMarkers = false
        display.pageScrollAmount = 66
        display.showOrdinals = true
        display.bookmarksHideLabels = [hiddenLabelId]
        display.dayBackground = -2
        display.dayNoise = 3
        display.nightBackground = -123_456
        display.nightNoise = 4
        display.dayTextColor = -654_321
        display.nightTextColor = -111_111

        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = settingsStore
        controller.readingProgressStore?.saveSettings(
            ReadingProgressSettingsSnapshot(
                autoTrackReading: true,
                autoMarkMemorized: false,
                memorizeTypeFullWords: true,
                memorizeWordVisibility: "dim",
                memorizeErrorHeatmap: false,
                memorizeScrambleHideUsed: true,
                memorizeIncludeReference: false
            )
        )
        controller.displaySettings = display
        controller.nightMode = true
        controller.activeWindow = firstWindow
        controller.windowManagerRef = windowManager

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: recordedScripts())
        assertJSONKeys(payload, ["config", "appSettings", "initial"])
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        let appSettings = try XCTUnwrap(payload["appSettings"] as? [String: Any])
        assertJSONKeys(
            config,
            [
                "developmentMode",
                "testMode",
                "showAnnotations",
                "showChapterNumbers",
                "showVerseNumbers",
                "strongsMode",
                "showMorphology",
                "showRedLetters",
                "showVersePerLine",
                "showNonCanonical",
                "makeNonCanonicalItalic",
                "showSectionTitles",
                "showStrongsSeparately",
                "showFootNotes",
                "showFootNotesInline",
                "showXrefs",
                "expandXrefs",
                "fontFamily",
                "fontSize",
                "disableBookmarking",
                "showBookmarks",
                "showMyNotes",
                "bookmarksHideLabels",
                "bookmarksAssignLabels",
                "colors",
                "hyphenation",
                "lineSpacing",
                "justifyText",
                "marginSize",
                "topMargin",
                "showPageNumber",
                "infiniteScroll",
                "nonStrongsWordItalic",
                "showMarkAsReadButton",
                "showTitleScrollButton",
                "showMemorizationIndicators",
                "showAiDocMarkers",
                "pageScrollAmount",
                "showOrdinals",
            ]
        )
        assertJSONKeys(
            appSettings,
            [
                "nightMode",
                "errorBox",
                "favouriteLabels",
                "recentLabels",
                "studyPadCursors",
                "autoAssignLabels",
                "hideCompareDocuments",
                "activeWindow",
                "rightToLeft",
                "actionMode",
                "hasActiveIndicator",
                "activeSince",
                "limitAmbiguousModalSize",
                "windowId",
                "disableBibleModalButtons",
                "disableGenericModalButtons",
                "monochromeMode",
                "disableAnimations",
                "disableClickToEdit",
                "notesContentType",
                "fontSizeMultiplier",
                "enabledExperimentalFeatures",
                "autoTrackReading",
                "readingProgressSettings",
            ]
        )
        let colors = try XCTUnwrap(config["colors"] as? [String: Any])
        assertJSONKeys(
            colors,
            ["dayBackground", "dayNoise", "nightBackground", "nightNoise", "dayTextColor", "nightTextColor"]
        )
        let marginSize = try XCTUnwrap(config["marginSize"] as? [String: Any])
        assertJSONKeys(marginSize, ["marginLeft", "marginRight", "maxWidth"])

        XCTAssertEqual(payload["initial"] as? Bool, false)
        XCTAssertEqual(config["showVerseNumbers"] as? Bool, false)
        XCTAssertEqual(config["strongsMode"] as? Int, 2)
        XCTAssertEqual(config["showMorphology"] as? Bool, true)
        XCTAssertEqual(config["showRedLetters"] as? Bool, false)
        XCTAssertEqual(config["showVersePerLine"] as? Bool, true)
        XCTAssertEqual(config["showSectionTitles"] as? Bool, false)
        XCTAssertEqual(config["showFootNotes"] as? Bool, true)
        XCTAssertEqual(config["showFootNotesInline"] as? Bool, true)
        XCTAssertEqual(config["showXrefs"] as? Bool, true)
        XCTAssertEqual(config["expandXrefs"] as? Bool, true)
        XCTAssertEqual(config["fontFamily"] as? String, "Georgia")
        XCTAssertEqual(config["fontSize"] as? Int, 21)
        XCTAssertEqual(config["showBookmarks"] as? Bool, false)
        XCTAssertEqual(config["showMyNotes"] as? Bool, false)
        XCTAssertEqual(
            try XCTUnwrap(config["bookmarksHideLabels"] as? [String]),
            [hiddenLabelId.uuidString]
        )
        XCTAssertEqual(config["hyphenation"] as? Bool, false)
        XCTAssertEqual(config["lineSpacing"] as? Int, 14)
        XCTAssertEqual(config["justifyText"] as? Bool, true)
        XCTAssertEqual(config["topMargin"] as? Int, 12)
        XCTAssertEqual(config["showPageNumber"] as? Bool, true)
        XCTAssertEqual(config["infiniteScroll"] as? Bool, false)
        XCTAssertEqual(config["nonStrongsWordItalic"] as? Bool, true)
        XCTAssertEqual(config["showMarkAsReadButton"] as? Bool, false)
        XCTAssertEqual(config["showTitleScrollButton"] as? Bool, true)
        XCTAssertEqual(config["showMemorizationIndicators"] as? Bool, true)
        XCTAssertEqual(config["showAiDocMarkers"] as? Bool, false)
        XCTAssertEqual(config["pageScrollAmount"] as? Int, 66)
        XCTAssertEqual(config["showOrdinals"] as? Bool, true)
        XCTAssertEqual(colors["dayBackground"] as? Int, -2)
        XCTAssertEqual(colors["dayNoise"] as? Int, 3)
        XCTAssertEqual(colors["nightBackground"] as? Int, -123_456)
        XCTAssertEqual(colors["nightNoise"] as? Int, 4)
        XCTAssertEqual(colors["dayTextColor"] as? Int, -654_321)
        XCTAssertEqual(colors["nightTextColor"] as? Int, -111_111)
        XCTAssertEqual(marginSize["marginLeft"] as? Int, 5)
        XCTAssertEqual(marginSize["marginRight"] as? Int, 6)
        XCTAssertEqual(marginSize["maxWidth"] as? Int, 410)

        XCTAssertEqual(appSettings["nightMode"] as? Bool, true)
        XCTAssertEqual(appSettings["errorBox"] as? Bool, true)
        XCTAssertEqual(appSettings["activeWindow"] as? Bool, true)
        XCTAssertEqual(appSettings["hasActiveIndicator"] as? Bool, true)
        XCTAssertEqual(appSettings["rightToLeft"] as? Bool, false)
        XCTAssertEqual(appSettings["actionMode"] as? Bool, false)
        XCTAssertEqual(appSettings["limitAmbiguousModalSize"] as? Bool, false)
        XCTAssertEqual(appSettings["windowId"] as? String, "")
        XCTAssertEqual(appSettings["monochromeMode"] as? Bool, true)
        XCTAssertEqual(appSettings["disableAnimations"] as? Bool, true)
        XCTAssertEqual(appSettings["disableClickToEdit"] as? Bool, true)
        XCTAssertEqual(appSettings["notesContentType"] as? String, "HTML")
        XCTAssertEqual(appSettings["fontSizeMultiplier"] as? Double, 1.25)
        XCTAssertEqual(appSettings["autoTrackReading"] as? Bool, true)
        XCTAssertNotNil(appSettings["activeSince"] as? Int)
        let readingProgressSettings = try XCTUnwrap(appSettings["readingProgressSettings"] as? [String: Any])
        assertJSONKeys(
            readingProgressSettings,
            [
                "autoMarkMemorized",
                "memorizeTypeFullWords",
                "memorizeWordVisibility",
                "memorizeErrorHeatmap",
                "memorizeScrambleHideUsed",
                "memorizeIncludeReference",
            ]
        )
        XCTAssertEqual(readingProgressSettings["autoMarkMemorized"] as? Bool, false)
        XCTAssertEqual(readingProgressSettings["memorizeTypeFullWords"] as? Bool, true)
        XCTAssertEqual(readingProgressSettings["memorizeWordVisibility"] as? String, "dim")
        XCTAssertEqual(readingProgressSettings["memorizeErrorHeatmap"] as? Bool, false)
        XCTAssertEqual(readingProgressSettings["memorizeScrambleHideUsed"] as? Bool, true)
        XCTAssertEqual(readingProgressSettings["memorizeIncludeReference"] as? Bool, false)
        XCTAssertEqual(
            appSettings["studyPadCursors"] as? [String: Int],
            [studyPadCursorId.uuidString: 7]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["autoAssignLabels"] as? [String])),
            [autoAssignLabelId.uuidString]
        )
        XCTAssertEqual(Set(try XCTUnwrap(appSettings["hideCompareDocuments"] as? [String])), ["ESV", "KJV"])
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["disableBibleModalButtons"] as? [String])),
            ["bookmark", "speak"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["disableGenericModalButtons"] as? [String])),
            ["generic-note"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["enabledExperimentalFeatures"] as? [String])),
            ["add_paragraph_break", "bookmark_edit_actions"]
        )
    }

    @MainActor
    func testToggleCompareDocumentPersistsWorkspaceHiddenStateAndReemitsConfig() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let workspace = workspaceStore.createWorkspace(name: "Compare State")
        workspace.workspaceSettings = WorkspaceSettings(hideCompareDocuments: ["ESV"])
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let controller = BibleReaderController(bridge: bridge)
        controller.activeWindow = window

        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            try? context.save()
        }

        controller.bridgeDidSetClientReady(bridge)
        let initialPayload = try setConfigPayload(from: recordedScripts())
        let initialAppSettings = try XCTUnwrap(initialPayload["appSettings"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(initialAppSettings["hideCompareDocuments"] as? [String])), ["ESV"])

        let initialScriptCount = recordedScripts().count
        XCTAssertEqual(bridge.dispatchMessage(method: "toggleCompareDocument", args: ["KJV"]), .handled)

        XCTAssertEqual(workspace.workspaceSettings?.hideCompareDocuments, ["ESV", "KJV"])
        XCTAssertEqual(persistCount, 1)
        let togglePayload = try setConfigPayload(from: Array(recordedScripts().dropFirst(initialScriptCount)))
        let toggleAppSettings = try XCTUnwrap(togglePayload["appSettings"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(toggleAppSettings["hideCompareDocuments"] as? [String])), ["ESV", "KJV"])
    }

    @MainActor
    func testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Reader Config")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow
        settingsStore.setBool(.showActiveWindowIndicator, value: true)

        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = settingsStore
        controller.activeWindow = secondWindow
        controller.windowManagerRef = windowManager

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: recordedScripts())
        let appSettings = try XCTUnwrap(payload["appSettings"] as? [String: Any])
        XCTAssertEqual(appSettings["activeWindow"] as? Bool, false)
        XCTAssertEqual(appSettings["hasActiveIndicator"] as? Bool, false)
    }

    @MainActor
    func testRequestMoreToBeginningSendsDocumentResponseWithOriginalCallId() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 2, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let baselineCount = recordedScripts().count
        controller.bridge(bridge, requestMoreToBeginning: 3701)

        let responseScript = try XCTUnwrap(
            recordedScripts().dropFirst(baselineCount).first {
                $0.contains("bibleView.response(3701")
            }
        )

        XCTAssertTrue(
            responseScript.hasPrefix("bibleView.response(3701, {"),
            "Expected a document JSON response for the original callId. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""key":"Gen.1""#),
            "Expected the previous chapter document to be returned. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""osisFragment""#),
            "Expected the response payload to preserve the Bible document shape. Script: \(responseScript)"
        )
    }

    @MainActor
    func testRefChooserDialogSendsResponseWithOriginalCallId() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.onRefChooserDialog = { completion in
            completion("Gen.1.1")
        }

        controller.bridge(bridge, refChooserDialog: 3702)

        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3702, "Gen.1.1");"#)
    }

    @MainActor
    func testParseRefSendsResponseWithOriginalCallId() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)

        controller.bridge(bridge, parseRef: 3703, text: "Genesis 1:1")

        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3703, "Gen.1.1");"#)
    }

    @MainActor
    func testMyDocumentRawContentBridgeSendsAndroidCompatiblePayloadAndNullFallback() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let sourcePromptId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            sourcePromptId: sourcePromptId
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Raw *markdown*")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let controller = BibleReaderController(bridge: bridge)
        controller.myDocumentStore = store
        var sharedText: String?
        controller.onShareVerseText = { sharedText = $0 }

        controller.bridge(bridge, getMyDocumentPageRawContent: 3704, bookInitials: "MYDOC", pageKey: "intro")
        controller.bridge(bridge, shareMyDocumentContent: "MYDOC", pageKey: "intro")
        controller.bridge(bridge, getMyDocumentPageRawContent: 3705, bookInitials: "MYDOC", pageKey: "missing")

        let payloadScript = try XCTUnwrap(recordedScripts().first { $0.contains("bibleView.response(3704") })
        XCTAssertTrue(payloadScript.hasPrefix("bibleView.response(3704, {"))
        XCTAssertTrue(payloadScript.contains(#""pageId":"11111111-1111-1111-1111-111111111111""#))
        XCTAssertTrue(payloadScript.contains(#""contentType":"MARKDOWN""#))
        XCTAssertTrue(payloadScript.contains(#""content":"Raw *markdown*""#))
        XCTAssertTrue(payloadScript.contains(#""title":"Intro""#))
        XCTAssertTrue(payloadScript.contains(#""sourcePromptId":"22222222-2222-2222-2222-222222222222""#))
        XCTAssertEqual(sharedText, "Intro\n\nRaw *markdown*")
        XCTAssertEqual(recordedScripts().last, "bibleView.response(3705, null);")
    }

    @MainActor
    func testMyDocumentEditBridgePersistsContentAndReloadsVisiblePage() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            languageCode: "en"
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Original *markdown*")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let controller = BibleReaderController(bridge: bridge)
        controller.myDocumentStore = store
        controller.bridge(bridge, selectionChanged: "Selected text")
        controller.bridge(bridge, setEditing: true)

        XCTAssertTrue(controller.loadMyDocumentPage(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=MYDOC;book=My Document;chapter=none;key=intro"
        )
        XCTAssertFalse(controller.hasActiveSelection)
        XCTAssertEqual(controller.selectedText, "")
        XCTAssertFalse(controller.editingInWebView)
        XCTAssertTrue(recordedScripts().contains("window.getSelection().removeAllRanges();"))

        controller.bridge(
            bridge,
            saveMyDocumentPageContent: "MYDOC",
            pageId: pageId.uuidString,
            content: "Edited **markdown**",
            title: "Renamed"
        )

        let savedPayload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(savedPayload.content, "Edited **markdown**")
        XCTAssertEqual(savedPayload.title, "Renamed")

        controller.bridge(bridge, reloadMyDocumentPage: "MYDOC")

        let addDocumentScripts = recordedScripts().filter { $0.contains("emit('add_documents'") }
        XCTAssertEqual(addDocumentScripts.count, 2)

        let reloadedScript = try XCTUnwrap(addDocumentScripts.last)
        XCTAssertTrue(reloadedScript.contains(#""bookInitials":"MYDOC""#))
        XCTAssertTrue(reloadedScript.contains(#""bookCategory":"GENERAL_BOOK""#))
        XCTAssertTrue(reloadedScript.contains(#""isMyDocument":true"#))
        XCTAssertTrue(reloadedScript.contains(#""myDocumentPageId":"33333333-3333-3333-3333-333333333333""#))
        XCTAssertTrue(reloadedScript.contains(#""keyName":"Renamed""#))
        XCTAssertTrue(reloadedScript.contains("Edited **markdown**"))
        XCTAssertFalse(reloadedScript.contains("Original *markdown*"))
    }

    @MainActor
    func testMyDocumentAIPageBridgeDeletesActivePageAndHandsOffRegeneration() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let aiPageId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let userPageId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let promptId = try XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let aiPage = MyDocumentPage(
            id: aiPageId,
            title: "AI Page",
            pageKey: "ai",
            contentType: .markdown,
            sourcePromptId: promptId,
            languageCode: "en"
        )
        let aiContent = MyDocumentPageContent(pageId: aiPageId, content: "AI generated content")
        let aiCacheEntry = AiPageCacheEntry(
            pageId: aiPageId,
            sourcePromptId: promptId,
            sourceContext: #"{"osisRef":"Gen.1"}"#,
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 31,
            sourceModelName: "model"
        )
        let userPage = MyDocumentPage(
            id: userPageId,
            title: "User Page",
            pageKey: "user",
            contentType: .markdown
        )
        let userContent = MyDocumentPageContent(pageId: userPageId, content: "User content")

        aiPage.pageContent = aiContent
        aiPage.document = document
        aiCacheEntry.page = aiPage
        aiPage.aiPageCacheEntries = [aiCacheEntry]
        userPage.pageContent = userContent
        userPage.document = document
        document.pages = [aiPage, userPage]
        context.insert(document)
        context.insert(aiPage)
        context.insert(aiContent)
        context.insert(aiCacheEntry)
        context.insert(userPage)
        context.insert(userContent)
        try context.save()

        let controller = BibleReaderController(bridge: bridge)
        controller.myDocumentStore = store
        var regeneratedContext: MyDocumentAIPageActionContext?
        var persistCount = 0
        controller.onRegenerateMyDocumentPage = { regeneratedContext = $0 }
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, regenerateMyDocumentPage: aiPageId.uuidString)
        XCTAssertEqual(regeneratedContext?.pageId, aiPageId)
        XCTAssertEqual(regeneratedContext?.sourcePromptId, promptId)
        XCTAssertEqual(regeneratedContext?.sourceContext, #"{"osisRef":"Gen.1"}"#)
        XCTAssertEqual(regeneratedContext?.sourceModelName, "model")

        regeneratedContext = nil
        controller.bridge(bridge, regenerateMyDocumentPage: userPageId.uuidString)
        XCTAssertNil(regeneratedContext)

        controller.bridge(bridge, deleteMyDocumentPage: userPageId.uuidString)
        XCTAssertNotNil(store.rawContentPayload(bookInitials: "AIDocuments", pageKey: "user"))

        XCTAssertTrue(controller.loadMyDocumentPage(bookInitials: "AIDocuments", pageKey: "ai"))
        let clearDocumentCountBeforeDelete = recordedScripts().filter { $0.contains("emit('clear_document'") }.count

        controller.bridge(bridge, deleteMyDocumentPage: aiPageId.uuidString)

        XCTAssertNil(store.rawContentPayload(bookInitials: "AIDocuments", pageKey: "ai"))
        XCTAssertNotNil(store.rawContentPayload(bookInitials: "AIDocuments", pageKey: "user"))
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=bible;module=KJV;book=Genesis;chapter=1;key=Gen.1"
        )
        XCTAssertGreaterThan(
            recordedScripts().filter { $0.contains("emit('clear_document'") }.count,
            clearDocumentCountBeforeDelete
        )
    }

    func testOpenExternalLinkRoutesAbErrorToIssueTrackerURL() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        var openedURL: URL?
        controller.onOpenExternalURL = { openedURL = $0 }

        controller.bridge(bridge, openExternalLink: "ab-error://error")

        XCTAssertEqual(openedURL?.absoluteString, "https://github.com/AndBible/and-bible/issues")
    }
    #endif

    func testNavigateToPersistsSelectedVerseOnPageManager() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)

        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

    func testDidScrollToOrdinalDebouncesPersistenceWithinCurrentChapter() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        let persisted = expectation(description: "Visible verse state persisted after debounce")
        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            persisted.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: 5, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)

        wait(for: [persisted], timeout: 2.0)

        XCTAssertEqual(persistCount, 1)
    }

    func testDidScrollToOrdinalPersistsImmediatelyWhenChapterChanges() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, didScrollToOrdinal: 45, key: "Gen.2", atChapterTop: false)

        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

}
