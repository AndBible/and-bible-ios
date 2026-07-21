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

    func testRawContentPayloadResolvesDuplicatePageKeysDeterministicallyByDisplayOrder() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let createdAt = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 5,
            day: 22
        ).date)
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let firstPageId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let secondPageId = try XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let firstPage = MyDocumentPage(
            id: firstPageId,
            title: "A",
            pageKey: "duplicate",
            orderNumber: 1,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let secondPage = MyDocumentPage(
            id: secondPageId,
            title: "B",
            pageKey: "duplicate",
            orderNumber: 2,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let firstContent = MyDocumentPageContent(pageId: firstPageId, content: "First by order")
        let secondContent = MyDocumentPageContent(pageId: secondPageId, content: "Second by order")

        firstPage.pageContent = firstContent
        firstPage.document = document
        secondPage.pageContent = secondContent
        secondPage.document = document
        document.pages = [secondPage, firstPage]
        context.insert(document)
        context.insert(firstPage)
        context.insert(firstContent)
        context.insert(secondPage)
        context.insert(secondContent)
        try context.save()

        let payload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "duplicate"))
        XCTAssertEqual(payload.pageId, "55555555-5555-5555-5555-555555555555")
        XCTAssertEqual(payload.content, "First by order")
    }

    func testSavePageContentUpdatesRawContentAndOptionalTitle() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageId = try XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let createdAt = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 5,
            day: 22
        ).date)
        let document = MyDocument(name: "My Document", initials: "MYDOC", updatedAt: createdAt)
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Original")

        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        XCTAssertTrue(store.savePageContent(
            bookInitials: "MYDOC",
            pageId: pageId,
            content: "Edited **markdown**",
            title: "Renamed"
        ))

        let payload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(payload.content, "Edited **markdown**")
        XCTAssertEqual(payload.title, "Renamed")
        XCTAssertGreaterThan(page.updatedAt, createdAt)
        XCTAssertGreaterThan(document.updatedAt, createdAt)

        XCTAssertTrue(store.savePageContent(
            bookInitials: "MYDOC",
            pageId: pageId,
            content: "Edited again",
            title: nil
        ))

        let preservedTitlePayload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(preservedTitlePayload.content, "Edited again")
        XCTAssertEqual(preservedTitlePayload.title, "Renamed")
    }

    func testSavePageContentCreatesMissingContentAndScopesByDocumentInitials() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageId = try XCTUnwrap(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .html
        )

        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        try context.save()

        XCTAssertFalse(store.savePageContent(
            bookInitials: "OTHER",
            pageId: pageId,
            content: "Wrong document",
            title: "Wrong"
        ))

        XCTAssertTrue(store.savePageContent(
            bookInitials: "MYDOC",
            pageId: pageId,
            content: "<p>Edited</p>",
            title: nil
        ))

        let payload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(payload.contentType, "HTML")
        XCTAssertEqual(payload.content, "<p>Edited</p>")
        XCTAssertEqual(payload.title, "Intro")
        XCTAssertNotNil(page.pageContent)
    }

    /**
     Protects Android's transactional page-save contract when SwiftData persistence fails.

     The fixture leaves an unrelated document update pending while attempting rejected edits against
     both an existing content row and a page that would require a new row, then saves the context.
     Reopening the on-disk store must reveal only the unrelated update; losing that update indicates
     an over-broad rollback, while any edited title, timestamp, body, or inserted content row means a
     failed editor response can leak into a later save.

     The injected save closure fails synchronously and deterministically before the unrelated direct
     context save. The temporary store directory is removed after the reopened-state assertions.
     */
    func testFailedPageContentSaveRestoresPageGraphBeforeUnrelatedSave() throws {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDocumentSaveAtomicity-\(UUID().uuidString)", isDirectory: true)
        let storeURL = storeDirectory.appendingPathComponent("MyDocuments.store")
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let originalDate = try XCTUnwrap(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 7,
            day: 20,
            hour: 12
        ).date)
        let existingContentPageID = try XCTUnwrap(
            UUID(uuidString: "12121212-1212-1212-1212-121212121212")
        )
        let missingContentPageID = try XCTUnwrap(
            UUID(uuidString: "34343434-3434-3434-3434-343434343434")
        )

        do {
            let container = try makePersistentMyDocumentModelContainer(at: storeURL)
            let context = ModelContext(container)
            let document = MyDocument(
                name: "Target Document",
                initials: "TARGET",
                updatedAt: originalDate
            )
            let existingContentPage = MyDocumentPage(
                id: existingContentPageID,
                title: "Existing Title",
                pageKey: "existing",
                createdAt: originalDate,
                updatedAt: originalDate
            )
            let existingContent = MyDocumentPageContent(
                pageId: existingContentPageID,
                content: "Original body"
            )
            let missingContentPage = MyDocumentPage(
                id: missingContentPageID,
                title: "Empty Title",
                pageKey: "empty",
                createdAt: originalDate,
                updatedAt: originalDate
            )
            let unrelatedDocument = MyDocument(
                name: "Unrelated Before",
                initials: "OTHER",
                updatedAt: originalDate
            )

            existingContentPage.document = document
            existingContentPage.pageContent = existingContent
            existingContent.page = existingContentPage
            missingContentPage.document = document
            document.pages = [existingContentPage, missingContentPage]
            context.insert(document)
            context.insert(existingContentPage)
            context.insert(existingContent)
            context.insert(missingContentPage)
            context.insert(unrelatedDocument)
            try context.save()
            unrelatedDocument.name = "Unrelated Pending"

            let store = MyDocumentStore(
                modelContext: context,
                savePageContentChanges: { throw ForcedMyDocumentSaveError() }
            )

            XCTAssertFalse(store.savePageContent(
                bookInitials: "TARGET",
                pageId: existingContentPageID,
                content: "Rejected existing body",
                title: "Rejected Existing Title"
            ))
            XCTAssertFalse(store.savePageContent(
                bookInitials: "TARGET",
                pageId: missingContentPageID,
                content: "Rejected inserted body",
                title: "Rejected Empty Title"
            ))

            XCTAssertEqual(existingContentPage.title, "Existing Title")
            XCTAssertEqual(existingContentPage.updatedAt, originalDate)
            XCTAssertEqual(existingContent.content, "Original body")
            XCTAssertEqual(missingContentPage.title, "Empty Title")
            XCTAssertEqual(missingContentPage.updatedAt, originalDate)
            XCTAssertNil(missingContentPage.pageContent)
            XCTAssertEqual(document.updatedAt, originalDate)
            XCTAssertEqual(unrelatedDocument.name, "Unrelated Pending")

            try context.save()
        }

        let reopenedContainer = try makePersistentMyDocumentModelContainer(at: storeURL)
        let reopenedContext = ModelContext(reopenedContainer)
        let reopenedStore = MyDocumentStore(modelContext: reopenedContext)
        let reopenedDocument = try XCTUnwrap(reopenedStore.document(initials: "TARGET"))
        let reopenedExistingPage = try XCTUnwrap(reopenedStore.page(
            bookInitials: "TARGET",
            pageId: existingContentPageID
        ))
        let reopenedMissingContentPage = try XCTUnwrap(reopenedStore.page(
            bookInitials: "TARGET",
            pageId: missingContentPageID
        ))

        XCTAssertEqual(reopenedDocument.updatedAt, originalDate)
        XCTAssertEqual(reopenedExistingPage.title, "Existing Title")
        XCTAssertEqual(reopenedExistingPage.updatedAt, originalDate)
        XCTAssertEqual(reopenedExistingPage.pageContent?.content, "Original body")
        XCTAssertEqual(reopenedMissingContentPage.title, "Empty Title")
        XCTAssertEqual(reopenedMissingContentPage.updatedAt, originalDate)
        XCTAssertNil(reopenedMissingContentPage.pageContent)
        XCTAssertEqual(reopenedStore.document(initials: "OTHER")?.name, "Unrelated Pending")

        let rejectedContentDescriptor = FetchDescriptor<MyDocumentPageContent>(
            predicate: #Predicate { $0.pageId == missingContentPageID }
        )
        XCTAssertTrue(try reopenedContext.fetch(rejectedContentDescriptor).isEmpty)
    }

    func testAIPageActionContextRequiresSourcePromptMetadata() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let aiPageId = try XCTUnwrap(UUID(uuidString: "99999999-9999-9999-9999-999999999999"))
        let userPageId = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        let promptId = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let aiPage = MyDocumentPage(
            id: aiPageId,
            title: "AI Page",
            pageKey: "ai",
            sourcePromptId: promptId
        )
        let userPage = MyDocumentPage(
            id: userPageId,
            title: "User Page",
            pageKey: "user"
        )
        let cacheEntry = AiPageCacheEntry(
            pageId: aiPageId,
            sourcePromptId: promptId,
            sourceContext: #"{"osisRef":"Gen.1"}"#,
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 31,
            contextHash: "hash",
            usedWriteTools: true,
            sourceModelName: "model",
            sourceBookInitials: "KJV",
            sourceBookKey: "Gen.1"
        )

        aiPage.document = document
        userPage.document = document
        cacheEntry.page = aiPage
        aiPage.aiPageCacheEntries = [cacheEntry]
        document.pages = [aiPage, userPage]
        context.insert(document)
        context.insert(aiPage)
        context.insert(userPage)
        context.insert(cacheEntry)
        try context.save()

        let contextPayload = try XCTUnwrap(store.aiPageActionContext(pageId: aiPageId))
        XCTAssertEqual(contextPayload.pageId, aiPageId)
        XCTAssertEqual(contextPayload.bookInitials, "MYDOC")
        XCTAssertEqual(contextPayload.pageKey, "ai")
        XCTAssertEqual(contextPayload.pageTitle, "AI Page")
        XCTAssertEqual(contextPayload.sourcePromptId, promptId)
        XCTAssertEqual(contextPayload.sourceContext, #"{"osisRef":"Gen.1"}"#)
        XCTAssertEqual(contextPayload.kjvOrdinalStart, 1)
        XCTAssertEqual(contextPayload.kjvOrdinalEnd, 31)
        XCTAssertEqual(contextPayload.contextHash, "hash")
        XCTAssertTrue(contextPayload.usedWriteTools)
        XCTAssertEqual(contextPayload.sourceModelName, "model")
        XCTAssertEqual(contextPayload.sourceBookInitials, "KJV")
        XCTAssertEqual(contextPayload.sourceBookKey, "Gen.1")
        XCTAssertNil(store.aiPageActionContext(pageId: userPageId))
    }

    func testDeleteAIPageRemovesContentCacheAndRefusesUserPages() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let aiPageId = try XCTUnwrap(UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc"))
        let userPageId = try XCTUnwrap(UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd"))
        let missingPageId = try XCTUnwrap(UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"))
        let promptId = try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let aiPage = MyDocumentPage(
            id: aiPageId,
            title: "AI Page",
            pageKey: "ai",
            sourcePromptId: promptId
        )
        let aiContent = MyDocumentPageContent(pageId: aiPageId, content: "AI content")
        let cacheEntry = AiPageCacheEntry(pageId: aiPageId, sourcePromptId: promptId)
        let userPage = MyDocumentPage(
            id: userPageId,
            title: "User Page",
            pageKey: "user"
        )
        let userContent = MyDocumentPageContent(pageId: userPageId, content: "User content")

        aiPage.pageContent = aiContent
        aiPage.document = document
        cacheEntry.page = aiPage
        aiPage.aiPageCacheEntries = [cacheEntry]
        userPage.pageContent = userContent
        userPage.document = document
        document.pages = [aiPage, userPage]
        context.insert(document)
        context.insert(aiPage)
        context.insert(aiContent)
        context.insert(cacheEntry)
        context.insert(userPage)
        context.insert(userContent)
        try context.save()

        XCTAssertEqual(store.deleteAIPage(pageId: userPageId), .notAIPage)
        XCTAssertEqual(store.deleteAIPage(pageId: missingPageId), .pageNotFound)
        XCTAssertNotNil(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "user"))

        switch store.deleteAIPage(pageId: aiPageId) {
        case .deleted(let actionContext):
            XCTAssertEqual(actionContext.pageId, aiPageId)
            XCTAssertEqual(actionContext.sourcePromptId, promptId)
            XCTAssertEqual(actionContext.bookInitials, "MYDOC")
            XCTAssertEqual(actionContext.pageKey, "ai")
        default:
            XCTFail("Expected AI page deletion to succeed")
        }

        XCTAssertNil(store.page(pageId: aiPageId))
        XCTAssertNil(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "ai"))
        XCTAssertNotNil(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "user"))

        let deletedContentDescriptor = FetchDescriptor<MyDocumentPageContent>(
            predicate: #Predicate { $0.pageId == aiPageId }
        )
        let deletedCacheDescriptor = FetchDescriptor<AiPageCacheEntry>(
            predicate: #Predicate { $0.pageId == aiPageId }
        )
        XCTAssertTrue(try context.fetch(deletedContentDescriptor).isEmpty)
        XCTAssertTrue(try context.fetch(deletedCacheDescriptor).isEmpty)
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

    /**
     Opens a disk-backed My Documents test store at a stable URL so tests can verify durable state
     through a fresh `ModelContainer`.

     - Parameter url: Store URL inside a caller-owned temporary directory.
     - Returns: A local-only SwiftData container containing the complete My Documents schema.
     - Side effects: Creates or opens the SQLite-backed SwiftData store at `url`.
     - Failure modes: Rethrows schema or persistent-store initialization errors.
     */
    private func makePersistentMyDocumentModelContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
        ])
        let configuration = ModelConfiguration(
            "MyDocumentSaveAtomicity",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

/** Deterministic persistence failure injected into My Documents page-save tests. */
private struct ForcedMyDocumentSaveError: Error {}
