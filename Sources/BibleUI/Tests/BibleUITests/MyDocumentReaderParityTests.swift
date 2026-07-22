// MyDocumentReaderParityTests.swift -- Reader, AI metadata, persistence, and share parity

import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
#if os(iOS)
import UIKit
#endif

final class MyDocumentReaderParityTests: BibleUISwordFixtureTestCase {
    /**
     Builds one exact generic bookmark DTO for My Documents payload hydration assertions.

     - Parameters:
       - id: Stable bookmark identifier asserted after JSON serialization.
       - bookInitials: Exact generated-book initials.
       - key: Exact page key within the generated book.
     - Returns: Fully shaped generic bookmark payload for the exact source page.
     - Side effects: None.
     - Failure modes: None; all non-identity values are deterministic fixtures.
     */
    private func genericBookmarkPayload(id: String, bookInitials: String, key: String) -> GenericBookmarkData {
        GenericBookmarkData(
            id: id,
            type: "generic-bookmark",
            hashCode: 1,
            ordinalRange: [0, 0],
            offsetRange: nil,
            labels: [],
            bookInitials: bookInitials,
            bookName: bookInitials,
            bookAbbreviation: bookInitials,
            createdAt: 0,
            text: "Answer",
            fullText: "Answer",
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
            highlightedText: "Answer",
            osisFragment: nil
        )
    }

    /**
     Verifies prompt/model metadata and source-page AI markers use Android's reader payload shape.

     A generated page points back to a source My Documents page through `AiPageCacheEntry`. The
     store must project the localized unknown-prompt fallback and model for the generated page, and
     project that generated page as a deterministic `ClientAiDocMarker` on its source page.
     */
    @MainActor
    func testReaderMetadataProjectsPromptModelAndSourcePageMarker() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let promptID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let sourceDocument = MyDocument(name: "Sources", initials: "SOURCE")
        let sourcePage = MyDocumentPage(title: "Source", pageKey: "source")
        let generatedDocument = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let generatedPage = MyDocumentPage(
            title: "Generated answer",
            pageKey: "answer",
            sourcePromptId: promptID
        )
        let cache = AiPageCacheEntry(
            pageId: generatedPage.id,
            sourcePromptId: promptID,
            sourceContext: "context",
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            contextHash: "hash",
            usedWriteTools: false,
            sourceModelName: "android-model",
            sourceBookInitials: "SOURCE",
            sourceBookKey: "source"
        )
        sourcePage.document = sourceDocument
        sourceDocument.pages = [sourcePage]
        generatedPage.document = generatedDocument
        generatedPage.aiPageCacheEntries = [cache]
        generatedDocument.pages = [generatedPage]
        cache.page = generatedPage
        context.insert(sourceDocument)
        context.insert(sourcePage)
        context.insert(generatedDocument)
        context.insert(generatedPage)
        context.insert(cache)
        try context.save()

        let store = MyDocumentStore(modelContext: context)
        let generatedMetadata = store.readerMetadata(
            for: generatedPage,
            bookInitials: "AIDocuments",
            pageKey: "answer",
            unknownPromptName: "AI"
        )
        XCTAssertEqual(generatedMetadata.sourcePromptId, promptID)
        XCTAssertEqual(generatedMetadata.sourcePromptName, "AI")
        XCTAssertEqual(generatedMetadata.sourceModelName, "android-model")

