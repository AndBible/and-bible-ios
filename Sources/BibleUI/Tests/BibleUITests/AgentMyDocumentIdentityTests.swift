// AgentMyDocumentIdentityTests.swift -- Java-exact Agent My Documents identity contracts

import SwiftData
import XCTest

@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/** Verifies production Agent My Documents routing preserves Android/Java identity semantics. */
@MainActor
final class AgentMyDocumentIdentityTests: BibleUISwordFixtureTestCase {
    /**
     Resolves canonically equivalent but Java-distinct initials to their exact persisted rows.

     - Setup: Persists composed and decomposed UTF-16 initials with distinct pages, then calls the
       production Agent adapter by initials with raw content enabled.
     - Expected: Each spelling returns only its exact document/page identity and authored content.
     - Failure meaning: Swift canonical equality aliases two Android-distinct book registrations,
       exposing or editing the wrong My Documents collection.
     - Side effects: Creates isolated in-memory My Documents/bookmark/workspace graphs and one
       temporary empty search database removed by teardown.
     */
    func testComposedAndDecomposedInitialsResolveExactAgentDocuments() throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let composed = "Caf\u{00E9}Agent"
        let decomposed = "Cafe\u{0301}Agent"
        XCTAssertFalse(SwordJavaStringIdentity.equals(composed, decomposed))
        let composedDocument = insertDocument(
            name: "Composed",
            initials: composed,
            pageTitle: "Composed page",
            content: "composed content",
            context: context
        )
        let decomposedDocument = insertDocument(
            name: "Decomposed",
            initials: decomposed,
            pageTitle: "Decomposed page",
            content: "decomposed content",
            context: context
        )
        try context.save()
        let adapter = try makeAdapter(myDocumentContext: context)

        let composedResult = try adapter.getMyDocumentPages(
            documentID: nil,
            initials: composed,
            includeContent: true
        )
        let decomposedResult = try adapter.getMyDocumentPages(
            documentID: nil,
            initials: decomposed,
            includeContent: true
        )

