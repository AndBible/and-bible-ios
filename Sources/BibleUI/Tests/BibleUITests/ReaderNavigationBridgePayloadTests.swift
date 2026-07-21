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
     Builds one generic bookmark DTO for exact document hydration tests.

     - Parameters:
       - id: Stable bookmark identifier asserted in the serialized document.
       - bookInitials: Exact source initials expected by the factory provider.
       - key: Exact source key expected by the factory provider.
     - Returns: Fully shaped whole-page generic bookmark payload.
     - Side effects: None.
     - Failure modes: None; the fixture uses only deterministic literal values.
     */
    private func genericBookmarkDataForFactoryTest(
        id: String,
        bookInitials: String,
        key: String
    ) -> GenericBookmarkData {
        GenericBookmarkData(
            id: id,
            type: "generic-bookmark",
            hashCode: 1,
            ordinalRange: [nil, nil],
            offsetRange: nil,
            labels: [],
            bookInitials: bookInitials,
            bookName: bookInitials,
            bookAbbreviation: bookInitials,
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
            editAction: nil,
            key: key,
            keyName: key,
            highlightedText: "",
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
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any],
            "Expected Compare to emit a parsed MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertEqual(document["type"] as? String, "multi")
        XCTAssertEqual(document["compare"] as? Bool, true)
        let fragments = try XCTUnwrap(document["osisFragments"] as? [[String: Any]])
        let source = try XCTUnwrap(fragments.first)
        XCTAssertEqual(source["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(source["bookInitials"] as? String, activeModuleName)
        XCTAssertEqual(source["bookAbbreviation"] as? String, activeModuleName)
        XCTAssertEqual(source["osisRef"] as? String, "2Cor.2.5-2Cor.2.7")
        XCTAssertEqual(source["keyName"] as? String, "2 Corinthians 2:5-7")
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
            installedBibleModules: [moduleInfo]
        )
        let sourceModule = try XCTUnwrap(manager.module(named: "KJV"))

        let request = try XCTUnwrap(
            builder.makeRequest(
                bookInitials: "KJV",
                startOrdinal: try XCTUnwrap(
                    sourceModule.verseOrdinal(osisBookId: "2Cor", chapter: 2, verse: 5)
                ),
                endOrdinal: try XCTUnwrap(
                    sourceModule.verseOrdinal(osisBookId: "2Cor", chapter: 2, verse: 7)
                )
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
        XCTAssertEqual(fragment["v11n"] as? String, "KJV")
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
        let markerPageID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
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
            },
            aiDocMarkersForPage: { _, _ in
                XCTFail("Bible documents must query AI markers by KJVA overlap, not source key")
                return []
            },
            aiDocMarkersForKJVARange: { startOrdinal, endOrdinal in
                XCTAssertEqual(startOrdinal, 4)
                XCTAssertEqual(endOrdinal, 6)
                return [
                    MyDocumentAIDocMarker(
                        pageId: markerPageID,
                        documentId: markerPageID,
                        documentInitials: "AIDocuments",
                        pageTitle: "Creation notes",
                        pageKey: "creation",
                        kjvOrdinalStart: 4,
                        kjvOrdinalEnd: 6,
                        sourcePromptId: nil,
                        sourceBookInitials: "Vulg",
                        sourceBookKey: "Gen.1.1-3"
                    ),
                ]
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
                    xml: #"<div><verse osisID="Gen.1.1">In the beginning</verse></div>"#,
                    moduleName: "King James Version",
                    moduleAbbreviation: "KJV",
                    versificationName: "KJV",
                    aiMarkerKJVAOrdinalRange: [4, 6]
                )
            )
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let marker = try XCTUnwrap((document["aiDocMarkers"] as? [[String: Any]])?.first)

        XCTAssertEqual(document["type"] as? String, "bible")
        XCTAssertEqual(document["bookInitials"] as? String, "KJV")
        XCTAssertEqual(document["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(document["bookName"] as? String, "King James Version")
        XCTAssertEqual(document["v11n"] as? String, "KJV")
        XCTAssertEqual(document["key"] as? String, "Gen.1")
        XCTAssertEqual(document["ordinalRange"] as? [Int], [100, 103])
        XCTAssertEqual(document["chapterReadCount"] as? Int, 2)
        XCTAssertEqual(document["memorizedOrdinals"] as? [Int], [100, 101])
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [103])
        XCTAssertEqual(marker["id"] as? String, markerPageID.uuidString)
        XCTAssertEqual(marker["sourceBookInitials"] as? String, "Vulg")
        XCTAssertEqual(marker["sourceBookKey"] as? String, "Gen.1.1-3")
        XCTAssertEqual(fragment["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragment["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(fragment["v11n"] as? String, "KJV")
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [100, 103])
    }

    /**
     Verifies Bible AI markers leave KJVA storage ordinals before Vue payload serialization.

     - Setup: Stores the KJVA Psalm 11 superscription through verse 1, whose Android mapping is
       Vulgate Psalm 10:1-2, and builds a Vulgate Bible document.
     - Expected result: Marker ordinals and abbreviated text belong to Vulgate, while the marker
       provider query still receives the authoritative stored KJVA range.
     - Failure meaning: A divergent-canon reader can place AI markers on unrelated displayed verses
       by relabeling KJVA endpoints as target-module ordinals.
     - Side effects: Lazily reads bundled JSword mapping and SWORD canon fixtures only.
     */
    func testBibleAIMarkerPayloadConvertsKJVAEndpointsToDisplayedVersification() throws {
        let kjvaStart = try XCTUnwrap(
            JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 11)
        )
        let kjvaEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Ps", chapter: 11, verse: 1)
        )
        let targetStartReference = SwordVersification.Reference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 1
        )
        let targetEndReference = SwordVersification.Reference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 2
        )
        let targetStart = try XCTUnwrap(
            SwordVersification.referenceIndex(for: targetStartReference, versification: "Vulg")
        )
        let targetEnd = try XCTUnwrap(
            SwordVersification.referenceIndex(for: targetEndReference, versification: "Vulg")
        )
        let markerID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")
        )
        let factory = BibleReaderDocumentPayloadFactory(
            activeModuleName: "VulgFixture",
            hasStrongs: false,
            bookmarkPayload: { _ in self.emptyBibleBookmarkDataForFactoryTest() },
            chapterOrdinalRange: { _, _, _ in
                XCTFail("Explicit target ordinals must bypass chapter resolution")
                return nil
            },
            kjvBookOrdinal: { _ in nil },
            chapterReadCount: { _, _ in nil },
            memorizedOrdinals: { _, _, _ in [] },
            targetOrdinals: { _, _, _ in [] },
            aiDocMarkersForKJVARange: { start, end in
                XCTAssertEqual([start, end], [kjvaStart, kjvaEnd])
                return [
                    MyDocumentAIDocMarker(
                        pageId: markerID,
                        documentId: markerID,
                        documentInitials: "AIDocuments",
                        pageTitle: "Psalm context",
                        pageKey: "psalm-context",
                        kjvOrdinalStart: kjvaStart,
                        kjvOrdinalEnd: kjvaEnd,
                        sourcePromptId: nil,
                        sourceBookInitials: "KJV",
                        sourceBookKey: "Ps.11.0-Ps.11.1"
                    ),
                ]
            }
        )

        let json = try XCTUnwrap(
            factory.documentJSON(
                BibleReaderDocumentPayloadRequest(
                    osisBookId: "Ps",
                    bookName: "Psalms",
                    chapter: 10,
                    verseCount: 2,
                    isNewTestament: false,
                    xml: #"<div><verse osisID="Ps.10.1">Psalm</verse></div>"#,
                    ordinalRangeOverride: [targetStart, targetEnd],
                    versificationName: "Vulg",
                    aiMarkerKJVAOrdinalRange: [kjvaStart, kjvaEnd]
                )
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let marker = try XCTUnwrap((payload["aiDocMarkers"] as? [[String: Any]])?.first)

        XCTAssertEqual(marker["ordinalRange"] as? [Int], [targetStart, targetEnd])
        XCTAssertNotEqual(marker["ordinalRange"] as? [Int], [kjvaStart, kjvaEnd])
        XCTAssertEqual(marker["verseRangeAbbreviated"] as? String, "Psa 10:1-2")
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
                    xml: "<div></div>",
                    versificationName: "KJV"
                )
            )
        )
    }

    /**
     Protects the Vue `ErrorDocument` bridge contract used for installed reader content gaps.

     Download failures must fail module installation before a module is published. This payload is
     only for reader-time empty content from an already installed module, and uses normal severity so
     Vue shows the message without the unexpected-error reporting affordance.
     */
    func testReaderDocumentPayloadFactoryBuildsNoContentErrorDocument() throws {
        let factory = BibleReaderDocumentPayloadFactory(
            activeModuleName: "KJV",
            hasStrongs: false,
            bookmarkPayload: { _ in
                XCTFail("Error documents do not project Bible bookmarks")
                return self.emptyBibleBookmarkDataForFactoryTest()
            },
            chapterOrdinalRange: { _, _, _ in
                XCTFail("Error documents should not resolve Bible ordinal ranges")
                return nil
            },
            kjvBookOrdinal: { _ in nil },
            chapterReadCount: { _, _ in nil },
            memorizedOrdinals: { _, _, _ in [] },
            targetOrdinals: { _, _, _ in [] }
        )

        let json = try XCTUnwrap(
            factory.errorDocumentJSON(message: "No content for selected verse")
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(document["id"] as? String, "doc-1")
        XCTAssertEqual(document["type"] as? String, "error")
        XCTAssertEqual(document["errorMessage"] as? String, "No content for selected verse")
        XCTAssertEqual(document["severity"] as? String, "NORMAL")
    }

    /**
     Protects the EPUB document path used by the shared Vue reader.

     EPUB sections are rendered as native HTML through `OsisDocument`, not the Bible document path.
     This matches the existing iOS bridge behavior while using the same document surface Android
     uses for general rendered content. A failure means EPUB content can regress to blank rendering
     because Vue may try to parse XHTML as OSIS.
     */
    func testReaderDocumentPayloadFactoryBuildsEpubNativeHtmlDocument() throws {
        let bookmarkID = "11111111-2222-3333-4444-555555555555"
        let markerPageID = try XCTUnwrap(
            UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")
        )
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
            targetOrdinals: { _, _, _ in [] },
            genericBookmarks: { initials, key in
                XCTAssertEqual(initials, "Epub-[x]\\^_epub")
                XCTAssertEqual(key, "17")
                return [
                    self.genericBookmarkDataForFactoryTest(
                        id: bookmarkID,
                        bookInitials: initials,
                        key: key
                    ),
                ]
            },
            aiDocMarkersForPage: { initials, key in
                XCTAssertEqual(initials, "Epub-[x]\\^_epub")
                XCTAssertEqual(key, "17")
                return [
                    MyDocumentAIDocMarker(
                        pageId: markerPageID,
                        documentId: markerPageID,
                        documentInitials: "AIDocuments",
                        pageTitle: "Generated answer",
                        pageKey: "answer",
                        kjvOrdinalStart: 4,
                        kjvOrdinalEnd: 4,
                        sourcePromptId: nil,
                        sourceBookInitials: initials,
                        sourceBookKey: key
                    ),
                ]
            }
        )

        let json = factory.epubDocumentJSON(
            bookName: "Pilgrim's Progress",
            bookInitials: "Epub-[x]\\^_epub",
            key: "17",
            keyName: "Chapter One",
            content: #"<div><span class="ordinal" data-ordinal="8">Text</span></div>"#,
            ordinalRange: [8, 21],
            language: "ar"
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
        let genericBookmark = try XCTUnwrap(
            (document["genericBookmarks"] as? [[String: Any]])?.first
        )
        let marker = try XCTUnwrap((document["aiDocMarkers"] as? [[String: Any]])?.first)

        XCTAssertEqual(document["type"] as? String, "osis")
        XCTAssertEqual(document["id"] as? String, "Epub__x____epub_17")
        XCTAssertEqual(document["bookCategory"] as? String, "GENERAL_BOOK")
        XCTAssertEqual(document["bookInitials"] as? String, "Epub-[x]\\^_epub")
        XCTAssertEqual(document["bookName"] as? String, "Pilgrim's Progress")
        XCTAssertEqual(document["bookAbbreviation"] as? String, "Pilgrim's Progress")
        XCTAssertEqual(document["key"] as? String, "17")
        XCTAssertEqual(document["osisRef"] as? String, "17")
        XCTAssertEqual(document["annotateRef"] as? String, "17")
        XCTAssertTrue(document["v11n"] is NSNull)
        XCTAssertEqual(document["isNativeHtml"] as? Bool, true)
        XCTAssertEqual(document["ordinalRange"] as? [Int], [8, 21])
        XCTAssertEqual(genericBookmark["id"] as? String, bookmarkID)
        XCTAssertEqual(genericBookmark["key"] as? String, "17")
        XCTAssertEqual(marker["id"] as? String, markerPageID.uuidString)
        XCTAssertEqual(marker["sourceBookInitials"] as? String, "Epub-[x]\\^_epub")
        XCTAssertEqual(marker["sourceBookKey"] as? String, "17")
        XCTAssertEqual(fragment["xml"] as? String, #"<div><span class="ordinal" data-ordinal="8">Text</span></div>"#)
        XCTAssertEqual(fragment["bookCategory"] as? String, "GENERAL_BOOK")
        XCTAssertEqual(fragment["bookInitials"] as? String, "Epub-[x]\\^_epub")
        XCTAssertEqual(fragment["bookAbbreviation"] as? String, "Pilgrim's Progress")
        XCTAssertEqual(fragment["key"] as? String, "Epub-[x]\\^_epub--17")
        XCTAssertEqual(fragment["keyName"] as? String, "Chapter One")
        XCTAssertEqual(fragment["osisRef"] as? String, "17")
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertEqual(fragment["language"] as? String, "ar")
        XCTAssertEqual(fragment["direction"] as? String, "rtl")
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, false)
        XCTAssertEqual(fragment["ordinalRange"] as? [Int], [8, 21])
    }

    /**
     Verifies missing auxiliary modules fail visibly without fabricating OSIS content.

     The module picker and auxiliary browsers can ask the reader to show dictionary, general-book,
     or map content before a module is selected. The loader must emit the shared error document and
     complete setup contract while retaining the compact rendered state used by native chrome.

     - Side effects: Creates three controller/bridge pairs and emits one missing-module result for
       each auxiliary category.
     - Failure modes: Fails if a path fabricates XML, omits setup fields, loses its visible error, or
       changes the category-specific rendered-state token.
     */
    func testReaderAuxiliaryContentMissingModulesEmitErrorDocuments() throws {
        let cases: [
            (
                action: (BibleReaderController) -> Void,
                category: String,
                renderedState: String,
                expectedMessage: String
            )
        ] = [
            (
                action: { $0.loadDictionaryEntry() },
                category: "dictionary",
                renderedState: "category=dictionary;module=none;book=Dictionary;chapter=none;key=none",
                expectedMessage: "No dictionary module is selected. Download one from the module browser."
            ),
            (
                action: { $0.loadGeneralBookEntry() },
                category: "general_book",
                renderedState: "category=general_book;module=none;book=General Book;chapter=none;key=none",
                expectedMessage: "No general book module is selected. Download one from the module browser."
            ),
            (
                action: { $0.loadMapEntry() },
                category: "map",
                renderedState: "category=map;module=none;book=Map;chapter=none;key=none",
                expectedMessage: "No map module is selected. Download one from the module browser."
            ),
        ]

        for testCase in cases {
            let (bridge, recordedScripts) = makeRecordingBridge()
            let controller = BibleReaderController(bridge: bridge, initializesSword: false)

            testCase.action(controller)

            let document = try XCTUnwrap(
                bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any],
                "Expected \(testCase.category) to emit an auxiliary error document"
            )
            let setup = try XCTUnwrap(
                bridgeEmissionPayload(from: recordedScripts(), event: "setup_content") as? [String: Any]
            )

            XCTAssertEqual(document["type"] as? String, "error")
            XCTAssertEqual(document["errorMessage"] as? String, testCase.expectedMessage)
            XCTAssertEqual(document["severity"] as? String, "NORMAL")
            XCTAssertEqual(setup.keys.count, 10)
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
