import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies the drawer My Notes/My Documents action opens Android's app-owned document manager.
     *
     * Android's drawer `myDocumentsButton` launches `MyDocumentsActivity`, then
     * `MyDocumentPagesActivity`; selecting a page returns to the reader and opens that generated
     * general-book document. iOS should therefore present a reader destination for the document
     * manager instead of directly loading the current-passage My Notes pseudo-document.
     *
     * - Side effects:
     *   - opens the reader drawer and activates My Documents
     *   - selects the seeded document and its first page
     * - Failure modes:
     *   - fails if the drawer action regresses to sheet/modal presentation, skips the document
     *     manager, or does not load the selected My Documents page in the reader
     */
    func testMyDocumentsScreenOpensFromReaderMenuAndOpensPage() {
        let app = makeApp()
        app.launch()

        openReaderActionDestination(
            actionIdentifier: "readerOpenMyNotesAction",
            destinationIdentifier: "myDocumentsListScreen",
            readinessIdentifiers: ["myDocumentsListStateExport"],
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=myDocuments", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer My Documents should use reader destination back chrome, not iOS sheet Done chrome."
        )
        waitForMyDocumentsListState(containing: "total=1", in: app, timeout: 10)
        waitForMyDocumentsListState(containing: myDocumentsRowStateToken("UITESTDOC"), in: app, timeout: 10)

        tapElementReliably(
            requireElement("myDocumentsDocumentRow::UITESTDOC", in: app, timeout: 10),
            timeout: 10
        )
        waitForMyDocumentPagesState(containing: "document=UITESTDOC", in: app, timeout: 10)
        waitForMyDocumentPagesState(containing: myDocumentsRowStateToken("intro"), in: app, timeout: 10)
        tapElementReliably(
            requireElement("myDocumentsPageRow::UITESTDOC::intro", in: app, timeout: 10),
            timeout: 10
        )

        waitForReaderRenderedContentState(containing: "readerDestination=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "category=general_book;module=UITESTDOC;book=UI Test Document;chapter=none;key=intro",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies StudyPads, History, and Bookmarks visible navigation routes from one seeded workflow.
     *
     * Android launches StudyPads, History, and Bookmarks as app-owned reader destinations, then
     * returns to the reader when the user backs out or selects a row. This workflow keeps those live
     * route/no-sheet contracts with selection behavior so the UI suite does not spend a separate
     * cold app launch on StudyPads route ownership while retaining terminal My Documents and
     * My Notes coverage in their dedicated smokes.
     *
     * - Side effects:
     *   - launches the reader shell with labeled `Genesis 1:1` and `Exodus 2:1` bookmarks, a
     *     matching StudyPad, and a persisted `Exodus 2:1` history row, while the reader itself
     *     starts on `Genesis 1`
     *   - opens StudyPads from the drawer, verifies the seeded row is available in the reader
     *     destination, and returns to the reader shell
     *   - opens History from the reader menu and selects the seeded row
     *   - opens the bookmark list from the actual reader overflow menu
     *   - opens Label Assignment for the seeded Genesis bookmark, verifies assignment state, and
     *     returns to the bookmark list
     *   - taps the seeded bookmark row and waits for the visible reader reference to reach
     *     `Genesis 1`
     *   - reopens Bookmarks, selects the seeded label, and opens the matching StudyPad document
     * - Failure modes:
     *   - fails if StudyPads regresses to sheet/modal presentation, shows sheet Done chrome, skips
     *     its Android-style manager screen, or cannot return to the reader destination chrome
     *   - fails if the history route regresses or selecting the seeded row does not navigate the
     *     reader to `Exodus 2`
     *   - fails if the bookmark list route regresses to sheet presentation
     *   - fails if the bookmark list, label-assignment screen, or seeded bookmark rows never appear
     *   - fails if Label Assignment cannot dismiss back to the bookmark list
     *   - fails if tapping the seeded bookmark row does not drive the reader back to `Genesis 1`
     *   - fails if the selected-label StudyPad handoff is no longer visible or no longer opens the
     *     matching StudyPad document
     *
     * Label creation, favourite toggles, Bible label removal, and generic bookmark assignment are
     * covered by `LabelAssignmentMutationTests` in the app-host-free package lane.
     */
    func testBookmarkSelectionNavigatesReaderToSeededReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        XCTAssertTrue(
            initialReference.localizedCaseInsensitiveContains("Genesis 1"),
            "Expected the seeded bookmark-filter scenario to start on Genesis 1, but saw '\(initialReference)'."
        )

        let studyPadsDestination = openReaderActionDestination(
            actionIdentifier: "readerOpenStudyPadsAction",
            destinationIdentifier: "labelManagerScreen",
            readinessIdentifiers: ["labelManagerAddButton", "labelManagerStateExport"],
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=studyPads", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer StudyPads should use reader destination back chrome, not iOS sheet Done chrome."
        )
        waitForLabelManagerState(containing: labelManagerRowStateToken("UI Test Seed"), in: app, timeout: 10)
        tapElementReliably(requireElement("readerDestinationBackButton", in: app, timeout: 10), timeout: 10)
        waitForElementToDisappear(studyPadsDestination, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected backing out of the StudyPads destination to return to the reader shell."
        )

        XCTAssertTrue(openHistory(in: app).exists)
        tapElementReliably(requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10), timeout: 10)
        let historyReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            historyReference.localizedCaseInsensitiveContains("Exodus 2"),
            "Expected selecting the seeded history row to navigate to Exodus 2, but saw '\(historyReference)'."
        )

        XCTAssertTrue(openBookmarkList(in: app).exists)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=bookmarks", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer Bookmarks should use reader destination back chrome, not iOS sheet Done chrome."
        )

        tapElementReliably(
            requireElement("bookmarkListEditLabelsButton::Genesis_1_1", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("labelAssignmentScreen", in: app, timeout: 10).exists)
        let seedRow = requireElement("labelAssignmentRow::UI_Test_Seed", in: app, timeout: 10)
        XCTAssertEqual(seedRow.value as? String, "assigned,notFavourite")
        dismissLabelAssignmentToBookmarkList(in: app, timeout: 20)

        let bookmarkRow = requireBookmarkRow("Genesis_1_1", in: app, timeout: 10)
        tapElementReliably(bookmarkRow, timeout: 10)
        let updatedReference = waitForReaderReferenceValueToChange(
            from: historyReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Genesis 1"),
            "Expected selecting the seeded bookmark to navigate to Genesis 1, but saw '\(updatedReference)'."
        )

        XCTAssertTrue(openBookmarkList(in: app).exists)
        openSeedStudyPadFromBookmarkList(in: app)
        waitForStudyPadPresentation(in: app, timeout: 20)
        let studyPadTitle = requireElement("readerStudyPadTitle", in: app, timeout: 10)
        XCTAssertEqual(studyPadTitle.label, "UI Test Seed")
    }

    /**
     Verifies the Android My Notes pseudo-document opens through Choose Document.
     *
     * Android exposes My Notes as a `FakeBookFactory` pseudo-document in the document chooser,
     * while the drawer action opens the My Documents manager. This visible smoke keeps that route
     * wired without replaying note edit/delete persistence that package tests already cover.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic Genesis note fixture
     *   - opens Choose Document, selects the My Notes pseudo-document, and waits for the embedded
     *     My Notes document state to render
     * - Failure modes:
     *   - fails if the chooser route, pseudo-document row, or initial My Notes document state is
     *     unavailable from the production reader path
     */
    func testMyNotesPseudoDocumentOpensFromChooser() {
        let app = makeApp()
        let rowToken = "Genesis_1_1"
        let originalNote = "UI_Test_My_Notes_Note"
        app.launch()

        openMyNotesFromReader(in: app)
        waitForVisibleMyNotesState(containing: "myNotesCount=1", in: app, timeout: 20)
        waitForVisibleMyNotesState(containing: "|\(rowToken)=\(originalNote)|", in: app, timeout: 20)
    }

    /**
     Finds a row in the Android-style quick selector, scrolling until SwiftUI materializes it.

     The quick selector intentionally uses a bounded `ScrollView` with a lazy row stack so local
     simulators with many installed modules do not grow the popup offscreen. XCTest cannot resolve
     lazy rows before they enter that viewport, so callers must search by scrolling instead of
     requiring the row before it exists.

     - Parameters:
       - identifier: Accessibility identifier for the desired quick-selector row.
       - quickSelector: Scroll view that owns the quick-selector rows.
       - app: Application under test, used to resolve row candidates after each scroll.
       - timeout: Maximum search time before failing the test.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Returns: Visible quick-selector row element.
     - Side effects: Scrolls the quick selector downward while searching.
     - Failure modes: Fails the XCTest when the row never appears or remains outside the visible
       quick-selector viewport.
     */
    func requireQuickSelectorRow(
        _ identifier: String,
        in quickSelector: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCandidate: XCUIElement?

        repeat {
            if let candidate = heuristicElementCandidates(for: identifier, in: app)
                .first(where: { $0.exists }) {
                lastCandidate = candidate
                if isElementVisible(candidate, within: quickSelector) {
                    return candidate
                }
            }

            quickSelector.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let lastCandidate {
            XCTAssertTrue(
                isElementVisible(lastCandidate, within: quickSelector),
                "Expected quick selector to scroll until '\(identifier)' is visible.",
                file: file,
                line: line
            )
            return lastCandidate
        }

        XCTFail(
            "Expected quick selector row '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return app.buttons[identifier].firstMatch
    }
}