        let sourceMetadata = store.readerMetadata(
            for: sourcePage,
            bookInitials: "SOURCE",
            pageKey: "source",
            unknownPromptName: "AI"
        )
        XCTAssertEqual(sourceMetadata.aiDocMarkers.count, 1)
        XCTAssertEqual(sourceMetadata.aiDocMarkers.first?.pageId, generatedPage.id)
        XCTAssertEqual(sourceMetadata.aiDocMarkers.first?.documentInitials, "AIDocuments")
        XCTAssertEqual(sourceMetadata.aiDocMarkers.first?.kjvOrdinalStart, 4)
        XCTAssertEqual(sourceMetadata.aiDocMarkers.first?.sourceBookKey, "source")
        XCTAssertEqual(store.aiDocMarkers(kjvaRange: 4...5).map(\.pageId), [generatedPage.id])
        XCTAssertTrue(store.aiDocMarkers(kjvaRange: 5...6).isEmpty)
    }

    /**
     Verifies the WebView document carries Android's native-HTML, AI footer, and marker contracts.
     */
    func testDocumentPayloadCarriesAndroidAIMetadataAndMarkerShape() throws {
        let coordinator = BibleReaderMyDocumentCoordinator()
        let promptID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let markerPageID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let markerDocumentID = try XCTUnwrap(UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"))
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let page = MyDocumentPage(
            title: "Answer",
            pageKey: "answer",
            sourcePromptId: promptID,
            languageCode: "en"
        )
        page.pageContent = MyDocumentPageContent(pageId: page.id, content: "**Answer**")
        let metadata = MyDocumentReaderMetadata(
            sourcePromptId: promptID,
            sourcePromptName: "Explain passage",
            sourceModelName: "model-1",
            aiDocMarkers: [
                MyDocumentAIDocMarker(
                    pageId: markerPageID,
                    documentId: markerDocumentID,
                    documentInitials: "AIDocuments",
                    pageTitle: "Related answer",
                    pageKey: "related",
                    kjvOrdinalStart: 4,
                    kjvOrdinalEnd: 4,
                    sourcePromptId: promptID,
                    sourceBookInitials: "KJV",
                    sourceBookKey: "Gen.1.1"
                ),
            ]
        )
        let genericBookmarkID = "22222222-3333-4444-5555-666666666666"

        let json = try XCTUnwrap(
            coordinator.documentJSON(
                document: document,
                page: page,
                metadata: metadata,
                genericBookmarks: [
                    genericBookmarkPayload(
                        id: genericBookmarkID,
                        bookInitials: document.initials,
                        key: page.pageKey
                    ),
                ],
                bookLocale: Locale(identifier: "en")
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        let marker = try XCTUnwrap((payload["aiDocMarkers"] as? [[String: Any]])?.first)
        let genericBookmark = try XCTUnwrap(
            (payload["genericBookmarks"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(payload["id"] as? String, "AIDocuments_answer")
        XCTAssertEqual(payload["isNativeHtml"] as? Bool, true)
        XCTAssertEqual(payload["isAiDocument"] as? Bool, true)
        XCTAssertEqual(payload["sourcePromptId"] as? String, promptID.uuidString)
        XCTAssertEqual(payload["sourcePromptName"] as? String, "Explain passage")
        XCTAssertEqual(payload["sourceModelName"] as? String, "model-1")
        XCTAssertTrue(payload["v11n"] is NSNull)
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertEqual(fragment["language"] as? String, "en")
        XCTAssertEqual(fragment["direction"] as? String, "ltr")
        XCTAssertEqual(payload["ordinalRange"] as? [Int], [0, 0])
        XCTAssertEqual(fragment["key"] as? String, "AIDocuments--answer")
        XCTAssertTrue(fragment["ordinalRange"] is NSNull)
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        XCTAssertTrue(xml.contains("<BVA"))
        XCTAssertTrue(xml.contains(">Answer</BVA>"))
        XCTAssertEqual(genericBookmark["id"] as? String, genericBookmarkID)
        XCTAssertEqual(genericBookmark["bookInitials"] as? String, document.initials)
        XCTAssertEqual(genericBookmark["key"] as? String, page.pageKey)
        XCTAssertEqual(marker["type"] as? String, "ai-doc-marker")
        XCTAssertEqual(marker["id"] as? String, markerPageID.uuidString)
        XCTAssertEqual(marker["ordinalRange"] as? [Int], [4, 4])
        XCTAssertEqual(marker["verseRangeAbbreviated"] as? String, "Gen 1:1")
        XCTAssertEqual(marker["sourcePromptId"] as? String, promptID.uuidString)
        XCTAssertEqual(marker["sourceBookInitials"] as? String, "KJV")
        XCTAssertEqual(marker["sourceBookKey"] as? String, "Gen.1.1")
        XCTAssertEqual(marker["labels"] as? [String], ["00000000-0000-ab1e-0000-a1d0c00001a1"])
        XCTAssertGreaterThanOrEqual(marker["hashCode"] as? Int ?? -1, 0)
    }

    /**
     Verifies My Documents use generated-book locale rather than page text-to-speech language.

     - Setup: Crosses Arabic page language with an English locale, then English page language with an
       Arabic locale so neither expected result can come from page metadata or developer-machine
       locale state.
     - Expected result: Both document and fragment `v11n` values are JSON null; the English generated
       book is LTR and the Arabic generated book is RTL regardless of each page's TTS language.
     - Failure meaning: My Documents can masquerade as KJVA content or page TTS metadata can flip the
       generated book's reader direction contrary to Android.
     - Side effects: None; payloads are assembled and parsed in memory.
     */
    func testMyDocumentPayloadUsesNullableVersificationAndLanguageDirection() throws {
        let coordinator = BibleReaderMyDocumentCoordinator()
        let document = MyDocument(name: "Journal", initials: "MyDoc_Journal")

        let cases = [
            (pageLanguage: "ar", locale: "en", expectedLanguage: "en", expectedDirection: "ltr"),
            (pageLanguage: "en", locale: "ar", expectedLanguage: "ar", expectedDirection: "rtl"),
        ]
        for testCase in cases {
            let page = MyDocumentPage(
                title: "Entry",
                pageKey: "entry-\(testCase.locale)",
                languageCode: testCase.pageLanguage
            )
            page.pageContent = MyDocumentPageContent(pageId: page.id, content: "Body")
            let json = try XCTUnwrap(
                coordinator.documentJSON(
                    document: document,
                    page: page,
                    bookLocale: Locale(identifier: testCase.locale)
                )
            )
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])

            XCTAssertTrue(payload["v11n"] is NSNull)
            XCTAssertTrue(fragment["v11n"] is NSNull)
            XCTAssertEqual(fragment["language"] as? String, testCase.expectedLanguage)
            XCTAssertEqual(fragment["direction"] as? String, testCase.expectedDirection)
        }
    }

    /**
     Verifies opening a page persists Android PageManager identity and a fresh controller restores it.

     The first controller saves `general_book` category, document initials, and page key through a
     real SwiftData PageManager. A new context and controller then restore and render the same My
     Documents payload without requiring an installed SWORD general-book module.
     */
    @MainActor
    func testPageManagerPersistsAndRestoresMyDocumentAfterRelaunch() throws {
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let myDocumentContext = ModelContext(myDocumentContainer)
        let document = MyDocument(name: "Journal", initials: "MyDoc_Journal")
        let page = MyDocumentPage(title: "Day one", pageKey: "day-one", languageCode: "en")
        let content = MyDocumentPageContent(pageId: page.id, content: "Relaunch body")
        page.document = document
        page.pageContent = content
        document.pages = [page]
        myDocumentContext.insert(document)
        myDocumentContext.insert(page)
        myDocumentContext.insert(content)
        try myDocumentContext.save()

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceContext = ModelContext(workspaceContainer)
        let window = Window(isSynchronized: false, isLinksWindow: false)
        let pageManager = PageManager(id: window.id)
        pageManager.window = window
        window.pageManager = pageManager
        workspaceContext.insert(window)
        workspaceContext.insert(pageManager)
        try workspaceContext.save()

        let firstController = BibleReaderController(bridge: BibleBridge())
        firstController.myDocumentStore = MyDocumentStore(modelContext: myDocumentContext)
        firstController.activeWindow = window
        firstController.onPersistState = { try? workspaceContext.save() }

        XCTAssertTrue(firstController.loadMyDocumentPage(
            bookInitials: "MyDoc_Journal",
            pageKey: "day-one"
        ))
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "MyDoc_Journal")
        XCTAssertEqual(pageManager.generalBookKey, "day-one")

        let relaunchWorkspaceContext = ModelContext(workspaceContainer)
        let restoredWindow = try XCTUnwrap(
            relaunchWorkspaceContext.fetch(FetchDescriptor<Window>()).first
        )
        let (relaunchBridge, scripts) = makeRecordingBridge()
        let relaunchController = BibleReaderController(bridge: relaunchBridge)
        relaunchController.myDocumentStore = MyDocumentStore(
            modelContext: ModelContext(myDocumentContainer)
        )
        relaunchController.activeWindow = restoredWindow

        relaunchController.restoreSavedPosition()
        relaunchController.loadCurrentContent()

        XCTAssertEqual(relaunchController.currentCategory, .generalBook)
        XCTAssertEqual(relaunchController.activeModuleName(for: .generalBook), "MyDoc_Journal")
        XCTAssertEqual(relaunchController.renderedContentState, "category=general_book;module=MyDoc_Journal;book=Journal;chapter=none;key=day-one")
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: scripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["bookInitials"] as? String, "MyDoc_Journal")
        XCTAssertEqual(payload["key"] as? String, "day-one")
    }

    /**
     Verifies AI marker navigation hands the exact target to pane-owned link routing.

     - Setup: Installs a routing callback on a controller with no My Documents destination loaded.
     - Expected result: The callback receives the exact document/key pair and current-pane reader
       state remains unchanged.
     - Failure meaning: Marker clicks can replace the initiating pane before the links-window policy
       chooses its destination.
     - Side effects: Invokes one in-memory bridge delegate callback only.
     */
    func testAIDocumentMarkerNavigationDelegatesToPaneRoutingPolicy() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let expected = AIDocumentPageRequest(
            documentInitials: "AIDocuments",
            pageKey: "answer"
        )
        var routedRequest: AIDocumentPageRequest?
        controller.onOpenAIDocumentPageInLinksWindow = { routedRequest = $0 }

        controller.bridge(bridge, openAIDocumentPage: expected)

        XCTAssertEqual(routedRequest, expected)
        XCTAssertNil(controller.activeGeneralBookModuleName)
        XCTAssertNil(controller.currentGeneralBookKey)
    }

    /**
     Verifies committed AI marker additions, updates, and deletion reach initiating and sibling panes.

     - Setup: Connects two controllers and one reader-facing store to an isolated typed event center,
       then inserts, edits, and deletes one generated page with AI cache metadata.
     - Expected result: Both bridges receive matching marker upserts for add/update and the same page
       identifier deletion, including the updated title.
     - Failure meaning: Vue marker state can remain stale in either the pane that initiated a change
       or another open pane.
     - Side effects: Persists an in-memory My Documents graph and records bridge JavaScript emissions.
     */
    @MainActor
    func testAIDocMarkerChangesPropagateToInitiatingAndSiblingPanes() throws {
        let eventCenter = MyDocumentAIDocMarkerEventCenter()
        let (initiatingBridge, initiatingScripts) = makeRecordingBridge()
        let (siblingBridge, siblingScripts) = makeRecordingBridge()
        let initiatingController = BibleReaderController(
            bridge: initiatingBridge,
            initializesSword: false,
            aiDocMarkerEventCenter: eventCenter
        )
        let siblingController = BibleReaderController(
            bridge: siblingBridge,
            initializesSword: false,
            aiDocMarkerEventCenter: eventCenter
        )
        _ = siblingController

        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(
            modelContext: context,
            aiDocMarkerEventCenter: eventCenter
        )
        initiatingController.myDocumentStore = store
        let promptID = try XCTUnwrap(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        )
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let page = MyDocumentPage(
            title: "Initial title",
            pageKey: "answer",
            sourcePromptId: promptID
        )
        let cache = AiPageCacheEntry(
            pageId: page.id,
            sourcePromptId: promptID,
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            sourceBookInitials: "KJV",
            sourceBookKey: "Gen.1.1"
        )
        page.document = document
        page.aiPageCacheEntries = [cache]
        document.pages = [page]
        cache.page = page

        XCTAssertTrue(store.insert(document))
        for scripts in [initiatingScripts(), siblingScripts()] {
            let markers = try XCTUnwrap(
                bridgeEmissionPayload(
                    from: scripts,
                    event: "add_or_update_ai_doc_markers"
                ) as? [[String: Any]]
            )
            XCTAssertEqual(markers.first?["title"] as? String, "Initial title")
        }

        let initiatingUpdateBaseline = initiatingScripts().count
        let siblingUpdateBaseline = siblingScripts().count
        initiatingController.bridge(
            initiatingBridge,
            saveMyDocumentPageContent: document.initials,
            pageId: page.id.uuidString,
            content: "Updated body",
            title: "Updated title"
        )
        for scripts in [
            Array(initiatingScripts().dropFirst(initiatingUpdateBaseline)),
            Array(siblingScripts().dropFirst(siblingUpdateBaseline)),
        ] {
            let markers = try XCTUnwrap(
                bridgeEmissionPayload(
                    from: scripts,
                    event: "add_or_update_ai_doc_markers"
                ) as? [[String: Any]]
            )
            XCTAssertEqual(markers.first?["title"] as? String, "Updated title")
        }

        let initiatingDeleteBaseline = initiatingScripts().count
        let siblingDeleteBaseline = siblingScripts().count
        initiatingController.bridge(
            initiatingBridge,
            deleteMyDocumentPage: page.id.uuidString
        )
        for scripts in [
            Array(initiatingScripts().dropFirst(initiatingDeleteBaseline)),
            Array(siblingScripts().dropFirst(siblingDeleteBaseline)),
        ] {
            let deletedIDs = try XCTUnwrap(
                bridgeEmissionPayload(
                    from: scripts,
                    event: "delete_ai_doc_markers"
                ) as? [String]
            )
            XCTAssertEqual(deletedIDs, [page.id.uuidString])
        }
    }

    /**
     Verifies AI marker navigation resolves the supplied generated-book identity without fallback.

     - Setup: Creates one generated page, opens it through the bridge request, then sends a missing
       key while current reader state could otherwise be reused.
     - Expected result: The exact page is rendered; the missing key leaves that page and the bridge
       emission count unchanged.
     - Failure meaning: Marker navigation depends on current reader state or snaps to another page.
     - Side effects: Writes in-memory My Documents rows and emits one reader document.
     - Failure modes: Throws for fixture persistence or a malformed emitted document payload.
     */
    @MainActor
    func testAIDocumentMarkerNavigationUsesExactDocumentAndKey() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let page = MyDocumentPage(title: "Exact answer", pageKey: "answer")
        let content = MyDocumentPageContent(pageId: page.id, content: "Exact generated content")
        page.document = document
        page.pageContent = content
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)

        controller.bridge(
            bridge,
            openAIDocumentPage: AIDocumentPageRequest(
                documentInitials: "AIDocuments",
                pageKey: "answer"
            )
        )

        let documentPayload = try XCTUnwrap(
            bridgeEmissionPayload(from: scripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(documentPayload["bookInitials"] as? String, "AIDocuments")
        XCTAssertEqual(documentPayload["key"] as? String, "answer")
        XCTAssertEqual(controller.activeGeneralBookModuleName, "AIDocuments")
        XCTAssertEqual(controller.currentGeneralBookKey, "answer")

        let emissionCount = scripts().count
        controller.bridge(
            bridge,
            openAIDocumentPage: AIDocumentPageRequest(
                documentInitials: "AIDocuments",
                pageKey: "missing"
            )
        )
        XCTAssertEqual(scripts().count, emissionCount)
        XCTAssertEqual(controller.activeGeneralBookModuleName, "AIDocuments")
        XCTAssertEqual(controller.currentGeneralBookKey, "answer")
    }

    /**
     Verifies native sharing keeps Android's subject and body as separate fields.
     */
    func testSharePayloadDoesNotConcatenateTitleAndBody() {
        let coordinator = BibleReaderMyDocumentCoordinator()
        let payload = coordinator.sharePayload(
            for: MyDocumentRawContentPayload(
                pageId: UUID().uuidString,
                contentType: MyDocumentContentType.markdown.rawValue,
                content: "Raw body",
                title: "Page title",
                sourcePromptId: nil
            )
        )

        XCTAssertEqual(payload.subject, "Page title")
        XCTAssertEqual(payload.body, "Raw body")
        XCTAssertFalse(payload.body.contains("Page title"))
    }

    #if os(iOS)
    /** Verifies UIKit receives raw body and subject through distinct activity-item callbacks. */
    @MainActor
    func testActivityItemSourceSeparatesShareSubjectAndBody() {
        let source = MyDocumentActivityItemSource(
            payload: MyDocumentSharePayload(subject: "Page title", body: "Raw body")
        )
        let activityController = UIActivityViewController(activityItems: [], applicationActivities: nil)

        XCTAssertEqual(
            source.activityViewControllerPlaceholderItem(activityController) as? String,
            "Raw body"
        )
        XCTAssertEqual(
            source.activityViewController(activityController, itemForActivityType: nil) as? String,
            "Raw body"
        )
        XCTAssertEqual(
            source.activityViewController(activityController, subjectForActivityType: nil),
            "Page title"
        )
    }
    #endif
}