        XCTAssertEqual(try documentID(from: composedResult), composedDocument.id)
        XCTAssertEqual(try firstPageContent(from: composedResult), "composed content")
        XCTAssertEqual(try documentID(from: decomposedResult), decomposedDocument.id)
        XCTAssertEqual(try firstPageContent(from: decomposedResult), "decomposed content")
    }

    /**
     Keeps stable document IDs authoritative while rejecting conflicting AI-document identity pairs.

     - Setup: Persists Android's AI Documents row and one ordinary row, then supplies the AI row ID
       together with the ordinary initials to both collection lookup and AI ownership checks.
     - Expected: General page lookup follows the explicitly preferred stable ID, while
       `isAIDocument` rejects the conflicting pair and accepts only two identities resolving to the
       same AI row.
     - Failure meaning: Optional initials can redirect an ID-scoped operation, or permission logic
       can treat contradictory identities as proof that a page belongs to AI Documents.
     - Side effects: Creates isolated in-memory stores and one temporary search database.
     */
    func testConflictingDocumentIDAndInitialsPreserveLookupAuthorityAndFailAIOwnership() async throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let aiDocument = insertDocument(
            name: "AI Documents",
            initials: MyDocumentManagementSession.aiDocumentsInitials,
            pageTitle: "AI page",
            content: "AI content",
            context: context
        )
        let ordinaryDocument = insertDocument(
            name: "Ordinary",
            initials: "OrdinaryAgentDocument",
            pageTitle: "Ordinary page",
            content: "ordinary content",
            context: context
        )
        try context.save()
        let adapter = try makeAdapter(myDocumentContext: context)

        let result = try adapter.getMyDocumentPages(
            documentID: aiDocument.id,
            initials: ordinaryDocument.initials,
            includeContent: true
        )

        XCTAssertEqual(try documentID(from: result), aiDocument.id)
        XCTAssertEqual(try firstPageContent(from: result), "AI content")
        let conflictingAIIdentity = await adapter.isAIDocument(
            documentID: aiDocument.id,
            initials: ordinaryDocument.initials
        )
        let matchingAIIdentity = await adapter.isAIDocument(
            documentID: aiDocument.id,
            initials: aiDocument.initials
        )
        let ordinaryIDWithAIInitials = await adapter.isAIDocument(
            documentID: ordinaryDocument.id,
            initials: aiDocument.initials
        )
        XCTAssertFalse(conflictingAIIdentity)
        XCTAssertTrue(matchingAIIdentity)
        XCTAssertFalse(ordinaryIDWithAIInitials)
    }

    /** Inserts one exact document/page/content graph without generation-time normalization. */
    @discardableResult
    private func insertDocument(
        name: String,
        initials: String,
        pageTitle: String,
        content: String,
        context: ModelContext
    ) -> MyDocument {
        let document = MyDocument(name: name, initials: initials)
        let page = MyDocumentPage(title: pageTitle, pageKey: "page", contentType: .markdown)
        let pageContent = MyDocumentPageContent(pageId: page.id, content: content)
        page.pageContent = pageContent
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(pageContent)
        return document
    }

    /** Builds the real adapter around the supplied My Documents persistence container. */
    private func makeAdapter(myDocumentContext: ModelContext) throws -> BibleUIAgentDomainAdapter {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let bookmarkContext = ModelContext(try makeBookmarkListModelContainer())
        let workspaceContext = ModelContext(try makeWorkspaceModelContainer())
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-mydoc-identity-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        return BibleUIAgentDomainAdapter(
            swordManager: manager,
            sqliteLibrary: SQLiteDocumentModuleLibrary(discoveredModules: []),
            searchIndexService: SearchIndexService(databasePath: databaseURL.path),
            bookmarkService: BookmarkService(
                store: BookmarkStore(modelContext: bookmarkContext)
            ),
            labelConfigurationService: WorkspaceLabelConfigurationService(
                modelContext: bookmarkContext
            ),
            myDocumentLibraryStore: MyDocumentLibraryStore(modelContext: myDocumentContext),
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContext),
            windowManager: WindowManager(
                workspaceStore: WorkspaceStore(modelContext: workspaceContext)
            ),
            documentAccessPolicy: AgentMyDocumentAllowAllPolicy(),
            windowDocumentRouter: AgentMyDocumentUnusedWindowRouter()
        )
    }

    /** Reads the stable document ID from one successful Agent JSON result. */
    private func documentID(from result: AgentToolResult) throws -> UUID {
        try XCTUnwrap(
            result.data?.objectValue?["documentId"]?.stringValue.flatMap(UUID.init(uuidString:))
        )
    }

    /** Reads the first bounded page body from one successful Agent JSON result. */
    private func firstPageContent(from result: AgentToolResult) throws -> String {
        try XCTUnwrap(
            result.data?.objectValue?["pages"]?.arrayValue?.first?
                .objectValue?["content"]?.stringValue
        )
    }
}

/** Focused identity-test policy that allows every installed source token. */
@MainActor
private struct AgentMyDocumentAllowAllPolicy: BibleUIAgentDocumentAccessPolicy {
    /** Allows one source without reading settings. */
    func allows(documentInitials: String) -> Bool { true }
}

/** Sentinel router proving My Documents identity tests never mutate a live reader pane. */
private struct AgentMyDocumentUnusedWindowRouter: BibleUIAgentWindowDocumentRouting {
    /** Fails if an unrelated window mutation escapes the focused adapter operation. */
    @MainActor
    func setDocument(
        windowID: UUID,
        documentInitials: String,
        key: String?
    ) async throws -> BibleUIAgentWindowDocumentState {
        throw AgentMyDocumentUnexpectedWindowMutation.unexpected
    }
}

/** Unexpected live-reader side effect from a My Documents-only Agent operation. */
private enum AgentMyDocumentUnexpectedWindowMutation: Error {
    /// The focused operation unexpectedly attempted window navigation.
    case unexpected
}
