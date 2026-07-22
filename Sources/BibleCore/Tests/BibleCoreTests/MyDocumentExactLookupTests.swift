import SwiftData
import XCTest
@testable import BibleCore

/** Strict My Documents identity tests for exact bookmark navigation preflight. */
final class MyDocumentExactLookupTests: XCTestCase {
    /**
     Verifies unique initials and a unique parent-scoped page key resolve the exact persisted rows.

     The in-memory store contains one document and page. The lookup is read-only; a failure means the
     strict API cannot replace compatibility first-match lookup in bookmark navigation.
     */
    func testExactDocumentAndPageLookupsReturnUniqueIdentity() throws {
        let fixture = try makeStore()
        let document = MyDocument(name: "Journal", initials: "Journal")
        let page = MyDocumentPage(title: "Entry", pageKey: "entry")
        attach(page, to: document)
        fixture.context.insert(document)
        fixture.context.insert(page)
        try fixture.context.save()

        XCTAssertEqual(try fixture.store.exactDocument(initials: "Journal").id, document.id)
        XCTAssertEqual(
            try fixture.store.exactPage(bookInitials: "Journal", pageKey: "entry").id,
            page.id
        )
    }

    /**
     Verifies absent document and page identities produce distinct typed failures.

     A real document is inserted before the missing-page check so the test distinguishes parent
     absence from child absence. No models are changed by either failed lookup.
     */
    func testExactLookupsReportMissingDocumentAndMissingPage() throws {
        let fixture = try makeStore()
        let document = MyDocument(name: "Journal", initials: "Journal")
        fixture.context.insert(document)
        try fixture.context.save()

        XCTAssertThrowsError(try fixture.store.exactDocument(initials: "Missing")) { error in
            XCTAssertEqual(
                error as? MyDocumentExactLookupError,
                .documentNotFound(initials: "Missing")
            )
        }
        XCTAssertThrowsError(
            try fixture.store.exactPage(bookInitials: "Journal", pageKey: "missing")
        ) { error in
            XCTAssertEqual(
                error as? MyDocumentExactLookupError,
                .pageNotFound(bookInitials: "Journal", pageKey: "missing")
            )
        }
    }

    /**
     Verifies duplicate document initials fail before page lookup can choose one graph.

     Two directly inserted rows bypass the management layer's normal uniqueness guard. The legacy
     optional API remains callable for compatibility, while both strict operations expose ambiguity.
     */
    func testExactLookupsRejectDuplicateDocumentIdentity() throws {
        let fixture = try makeStore()
        let first = MyDocument(name: "First", initials: "Duplicate")
        let second = MyDocument(name: "Second", initials: "Duplicate")
        fixture.context.insert(first)
        fixture.context.insert(second)
        try fixture.context.save()

        XCTAssertNotNil(fixture.store.document(initials: "Duplicate"))
        XCTAssertThrowsError(try fixture.store.exactDocument(initials: "Duplicate")) { error in
            XCTAssertEqual(
                error as? MyDocumentExactLookupError,
                .duplicateDocuments(initials: "Duplicate")
            )
        }
        XCTAssertThrowsError(
            try fixture.store.exactPage(bookInitials: "Duplicate", pageKey: "entry")
        ) { error in
            XCTAssertEqual(
                error as? MyDocumentExactLookupError,
                .duplicateDocuments(initials: "Duplicate")
            )
        }
    }

    /**
     Verifies duplicate page keys inside one unique document fail instead of selecting display order.

     The compatibility API still returns a row, preserving existing reader behavior, while the exact
     API reports that the parent-scoped key cannot authorize bookmark navigation.
     */
    func testExactPageLookupRejectsDuplicateParentScopedKey() throws {
        let fixture = try makeStore()
        let document = MyDocument(name: "Journal", initials: "Journal")
        let first = MyDocumentPage(title: "First", pageKey: "entry", orderNumber: 0)
        let second = MyDocumentPage(title: "Second", pageKey: "entry", orderNumber: 1)
        attach(first, to: document)
        attach(second, to: document)
        fixture.context.insert(document)
        fixture.context.insert(first)
        fixture.context.insert(second)
        try fixture.context.save()

        XCTAssertNotNil(fixture.store.page(bookInitials: "Journal", pageKey: "entry"))
        XCTAssertThrowsError(
            try fixture.store.exactPage(bookInitials: "Journal", pageKey: "entry")
        ) { error in
            XCTAssertEqual(
                error as? MyDocumentExactLookupError,
                .duplicatePages(bookInitials: "Journal", pageKey: "entry")
            )
        }
    }

    /** Associates one page with its parent on both sides of the SwiftData relationship. */
    private func attach(_ page: MyDocumentPage, to document: MyDocument) {
        page.document = document
        document.pages = (document.pages ?? []) + [page]
    }

    /**
     Creates one isolated in-memory My Documents graph and its strict lookup store.

     - Returns: A retained container, context, and store tuple for one test.
     - Side effects: Allocates an in-memory SwiftData store only.
     - Failure modes: Rethrows schema/container initialization errors.
     */
    private func makeStore() throws -> (
        container: ModelContainer,
        context: ModelContext,
        store: MyDocumentStore
    ) {
        let schema = Schema([
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        return (container, context, MyDocumentStore(modelContext: context))
    }
}
