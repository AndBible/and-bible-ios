import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Package-level reader bridge and document-payload tests migrated from the app-host bundle.

 These tests protect Android/Vue reader payload contracts that belong to BibleUI and its bridge
 collaborators. The suite extends `BibleUISwordFixtureTestCase` only for isolated SWORD-fixture
 fixtures; it does not require app delegate, scene, or installed app bootstrap behavior.
 */
final class ReaderNavigationBridgePayloadTests: BibleUISwordFixtureTestCase {
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
     are not `(chapter - 1) * 40 + verse`. The KJV test fixture module supplies the same SWORD
     versification data here; a failure means compare links have drifted back toward synthetic
     ordinals and can open the wrong verse range.
     */
    func testReaderCompareBridgeRequestEmitsVueCompareDocument() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
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
     document with `compare=true`. This test exercises the builder directly against the KJV test fixture
     SWORD fixture so the controller can remain an orchestration boundary while the builder owns
     module ordering, verse extraction, range titles, and typed bridge JSON assembly.
     */
    func testCompareDocumentBuilderBuildsAndroidMultiDocumentPayload() throws {
        let modulePath = try makeTemporarySwordFixturePath()
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
}
