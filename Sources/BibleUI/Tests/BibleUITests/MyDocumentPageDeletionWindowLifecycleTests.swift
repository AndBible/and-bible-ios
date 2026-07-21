// MyDocumentPageDeletionWindowLifecycleTests.swift -- Android window behavior after AI page deletion

import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

/**
 Verifies Android-compatible reader-window ownership after deleting an active AI My Documents page.

 The suite uses in-memory production SwiftData stores. It proves the workspace window count controls
 close-versus-fallback behavior and then drives the real bridge deletion path so a closed pane never
 renders replacement content while the sole pane always returns to its Bible category.
 */
@MainActor
final class MyDocumentPageDeletionWindowLifecycleTests: XCTestCase {
    /**
     Proves persisted workspace membership, not visible layout, controls whether a pane is removable.

     A two-window workspace closes the requested secondary window through `WindowManager`; the
     remaining primary window then resolves to Bible fallback and cannot be removed. A failure means
     iOS has drifted from Android's `windowRepository.sortedWindows.size > 1` contract.
     */
    func testDeletionClosesRemovableWindowAndPreservesSolePrimaryWindow() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let workspace = store.createWorkspace(name: "Deletion lifecycle")
        let primaryWindow = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let secondaryWindow = store.addWindow(
            to: workspace,
            document: "KJV",
            category: DocumentCategory.bible.pageManagerKey
        )
        let windowManager = WindowManager(workspaceStore: store)
        windowManager.setActiveWorkspace(workspace)

        XCTAssertEqual(
            MyDocumentPageDeletionWindowLifecycle.resolve(
                window: secondaryWindow,
                windowManager: windowManager
            ),
            .paneClosed
        )
        XCTAssertEqual(windowManager.windowsInPersistedOrder.map(\.id), [primaryWindow.id])

        XCTAssertEqual(
            MyDocumentPageDeletionWindowLifecycle.resolve(
                window: primaryWindow,
                windowManager: windowManager
            ),
            .showBible
        )
        XCTAssertEqual(windowManager.windowsInPersistedOrder.map(\.id), [primaryWindow.id])
    }

    /**
     Drives successful AI page deletion through both owner resolutions used by real reader panes.

     The removable-pane fixture returns `.paneClosed`; deletion must persist but must not rewrite or
     reload its now-detached reader. The sole-pane fixture returns `.showBible`; deletion must persist,
     switch its `PageManager` to Bible, and invoke persistence exactly once. A failure reintroduces
     the iOS behavior that silently reused every deleted My Documents pane as a Bible pane.
     */
    func testBridgeDeletionRendersBibleOnlyWhenWindowOwnerCannotClosePane() throws {
        let removableFixture = try makeActiveAIPageFixture(pageKey: "removable")
        var closeResolutionCount = 0
        var removablePersistCount = 0
        removableFixture.controller.onDeleteActiveMyDocumentPage = {
            closeResolutionCount += 1
            return .paneClosed
        }
        removableFixture.controller.onPersistState = { removablePersistCount += 1 }

        removableFixture.controller.bridge(
            removableFixture.bridge,
            deleteMyDocumentPage: removableFixture.pageID.uuidString
        )

        XCTAssertNil(removableFixture.store.rawContentPayload(
            bookInitials: removableFixture.bookInitials,
            pageKey: removableFixture.pageKey
        ))
        XCTAssertEqual(closeResolutionCount, 1)
        XCTAssertEqual(removablePersistCount, 0)
        XCTAssertEqual(removableFixture.controller.currentCategory, .generalBook)
        XCTAssertEqual(
            removableFixture.window.pageManager?.currentCategoryName,
            DocumentCategory.generalBook.pageManagerKey
        )

        let primaryFixture = try makeActiveAIPageFixture(pageKey: "primary")
        var fallbackResolutionCount = 0
        var primaryPersistCount = 0
        primaryFixture.controller.onDeleteActiveMyDocumentPage = {
            fallbackResolutionCount += 1
            return .showBible
        }
        primaryFixture.controller.onPersistState = { primaryPersistCount += 1 }

        primaryFixture.controller.bridge(
            primaryFixture.bridge,
            deleteMyDocumentPage: primaryFixture.pageID.uuidString
        )

        XCTAssertNil(primaryFixture.store.rawContentPayload(
            bookInitials: primaryFixture.bookInitials,
            pageKey: primaryFixture.pageKey
        ))
        XCTAssertEqual(fallbackResolutionCount, 1)
        XCTAssertEqual(primaryPersistCount, 1)
        XCTAssertEqual(primaryFixture.controller.currentCategory, .bible)
        XCTAssertEqual(
            primaryFixture.window.pageManager?.currentCategoryName,
            DocumentCategory.bible.pageManagerKey
        )
    }

    /**
     Creates one rendered source-prompt-backed My Documents page for bridge deletion tests.

     - Parameter pageKey: Stable key used for the generated page and lookup assertions.
     - Returns: A fixture retaining its in-memory store, reader controller, bridge, and pane state.
     - Side effects: Inserts and saves a My Documents graph, then renders the page into the reader.
     - Failure modes: Throws if SwiftData setup/save fails or reports an XCTest unwrap failure.
     */
    private func makeActiveAIPageFixture(pageKey: String) throws -> ActiveAIPageFixture {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageID = UUID()
        let promptID = UUID()
        let bookInitials = "AIDocuments-\(pageKey)"
        let document = MyDocument(name: "AI Documents", initials: bookInitials)
        let page = MyDocumentPage(
            id: pageID,
            title: "Generated page",
            pageKey: pageKey,
            contentType: .markdown,
            sourcePromptId: promptID,
            languageCode: "en"
        )
        let content = MyDocumentPageContent(pageId: pageID, content: "Generated content")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let window = BibleCore.Window()
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.generalBook.pageManagerKey
        )
        window.pageManager = pageManager
        pageManager.window = window
        controller.activeWindow = window
        controller.myDocumentStore = store
        XCTAssertTrue(controller.loadMyDocumentPage(bookInitials: bookInitials, pageKey: pageKey))

        return ActiveAIPageFixture(
            container: container,
            store: store,
            controller: controller,
            bridge: bridge,
            window: window,
            pageID: pageID,
            bookInitials: bookInitials,
            pageKey: pageKey
        )
    }
}

/** Retains all state needed to drive one active AI My Documents page through bridge deletion. */
private struct ActiveAIPageFixture {
    /// Owns the in-memory SwiftData backing store for the fixture lifetime.
    let container: ModelContainer
    /// Store that resolves and deletes the generated page.
    let store: MyDocumentStore
    /// Reader whose active page and fallback behavior are under test.
    let controller: BibleReaderController
    /// Bridge used to invoke the production deletion delegate method.
    let bridge: BibleBridge
    /// Pane model whose category records the lifecycle result.
    let window: BibleCore.Window
    /// Stable generated page identity supplied by the web action.
    let pageID: UUID
    /// Generated general-book initials owning the page.
    let bookInitials: String
    /// Page key used to verify durable deletion.
    let pageKey: String
}
