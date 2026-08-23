// MyDocumentManagementTests.swift -- Android-parity My Documents management contracts

import Foundation
import SwiftData
import XCTest
@testable import BibleCore

final class MyDocumentManagementTests: XCTestCase {
    /**
     Verifies Cancel restores the complete pre-edit graph rather than leaking eager mutations.

     The setup combines rename, description, page creation/content editing, document creation,
     document reorder, and page reorder in one session. Discard must restore byte-equivalent draft
     values and a clean state. This protects the explicit Save/Cancel boundary from regressions that
     write one workflow directly to SwiftData.
     */
    func testCancelDiscardsAllPendingManagementMutations() throws {
        let firstPage = MyDocumentPageDraft(
            title: "First",
            pageKey: "first",
            orderNumber: 0,
            content: "Original"
        )
        let secondPage = MyDocumentPageDraft(
            title: "Second",
            pageKey: "second",
            orderNumber: 1,
            content: "Second body"
        )
        let original = MyDocumentDraft(
            name: "Study",
            documentDescription: "Original description",
            initials: "MyDoc_Study",
            pages: [firstPage, secondPage]
        )
        var session = MyDocumentManagementSession(documents: [original])

        try session.renameDocument(id: original.id, name: "Renamed")
        try session.setDocumentDescription(id: original.id, description: "Changed")
        try session.movePages(documentID: original.id, fromOffsets: [0], toOffset: 2)
        let pageID = try session.createPage(
            documentID: original.id,
            title: "Draft",
            contentType: .html
        )
        try session.updatePage(
            documentID: original.id,
            pageID: pageID,
            title: "Draft",
            contentType: .html,
            content: "<p>Unsaved</p>"
        )
        _ = try session.createDocument(name: "Another")

        XCTAssertTrue(session.isDirty)
        session.discardChanges()

        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.documents, [original])
    }

    /**
     Verifies Save advances the Cancel baseline and preserves Android's protected AI ordering.
     */
    func testAcceptedSaveBecomesNewCancelBaselineAndKeepsAIDocumentsFirst() throws {
        let aiPage = MyDocumentPageDraft(title: "AI", pageKey: "ai")
        let aiDocument = MyDocumentDraft(
            name: "AI Documents",
            initials: MyDocumentManagementSession.aiDocumentsInitials,
            orderNumber: 8,
            pages: [aiPage]
        )
        let notes = MyDocumentDraft(name: "Notes", initials: "MyDoc_Notes", orderNumber: 0)
        var session = MyDocumentManagementSession(documents: [notes, aiDocument])

        XCTAssertEqual(session.documents.map(\.initials), ["AIDocuments", "MyDoc_Notes"])
        XCTAssertThrowsError(try session.deleteDocument(id: aiDocument.id)) { error in
            XCTAssertEqual(error as? MyDocumentManagementError, .cannotDeleteNonemptyAIDocument)
        }

        try session.renameDocument(id: notes.id, name: "Saved Notes")
        session.acceptSavedChanges()
        try session.renameDocument(id: notes.id, name: "Unsaved Notes")
        session.moveDocuments(fromOffsets: [1], toOffset: 0)
        session.discardChanges()

        XCTAssertEqual(session.documents.map(\.initials), ["AIDocuments", "MyDoc_Notes"])
        XCTAssertEqual(session.document(id: notes.id)?.name, "Saved Notes")
        XCTAssertFalse(session.isDirty)
    }

    /**
     Verifies Android's initials generation and collision behavior exactly.
     */
    func testInitialsGenerationMatchesAndroidContract() {
        XCTAssertEqual(
            MyDocumentManagementSession.generateInitials(
                for: "Bible Study 2026!",
                unavailable: []
            ),
            "MyDoc_BibleStudy"
        )
        XCTAssertEqual(
            MyDocumentManagementSession.generateInitials(
                for: "Bible Study 2026!",
                unavailable: ["MyDoc_BibleStudy", "MyDoc_BibleStudy_1"]
            ),
            "MyDoc_BibleStudy_2"
        )
        XCTAssertEqual(
            MyDocumentManagementSession.generateInitials(for: "---", unavailable: []),
            "MyDoc_MyDoc"
        )
    }

    /**
     Applies the live global-registry predicate to explicit and generated creation identities.

     - Setup: An explicit token is owned, and the first two generated candidates are reported owned.
     - Expected: Explicit creation fails without mutation; generated creation selects the first
       globally unowned suffix.
     - Failure meaning: UI/AI creation can persist a My Documents row that Android's global
       `Books.getBook(candidate.initials)` would reject.
     - Side effects: Mutates only the in-memory draft session after the successful generated case.
     */
    func testCreationUsesLiveGlobalRegistryAvailabilityForEveryCandidate() throws {
        var session = MyDocumentManagementSession(documents: [])

        XCTAssertThrowsError(try session.createDocument(
            name: "Explicit",
            isInitialsUnavailable: { $0 == "Native Full Name" },
            initials: "Native Full Name"
        )) { error in
            XCTAssertEqual(
                error as? MyDocumentManagementError,
                .duplicateInitials("Native Full Name")
            )
        }
        XCTAssertTrue(session.documents.isEmpty)

        let documentID = try session.createDocument(
            name: "Bible Study",
            isInitialsUnavailable: {
                ["MyDoc_BibleStudy", "MyDoc_BibleStudy_1"].contains($0)
            }
        )

        XCTAssertEqual(session.document(id: documentID)?.initials, "MyDoc_BibleStudy_2")
    }

    /**
     Replays pending My Documents through Android's full `Books.getBook` admission tiers.

     - Setup: Creates a `Foo` draft before `foo`, then creates a prior document whose full name is
       the unsuffixed initials generated for `Bible Study`.
     - Expected: Case-insensitive initials ownership and exact full-name ownership each force the
       next Android suffix instead of leaving an unregistrable pending draft.
     - Failure meaning: iOS deferred creation diverges from Android's immediate registration and
       can publish a document that the global Books registry suppresses.
     - Side effects: Mutates only an in-memory management session.
     */
    func testCreationReplaysPendingInitialsAndFullNameRegistryOwnership() throws {
        var caseSession = MyDocumentManagementSession(documents: [])
        let uppercaseID = try caseSession.createDocument(name: "Foo")
        let lowercaseID = try caseSession.createDocument(name: "foo")

        XCTAssertEqual(caseSession.document(id: uppercaseID)?.initials, "MyDoc_Foo")
        XCTAssertEqual(caseSession.document(id: lowercaseID)?.initials, "MyDoc_foo_1")

        var fullNameSession = MyDocumentManagementSession(documents: [])
        _ = try fullNameSession.createDocument(
            name: "MyDoc_BibleStudy",
            initials: "PriorOwner"
        )
        let generatedID = try fullNameSession.createDocument(name: "Bible Study")

        XCTAssertEqual(
            fullNameSession.document(id: generatedID)?.initials,
            "MyDoc_BibleStudy_1"
        )
    }

    /**
     Revalidates pending My Documents registry ownership immediately before transactional Save.

     - Setup: Persists one document, creates a second document with explicit initials, then renames
       the earlier draft so its full name owns the second document's initials.
     - Expected: Save rejects the later registration and leaves both the rename and insertion out
       of persistent storage.
     - Failure meaning: A draft sequence can pass creation-time checks but publish an Android-hidden
       book after a pending rename changes global identity ownership.
     - Side effects: Writes the baseline document to an in-memory SwiftData container; the rejected
       save performs no persistent mutation.
     */
    @MainActor
    func testSaveReplaysPendingFullNameOwnershipWithoutPartialPersistence() throws {
        let container = try makeContainer()
        let store = MyDocumentLibraryStore(modelContext: ModelContext(container))
        var session = try store.loadSession()
        let priorID = try session.createDocument(name: "Original", initials: "PriorOwner")
        try store.save(&session)

        _ = try session.createDocument(name: "Candidate", initials: "FutureOwner")
        try session.renameDocument(id: priorID, name: "FutureOwner")

        XCTAssertThrowsError(try store.save(&session)) { error in
            XCTAssertEqual(
                error as? MyDocumentManagementError,
                .duplicateInitials("FutureOwner")
            )
        }

        let persisted = try store.loadSession().documents
        XCTAssertEqual(persisted.map(\.initials), ["PriorOwner"])
        XCTAssertEqual(persisted.map(\.name), ["Original"])
    }

    /**
     Grandfathers an unchanged MyDocument registration omitted by authoritative restore replay.

     - Setup: Persists a restore-shaped graph where the first row's full name case-folds to the
       second row's initials, then edits only the suppressed row's description in a new session.
     - Expected result: Save retains both rows and publishes the unrelated description because the
       same exact baseline owner still causes the same Android registration omission.
     - Failure meaning: An authoritative restore can make a hidden-but-valid row permanently
       uneditable, even when the user does not introduce or change an identity collision.
     - Side effects: Writes and edits two rows in an in-memory SwiftData container.
     */
    @MainActor
    func testSaveAllowsUnrelatedEditToRestoreRetainedSuppressedDocument() throws {
        let container = try makeContainer()
        let restoreContext = ModelContext(container)
        let owner = MyDocument(
            name: "Retained Identity",
            initials: "RestoreOwner",
            orderNumber: 0
        )
        let suppressed = MyDocument(
            name: "Suppressed row",
            initials: "retained identity",
            orderNumber: 1
        )
        restoreContext.insert(owner)
        restoreContext.insert(suppressed)
        try restoreContext.save()

        let store = MyDocumentLibraryStore(modelContext: ModelContext(container))
        var session = try store.loadSession()
        try session.setDocumentDescription(
            id: suppressed.id,
            description: "Edited after restore"
        )

        try store.save(&session)

        let persisted = try store.loadSession().documents
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(
            persisted.first(where: { $0.id == suppressed.id })?.documentDescription,
            "Edited after restore"
        )
    }

    /**
     Preserves Java-exact identity for canonically equivalent My Documents initials.

     - Setup: Creates and saves two documents whose initials are composed/decomposed UTF-16
       spellings of the same visible text, and separately supplies the composed spelling through
       the legacy reservation set while creating the decomposed spelling.
     - Expected result: Android-distinct spellings coexist and persist, while a byte-for-byte UTF-16
       duplicate remains rejected.
     - Failure meaning: Swift `String`/`Set` canonical equivalence is still imposing a stricter
       creation rule than JSword `Books.getBook` and hiding a registration Android accepts.
     - Side effects: Writes only to an in-memory SwiftData container.
     */
    @MainActor
    func testCreationAndSaveKeepCanonicalEquivalentJavaIdentitiesDistinct() throws {
        let composed = "Local-Caf\u{00E9}"
        let decomposed = "Local-Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))

        var reservedSession = MyDocumentManagementSession(documents: [])
        let reservedID = try reservedSession.createDocument(
            name: "Reserved distinction",
            reservedInitials: [composed],
            initials: decomposed
        )
        XCTAssertEqual(
            Array(try XCTUnwrap(reservedSession.document(id: reservedID)).initials.utf16),
            Array(decomposed.utf16)
        )

        let container = try makeContainer()
        let store = MyDocumentLibraryStore(modelContext: ModelContext(container))
        var session = try store.loadSession()
        _ = try session.createDocument(name: "Composed", initials: composed)
        _ = try session.createDocument(name: "Decomposed", initials: decomposed)
        XCTAssertThrowsError(
            try session.createDocument(name: "Duplicate", initials: composed)
        ) { error in
            XCTAssertEqual(
                error as? MyDocumentManagementError,
                .duplicateInitials(composed)
            )
        }

        try store.save(&session)

        let persisted = try store.loadSession().documents.map(\.initials)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertTrue(persisted.contains { Array($0.utf16) == Array(composed.utf16) })
        XCTAssertTrue(persisted.contains { Array($0.utf16) == Array(decomposed.utf16) })
    }

    /**
     Saves an unrelated edit when one restored document has Java-distinct canonical page keys.

     - Setup: Persists two pages whose composed/decomposed keys are Swift-equal but have different
       UTF-16 sequences, then changes only the parent document description in a loaded session.
     - Expected result: Save accepts the Android-BINARY-distinct keys and preserves both spellings.
     - Failure meaning: Management validation imposed Swift canonical equivalence on a legal
       imported graph and made every later unrelated edit unsavable.
     - Side effects: Writes and reloads one in-memory SwiftData document graph.
     */
    @MainActor
    func testSavePreservesRestoredJavaDistinctCanonicalPageKeys() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let composed = "Page-Caf\u{00E9}"
        let decomposed = "Page-Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))

        let document = MyDocument(name: "Imported", initials: "ImportedPages")
        let composedPage = MyDocumentPage(id: UUID(), title: "Composed", pageKey: composed)
        let decomposedPage = MyDocumentPage(id: UUID(), title: "Decomposed", pageKey: decomposed)
        composedPage.document = document
        decomposedPage.document = document
        document.pages = [composedPage, decomposedPage]
        context.insert(document)
        context.insert(composedPage)
        context.insert(decomposedPage)
        try context.save()

        let store = MyDocumentLibraryStore(modelContext: ModelContext(container))
        var session = try store.loadSession()
        try session.setDocumentDescription(id: document.id, description: "Unrelated edit")
        try store.save(&session)

        let persisted = try store.loadSession().documents
        let restored = try XCTUnwrap(persisted.first { $0.id == document.id })
        XCTAssertEqual(restored.documentDescription, "Unrelated edit")
        XCTAssertEqual(Set(restored.pages.map { Array($0.pageKey.utf16) }), Set([
            Array(composed.utf16),
            Array(decomposed.utf16),
        ]))
    }

    /**
     Verifies import sorting, title rules, type inference, raw fidelity, and export filenames.
     */
    func testImportAndExportRoundTripMatchesAndroidFilenameContract() throws {
        let files = [
            MyDocumentImportFile(fileName: "02-Second.HTML", content: "<p>Two & more</p>"),
            MyDocumentImportFile(fileName: "01-First.md", content: "# One\n"),
            MyDocumentImportFile(fileName: "03-Other.txt", content: "Raw third"),
        ]
        var session = MyDocumentManagementSession(documents: [])
        let documentID = try session.importDocument(name: "Imported", files: files)
        let document = try XCTUnwrap(session.document(id: documentID))

        XCTAssertEqual(document.pages.map(\.title), ["First", "Second", "Other"])
        XCTAssertEqual(document.pages.map(\.contentType), [.markdown, .html, .markdown])
        XCTAssertEqual(document.pages.map(\.content), ["# One\n", "<p>Two & more</p>", "Raw third"])

        let exported = MyDocumentTransferService.exportDocument(document)
        XCTAssertEqual(exported.map(\.fileName), ["01-First.md", "02-Second.html", "03-Other.md"])
        XCTAssertEqual(exported.map(\.content), document.pages.map(\.content))
        XCTAssertEqual(exported.map(\.contentType), ["text/markdown", "text/html", "text/markdown"])

        let pageImport = try MyDocumentTransferService.importPages(
            from: [MyDocumentImportFile(fileName: "01-Kept Prefix.htm", content: "body")],
            stripsDocumentOrderPrefix: false
        )
        XCTAssertEqual(pageImport.first?.title, "01-Kept Prefix")
        XCTAssertEqual(pageImport.first?.contentType, .html)
        XCTAssertEqual(MyDocumentTransferService.sanitizedExportTitle("\u{03A8}\u{8A18}"), "page")

        let lexicalOrder = try MyDocumentTransferService.importPages(
            from: [
                MyDocumentImportFile(fileName: "2-Second.md", content: "second"),
                MyDocumentImportFile(fileName: "10-Tenth.md", content: "tenth"),
            ],
            stripsDocumentOrderPrefix: true
        )
        XCTAssertEqual(lexicalOrder.map(\.title), ["Tenth", "Second"])
    }

    /**
     Verifies one transactional Save survives a fresh context with exact order and raw content.

     This models app relaunch: the first context creates/imports/reorders, the library store saves,
     and a second context reconstructs a clean session from the persistent graph.
     */
    @MainActor
    func testTransactionalSaveRestoresDocumentAndPageOrderAfterRelaunch() throws {
        let container = try makeContainer()
        let writeContext = ModelContext(container)
        let writeStore = MyDocumentLibraryStore(modelContext: writeContext)
        var session = try writeStore.loadSession()
        let firstID = try session.createDocument(name: "First")
        let secondID = try session.createDocument(name: "Second")
        _ = try session.importPage(
            documentID: firstID,
            file: MyDocumentImportFile(fileName: "B.md", content: "Body B")
        )
        _ = try session.importPage(
            documentID: firstID,
            file: MyDocumentImportFile(fileName: "A.html", content: "<b>Body A</b>")
        )
        try session.movePages(documentID: firstID, fromOffsets: [1], toOffset: 0)
        session.moveDocuments(fromOffsets: [1], toOffset: 0)

        try writeStore.save(&session)
        XCTAssertFalse(session.isDirty)

        let readContext = ModelContext(container)
        let restored = try MyDocumentLibraryStore(modelContext: readContext).loadSession()

        XCTAssertEqual(restored.documents.map(\.id), [secondID, firstID])
        XCTAssertEqual(restored.documents.map(\.orderNumber), [0, 1])
        let restoredFirst = try XCTUnwrap(restored.document(id: firstID))
        XCTAssertEqual(restoredFirst.pages.map(\.title), ["A", "B"])
        XCTAssertEqual(restoredFirst.pages.map(\.orderNumber), [0, 1])
        XCTAssertEqual(restoredFirst.pages.map(\.content), ["<b>Body A</b>", "Body B"])
    }

    /**
     Verifies an unsaved session cannot leak changes into SwiftData or a relaunch context.
     */
    @MainActor
    func testUnsavedSessionLeavesPersistedLibraryUnchanged() throws {
        let container = try makeContainer()
        let initialContext = ModelContext(container)
        let initialStore = MyDocumentLibraryStore(modelContext: initialContext)
        var initialSession = try initialStore.loadSession()
        let documentID = try initialSession.createDocument(name: "Persisted")
        try initialStore.save(&initialSession)

        var draft = try initialStore.loadSession()
        try draft.renameDocument(id: documentID, name: "Unsaved")
        _ = try draft.createDocument(name: "Also Unsaved")

        let relaunchContext = ModelContext(container)
        let restored = try MyDocumentLibraryStore(modelContext: relaunchContext).loadSession()
        XCTAssertEqual(restored.documents.map(\.name), ["Persisted"])
    }

    /**
     Verifies My Documents persistence cannot commit unrelated pending scene-context changes.

     The manager receives a scene context because that is the natural SwiftUI integration point,
     but its transaction must run in an isolated context. Otherwise its single `save()` would also
     publish every unsaved model in the scene and its rollback path could discard those edits.
     */
    @MainActor
    func testLibrarySaveDoesNotCommitUnrelatedCallerContextChanges() throws {
        let container = try makeContainer()
        let sceneContext = ModelContext(container)
        sceneContext.insert(MyDocument(name: "Unrelated pending", initials: "MyDoc_Pending"))

        let store = MyDocumentLibraryStore(modelContext: sceneContext)
        var session = try store.loadSession()
        _ = try session.createDocument(name: "Managed")
        try store.save(&session)

        sceneContext.rollback()
        let verificationContext = ModelContext(container)
        let persistedDocuments = try verificationContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(persistedDocuments.map(\.name), ["Managed"])
    }

    /** Verifies a rebuilt reader store observes an isolated management save immediately. */
    @MainActor
    func testFreshReaderStoreObservesIsolatedManagementSave() throws {
        let container = try makeContainer()
        let mainContext = container.mainContext
        let document = MyDocument(name: "Study", initials: "MyDoc_Study")
        let page = MyDocumentPage(title: "Page", pageKey: "page")
        let content = MyDocumentPageContent(pageId: page.id, content: "Original")
        page.document = document
        page.pageContent = content
        document.pages = [page]
        content.page = page
        mainContext.insert(document)
        mainContext.insert(page)
        mainContext.insert(content)
        try mainContext.save()

        let store = MyDocumentLibraryStore(modelContext: mainContext)
        var session = try store.loadSession()
        try session.updatePage(
            documentID: document.id,
            pageID: page.id,
            title: "Page",
            contentType: .markdown,
            content: "Updated"
        )
        try store.save(&session)

        let refreshedReaderStore = MyDocumentStore(modelContext: ModelContext(container))
        let payload = try XCTUnwrap(
            refreshedReaderStore.rawContentPayload(
                bookInitials: document.initials,
                pageKey: page.pageKey
            )
        )
        XCTAssertEqual(payload.content, "Updated")
    }

    /**
     Verifies ordinary management saves preserve AI provenance rows owned by retained pages.
     */
    @MainActor
    func testManagementSavePreservesRetainedAIPageMetadata() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let promptID = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"))
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let page = MyDocumentPage(
            title: "Response",
            pageKey: "response",
            sourcePromptId: promptID
        )
        let content = MyDocumentPageContent(pageId: page.id, content: "Original")
        let cache = AiPageCacheEntry(
            pageId: page.id,
            sourcePromptId: promptID,
            sourceContext: "context",
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            contextHash: "hash",
            usedWriteTools: true,
            sourceModelName: "model",
            sourceBookInitials: "KJV",
            sourceBookKey: "Gen.1.1"
        )
        page.document = document
        page.pageContent = content
        page.aiPageCacheEntries = [cache]
        document.pages = [page]
        content.page = page
        cache.page = page
        context.insert(document)
        context.insert(page)
        context.insert(content)
        context.insert(cache)
        try context.save()

        let store = MyDocumentLibraryStore(modelContext: context)
        var session = try store.loadSession()
        try session.renameDocument(id: document.id, name: "Renamed AI")
        try session.updatePage(
            documentID: document.id,
            pageID: page.id,
            title: "Updated response",
            contentType: .markdown,
            content: "Updated"
        )
        try store.save(&session)

        let verificationContext = ModelContext(container)
        let cacheRows = try verificationContext.fetch(FetchDescriptor<AiPageCacheEntry>())
        let persistedPage = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<MyDocumentPage>())
                .first(where: { $0.id == page.id })
        )
        XCTAssertEqual(cacheRows.count, 1)
        XCTAssertEqual(cacheRows.first?.sourcePromptId, promptID)
        XCTAssertEqual(cacheRows.first?.sourceModelName, "model")
        XCTAssertEqual(persistedPage.pageContent?.content, "Updated")
        XCTAssertEqual(persistedPage.sourcePromptId, promptID)
    }

    /**
     Verifies a stale management session cannot delete or overwrite rows added concurrently.

     AI generation and remote sync can write while the manager is open. Saving a document rename
     must apply that baseline delta while retaining a newly added AI page, its cache metadata, and a
     concurrently inserted document. The refreshed session must expose all preserved rows.
     */
    @MainActor
    func testManagementSavePreservesRowsAddedAfterSessionLoad() throws {
        let container = try makeContainer()
        let setupContext = ModelContext(container)
        let document = MyDocument(name: "Study", initials: "MyDoc_Study")
        let originalPage = MyDocumentPage(title: "Original", pageKey: "original")
        originalPage.document = document
        document.pages = [originalPage]
        setupContext.insert(document)
        setupContext.insert(originalPage)
        try setupContext.save()

        let managementContext = ModelContext(container)
        let store = MyDocumentLibraryStore(modelContext: managementContext)
        var session = try store.loadSession()

        let concurrentContext = ModelContext(container)
        let concurrentDocument = try XCTUnwrap(
            concurrentContext.fetch(FetchDescriptor<MyDocument>()).first(where: { $0.id == document.id })
        )
        let promptID = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"))
        let generatedPage = MyDocumentPage(
            title: "Generated",
            pageKey: "generated",
            orderNumber: 1,
            sourcePromptId: promptID
        )
        let generatedContent = MyDocumentPageContent(pageId: generatedPage.id, content: "AI body")
        let generatedCache = AiPageCacheEntry(
            pageId: generatedPage.id,
            sourcePromptId: promptID,
            sourceModelName: "model"
        )
        generatedPage.document = concurrentDocument
        generatedPage.pageContent = generatedContent
        generatedPage.aiPageCacheEntries = [generatedCache]
        generatedContent.page = generatedPage
        generatedCache.page = generatedPage
        concurrentDocument.pages = (concurrentDocument.pages ?? []) + [generatedPage]
        let syncedDocument = MyDocument(name: "Synced", initials: "MyDoc_Synced", orderNumber: 2)
        concurrentContext.insert(generatedPage)
        concurrentContext.insert(generatedContent)
        concurrentContext.insert(generatedCache)
        concurrentContext.insert(syncedDocument)
        try concurrentContext.save()

        try session.renameDocument(id: document.id, name: "Renamed Study")
        try store.save(&session)

        let verificationContext = ModelContext(container)
        let savedDocuments = try verificationContext.fetch(FetchDescriptor<MyDocument>())
        let savedPages = try verificationContext.fetch(FetchDescriptor<MyDocumentPage>())
        let savedCaches = try verificationContext.fetch(FetchDescriptor<AiPageCacheEntry>())
        XCTAssertEqual(Set(savedDocuments.map(\.initials)), ["MyDoc_Study", "MyDoc_Synced"])
        XCTAssertEqual(savedDocuments.first(where: { $0.id == document.id })?.name, "Renamed Study")
        XCTAssertEqual(Set(savedPages.map(\.pageKey)), ["original", "generated"])
        XCTAssertEqual(savedCaches.first?.sourceModelName, "model")
        XCTAssertEqual(Set(session.documents.map(\.initials)), ["MyDoc_Study", "MyDoc_Synced"])
        XCTAssertFalse(session.isDirty)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
    }
}
