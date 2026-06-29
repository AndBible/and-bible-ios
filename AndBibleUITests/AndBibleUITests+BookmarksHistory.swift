import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies StudyPads opens from the drawer and selecting a row opens the StudyPad document.
     *
     * Android launches `ManageLabels` in `Mode.STUDYPAD` from the drawer, so iOS should expose the
     * StudyPads selector as a reader-owned destination instead of the legacy modal sheet route.
     * Android then opens the selected StudyPad through `studyPadSelected`, so the regression also
     * proves a seeded row exits the destination and renders the corresponding StudyPad document.
     *
     * - Side effects:
     *   - opens the reader drawer and activates StudyPads
     *   - selects the seeded StudyPad row
     * - Failure modes:
     *   - fails if StudyPads does not appear, if the route regresses to a sheet/modal, or if sheet
     *     Done chrome is visible on the drawer-owned screen
     *   - fails if selecting the row does not open the matching StudyPad document
     */
    func testStudyPadsScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        openReaderActionDestination(
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
        tapElementReliably(labelRow(named: "UI Test Seed", in: app), timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=none", in: app, timeout: 10)
        waitForStudyPadPresentation(in: app, timeout: 20)
        XCTAssertEqual(requireElement("readerStudyPadTitle", in: app, timeout: 10).label, "UI Test Seed")
    }

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
     Verifies Bookmarks opens from the drawer as an app-owned reader destination, label assignment
     is reachable from a seeded row, and selecting another row navigates the reader.
     *
     * Android launches Bookmarks from the drawer as an app-owned destination, then returns to the
     * reader when the user selects a row. This workflow keeps the route/no-sheet parity assertions
     * with the live selection behavior so the UI suite does not spend a separate cold app launch on
     * route ownership alone.
     *
     * - Side effects:
     *   - launches the reader shell with labeled `Genesis 1:1` and `Exodus 2:1` bookmarks while
     *     the reader itself stays on `Genesis 1`
     *   - opens the bookmark list from the actual reader overflow menu
     *   - opens Label Assignment for the seeded Genesis bookmark, verifies assignment state, and
     *     returns to the bookmark list
     *   - taps the seeded bookmark row and waits for the visible reader reference to reach
     *     `Exodus 2`
     * - Failure modes:
     *   - fails if the bookmark list route regresses to sheet presentation
     *   - fails if the bookmark list, label-assignment screen, or seeded bookmark rows never appear
     *   - fails if Label Assignment cannot dismiss back to the bookmark list
     *   - fails if tapping the seeded bookmark row does not drive the reader to `Exodus 2`
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
            "Expected the seeded bookmark-navigation scenario to start on Genesis 1, but saw '\(initialReference)'."
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

        let bookmarkRow = requireBookmarkRow("Exodus_2_1", in: app, timeout: 10)
        tapElementReliably(bookmarkRow, timeout: 10)
        let updatedReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Exodus 2"),
            "Expected selecting the seeded bookmark to navigate to Exodus 2, but saw '\(updatedReference)'."
        )
    }

    /**
     Verifies that bookmark navigation from a third window updates only that pane's rendered content.
     *
     * - Side effects:
     *   - launches the seeded bookmark-navigation-three-windows fixture with three visible reader
     *     windows
     *   - activates the third window, opens the bookmark list from that pane, and selects the
     *     seeded `Exodus 2:1` row
     *   - switches back to the first window to confirm its rendered content stayed on `Genesis 1`
     * - Failure modes:
     *   - fails if the seeded third window cannot be activated
     *   - fails if the third window does not render `Exodus 2`
     *   - fails if the first window's rendered content also changes away from `Genesis 1`
     */
    func testThirdWindowBookmarkNavigationUpdatesOnlyTargetPaneContent() {
        let app = makeApp()
        app.launch()

        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )

        _ = openBookmarkList(in: app)
        tapElementReliably(requireBookmarkRow("Exodus_2_1", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible;module=KJV;book=Exodus;chapter=2",
            in: app,
            timeout: 20
        )

        tapWindowTab(0, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies that a third-window document-type switch updates that pane's content instead of only
     mutating tab chrome.
     *
     * - Side effects:
     *   - launches the commentary-module-three-windows fixture with three visible reader windows
     *     and activates the third one
     *   - switches that third pane into commentary and then back into Bible using the real toolbar
     *     document controls and, when needed, the Android-parity quick selector or full module
     *     picker
     *   - switches back to the first tab to confirm its rendered content never left `Genesis 1`
     * - Failure modes:
     *   - fails if the third window cannot be activated
     *   - fails if the third pane never reports `category=commentary` and then `category=bible`
     *   - fails if the first pane's rendered content drifts while the third pane is changing modes
     */
    func testThirdWindowDocumentSwitchUpdatesOnlyTargetPaneContent() {
        let app = makeApp()
        app.launch()

        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerCommentaryToolbarButton", in: app, timeout: 10), timeout: 10)
        if waitForAnyElement(["readerCommentaryQuickSelector"], in: app, timeout: 3) != nil {
            let quickSelector = requireElement("readerCommentaryQuickSelector", in: app, timeout: 10)
            let commentaryQuickRow = requireQuickSelectorRow(
                "readerCommentaryQuickSelectorRow_000UITestComm",
                in: quickSelector,
                app: app,
                timeout: 10
            )
            XCTAssertEqual(
                commentaryQuickRow.value as? String,
                "available",
                "000UITestComm quick-selector row must be selectable when switching from Bible."
            )
            tapElementReliably(commentaryQuickRow, timeout: 10)
        } else if waitForAnyElement(["modulePickerScreen"], in: app, timeout: 3) != nil {
            tapFirstModulePickerRow(in: app, timeout: 10)
        }
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=commentary",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 10), timeout: 10)
        if waitForAnyElement(["readerBibleQuickSelector"], in: app, timeout: 3) != nil {
            let quickSelector = requireElement("readerBibleQuickSelector", in: app, timeout: 10)
            let kjvQuickRow = requireQuickSelectorRow(
                "readerBibleQuickSelectorRow_KJV",
                in: quickSelector,
                app: app,
                timeout: 10
            )
            XCTAssertEqual(
                kjvQuickRow.value as? String,
                "available",
                "KJV quick-selector row must remain selectable when returning from commentary."
            )
            tapElementReliably(kjvQuickRow, timeout: 10)
        } else if waitForAnyElement(["modulePickerScreen"], in: app, timeout: 3) != nil {
            if let kjvRow = resolvedElement("modulePickerRow::KJV", in: app) {
                tapElementReliably(kjvRow, timeout: 10)
            } else {
                tapFirstModulePickerRow(in: app, timeout: 10)
            }
        }
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible",
            in: app,
            timeout: 20
        )

        tapWindowTab(0, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies that the reader Strong's quick toggle is scoped to the active window only.
     *
     * - Side effects:
     *   - launches the baseline fixture with three visible reader windows and activates the third
     *     one
     *   - toggles Strong's on in the third window, confirms the first window stays off, then
     *     toggles Strong's on in the first window and confirms the third window preserves its own
     *     state
     *   - toggles Strong's back off in the third window and confirms the first window stays on
     * - Failure modes:
     *   - fails if the Strong's quick-toggle button is unavailable in the active pane
     *   - fails if toggling one window changes the active Strong's mode seen in a sibling pane
     *   - fails if re-focusing a window does not restore that window's own persisted Strong's mode
     */
    func testThirdWindowStrongsToggleAffectsOnlyActiveWindow() {
        let app = makeApp()
        app.launch()

        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "strongsMode=0", in: app, timeout: 20)

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "windowOrder=2", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "strongsMode=0", in: app, timeout: 20)

        tapElementReliably(requireElement("readerStrongsToolbarButton", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(containing: "windowOrder=2", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "strongsMode=1", in: app, timeout: 20)

        tapWindowTab(0, in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "windowOrder=0", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "strongsMode=0", in: app, timeout: 20)

        tapElementReliably(requireElement("readerStrongsToolbarButton", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(containing: "windowOrder=0", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "strongsMode=1", in: app, timeout: 20)

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "windowOrder=2", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "strongsMode=1", in: app, timeout: 20)

        tapElementReliably(requireElement("readerStrongsToolbarButton", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(containing: "strongsMode=2", in: app, timeout: 20)
        tapElementReliably(requireElement("readerStrongsToolbarButton", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(containing: "strongsMode=0", in: app, timeout: 20)

        tapWindowTab(0, in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "windowOrder=0", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "strongsMode=1", in: app, timeout: 20)
    }

    /**
     Verifies that selecting a seeded bookmark label filter exposes the StudyPad handoff and opens
     the matching StudyPad document in the reader shell.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic `Genesis 1:1` bookmark assigned to the
     *     seeded `UI Test Seed` label
     *   - opens the bookmark list from the actual reader overflow menu
     *   - selects the seeded label chip and triggers the real `Open StudyPad` action
     * - Failure modes:
     *   - fails if the seeded label filter or StudyPad action never appears
     *   - fails if the reader never enters StudyPad mode for `UI Test Seed`
     */
    func testBookmarkListOpensStudyPadForSelectedLabel() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
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
     Verifies that selecting a seeded history row jumps the active reader to that prior location.
     *
     * - Side effects:
     *   - launches the app with one deterministic persisted history row while staying on the real
     *     reader shell
     *   - opens History from the reader menu
     *   - selects the seeded history row and waits for the visible reader reference to change
     *     from `Genesis 1` to `Exodus 2`
     * - Failure modes:
     *   - fails if the reader shell or seeded history row never appears
     *   - fails if selecting the history row does not update the reader reference to `Exodus 2`
     */
    func testHistorySelectionNavigatesReaderToSeededReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        XCTAssertTrue(
            initialReference.localizedCaseInsensitiveContains("Genesis 1"),
            "Expected the seeded history scenario to start on Genesis 1, but saw '\(initialReference)'."
        )

        XCTAssertTrue(openHistory(in: app).exists)
        tapElementReliably(requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10), timeout: 10)
        let updatedReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Exodus 2"),
            "Expected selecting the seeded history row to navigate to Exodus 2, but saw '\(updatedReference)'."
        )
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
