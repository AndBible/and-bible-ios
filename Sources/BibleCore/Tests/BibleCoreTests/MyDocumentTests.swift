// MyDocumentTests.swift -- Tests for My Documents persistence and raw content lookup

import XCTest
import SwiftData
@testable import BibleCore

final class MyDocumentStoreTests: XCTestCase {
    func testRawContentPayloadResolvesByDocumentInitialsAndPageKey() throws {
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

        let payload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(payload.pageId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(payload.contentType, "MARKDOWN")
        XCTAssertEqual(payload.content, "Raw *markdown*")
        XCTAssertEqual(payload.title, "Intro")
        XCTAssertEqual(payload.sourcePromptId, "22222222-2222-2222-2222-222222222222")
    }

    func testRawContentPayloadReturnsNilForMissingPage() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        store.insert(MyDocument(name: "My Document", initials: "MYDOC"))

        XCTAssertNil(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "missing"))
        XCTAssertNil(store.rawContentPayload(bookInitials: "UNKNOWN", pageKey: "intro"))
    }

    func testRawContentPayloadScopesDuplicatePageKeysByDocumentInitials() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)

        let firstDocument = MyDocument(name: "First Document", initials: "FIRST")
        let firstPageId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let firstPage = MyDocumentPage(
            id: firstPageId,
            title: "Shared Page",
            pageKey: "shared",
            contentType: .markdown
        )
        let firstContent = MyDocumentPageContent(pageId: firstPageId, content: "First content")
        firstPage.pageContent = firstContent
        firstPage.document = firstDocument
        firstDocument.pages = [firstPage]

        let secondDocument = MyDocument(name: "Second Document", initials: "SECOND")
        let secondPageId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let secondPage = MyDocumentPage(
            id: secondPageId,
            title: "Shared Page",
            pageKey: "shared",
            contentType: .html
        )
        let secondContent = MyDocumentPageContent(pageId: secondPageId, content: "Second content")
        secondPage.pageContent = secondContent
        secondPage.document = secondDocument
        secondDocument.pages = [secondPage]

        context.insert(firstDocument)
        context.insert(firstPage)
        context.insert(firstContent)
        context.insert(secondDocument)
        context.insert(secondPage)
        context.insert(secondContent)
        try context.save()

        let firstPayload = try XCTUnwrap(store.rawContentPayload(bookInitials: "FIRST", pageKey: "shared"))
        XCTAssertEqual(firstPayload.pageId, "33333333-3333-3333-3333-333333333333")
        XCTAssertEqual(firstPayload.contentType, "MARKDOWN")
        XCTAssertEqual(firstPayload.content, "First content")

        let secondPayload = try XCTUnwrap(store.rawContentPayload(bookInitials: "SECOND", pageKey: "shared"))
        XCTAssertEqual(secondPayload.pageId, "44444444-4444-4444-4444-444444444444")
        XCTAssertEqual(secondPayload.contentType, "HTML")
        XCTAssertEqual(secondPayload.content, "Second content")
    }

    private func makeMyDocumentModelContainer() throws -> ModelContainer {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
