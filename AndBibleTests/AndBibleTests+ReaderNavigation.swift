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
    /**
     Builds a fully shaped placeholder bookmark payload for document-payload factory tests.

     The factory tests below use empty bookmark arrays and fail if the bookmark projection closure
     is invoked. Swift still requires the closure to return the exact bridge DTO type, so this
     helper centralizes the inert value and keeps the tests focused on document schema behavior.
     */
    private func emptyBibleBookmarkDataForFactoryTest() -> BibleBookmarkData {
        BibleBookmarkData(
            id: "",
            type: "bookmark",
            hashCode: 0,
            ordinalRange: [],
            offsetRange: nil,
            labels: [],
            bookInitials: "",
            bookName: "",
            bookAbbreviation: "",
            createdAt: 0,
            text: "",
            fullText: "",
            bookmarkToLabels: [],
            primaryLabelId: nil,
            lastUpdatedOn: 0,
            notes: nil,
            notesContentType: nil,
            hasNote: false,
            wholeVerse: true,
            customIcon: nil,
            editAction: EditActionData(),
            osisRef: "",
            originalOrdinalRange: [],
            verseRange: "",
            verseRangeOnlyNumber: "",
            verseRangeAbbreviated: "",
            v11n: "KJVA",
            osisFragment: nil
        )
    }

    /**
     Protects Android/JSword ordinal parity for compare links.

     The web client sends verse ordinals into the native compare bridge. Android resolves those
     ordinals through JSword's active versification, whose values include intro slots and therefore
     are not `(chapter - 1) * 40 + verse`. The bundled KJV module supplies the same SWORD
     versification data here; a failure means compare links have drifted back toward synthetic
     ordinals and can open the wrong verse range.
     */
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
        let activeModule = try XCTUnwrap(manager.module(named: activeModuleName))

        func ordinal(for verse: Int) throws -> Int {
            try XCTUnwrap(
                activeModule.verseOrdinal(osisBookId: "2Cor", chapter: chapter, verse: verse)
            )
        }

        controller.navigateTo(book: secondCorinthians, chapter: chapter, verse: 1)

        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "compare",
                args: [
                    activeModuleName,
                    try ordinal(for: startVerse),
                    try ordinal(for: endVerse),
                ]
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

    /**
     Protects the extracted compare document builder's Android `MultiDocument` contract.

     Android renders Compare through `FakeBookFactory.compareDocument` as a multi-fragment Bible
     document with `compare=true`. This test exercises the builder directly against the bundled KJV
     SWORD fixture so the controller can remain an orchestration boundary while the builder owns
     module ordering, verse extraction, range titles, and typed bridge JSON assembly.
     */
    func testCompareDocumentBuilderBuildsAndroidMultiDocumentPayload() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let moduleInfo = try XCTUnwrap(manager.installedModules().first { $0.name == "KJV" })
        let builder = BibleReaderCompareDocumentBuilder(
            swordManager: manager,
            installedBibleModules: [moduleInfo],
            activeModuleName: "KJV"
        )

        let request = try XCTUnwrap(
            builder.makeRequest(
                osisBookId: "2Cor",
                bookName: "2 Corinthians",
                chapter: 2,
                isNewTestament: true,
                startVerse: 5,
                endVerse: 7
            )
        )
        let json = try XCTUnwrap(BibleReaderCompareDocumentBuilder.buildDocumentJSON(request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "multi")
        XCTAssertEqual(object["compare"] as? Bool, true)
        let fragments = try XCTUnwrap(object["osisFragments"] as? [[String: Any]])
        XCTAssertEqual(fragments.count, 1)
        let fragment = try XCTUnwrap(fragments.first)
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.bible.rawValue)
        XCTAssertEqual(fragment["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragment["bookAbbreviation"] as? String, "KJV")
        XCTAssertEqual(fragment["osisRef"] as? String, "2Cor.2.5-2Cor.2.7")
        XCTAssertEqual(fragment["keyName"] as? String, "2 Corinthians 2:5-7")
        XCTAssertEqual(fragment["isNewTestament"] as? Bool, true)
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertEqual(fragment["language"] as? String, "en")
        XCTAssertEqual(fragment["direction"] as? String, "ltr")
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [
            try XCTUnwrap(manager.module(named: "KJV")?.verseOrdinal(osisBookId: "2Cor", chapter: 2, verse: 5)),
            try XCTUnwrap(manager.module(named: "KJV")?.verseOrdinal(osisBookId: "2Cor", chapter: 2, verse: 7)),
        ])
    }

    /**
     Protects the extracted reader document payload factory's Bible document contract.

     Android and Vue consume document ordinals, Strong's capability, reading progress, and
     memorization metadata from the same document object. This test supplies deterministic
     collaborators for those controller-owned dependencies and verifies the serialized JSON still
     carries them after the schema assembly moved out of `BibleReaderController`.
     */
    func testReaderDocumentPayloadFactoryBuildsBibleDocumentWithProgressContracts() throws {
        let factory = BibleReaderDocumentPayloadFactory(
            activeModuleName: "KJV",
            hasStrongs: true,
            bookmarkPayload: { bookmark in
                XCTFail("No bookmarks should be projected in this fixture: \(bookmark.id)")
                return self.emptyBibleBookmarkDataForFactoryTest()
            },
            chapterOrdinalRange: { book, chapter, verseCount in
                XCTAssertEqual(book, "Genesis")
                XCTAssertEqual(chapter, 1)
                XCTAssertEqual(verseCount, 3)
                return (start: 100, end: 103, verseCount: verseCount)
            },
            kjvBookOrdinal: { book in
                XCTAssertEqual(book, "Genesis")
                return 1
            },
            chapterReadCount: { kjvBookOrdinal, chapter in
                XCTAssertEqual(kjvBookOrdinal, 1)
                XCTAssertEqual(chapter, 1)
                return 2
            },
            memorizedOrdinals: { bookInitials, startOrdinal, endOrdinal in
                XCTAssertEqual(bookInitials, "KJV")
                XCTAssertEqual(startOrdinal, 100)
                XCTAssertEqual(endOrdinal, 103)
                return [100, 101]
            },
            targetOrdinals: { bookInitials, startOrdinal, endOrdinal in
                XCTAssertEqual(bookInitials, "KJV")
                XCTAssertEqual(startOrdinal, 100)
                XCTAssertEqual(endOrdinal, 103)
                return [103]
            }
        )

        let json = try XCTUnwrap(
            factory.documentJSON(
                BibleReaderDocumentPayloadRequest(
                    osisBookId: "Gen",
                    bookName: "Genesis",
                    chapter: 1,
                    verseCount: 3,
                    isNewTestament: false,
                    xml: #"<div><verse osisID="Gen.1.1">In the beginning</verse></div>"#
                )
            )
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])

        XCTAssertEqual(document["type"] as? String, "bible")
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(document["key"] as? String, "Gen.1")
        XCTAssertEqual(document["ordinalRange"] as? [Int], [100, 103])
        XCTAssertEqual(document["chapterReadCount"] as? Int, 2)
        XCTAssertEqual(document["memorizedOrdinals"] as? [Int], [100, 101])
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [103])
        XCTAssertEqual(fragment["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragment["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [100, 103])
    }

    /**
     Verifies Bible documents still fail closed when the active SWORD/JSword versification cannot
     resolve an ordinal range.

     The reader must not emit a Bible document with synthetic `[0, 0]` ordinals because bookmarks,
     memorization, scroll sync, and reading progress all depend on real JSword/SWORD ordinals.
     A failure means the extracted factory is masking missing module range data instead of
     preserving the controller's previous `nil` behavior.
     */
    func testReaderDocumentPayloadFactoryRejectsBibleDocumentWithoutOrdinalRange() {
        let factory = BibleReaderDocumentPayloadFactory(
            activeModuleName: "KJV",
            hasStrongs: false,
            bookmarkPayload: { _ in
                XCTFail("No bookmarks should be projected when ordinal range resolution fails")
                return self.emptyBibleBookmarkDataForFactoryTest()
            },
            chapterOrdinalRange: { _, _, _ in nil },
            kjvBookOrdinal: { _ in nil },
            chapterReadCount: { _, _ in nil },
            memorizedOrdinals: { _, _, _ in [] },
            targetOrdinals: { _, _, _ in [] }
        )

        XCTAssertNil(
            factory.documentJSON(
                BibleReaderDocumentPayloadRequest(
                    osisBookId: "Gen",
                    bookName: "Genesis",
                    chapter: 1,
                    verseCount: 31,
                    isNewTestament: false,
                    xml: "<div></div>"
                )
            )
        )
    }

    /**
     Protects the EPUB document path used by the shared Vue reader.

     EPUB sections are rendered as native HTML through `OsisDocument`, not the Bible document path.
     This matches the existing iOS bridge behavior while using the same document surface Android
     uses for general rendered content. A failure means EPUB content can regress to blank rendering
     because Vue may try to parse XHTML as OSIS.
     */
    func testReaderDocumentPayloadFactoryBuildsEpubNativeHtmlDocument() throws {
        let factory = BibleReaderDocumentPayloadFactory(
            activeModuleName: "KJV",
            hasStrongs: false,
            bookmarkPayload: { _ in
                XCTFail("EPUB documents do not project Bible bookmarks")
                return self.emptyBibleBookmarkDataForFactoryTest()
            },
            chapterOrdinalRange: { _, _, _ in
                XCTFail("EPUB documents should not resolve Bible ordinal ranges")
                return nil
            },
            kjvBookOrdinal: { _ in nil },
            chapterReadCount: { _, _ in nil },
            memorizedOrdinals: { _, _, _ in [] },
            targetOrdinals: { _, _, _ in [] }
        )

        let json = factory.epubDocumentJSON(
            bookName: "Chapter One",
            bookInitials: "Pilgrim",
            content: #"<html><body><a id="start"></a>Text</body></html>"#
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])

        XCTAssertEqual(document["type"] as? String, "osis")
        XCTAssertEqual(document["bookCategory"] as? String, "GENERAL_BOOK")
        XCTAssertEqual(document["bookInitials"] as? String, "Pilgrim")
        XCTAssertEqual(document["bookName"] as? String, "Chapter One")
        XCTAssertEqual(document["isNativeHtml"] as? Bool, true)
        XCTAssertEqual(document["ordinalRange"] as? [Int], [0, 0])
        XCTAssertEqual(fragment["xml"] as? String, #"<html><body><a id="start"></a>Text</body></html>"#)
        XCTAssertEqual(fragment["bookCategory"] as? String, "GENERAL_BOOK")
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, false)
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [0, 0])
    }

    /**
     Verifies the controller's auxiliary no-module fallbacks survive delegation to the loader.

     The module picker and auxiliary browsers can ask the reader to show dictionary, general-book,
     or map content before a module is selected. Android keeps those as reader documents rather than
     native alerts. A failure means the extraction changed the visible fallback document or the
     compact rendered-content state UI tests use to observe the active reader.
     */
    func testReaderAuxiliaryContentNoModuleFallbacksEmitReaderDocuments() throws {
        let cases: [
            (
                action: (BibleReaderController) -> Void,
                category: String,
                bookCategory: String,
                renderedState: String,
                expectedXML: String
            )
        ] = [
            (
                action: { $0.loadDictionaryEntry() },
                category: "dictionary",
                bookCategory: "DICTIONARY",
                renderedState: "category=dictionary;module=none;book=Dictionary;chapter=none;key=none",
                expectedXML: "No dictionary module is selected."
            ),
            (
                action: { $0.loadGeneralBookEntry() },
                category: "general_book",
                bookCategory: "GENERAL_BOOK",
                renderedState: "category=general_book;module=none;book=General Book;chapter=none;key=none",
                expectedXML: "No general book module is selected."
            ),
            (
                action: { $0.loadMapEntry() },
                category: "map",
                bookCategory: "MAP",
                renderedState: "category=map;module=none;book=Map;chapter=none;key=none",
                expectedXML: "No map module is selected."
            ),
        ]

        for testCase in cases {
            let (bridge, recordedScripts) = makeRecordingBridge()
            let controller = BibleReaderController(bridge: bridge, initializesSword: false)

            testCase.action(controller)

            let document = try XCTUnwrap(
                bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any],
                "Expected \(testCase.category) to emit an auxiliary fallback document"
            )
            let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])

            XCTAssertEqual(document["bookCategory"] as? String, testCase.bookCategory)
            XCTAssertEqual(fragment["bookCategory"] as? String, testCase.bookCategory)
            XCTAssertTrue(
                (fragment["xml"] as? String)?.contains(testCase.expectedXML) == true,
                "Expected \(testCase.category) XML to contain fallback copy"
            )
            XCTAssertEqual(controller.renderedContentState, testCase.renderedState)
        }
    }

    /**
     Verifies the shared rendered-content token contract used by the reader, bottom tab labels, and
     compact UI-test state export.
     *
     * Setup:
     * - constructs a dictionary rendered-content state with delimiter characters in display fields
     *
     * Expected result:
     * - encoding preserves the existing semicolon-separated field order and sanitizes delimiter
     *   characters the same way the controller did inline
     * - parsing returns the same key/value tokens so non-controller consumers do not duplicate token
     *   parsing logic
     *
     * Failure meaning:
     * - reader rendered-content state consumers have drifted from the controller's accessibility and
     *   tab-display contract.
     */
    func testRenderedContentStateBuildsAndParsesSharedTokens() {
        let state = BibleReaderRenderedContentState(
            category: .dictionary,
            moduleName: "Strongs=Hebrew;Primary",
            book: "H00430|lemma",
            chapter: nil,
            key: "H00430,entry\nselected"
        )

        XCTAssertEqual(
            state.encodedValue,
            "category=dictionary;module=Strongs_Hebrew_Primary;book=H00430_lemma;chapter=none;key=H00430_entry selected"
        )

        let tokens = BibleReaderRenderedContentState.tokens(from: state.encodedValue)
        XCTAssertEqual(tokens["category"], "dictionary")
        XCTAssertEqual(tokens["module"], "Strongs_Hebrew_Primary")
        XCTAssertEqual(tokens["book"], "H00430_lemma")
        XCTAssertEqual(tokens["chapter"], "none")
        XCTAssertEqual(tokens["key"], "H00430_entry selected")
        XCTAssertEqual(BibleReaderRenderedContentState.empty.encodedValue, BibleReaderController.emptyRenderedContentState)

        let duplicateTokens = BibleReaderRenderedContentState.tokens(
            from: "category=bible;module=KJV;module=ESV;malformed;book=Genesis"
        )
        XCTAssertEqual(duplicateTokens["category"], "bible")
        XCTAssertEqual(duplicateTokens["module"], "ESV")
        XCTAssertEqual(duplicateTokens["book"], "Genesis")
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
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let multiDocJSON = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["H00430"], robinson: []),
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
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
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
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )

        targetController.bridge(BibleBridge(), saveState: #"{"selectedStrongsDict":"HebrewGreek"}"#)
        XCTAssertEqual(
            targetController.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    /**
     Protects Android links-window identity for Strong's and dictionary result documents.

     Android opens Strong's results in the target links window as
     `FakeBookFactory.multiDocument`, with the selected dictionaries rendered inside that page rather
     than becoming the window's document identity. The setup renders a Strong's `MultiDocument` into a
     target controller with a `PageManager`, then simulates Vue saving a different selected dictionary
     tab. The expected result is that native page/category state remains the general-book `Multi`
     special document, the links window stays non-Bible syncable behavior-wise, and tab selection does
     not relabel the whole window as `HebrewGreek`. A failure means iOS has preserved an iOS-only
     transient dictionary identity instead of Android's durable links-window document semantics.
     */
    @MainActor
    func testDefinitionDocumentUsesAndroidMultiPageIdentityForLinksWindowTarget() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        let documentJSON = try XCTUnwrap(
            controller.buildStrongsMultiDocJSON(strongs: ["H00430"], robinson: [])
        )

        controller.loadDefinitionDocument(
            documentJSON,
            renderedBook: "Strongs",
            renderedKey: "strongs"
        )

        let androidBookAndKeyListRef = "StrongsHebrew:00430"
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.currentGeneralBookKey, androidBookAndKeyListRef)
        XCTAssertTrue(controller.hasStrongs)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, androidBookAndKeyListRef)
        XCTAssertGreaterThan(persistCount, 0)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )

        controller.bridge(bridge, saveState: #"{"selectedStrongsDict":"HebrewGreek"}"#)

        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, androidBookAndKeyListRef)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    /**
     Protects Android links-window identity for multi-reference Bible link result documents.

     Android does not leave a links-window target on the source Bible page after opening a multi-link;
     it sets the destination window's current document to `FakeBookFactory.multiDocument` and stores
     the synthetic key for that special document. The setup sends a minimal serialized Vue
     `MultiDocument` through the native target-controller entry point. The expected result is a
     persisted general-book `Multi` page identity with no mutation of the underlying Bible module
     selection. A failure means bottom tabs and restored window state can report a Bible window while
     visually displaying a link-result page.
     */
    @MainActor
    func testMultiReferenceDocumentUsesAndroidMultiPageIdentity() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        let bibleDocumentBeforeLoad = pageManager.bibleDocument
        let documentJSON = """
        {
          "id": "multi-test",
          "type": "multi",
          "osisFragments": [
            {"bookInitials": "KJV", "osisRef": "Gen.1.1"},
            {"bookInitials": "KJV", "osisRef": "John.3.16"}
          ],
          "compare": false
        }
        """

        controller.loadMultiReferenceDocument(documentJSON)

        let androidBookAndKeyListRef = "KJV:Gen.1.1||KJV:John.3.16"
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.currentGeneralBookKey, androidBookAndKeyListRef)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, androidBookAndKeyListRef)
        XCTAssertEqual(pageManager.bibleDocument, bibleDocumentBeforeLoad)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=multi"
        )
    }

    /**
     Protects restored Android `Multi` keys from malformed transient result payloads.

     Android's durable links-window restore key is the `BookAndKeyList` string stored in the general
     book page. iOS may still receive malformed transient JSON from a bridge path, but that should not
     overwrite the last restorable key with `nil`. The setup restores an existing Android `Multi`
     page, then loads a malformed multi-reference payload that cannot produce a new
     `BookAndKeyList`. The expected result is no durable PageManager mutation; a failure means one
     bad transient render can make the links window unrestorable after restart.
     */
    @MainActor
    func testMalformedMultiReferenceDocumentDoesNotEraseRestoredAndroidMultiKey() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1||KJV:John.3.16"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.loadMultiReferenceDocument(#"{"id":"bad-multi","type":"multi"}"#)

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.currentGeneralBookKey, "KJV:Gen.1.1||KJV:John.3.16")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, "KJV:Gen.1.1||KJV:John.3.16")
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Protects restoration of Android's synthetic `Multi` document identity.

     Android persists links-window result pages as a general-book page whose document initials are
     `Multi`, even though that document is created by `FakeBookFactory` rather than installed from
     SWORD. The setup restores a controller from those PageManager fields without registering any real
     general-book module named `Multi`. The expected result is that iOS still marks the window as the
     synthetic `Multi` general-book document and treats it like Android's special non-navigation page.
     A failure means restored links-window tabs can fall back to stale Bible identity simply because
     the synthetic document is not a SWORD module.
     */
    @MainActor
    func testRestoreSavedPositionRecognizesAndroidMultiDocumentIdentity() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1||KJV:John.3.16"
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, "Multi")
        XCTAssertEqual(controller.currentGeneralBookKey, "KJV:Gen.1.1||KJV:John.3.16")
        XCTAssertTrue(controller.hasStrongs)
        XCTAssertFalse(controller.hasNext)
        XCTAssertFalse(controller.hasPrevious)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
    }

    /**
     Protects Android's durable restore behavior for links-window `Multi` result pages.

     Android restores `FakeBookFactory.multiDocument` by parsing the persisted `BookAndKeyList` OSIS
     reference back into source document/key pairs, then rendering a `MultiFragmentDocument`. The setup
     starts with only the persisted PageManager category/document/key fields, as a process restart would.
     The expected result is a real Vue `MultiDocument` payload derived from the saved key; a failure
     means iOS has only fixed the bottom-tab label while losing the actual restored links-window content.
     */
    @MainActor
    func testRestoredAndroidMultiDocumentRebuildsPayloadFromPersistedKey() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1||KJV:John.3.16"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()

        controller.loadCurrentContent()

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0]["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragments[0]["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(fragments[1]["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragments[1]["osisRef"] as? String, "John.3.16")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=multi"
        )
    }

    #if os(iOS)
    /**
     Protects native selection state and payload decisions as a focused reader responsibility.

     Android action mode tracks selection state separately from page navigation, and `Multi`/generic
     pages must not fabricate Bible references from the pane that opened them. The setup exercises the
     coordinator directly with a normal Bible page and an Android-style non-Bible page. The expected
     result is a Bible copy/share payload only for Bible-capable pages, text-only copy for non-Bible
     pages, and cleared state after deselection. A failure means the selection extraction either lost
     state transitions or reintroduced stale Bible-reference behavior outside controller orchestration.
     The test performs no simulator, pasteboard, or persistence side effects and is deterministic.
     */
    func testReaderSelectionCoordinatorOwnsSelectionStateAndReferencePayloads() {
        var coordinator = BibleReaderSelectionCoordinator()
        let bibleContext = BibleReaderSelectionPageContext(
            canUseBibleReferenceActions: true,
            currentBook: "Genesis",
            currentChapter: 1,
            activeModuleName: "KJV"
        )
        let multiContext = BibleReaderSelectionPageContext(
            canUseBibleReferenceActions: false,
            currentBook: "Genesis",
            currentChapter: 1,
            activeModuleName: "KJV"
        )

        coordinator.selectionChanged("In the beginning")

        XCTAssertTrue(coordinator.hasActiveSelection)
        XCTAssertEqual(coordinator.selectedText, "In the beginning")
        XCTAssertEqual(
            coordinator.copyText(context: bibleContext),
            "In the beginning\n\u{2014} Genesis 1 (KJV)"
        )
        XCTAssertEqual(
            coordinator.shareText(context: bibleContext),
            "In the beginning\n\u{2014} Genesis 1 (KJV)"
        )
        XCTAssertEqual(coordinator.copyText(context: multiContext), "In the beginning")
        XCTAssertNil(coordinator.shareText(context: multiContext))

        coordinator.clearSelection()

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertEqual(coordinator.selectedText, "")
        XCTAssertNil(coordinator.copyText(context: bibleContext))
        XCTAssertNil(coordinator.shareText(context: bibleContext))
    }

    /**
     Protects native selection actions from falling back to the stale Bible page behind `Multi`.

     Android treats `FakeBookFactory.multiDocument` as a special general-book page. Bible-only
     actions such as sharing verse references are unavailable there, while plain copy must not invent
     a Bible reference from the source pane. The setup renders a `Multi` links-window document and
     marks a native text selection. The expected result is a text-only copy payload and no Bible share
     callback. A failure means iOS can expose stale `Genesis 1 (KJV)` style output for a links-window
     document that Android no longer considers a Bible page.
     */
    @MainActor
    func testMultiDocumentNativeSelectionActionsDoNotUseStaleBibleReference() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.loadMultiReferenceDocument("""
        {
          "id": "multi-selection-test",
          "type": "multi",
          "osisFragments": [
            {"bookInitials": "KJV", "osisRef": "Gen.1.1"}
          ],
          "compare": false
        }
        """)

        controller.bridge(bridge, selectionChanged: "Selected definition text")
        var sharedText: String?
        controller.onShareVerseText = { sharedText = $0 }

        XCTAssertEqual(controller.selectionCopyTextForCurrentPage(), "Selected definition text")
        XCTAssertNil(sharedText)

        controller.bridge(bridge, selectionChanged: "Selected definition text")
        controller.shareSelection()

        XCTAssertNil(sharedText)
    }
    #endif

    /**
     Protects pane menu action visibility before the pane controller is registered.

     SwiftUI can build a `BibleWindowPane` menu while the persisted `PageManager` already says the
     links window is Android's `general_book/Multi` page, but before `windowManager.controllers`
     contains the live controller. Android does not expose copy-reference or sync controls for that
     special page. The expected fallback is therefore based on persisted category/document state, not a
     permissive controller-nil default. A failure means the menu can briefly show stale Bible actions
     during initial render or controller re-registration.
     */
    func testPaneMenuCapabilitiesUsePageManagerBeforeControllerRegistration() {
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1"
        window.pageManager = pageManager

        let capabilities = BibleWindowPaneMenuCapabilities(window: window, controller: nil)

        XCTAssertFalse(capabilities.canCopyReference)
        XCTAssertFalse(capabilities.canSyncWindow)
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
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
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

    /**
     Verifies explicit verse navigation highlights the JSword/SWORD ordinal for the selected verse.

     Android stores the navigation target as the active versification's verse ordinal, including
     intro slots. The bundled KJV module supplies the expected ordinal here so this test fails if
     iOS reverts to literal verse numbers while still emitting an `originalOrdinalRange` field.
     */
    @MainActor
    func testLoadCurrentContentHighlightsExplicitVerseNavigationTarget() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let expectedOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5)
        )

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )

        XCTAssertTrue(
            addDocumentsScript.contains("\"originalOrdinalRange\":[\(expectedOrdinal),\(expectedOrdinal)]"),
            "Expected explicit verse navigation to preserve the original highlighted target. Script: \(addDocumentsScript)"
        )
    }

    /**
     Protects commentary rendering against chapter-shaped fallbacks.

     Android's `CurrentCommentaryPage` is a single-key page: when the current Bible verse is
     Genesis 1:5, the commentary document is keyed to that verse even if the selected commentary
     module has no entry there. The test uses a minimal empty `RawCom` module so the controller
     enters the real commentary path while the missing-entry branch stays deterministic. A failure
     means iOS has drifted back to whole-chapter commentary semantics or verse-1 placeholder ranges.
     */
    @MainActor
    func testCommentaryMissingEntryUsesSelectedVerseKeyAndOrdinalRange() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedEmptyRawCommentaryModule(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let bibleModule = try XCTUnwrap(manager.module(named: "KJV"))
        let expectedOrdinal = try XCTUnwrap(
            bibleModule.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5)
        )
        XCTAssertTrue(
            manager.installedModules(category: .commentary).contains { $0.name == "UITestComm" },
            "Expected the temporary RawCom fixture to be discovered as a commentary module."
        )

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        controller.switchCategory(to: .commentary)
        let baselineScriptCount = recordedScripts().count
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(recordedScripts().dropFirst(baselineScriptCount)),
                event: "add_documents"
            ) as? [String: Any]
        )
        let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)

        XCTAssertEqual(payload["bookCategory"] as? String, "COMMENTARY")
        XCTAssertEqual(payload["bookInitials"] as? String, "UITestComm")
        XCTAssertEqual(payload["key"] as? String, "Gen.1.5")
        XCTAssertEqual(payload["osisRef"] as? String, "Gen.1.5")
        XCTAssertEqual(payload["ordinalRange"] as? [Int], [expectedOrdinal, expectedOrdinal])
        XCTAssertEqual(fragment["key"] as? String, "Gen.1.5")
        XCTAssertEqual(fragment["osisRef"] as? String, "Gen.1.5")
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [expectedOrdinal, expectedOrdinal])
        XCTAssertTrue(
            xml.contains("No commentary available for this verse"),
            "Expected missing commentary text to describe the selected verse. XML: \(xml)"
        )
        XCTAssertFalse(
            xml.contains("No commentary available for this chapter"),
            "Commentary is a single-key document on Android and must not report chapter-level absence. XML: \(xml)"
        )
    }

    /**
     Verifies Android-style `multi://` links render as a Vue MultiDocument instead of a native sheet.

     Setup uses a temporary bundled KJV module and a recording bridge, then invokes the production
     external-link bridge path with two OSIS parameters. The expected result is an `add_documents`
     payload containing a multi document and no cross-reference sheet callback. A failure means iOS
     regressed to an iOS-only presentation path for links Android handles as in-reader documents. The
     test is main-actor isolated for controller callbacks and creates only temporary module fixtures.
     */
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

    /**
     Verifies comma-separated `osis://` links use the same MultiDocument path as Android.

     Setup records bridge emissions from the production external-link handler with a temporary KJV
     module. The expected result is one Vue multi-document payload containing both references and no
     cross-reference sheet callback. A failure means iOS is splitting or presenting multi-reference
     OSIS links differently from Android. The test is synchronous except for the main-run-loop drain
     needed to capture bridge emission.
     */
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

    /**
     Verifies OSIS range links use JSword/SWORD passage semantics instead of endpoint splitting.

     Android parses `osis://` references with JSword `PassageKeyFactory`, so
     `Gen.1.1-Gen.1.3` opens a multi-document containing verses 1, 2, and 3. The test drives the
     native link handler with the bundled KJV module and inspects the emitted Vue `MultiDocument`;
     a failure means cross-reference links can omit middle verses while appearing to open normally.
     */
    @MainActor
    func testOsisRangeLinkExpandsEveryVerseInVueMultiDocument() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var showedCrossReferences = false
        controller.onShowCrossReferences = { _ in showedCrossReferences = true }

        controller.bridge(bridge, openExternalLink: "osis://?osis=Gen.1.1-Gen.1.3&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertFalse(showedCrossReferences)
        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected OSIS range link to render a Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.2""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.3""#))
    }

    /**
     Verifies OSIS list separators and range expansion compose through the SWORD parser boundary.

     JSword `PassageKeyFactory` accepts comma-separated passage lists and expands each range against
     the active versification. iOS must preserve both semantics instead of sending the whole comma
     string to SWORD, whose flat parser only reliably expands individual segments here. A failure
     means mixed cross-reference links can silently drop later list entries or range members.
     */
    @MainActor
    func testOsisMixedListAndRangeLinkEmitsEveryParsedVerse() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var showedCrossReferences = false
        controller.onShowCrossReferences = { _ in showedCrossReferences = true }

        controller.bridge(bridge, openExternalLink: "osis://?osis=Gen.1.1-Gen.1.2,Exod.2.1&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertFalse(showedCrossReferences)
        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected mixed OSIS list/range link to render a Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.2""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Exod.2.1""#))
    }

    /**
     Protects the single-reference `osis://` path from being widened into MultiDocument behavior.

     Android opens a single OSIS reference as normal reader navigation, while multi-reference links
     become MultiDocument content. Setup drives the bridge with one OSIS reference and a recording
     bridge. The expected result is controller navigation to Exodus 2 without a multi-document payload
     or cross-reference sheet. A failure means the resolver/link split changed user-visible
     navigation semantics.
     */
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
     Protects Android's boundary between `osis://` navigation and `multi://` MultiDocument links.

     Android's `SCHEME_REFERENCE` handler reads only `getQueryParameter("osis")`; repeated `osis`
     query values are not a MultiDocument signal. Setup sends a deliberately duplicated `osis://`
     link through the native bridge with no SWORD module so the route is deterministic. The expected
     result is navigation to the first reference only and no transient multi-document payload. A
     failure means iOS widened single-reference links into invented multi-reference behavior instead
     of requiring Android's `multi://` route.
     */
    @MainActor
    func testOsisReferenceUsesFirstQueryValueLikeAndroidReferenceScheme() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)

        controller.bridge(bridge, openExternalLink: "osis://?osis=Exod.2.1&osis=Gen.1.1&v11n=KJVA")

        XCTAssertEqual(controller.currentBook, "Exodus")
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertFalse(recordedScripts().contains { $0.contains(#""type":"multi""#) })
    }

    /**
     Protects Android-style external-link classification outside controller orchestration.

     Android splits responsibilities between `BibleJavascriptInterface.openExternalLink`,
     `BibleView.openLink`, and `LinkControl`: pseudo-links become typed app routes while unknown
     web links remain platform URLs. The setup exercises the new pure router with Strong's,
     morphology, MyBible, MySword, multi-reference, EPUB, Downloads, My Notes, and StudyPad inputs.
     The expected result is typed route data with no bridge, SWORD, pasteboard, or simulator side
     effects. A failure means the extraction preserved the controller code shape without preserving
     Android's routing contract.
     */
    func testExternalLinkRouterClassifiesAndroidPseudoSchemes() {
        let router = BibleReaderExternalLinkRouter()

        XCTAssertEqual(
            router.route(for: "ab-w://?strong=H0430&robinson=N-NSM"),
            .definition(strongs: ["H0430"], robinson: ["N-NSM"])
        )
        XCTAssertEqual(
            router.route(for: "strongs://G2316"),
            .definition(strongs: ["G2316"], robinson: [])
        )
        XCTAssertEqual(
            router.route(for: "morphology://robinson/V-PAI-3S"),
            .definition(strongs: [], robinson: ["V-PAI-3S"])
        )
        XCTAssertEqual(
            router.route(for: "ab-find-all://?type=hebrew&name=5775"),
            .findAllOccurrences("H5775")
        )
        XCTAssertEqual(
            router.route(for: "download://?initials=KJV"),
            .downloads(searchText: "KJV")
        )
        XCTAssertEqual(
            router.route(for: "epub-ref://?book=Pilgrim&toKey=chapter1.xhtml&toId=anchor"),
            .epubReference(book: "Pilgrim", toKey: "chapter1.xhtml", toId: "anchor")
        )
        XCTAssertEqual(
            router.route(for: "my-notes://?osis=Gen.1.1&ordinal=1"),
            .myNotes(osisRef: "Gen.1.1", ordinal: 1)
        )
        XCTAssertEqual(
            router.route(for: "journal://?id=00000000-0000-0000-0000-000000000001&bookmarkId=00000000-0000-0000-0000-000000000002"),
            .studyPad(
                labelId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                bookmarkId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
        )
        XCTAssertEqual(
            router.route(for: "osis://?osis=Gen.1.1,Exod.2.1&v11n=KJVA"),
            .osisReferences(["Gen.1.1,Exod.2.1"])
        )
        XCTAssertEqual(
            router.route(for: "multi://?osis=Gen.1.1&osis=Exod.2.1&v11n=KJVA"),
            .multiReferences(["Gen.1.1", "Exod.2.1"])
        )
        XCTAssertEqual(
            router.route(for: "sword://Bible/John.3.16"),
            .swordReference("John.3.16")
        )
        XCTAssertEqual(
            router.route(for: "B:470 1:1"),
            .osisNavigation("Matt.1.1")
        )
        XCTAssertEqual(
            router.route(for: "#b40.1.1"),
            .osisNavigation("Matt.1.1")
        )
        XCTAssertEqual(
            router.route(for: "S:G2424"),
            .definition(strongs: ["G2424"], robinson: [])
        )
        XCTAssertEqual(
            router.route(for: "#dH0430"),
            .definition(strongs: ["H0430"], robinson: [])
        )
        XCTAssertEqual(
            router.route(for: "https://andbible.org"),
            .platformURL(URL(string: "https://andbible.org")!)
        )
    }

    /**
     Protects multi-reference document construction as its own Android `Multi` responsibility.

     Android stores cross-reference results as `FakeBookFactory.multiDocument` backed by a
     `BookAndKeyList`, not as a controller-local sheet. The setup feeds parsed references into the
     builder without an active SWORD module so fallback XML is deterministic. The expected JSON has
     the Vue `type: "multi"` shape, one OSIS fragment per reference, stable module/key metadata, and
     escaped fallback text. A failure means the extraction left document construction coupled to the
     controller or changed the persisted/rendered document contract.
     */
    func testMultiReferenceDocumentBuilderCreatesAndroidMultiPayload() throws {
        let refs = [
            OsisRef(book: "Genesis", chapter: 1, verse: 1, osisId: "Gen"),
            OsisRef(book: "Exodus", chapter: 2, verse: 1, osisId: "Exod"),
        ]
        let builder = BibleReaderMultiReferenceDocumentBuilder(
            activeModule: nil,
            activeModuleName: "KJV",
            compatibilityOrdinal: { chapter, verse in chapter * 1_000 + verse },
            isNewTestament: { $0 == "Matthew" }
        )

        let json = try XCTUnwrap(builder.buildDocumentJSON(refs: refs))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(payload["compare"] as? Bool, false)
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0]["key"] as? String, "KJV--Gen.1.1")
        XCTAssertEqual(fragments[0]["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(fragments[0]["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(fragments[0]["ordinalRange"] as? [Int], [1001, 1001])
        XCTAssertTrue(
            (fragments[0]["xml"] as? String)?.contains("Genesis 1:1") == true,
            "Expected fallback XML to include the display reference when no module is available."
        )
        XCTAssertEqual(fragments[1]["key"] as? String, "KJV--Exod.2.1")
        XCTAssertEqual(fragments[1]["ordinalRange"] as? [Int], [2001, 2001])
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

    /**
     Protects the reader bridge's last-resort margin fallback from iOS-only layout drift.

     Android's `WorkspaceEntities.kt` initializes text-display margins to left `3`, right `3`,
     and max width `170`. The bridge normally receives resolved app defaults, but restored or
     migrated data can temporarily leave both the pane settings and defaults empty; this test
     verifies that even that edge case encodes Android's baseline instead of the older iOS
     fallback (`2`, `2`, `600`). A failure means dictionary and reader panes can render with
     platform-specific margins before persisted settings are available.
     */
    func testReaderConfigMarginFallbackMatchesAndroidDefaultsWhenSettingsAreEmpty() throws {
        let config = BibleReaderDisplayConfig(settings: TextDisplaySettings(), defaults: TextDisplaySettings())
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let marginSize = try XCTUnwrap(object["marginSize"] as? [String: Any])

        XCTAssertEqual(marginSize["marginLeft"] as? Int, 3)
        XCTAssertEqual(marginSize["marginRight"] as? Int, 3)
        XCTAssertEqual(marginSize["maxWidth"] as? Int, 170)
    }

    /**
     Protects the WebView paging contract from invalid synced or migrated `PAGE_SCROLL_AMOUNT` data.

     Android's `PageScrollAmountPreference` only accepts six discrete percentages and falls back to
     `100%` for unknown stored values. This test drives the native client-ready path and verifies the
     emitted Vue `set_config` payload receives that normalized value, not the raw invalid setting.
     */
    @MainActor
    func testReaderConfigPayloadNormalizesInvalidPageScrollAmount() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        var display = TextDisplaySettings()
        display.pageScrollAmount = 150

        let controller = BibleReaderController(bridge: bridge)
        controller.displaySettings = display

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: recordedScripts())
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(config["pageScrollAmount"] as? Int, 100)
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

    /**
     Protects the extracted reader configuration coordinator's ownership of active-window projection.

     The setup mirrors Android's `windowControl.activeWindow.id == window.id` rule with two visible
     windows and active-indicator preference enabled. The focused contract is that the coordinator
     computes both `activeWindow` and `hasActiveIndicator` together so the controller does not keep
     duplicate window-state math beside the config payload builder. A failure means #146 regressed by
     moving state projection mechanically without preserving Android's active-pane semantics.
     */
    @MainActor
    func testReaderConfigurationCoordinatorComputesActiveWindowProjection() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Config Coordinator")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow

        let coordinator = BibleReaderConfigurationCoordinator()

        let activeProjection = coordinator.activeWindowState(
            activeWindow: firstWindow,
            windowManager: windowManager,
            activeIndicatorEnabled: true
        )
        let inactiveProjection = coordinator.activeWindowState(
            activeWindow: secondWindow,
            windowManager: windowManager,
            activeIndicatorEnabled: true
        )

        XCTAssertEqual(activeProjection.isActive, true)
        XCTAssertEqual(activeProjection.hasActiveIndicator, true)
        XCTAssertEqual(activeProjection.eventJSON, #"{"hasActiveIndicator":true,"isActive":true}"#)
        XCTAssertEqual(inactiveProjection.isActive, false)
        XCTAssertEqual(inactiveProjection.hasActiveIndicator, false)
        XCTAssertEqual(inactiveProjection.eventJSON, #"{"hasActiveIndicator":false,"isActive":false}"#)
    }

    /**
     Protects workspace-backed compare visibility as coordinator-owned reader configuration state.

     Android stores compare-document visibility with workspace settings instead of treating it as
     transient pane state. This test creates a persisted workspace, toggles one module through the
     coordinator, and verifies the updated set is written to `WorkspaceSettings`, mirrored to the
     coordinator fallback, and persisted exactly once. A failure means the extraction preserved file
     shape but left #146's reader/window/workspace state ownership split across the controller.
     */
    @MainActor
    func testReaderConfigurationCoordinatorPersistsHiddenCompareDocumentsToWorkspace() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let workspace = workspaceStore.createWorkspace(name: "Compare Coordinator")
        workspace.workspaceSettings = WorkspaceSettings(hideCompareDocuments: ["ESV"])
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        var coordinator = BibleReaderConfigurationCoordinator()
        var persistCount = 0

        coordinator.toggleHiddenCompareDocument("KJV", activeWindow: window) {
            persistCount += 1
        }

        XCTAssertEqual(workspace.workspaceSettings?.hideCompareDocuments, ["ESV", "KJV"])
        XCTAssertEqual(coordinator.hiddenCompareDocuments(activeWindow: window), ["ESV", "KJV"])
        XCTAssertEqual(persistCount, 1)

        coordinator.toggleHiddenCompareDocument("ESV", activeWindow: nil) {
            persistCount += 1
        }

        XCTAssertEqual(coordinator.hiddenCompareDocuments(activeWindow: nil), ["KJV"])
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects recent bookmark-label state as a coordinator-owned reader configuration input.

     Android exposes recently used bookmark labels through reader configuration without making the
     top-level reader controller own the de-duplication, ordering, and persisted setting value. The
     setup starts from the legacy comma-separated setting, reuses one older label, then adds enough
     labels to exceed the five-label cap. The expected result is most-recent-first ordering, no
     duplicate reused label, cap enforcement, and one persisted comma-separated value per tracked
     label. A failure means #146 regressed by leaving state semantics in the controller or changing
     the config payload behavior that Vue receives.
     */
    func testReaderRecentLabelCoordinatorLoadsDeduplicatesCapsAndPersistsRecentLabels() {
        var coordinator = BibleReaderRecentLabelCoordinator()
        var persistedValues: [String] = []

        coordinator.load(storedValue: "oldA,oldB")
        XCTAssertEqual(coordinator.labelIds, ["oldA", "oldB"])

        for labelId in ["oldC", "oldA", "oldD", "oldE", "oldF", "oldG"] {
            coordinator.track(labelId) { persistedValues.append($0) }
        }

        XCTAssertEqual(coordinator.labelIds, ["oldG", "oldF", "oldE", "oldD", "oldA"])
        XCTAssertEqual(
            persistedValues,
            [
                "oldC,oldA,oldB",
                "oldA,oldC,oldB",
                "oldD,oldA,oldC,oldB",
                "oldE,oldD,oldA,oldC,oldB",
                "oldF,oldE,oldD,oldA,oldC",
                "oldG,oldF,oldE,oldD,oldA"
            ]
        )
    }

    /**
     Protects pending/active transient `MultiDocument` state as a coordinator-owned reader concern.

     Android links-window `Multi` documents can be requested before the WebView client is ready, so
     iOS must remember the same transient document as both the active special document and the
     pending client-ready replay. The test then consumes that pending replay once and verifies that a
     later client-ready request remains active without leaving stale pending replay state. A failure
     means the controller has regained hidden transient state ownership or the Android `Multi`
     restore/replay contract can duplicate or lose special documents.
     */
    func testReaderTransientDocumentCoordinatorStoresActiveAndPendingReplayState() {
        var coordinator = BibleReaderTransientDocumentCoordinator()
        let pendingRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"pending"}"#,
            renderedBook: "Multi",
            renderedKey: "multi",
            renderedCategory: .generalBook,
            renderedModuleName: "Multi",
            pageCategory: .generalBook,
            pageDocumentInitials: "Multi",
            pageKey: "KJV:Gen.1.1"
        )
        let readyRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"ready"}"#,
            renderedBook: "Compare",
            renderedKey: "compare",
            renderedCategory: .bible,
            renderedModuleName: nil,
            pageCategory: nil,
            pageDocumentInitials: nil,
            pageKey: nil
        )

        coordinator.store(pendingRequest, clientReady: false)

        XCTAssertEqual(coordinator.activeRequest(isShowingAndroidMultiDocument: true)?.documentJSON, pendingRequest.documentJSON)
        XCTAssertNil(coordinator.activeRequest(isShowingAndroidMultiDocument: false))
        XCTAssertEqual(coordinator.consumePendingClientReadyRequest()?.documentJSON, pendingRequest.documentJSON)
        XCTAssertNil(coordinator.consumePendingClientReadyRequest())

        coordinator.store(readyRequest, clientReady: true)

        XCTAssertEqual(coordinator.activeRequest(isShowingAndroidMultiDocument: true)?.documentJSON, readyRequest.documentJSON)
        XCTAssertNil(coordinator.consumePendingClientReadyRequest())
    }

    /**
     Protects My Documents active-page identity as a coordinator-owned reader state rule.

     Android treats My Documents as generated general-book modules, so iOS must keep the active
     local page only while the rendered content still points at the same general-book document. The
     setup records one active page, exercises an unrelated module/category render, and expects the
     coordinator to preserve or clear the page key exactly where the controller previously did. A
     failure means #146 moved state ownership without preserving the reload/delete guard that keeps
     My Documents bridge actions scoped to the visible local document.
     */
    func testReaderMyDocumentCoordinatorTracksActivePageUntilDifferentRenderedContent() {
        var coordinator = BibleReaderMyDocumentCoordinator()

        coordinator.setActivePage(bookInitials: "MYDOC", pageKey: "intro")

        XCTAssertEqual(coordinator.activePageKey(for: "MYDOC"), "intro")
        XCTAssertNil(coordinator.activePageKey(for: "OTHER"))

        coordinator.clearActivePageUnless(category: .generalBook, moduleName: "MYDOC")
        XCTAssertEqual(coordinator.activePageKey(for: "MYDOC"), "intro")

        coordinator.clearActivePageUnless(category: .commentary, moduleName: "MYDOC")
        XCTAssertNil(coordinator.activePageKey(for: "MYDOC"))

        coordinator.setActivePage(bookInitials: "MYDOC", pageKey: "intro")
        coordinator.clearActivePageUnless(category: .generalBook, moduleName: "OTHER")

        XCTAssertNil(coordinator.activePageKey(for: "MYDOC"))
    }

    /**
     Protects the Android-compatible My Documents document payload outside the reader controller.

     Android exposes My Documents through the general-book document pipeline while retaining raw
     editable content behind bridge calls. The setup builds a Markdown page containing XML-sensitive
     characters and expects the coordinator to emit a valid Vue `OsisDocument` JSON payload with the
     same category, identity, AI metadata, and escaped markup fields used by the current reader. A
     failure means the extraction changed the WebView payload contract rather than simply moving it
     out of `BibleReaderController`.
     */
    func testReaderMyDocumentCoordinatorBuildsAndroidGeneralBookDocumentPayload() throws {
        let coordinator = BibleReaderMyDocumentCoordinator()
        let pageId = try XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let sourcePromptId = try XCTUnwrap(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            sourcePromptId: sourcePromptId,
            languageCode: "en"
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Raw <markdown> & \"quoted\"")
        page.pageContent = content
        page.document = document

        let json = try XCTUnwrap(coordinator.documentJSON(document: document, page: page))
        let renderedDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let osisFragment = try XCTUnwrap(renderedDocument["osisFragment"] as? [String: Any])

        XCTAssertEqual(renderedDocument["type"] as? String, "osis")
        XCTAssertEqual(renderedDocument["bookInitials"] as? String, "MYDOC")
        XCTAssertEqual(renderedDocument["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(renderedDocument["bookName"] as? String, "My Document")
        XCTAssertEqual(renderedDocument["key"] as? String, "intro")
        XCTAssertEqual(renderedDocument["isMyDocument"] as? Bool, true)
        XCTAssertEqual(renderedDocument["isAiDocument"] as? Bool, false)
        XCTAssertEqual(renderedDocument["myDocumentPageId"] as? String, pageId.uuidString)
        XCTAssertEqual(renderedDocument["sourcePromptId"] as? String, sourcePromptId.uuidString)
        XCTAssertEqual(osisFragment["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(osisFragment["bookInitials"] as? String, "MYDOC")
        XCTAssertEqual(osisFragment["keyName"] as? String, "Intro")
        XCTAssertEqual(osisFragment["language"] as? String, "en")
        XCTAssertEqual(
            osisFragment["xml"] as? String,
            "<div class=\"mydoc-markdown\"><markdown>Raw &lt;markdown&gt; &amp; &quot;quoted&quot;</markdown></div>"
        )
    }

    /**
     Protects infinite-scroll loaded-range state as a coordinator-owned reader concern.

     Android advances the loaded Bible range only after an adjacent chapter document is available.
     The setup asks for a previous chapter, deliberately does not commit it, and then asks again to
     prove failed document loading cannot advance the lower bound. It then commits the candidate and
     verifies the next request crosses into the previous book. A failure means the controller has
     regained mutate-and-revert loaded-range state that can drift after failed prepend loads.
     */
    func testReaderInfiniteScrollCoordinatorKeepsPreviousCandidateUncommittedUntilLoadSucceeds() {
        var coordinator = BibleReaderInfiniteScrollCoordinator()
        coordinator.reset(book: "Exodus", chapter: 2)

        let firstCandidate = coordinator.previousCandidate(
            previousBook: { $0 == "Exodus" ? "Genesis" : nil },
            chapterCount: { $0 == "Genesis" ? 50 : 40 }
        )
        XCTAssertEqual(firstCandidate, BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 1))

        XCTAssertEqual(
            coordinator.previousCandidate(
                previousBook: { $0 == "Exodus" ? "Genesis" : nil },
                chapterCount: { $0 == "Genesis" ? 50 : 40 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 1)
        )

        if let firstCandidate {
            coordinator.commitPrevious(firstCandidate)
        }

        XCTAssertEqual(
            coordinator.previousCandidate(
                previousBook: { $0 == "Exodus" ? "Genesis" : nil },
                chapterCount: { $0 == "Genesis" ? 50 : 40 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Genesis", chapter: 50)
        )
    }

    /**
     Protects the controller's pre-render infinite-scroll sentinel behavior during extraction.

     The legacy controller kept its loaded range at Genesis chapter 0 until the first reader render.
     Vue can still request append/prepend during that window: prepend has no valid chapter, while
     append resolves to Genesis 1. A failure here means the extracted coordinator changed startup
     bridge behavior instead of only moving the range ownership out of `BibleReaderController`.
     */
    func testReaderInfiniteScrollCoordinatorPreservesPreRenderAppendSentinel() {
        let coordinator = BibleReaderInfiniteScrollCoordinator()

        XCTAssertNil(
            coordinator.previousCandidate(
                previousBook: { $0 == "Genesis" ? nil : "Genesis" },
                chapterCount: { book in
                    XCTFail("Genesis sentinel prepend should not query chapter count, got \(book)")
                    return 0
                }
            )
        )

        XCTAssertEqual(
            coordinator.nextCandidate(
                nextBook: { book in
                    XCTFail("Genesis sentinel append should not query a next book, got \(book)")
                    return nil
                },
                chapterCount: { $0 == "Genesis" ? 50 : 0 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Genesis", chapter: 1)
        )
    }

    /**
     Protects infinite-scroll append range state as a coordinator-owned reader concern.

     Android appends within the current book until the active versification reaches the final
     chapter, then crosses to the next book. The setup starts at the final Genesis chapter, verifies
     that the next candidate is Exodus 1, commits it, and then verifies normal same-book append
     resumes at Exodus 2. A failure means the extraction changed cross-book append behavior instead
     of only moving loaded-range ownership out of `BibleReaderController`.
     */
    func testReaderInfiniteScrollCoordinatorCrossesToNextBookAfterFinalChapter() {
        var coordinator = BibleReaderInfiniteScrollCoordinator()
        coordinator.reset(book: "Genesis", chapter: 50)

        let nextBookCandidate = coordinator.nextCandidate(
            nextBook: { $0 == "Genesis" ? "Exodus" : nil },
            chapterCount: { $0 == "Genesis" ? 50 : 40 }
        )
        XCTAssertEqual(nextBookCandidate, BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 1))

        if let nextBookCandidate {
            coordinator.commitNext(nextBookCandidate)
        }

        XCTAssertEqual(
            coordinator.nextCandidate(
                nextBook: { $0 == "Genesis" ? "Exodus" : nil },
                chapterCount: { $0 == "Genesis" ? 50 : 40 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 2)
        )
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

    /**
     Protects append infinite-scroll bridge responses after the reader content is rendered.

     The setup loads Genesis 1 through the real controller path, records the existing bridge output,
     then requests more content at the end and verifies the original call id receives a full Genesis 2
     document payload. A failure means the coordinator extraction broke the controller delegate path,
     stale call id handling, or the Android-compatible document shape used by Vue infinite scroll.
     */
    @MainActor
    func testRequestMoreToEndSendsDocumentResponseWithOriginalCallId() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let baselineCount = recordedScripts().count
        controller.bridge(bridge, requestMoreToEnd: 3703)

        let responseScript = try XCTUnwrap(
            recordedScripts().dropFirst(baselineCount).first {
                $0.contains("bibleView.response(3703")
            }
        )

        XCTAssertTrue(
            responseScript.hasPrefix("bibleView.response(3703, {"),
            "Expected a document JSON response for the original callId. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""key":"Gen.2""#),
            "Expected the next chapter document to be returned. Script: \(responseScript)"
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

    /**
     Verifies the bridge `parseRef` response preserves call IDs and JSword-compatible parsing.

     Setup uses a recording bridge and temporary KJV module so reference parsing goes through the
     active-module parser path, matching Android's JSword `PassageKeyFactory` behavior. The expected
     result is a response with the original call ID for each request, compact OSIS serialization for
     valid references/lists/ranges, and `null` for out-of-range or reverse inputs. Failures indicate
     either bridge response routing drift or parser semantics that diverge from Android. The test is
     main-actor isolated, uses temporary module files only, and has deterministic synchronous parser
     inputs.
     */
    @MainActor
    func testParseRefSendsResponseWithOriginalCallId() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(bridge, parseRef: 3703, text: "Genesis 1:1")

        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3703, "Gen.1.1");"#)

        controller.bridge(bridge, parseRef: 3705, text: "III John 1:2")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3705, "3John.1.2");"#,
            "parseRef should delegate to the active module parser so JSword-compatible book names are accepted."
        )

        controller.bridge(bridge, parseRef: 3706, text: "Genesis 1:1, Exodus 2:1")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3706, "Gen.1.1 Exod.2.1");"#,
            "parseRef should preserve JSword PassageKeyFactory semantics for multi-reference passage lists."
        )

        controller.bridge(bridge, parseRef: 3707, text: "Genesis 1:1, 2")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3707, "Gen.1.1-Gen.1.2");"#,
            "parseRef should preserve JSword basis semantics for verse lists."
        )

        controller.bridge(bridge, parseRef: 3708, text: "Genesis 1")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3708, "Gen.1");"#,
            "parseRef should serialize whole chapters using JSword getOsisRef semantics."
        )

        controller.bridge(bridge, parseRef: 3709, text: "Genesis 1-2")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3709, "Gen.1-Gen.2");"#,
            "parseRef should serialize chapter ranges using JSword getOsisRef semantics."
        )

        controller.bridge(bridge, parseRef: 3704, text: "Gen.1.99")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3704, null);",
            "parseRef must reject out-of-range references through the active module parser instead of accepting any OSIS-looking string."
        )

        controller.bridge(bridge, parseRef: 3710, text: "Genesis 1:1, 99")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3710, null);",
            "parseRef must reject invalid shorthand verse-list entries the same way JSword validates VerseRange parts."
        )

        controller.bridge(bridge, parseRef: 3711, text: "Genesis 1:1-99")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3711, null);",
            "parseRef must reject invalid range endpoints before SWORD normalizes them."
        )

        controller.bridge(bridge, parseRef: 3712, text: "Genesis 2-1")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3712, null);",
            "parseRef must reject reverse ranges using active module ordinals instead of accepting fabricated ordering values."
        )
    }

    /**
     Protects reference parsing as a standalone reader responsibility instead of controller state.

     The resolver must preserve Android/JSword `PassageKeyFactory` behavior while being usable
     without routing through the bridge: active-module parsing accepts JSword-compatible book names,
     serializes verse lists and chapter ranges in compact OSIS form, and rejects coordinates SWORD
     would otherwise normalize. A failure means the controller extraction changed reference parsing
     semantics or left this behavior coupled to `BibleReaderController` orchestration.

     Setup uses the bundled temporary KJV SWORD module because Android validates these cases through
     the active document's JSword versification rather than a static iOS table. The expected result is
     exact OSIS serialization for valid references and `nil` for invalid explicit coordinates. The
     test creates only temporary module files through the shared fixture helper, performs no persisted
     app-state writes, and is deterministic because all parsing runs synchronously against the fixture
     module.
     */
    func testReferenceResolverPreservesActiveModuleParseRefSemantics() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let books = BibleReaderSwordCoordinator().bookList(for: module)
        let resolver = BibleReaderReferenceResolver(
            activeModule: module,
            bookList: books,
            fallbackBooks: BibleReaderController.defaultBooks,
            fallbackVerseCount: BibleReaderController.verseCount(for:chapter:)
        )

        XCTAssertEqual(resolver.resolveReference("Genesis 1:1"), "Gen.1.1")
        XCTAssertEqual(resolver.resolveReference("III John 1:2"), "3John.1.2")
        XCTAssertEqual(resolver.resolveReference("Genesis 1:1, Exodus 2:1"), "Gen.1.1 Exod.2.1")
        XCTAssertEqual(resolver.resolveReference("Genesis 1:1, 2"), "Gen.1.1-Gen.1.2")
        XCTAssertEqual(resolver.resolveReference("Genesis 1"), "Gen.1")
        XCTAssertEqual(resolver.resolveReference("Genesis 1-2"), "Gen.1-Gen.2")
        XCTAssertNil(resolver.resolveReference("Gen.1.99"))
        XCTAssertNil(resolver.resolveReference("Genesis 1:1, 99"))
        XCTAssertNil(resolver.resolveReference("Genesis 1:1-99"))
        XCTAssertNil(resolver.resolveReference("Genesis 2-1"))
    }

    /**
     Guards active-module reference resolution against static-canon fallback drift.

     Android resolves editor references through the active document versification. If iOS has an
     active SWORD module but cannot expose that module's book list, the resolver must fail closed
     instead of accepting KJV/default-canon names and OSIS IDs. A failure means the extraction
     reintroduced iOS-only fallback behavior that can fabricate references for the active module.

     Setup intentionally supplies a valid active KJV module with an empty book list, which models a
     metadata failure after module selection. The expected result is rejection from the full parser,
     direct OSIS parser, and human-readable parser. The test creates only temporary module files via
     the shared fixture helper, performs no persisted app-state writes, and has no async ordering
     assumptions.
     */
    func testReferenceResolverRejectsStaticFallbackWhenActiveModuleBookListIsUnavailable() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let resolver = BibleReaderReferenceResolver(
            activeModule: module,
            bookList: [],
            fallbackBooks: BibleReaderController.defaultBooks,
            fallbackVerseCount: BibleReaderController.verseCount(for:chapter:)
        )

        XCTAssertNil(resolver.resolveReference("Genesis 1:1"))
        XCTAssertNil(resolver.resolveOsisRef("Gen.1.1"))
        XCTAssertNil(resolver.resolveHumanRef("Genesis 1:1"))
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

    /**
     Protects visible-verse persistence against synthetic ordinal arithmetic.

     Android receives scroll ordinals that belong to the active JSword versification. This test
     uses the bundled KJV SWORD module to derive the ordinal for Genesis 1:5, then expects the
     native reader to reverse-map that ordinal back to verse 5 before debouncing persistence. A
     failure means reader state is deriving verses from fixed 40-verse chapter math.
     */
    func testDidScrollToOrdinalDebouncesPersistenceWithinCurrentChapter() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
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

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)

        wait(for: [persisted], timeout: 2.0)

        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android-style visible-verse tracking when the web client cannot supply a document key.

     Android's Bible `scrolledToOrdinal` path ignores the key for Bible documents and resolves the
     ordinal through JSword. The setup reports the bundled KJV ordinal for Genesis 2:3 with an empty
     key and expects iOS to update/persist the native chapter and verse from the ordinal. A failure
     means valid scroll telemetry can be dropped whenever `dataset.osisRef` is missing.
     */
    func testDidScrollToOrdinalPersistsVisibleVerseWhenKeyIsEmpty() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 3))
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

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 3)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 3)

        wait(for: [persisted], timeout: 2.0)

        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects visible-verse key parsing for OSIS refs that include a verse segment.

     Android's Bible visible-position callback updates by JSword ordinal and does not mistake
     `Gen.1.5` for chapter 5. The setup reports the Genesis 1:5 ordinal with a verse-qualified
     document key. The expected result is that native state remains in chapter 1, updates to verse 5,
     and uses the normal intra-chapter debounce path; a failure means source keys with verse suffixes
     can corrupt the pane chapter and send synchronized targets to the wrong location.
     */
    func testDidScrollToOrdinalParsesVerseQualifiedKeyAsChapter() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1.5", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

    /**
     Protects the synchronized-scroll loop when visible keys include verse suffixes.

     Android accepts verse-qualified keys as the same chapter position, updates stale inactive
     windows once, and then treats the target's matching callback as passive feedback. The setup
     makes the first synced pane report `Gen.1.5`, leaves the target's persisted book incomplete to
     model restored/stale pane state, checks that only the stale second pane remains a secondary
     target, applies that target update, and then sends the target callback. The expected result is
     one source broadcast with both panes on comparable Genesis 1:5 PageManager state and no reverse
     broadcast; a failure means iOS can corrupt the chapter from the key suffix, leave the target
     perpetually stale, or keep issuing redundant target scrolls that start the alternating rollback
     loop.
     */
    @MainActor
    func testVerseQualifiedSynchronizedScrollUpdatesTargetOnceWithoutReverseBroadcast() throws {
        let sourceBridge = BibleBridge()
        let targetBridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceController = BibleReaderController(bridge: sourceBridge, swordManagerOverride: manager)
        let targetController = BibleReaderController(bridge: targetBridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: sourceController.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Verse Qualified Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        sourceController.activeWindow = sourceWindow
        sourceController.windowManagerRef = windowManager
        targetController.activeWindow = targetWindow
        targetController.windowManagerRef = windowManager
        sourceController.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        targetController.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        targetWindow.pageManager?.bibleBibleBook = nil

        let sourceBroadcast = expectation(description: "source scroll broadcasts once")
        windowManager.onSyncVerseChanged = { eventSourceWindow, sourceOrdinal, key in
            XCTAssertEqual(eventSourceWindow.id, sourceWindow.id)
            XCTAssertEqual(sourceOrdinal, ordinal)
            XCTAssertEqual(key, "Gen.1.5")
            sourceBroadcast.fulfill()
        }

        sourceController.bridge(sourceBridge, didScrollToOrdinal: ordinal, key: "Gen.1.5", atChapterTop: false)

        wait(for: [sourceBroadcast], timeout: 1.0)
        XCTAssertEqual(sourceController.currentChapter, 1)
        XCTAssertEqual(sourceController.currentVerse, 5)
        XCTAssertEqual(sourceWindow.pageManager?.bibleChapterNo, 1)
        XCTAssertEqual(sourceWindow.pageManager?.bibleVerseNo, 5)
        XCTAssertEqual(windowManager.synchronizedVerseUpdateTargets(for: sourceWindow).map(\.id), [targetWindow.id])

        targetController.scrollToOrdinal(ordinal)

        XCTAssertEqual(targetWindow.pageManager?.bibleBibleBook, 0)
        XCTAssertTrue(windowManager.synchronizedVerseUpdateTargets(for: sourceWindow).isEmpty)

        let reverseBroadcast = expectation(description: "target acknowledgement must not rebroadcast")
        reverseBroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            reverseBroadcast.fulfill()
        }

        targetController.bridge(targetBridge, didScrollToOrdinal: ordinal, key: "Gen.1.5", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(targetController.currentChapter, 1)
        XCTAssertEqual(targetController.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleChapterNo, 1)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [reverseBroadcast], timeout: 0.35)
    }

    /**
     Protects Android's target-local synchronized scroll anchor conversion.

     Android synchronizes a `Verse` key, then converts it to the inactive window's own
     versification before emitting `scroll_to_verse`. This fixture uses a bundled KJV source
     ordinal for Genesis 1:10, whose intro-inclusive SWORD ordinal differs from the placeholder
     target ordinal, and expects the target WebView payload to use the target ordinal. A failure
     means iOS is forwarding source ordinals directly and can land nearby instead of on the same
     verse when panes use different ordinal spaces.
     */
    @MainActor
    func testSynchronizedScrollConvertsSourceVerseToTargetOrdinalSpace() throws {
        let sourceBridge = BibleBridge()
        let (targetBridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceController = BibleReaderController(bridge: sourceBridge, swordManagerOverride: manager)
        let targetController = BibleReaderController(bridge: targetBridge, initializesSword: false)
        let sourceModule = try XCTUnwrap(manager.module(named: sourceController.activeModuleName))
        let sourceOrdinal = try XCTUnwrap(
            sourceModule.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 10)
        )
        XCTAssertNotEqual(sourceOrdinal, 10)

        let sourceWindow = Window()
        let sourcePageManager = PageManager(id: sourceWindow.id)
        sourceWindow.pageManager = sourcePageManager
        sourceController.activeWindow = sourceWindow
        sourceController.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        let targetWindow = Window()
        let targetPageManager = PageManager(id: targetWindow.id)
        targetWindow.pageManager = targetPageManager
        targetController.activeWindow = targetWindow
        targetController.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        targetController.bridgeDidSetClientReady(targetBridge)
        let setupScriptCount = recordedScripts().count

        let sourceReference = try XCTUnwrap(sourceController.synchronizedVerseReference(ordinal: sourceOrdinal))
        XCTAssertEqual(sourceReference.osisBookId, "Gen")
        XCTAssertEqual(sourceReference.chapter, 1)
        XCTAssertEqual(sourceReference.verse, 10)

        targetController.scrollToSynchronizedVerse(
            osisBookId: sourceReference.osisBookId,
            chapter: sourceReference.chapter,
            verse: sourceReference.verse
        )

        let newScripts = Array(recordedScripts().dropFirst(setupScriptCount))
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: newScripts, event: "scroll_to_verse") as? [String: Any]
        )
        XCTAssertEqual(payload["ordinal"] as? Int, 10)
        XCTAssertEqual(payload["now"] as? Bool, false)
        XCTAssertEqual(targetController.currentVerse, 10)
        XCTAssertEqual(targetPageManager.bibleVerseNo, 10)
    }

    /**
     Protects Android's visible-verse old/new guard for synchronized windows.

     Android only posts a synchronized verse-change event when
     `CurrentBiblePage.setCurrentVerseOrdinal` changes the stored ordinal. The setup makes one
     synchronized iOS pane active at Genesis 1:5, then reports the same visible ordinal again. The
     expected result is no sync event because duplicate callbacks are scroll maintenance, not a new
     source position. A failure means stale duplicate callbacks can leave delayed sync work that
     later pulls another pane back after focus changes.
     */
    @MainActor
    func testDuplicateVisibleVerseCallbackDoesNotRebroadcastSynchronizedPane() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Duplicate Visible Verse")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        window.isSynchronized = true
        window.syncGroup = 0
        windowManager.setActiveWorkspace(workspace)
        windowManager.activeWindow = window
        controller.activeWindow = window
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        let rebroadcast = expectation(description: "duplicate visible verse must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, window.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(window.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects the synchronized-scroll feedback state machine used by reader panes.

     Android keeps secondary synchronized panes passive until explicit user interaction, including
     when a target scroll arrives before the Vue client is ready. The setup drives the extracted
     state machine without a WebView: it defers a target ordinal, promotes it after client-ready
     replay, acknowledges intermediate and matching callbacks, and finally clears through explicit
     interaction. The expected result is that sync-origin callbacks and native deltas stay passive
     until interaction. A failure means the state owner can reintroduce target-pane ping-pong even
     when controller-level tests pass through incidental state.
     */
    func testReaderSynchronizedScrollCoordinatorPreservesPassiveTargetStateUntilInteraction() {
        let coordinator = BibleReaderSynchronizedScrollCoordinator()

        XCTAssertTrue(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)

        coordinator.deferUntilClientReady(ordinal: 105)
        XCTAssertFalse(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)

        let deferredOrdinal = coordinator.consumeDeferredClientReadyOrdinalForReplay()
        XCTAssertEqual(deferredOrdinal, 105)
        if let deferredOrdinal {
            coordinator.markClientReadyReplayPending(ordinal: deferredOrdinal)
        }

        XCTAssertTrue(coordinator.acknowledgeVisibleOrdinal(104))
        XCTAssertFalse(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)
        XCTAssertTrue(coordinator.acknowledgeVisibleOrdinal(105))
        XCTAssertFalse(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)
        XCTAssertTrue(coordinator.acknowledgeVisibleOrdinal(106))

        coordinator.clearForUserInteraction()

        XCTAssertTrue(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)
        XCTAssertFalse(coordinator.acknowledgeVisibleOrdinal(105))
    }

    /**
     Protects Android's secondary-window synchronized scroll contract.

     Android posts a secondary scroll event to synced inactive windows and does not let the web
     client's resulting visible-verse callback become a new source window. The setup creates two
     synchronized panes, keeps the first pane active, then asks the second pane's controller to
     perform two sync-origin scrolls before acknowledging the latest. The expected result is that
     the second pane updates its visible verse state without focusing itself or rebroadcasting
     through `WindowManager`, while explicit user interaction cancels feedback suppression before a
     later real scroll callback; a failure means synced panes can ping-pong until a document
     boundary or stale sync requests can hide user-origin scrolling.
     */
    @MainActor
    func testSynchronizedScrollCallbackDoesNotRefocusOrRebroadcastTargetPane() throws {
        let bridge = BibleBridge()
        var emittedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { emittedScripts.append($0) }
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let olderOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 4))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Synchronized Scroll")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        emittedScripts.removeAll()
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "sync-origin scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(olderOrdinal)
        controller.scrollToOrdinal(ordinal)
        XCTAssertEqual(emittedScripts.count, 2)
        XCTAssertTrue(emittedScripts.allSatisfy { $0.contains("scroll_to_verse") })
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)

        let laterUserBroadcast = expectation(description: "older sync ordinal does not remain pending")
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            XCTAssertEqual(sourceWindow.id, targetWindow.id)
            XCTAssertEqual(sourceOrdinal, olderOrdinal)
            XCTAssertEqual(key, "Gen.1")
            laterUserBroadcast.fulfill()
        }

        controller.handleUserInteraction()
        controller.bridge(bridge, didScrollToOrdinal: olderOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(controller.currentVerse, 4)
        wait(for: [laterUserBroadcast], timeout: 1.0)
    }

    /**
     Protects inactive synced panes from intermediate programmatic scroll telemetry.

     Android keeps a secondary pane passive while a synchronized scroll is settling; WebView
     visible-verse callbacks that report nearby/intermediate ordinals are still feedback from the
     source pane, not a new user scroll in the target pane. The setup keeps the first synced window
     active, sends a sync scroll to the second window, then reports an adjacent ordinal before the
     target ordinal arrives. The expected result is that the second pane updates its native visible
     verse state without focusing itself or rebroadcasting. A failure means iOS can ping-pong
     between synced panes when WebKit reports partial scroll progress.
     */
    @MainActor
    func testSynchronizedScrollIntermediateCallbackDoesNotRefocusOrRebroadcastTargetPane() throws {
        let bridge = BibleBridge()
        var emittedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { emittedScripts.append($0) }
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let targetOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let intermediateOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 4))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Intermediate Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        emittedScripts.removeAll()
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "intermediate sync-origin scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(targetOrdinal)

        XCTAssertEqual(emittedScripts.count, 1)
        XCTAssertTrue(emittedScripts[0].contains("scroll_to_verse"))

        controller.bridge(bridge, didScrollToOrdinal: intermediateOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 4)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 4)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects Android's touch-driven source handoff for native WebView scroll telemetry.

     A synchronized secondary scroll can make UIKit report vertical scroll deltas while the target
     pane is moving programmatically. Android does not promote that inactive pane until an actual
     touch/web interaction occurs in it. The setup simulates the pane-host wiring: a native scroll
     delta is forwarded only when the controller classifies it as user-origin, then explicit user
     interaction is delivered and the same delta path is retried. The expected result is that
     sync-origin deltas neither focus nor auto-hide chrome, while real user interaction cancels the
     guard and restores normal delta forwarding. A failure means programmatic target scrolling can
     still activate and rebroadcast from the wrong pane.
     */
    @MainActor
    func testSynchronizedScrollNativeDeltaDoesNotFocusUntilExplicitUserInteraction() throws {
        let bridge = BibleBridge()
        bridge.javaScriptEvaluationObserver = { _ in }
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Native Delta Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        var forwardedDeltas: [Double] = []
        func simulatePaneNativeScrollDelta(_ deltaY: Double) {
            guard controller.shouldTreatNativeScrollDeltaAsUserInteraction() else { return }
            if windowManager.activeWindow?.id != targetWindow.id {
                controller.handleUserInteraction()
            }
            forwardedDeltas.append(deltaY)
        }

        controller.scrollToOrdinal(ordinal)
        simulatePaneNativeScrollDelta(18)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertTrue(forwardedDeltas.isEmpty)

        controller.handleUserInteraction()
        simulatePaneNativeScrollDelta(18)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(forwardedDeltas, [18])
    }

    /**
     Protects synchronized target panes across the native/WebView delivery boundary.

     Android updates an inactive synchronized window's key as sync-origin state before attempting
     the secondary scroll. If that inactive view later reports the same visible key, it must remain
     passive even when host focus has moved to the pane through a non-scroll path; only explicit
     user interaction may make it a new sync source. The setup uses a client-ready bridge without
     an attached WebView so the JavaScript emit is not delivered, then verifies the native sync
     state still suppresses the follow-up visible-verse callback. A failure means a detached or
     rebuilding target pane can rebroadcast its peer's synchronized key and start a reverse loop.
     */
    @MainActor
    func testDetachedSynchronizedScrollRemainsPassiveUntilExplicitInteraction() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let olderOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 4))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Detached Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "detached sync-origin scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(ordinal)
        windowManager.activeWindow = targetWindow
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)

        let userBroadcast = expectation(description: "explicit target interaction restores broadcasting")
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            XCTAssertEqual(sourceWindow.id, targetWindow.id)
            XCTAssertEqual(sourceOrdinal, olderOrdinal)
            XCTAssertEqual(key, "Gen.1")
            userBroadcast.fulfill()
        }

        controller.handleUserInteraction()
        controller.bridge(bridge, didScrollToOrdinal: olderOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(controller.currentVerse, 4)
        wait(for: [userBroadcast], timeout: 1.0)
    }

    /**
     Protects visible-verse telemetry from acting as source-window ownership.

     Android treats document visible-position reports as passive state updates; a synced pane only
     becomes the new source after an explicit touch or web interaction has already made it active.
     The setup leaves the second synchronized window inactive and sends a plain visible-verse
     callback without any native interaction. The expected result is that the target pane records
     the verse for restoration but neither focuses itself nor schedules reverse synchronization. A
     failure means an inactive pane can start the alternating sync loop from passive WebView
     telemetry alone.
     */
    @MainActor
    func testInactiveSynchronizedScrollCallbackDoesNotFocusOrBroadcastWithoutInteraction() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Passive Visible Verse")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "passive inactive scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects cross-chapter synchronized navigation from becoming a new scroll source.

     Android treats a secondary window chapter change caused by synchronized scrolling as passive
     feedback from the source pane. The setup keeps the first synced window active, asks the target
     controller to navigate to the source ordinal in the next chapter using the sync-specific entry
     point, then reports that visible ordinal from the web client. The expected result is that the
     target updates to the source verse without focusing or rebroadcasting. A failure means iOS only
     suppresses same-chapter sync scrolls and can still ping-pong when synced panes cross a chapter
     boundary.
     */
    @MainActor
    func testSynchronizedNavigationCallbackDoesNotRefocusOrRebroadcastTargetPane() throws {
        let bridge = BibleBridge()
        bridge.javaScriptEvaluationObserver = { _ in }
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Cross Chapter Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "sync-origin chapter navigation must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.navigateToSynchronizedPosition(book: "Genesis", chapter: 2, ordinal: ordinal)
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.2", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleChapterNo, 2)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects synchronized scrolling across the native/WebView bootstrap boundary.

     Android updates the inactive window's verse key before attempting a secondary visible scroll, so
     a rebuilding target pane lands on the synchronized verse when its content is replayed without
     becoming the new source window. This fixture attaches a recording bridge before
     `clientReady`, sends a sync scroll, and verifies iOS does not queue `scroll_to_verse` into an
     unmounted Vue listener while still suppressing the replay-induced `scrolledToOrdinal`
     callback. A failure means iOS can either drop the target pane position or treat a bootstrap
     replay as a user-origin sync source.
     */
    @MainActor
    func testSynchronizedScrollBeforeClientReadyReplaysWithoutRefocusOrRebroadcast() throws {
        let bridge = BibleBridge()
        var emittedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { emittedScripts.append($0) }
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Pre-Ready Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "ready replay must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(ordinal)

        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        XCTAssertFalse(emittedScripts.contains { $0.contains("scroll_to_verse") })

        controller.bridgeDidSetClientReady(bridge)

        XCTAssertFalse(emittedScripts.contains { $0.contains("scroll_to_verse") })
        XCTAssertTrue(
            emittedScripts.contains {
                $0.contains("setup_content") && $0.contains("\"jumpToOrdinal\":\(ordinal)")
            }
        )
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects user-origin synchronized scrolling while suppressing only secondary feedback.

     Android still treats a real scroll in a synchronized pane as the new source window. The setup
     mirrors the secondary-scroll regression fixture with a detached bridge, then delivers the
     explicit interaction that native dragging sends before a changed visible-position callback. The
     expected result is that explicit interaction clears sync-origin suppression and the active pane
     emits one sync event through `WindowManager`; a failure means the feedback-loop guard has
     disabled real synchronized scrolling or visible-verse telemetry is being treated as source
     ownership.
     */
    @MainActor
    func testUserScrollCallbackStillFocusesAndBroadcastsSynchronizedPane() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let syncOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let userOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 6))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "User Scroll")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let scrolledWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        scrolledWindow.isSynchronized = true
        scrolledWindow.syncGroup = 0
        windowManager.activeWindow = firstWindow
        controller.activeWindow = scrolledWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = scrolledWindow
        }
        let broadcast = expectation(description: "user-origin scroll rebroadcasts")
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            XCTAssertEqual(sourceWindow.id, scrolledWindow.id)
            XCTAssertEqual(sourceOrdinal, userOrdinal)
            XCTAssertEqual(key, "Gen.1")
            broadcast.fulfill()
        }

        controller.scrollToOrdinal(syncOrdinal)
        controller.handleUserInteraction()
        controller.bridge(bridge, didScrollToOrdinal: userOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, scrolledWindow.id)
        XCTAssertEqual(controller.currentVerse, 6)
        wait(for: [broadcast], timeout: 1.0)
    }

    /**
     Protects chapter-change scroll persistence against synthetic ordinal arithmetic.

     The document key tells the native reader which chapter is visible, but the verse number must
     still be reverse-mapped from the JSword/SWORD ordinal. Genesis 2:5 is intentionally chosen
     because SWORD's ordinal is not the legacy `45`; a failure means infinite-scroll persistence
     can store the wrong visible verse after a chapter boundary.
     */
    func testDidScrollToOrdinalPersistsImmediatelyWhenChapterChanges() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 5))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.2", atChapterTop: false)

        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

    /**
     Mutable state captured by the navigation context test closures.

     The production coordinator receives escaping closures owned by `BibleReaderController`. Tests
     use this reference type to model the same lifetime explicitly without unsafe pointer captures.
     A failure involving this helper usually means the test fixture no longer matches the
     coordinator's closure-based dependency contract.
     */
    private final class NavigationCoordinatorStateBox {
        /// Current visible Bible position.
        var position: BibleReaderNavigationPosition

        /// Recorded history keys supplied by explicit navigation.
        var history: [String] = []

        /// Number of durable persistence requests.
        var persistCount = 0

        /// Number of host content reload requests.
        var loadCount = 0

        /// Creates a fixture state box for one coordinator test.
        init(position: BibleReaderNavigationPosition) {
            self.position = position
        }
    }

    /**
     Builds a deterministic navigation context backed by in-memory state.

     The fixture uses two books and synthetic ordinals (`chapter * 100 + verse`) so assertions can
     focus on coordinator ownership rather than SWORD lookups. This mirrors the production contract:
     the controller supplies versification lookups, while the coordinator decides when to use them
     and when to persist PageManager state.
     */
    private func makeNavigationCoordinatorContext(
        state: NavigationCoordinatorStateBox,
        pageManager: PageManager,
        clientReady: Bool = true,
        isShowingAndroidMultiDocument: Bool = false
    ) -> BibleReaderNavigationContext {
        let books = [
            BibleReaderNavigationBook(name: "Genesis", osisId: "Gen", chapterCount: 50),
            BibleReaderNavigationBook(name: "Exodus", osisId: "Exod", chapterCount: 40),
        ]

        func book(named name: String) -> BibleReaderNavigationBook? {
            books.first { $0.name == name }
        }

        func osisId(for name: String) -> String {
            book(named: name)?.osisId ?? name
        }

        return BibleReaderNavigationContext(
            currentPosition: { state.position },
            setCurrentPosition: { state.position = $0 },
            pageManager: { pageManager },
            bookList: { books },
            isShowingAndroidMultiDocument: { isShowingAndroidMultiDocument },
            clientReady: { clientReady },
            chapterCount: { book(named: $0)?.chapterCount ?? 0 },
            nextBook: { name in
                guard let index = books.firstIndex(where: { $0.name == name }),
                      index + 1 < books.count else {
                    return nil
                }
                return books[index + 1].name
            },
            previousBook: { name in
                guard let index = books.firstIndex(where: { $0.name == name }),
                      index > 0 else {
                    return nil
                }
                return books[index - 1].name
            },
            bookNameForOsisId: { osisId in
                books.first { $0.osisId == osisId }?.name
            },
            ordinalForVerse: { _, chapter, verse in
                chapter * 100 + verse
            },
            verseReference: { bookName, ordinal in
                BibleReaderNavigationVerseReference(
                    chapter: ordinal / 100,
                    verse: ordinal % 100,
                    osisBookId: osisId(for: bookName)
                )
            },
            recordHistory: { bookName, chapter, verse in
                state.history.append("\(osisId(for: bookName)).\(chapter).\(verse)")
            },
            persistState: {
                state.persistCount += 1
            },
            loadCurrentContent: {
                state.loadCount += 1
            }
        )
    }

    /**
     Protects the extracted direct-navigation state transition.

     Setup creates an active in-memory PageManager and a client-ready context. Navigation to an
     explicit verse should update visible state, persist the Bible position, record the Android-style
     OSIS history key, retain the explicit ordinal range for the next render, and ask the host to
     reload content once. A failure means direct reader navigation has drifted back into ad hoc
     controller mutations instead of a single durable page-position transition.
     */
    func testReaderNavigationCoordinatorPersistsHistoryAndExplicitRestoreTarget() {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = NavigationCoordinatorStateBox(
            position: BibleReaderNavigationPosition(book: "Genesis", chapter: 1, verse: 1)
        )
        let pageManager = PageManager()
        let context = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager
        )

        coordinator.navigateTo(book: "Exodus", chapter: 2, verse: 3, context: context)

        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Exodus", chapter: 2, verse: 3))
        XCTAssertEqual(pageManager.bibleBibleBook, 1)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 3)
        XCTAssertEqual(state.history, ["Exod.2.3"])
        XCTAssertEqual(state.persistCount, 1)
        XCTAssertEqual(state.loadCount, 1)
        XCTAssertEqual(coordinator.originalNavigationOrdinalRange, [203, 203])
        XCTAssertEqual(
            coordinator.consumeContentRestoreTarget(
                currentPosition: state.position,
                ordinalForVerse: { _, chapter, verse in chapter * 100 + verse }
            ),
            .ordinal(203)
        )
    }

    /**
     Protects visible-scroll state updates reported by the Vue reader.

     Android treats WebView visible-position callbacks as page-manager updates, not transient UI
     hints. This test scrolls from Genesis into an Exodus key and expects the coordinator to update
     the visible book/chapter/verse, persist the new PageManager position immediately, and preserve a
     restore target for the current visible verse. A failure means iOS can reopen or synchronize a
     stale verse after infinite-scroll movement.
     */
    func testReaderNavigationCoordinatorVisibleScrollUpdatesBookChapterVerseAndPageManager() {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = NavigationCoordinatorStateBox(
            position: BibleReaderNavigationPosition(book: "Genesis", chapter: 1, verse: 1)
        )
        let pageManager = PageManager()
        let context = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager
        )

        let changed = coordinator.updateVisiblePosition(
            ordinal: 205,
            key: "Exod.2",
            atChapterTop: false,
            context: context
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Exodus", chapter: 2, verse: 5))
        XCTAssertEqual(pageManager.bibleBibleBook, 1)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
        XCTAssertEqual(state.persistCount, 1)
        XCTAssertEqual(state.loadCount, 0)
        XCTAssertEqual(
            coordinator.consumeContentRestoreTarget(
                currentPosition: state.position,
                ordinalForVerse: { _, chapter, verse in chapter * 100 + verse }
            ),
            .ordinal(205)
        )
    }

    /**
     Protects Android-style chapter wrapping and synthetic multi-document blocking.

     The reader host delegates next/previous chapter controls into the same coordinator used by
     bridge navigation. Genesis 50 should wrap to Exodus 1, Exodus 1 should wrap back to Genesis 50,
     and Android synthetic multi documents must not advertise Bible chapter navigation. A failure
     means toolbar, keyboard, swipe, and bridge navigation can diverge.
     */
    func testReaderNavigationCoordinatorChapterWrappingAndMultiDocumentNavigationAvailability() {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = NavigationCoordinatorStateBox(
            position: BibleReaderNavigationPosition(book: "Genesis", chapter: 50, verse: 1)
        )
        let pageManager = PageManager()
        let context = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager
        )

        XCTAssertTrue(coordinator.hasNext(context: context))
        coordinator.navigateNext(context: context)
        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Exodus", chapter: 1, verse: 1))

        coordinator.navigatePrevious(context: context)
        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Genesis", chapter: 50, verse: 1))

        let multiDocumentContext = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager,
            isShowingAndroidMultiDocument: true
        )
        XCTAssertFalse(coordinator.hasNext(context: multiDocumentContext))
        XCTAssertFalse(coordinator.hasPrevious(context: multiDocumentContext))
    }

}
