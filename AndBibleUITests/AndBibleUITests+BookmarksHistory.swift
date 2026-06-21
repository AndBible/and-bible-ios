import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func testBookmarksScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openBookmarkList(in: app).exists)
    }

    /**
     Verifies that selecting a seeded bookmark row dismisses the list and navigates the reader to
     that bookmark's chapter.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic `Exodus 2:1` bookmark while the reader
     *     itself stays on `Genesis 1`
     *   - opens the bookmark list from the actual reader overflow menu
     *   - taps the seeded bookmark row and waits for the visible reader reference to reach
     *     `Exodus 2`
     * - Failure modes:
     *   - fails if the bookmark list or seeded bookmark row never appears
     *   - fails if tapping the seeded bookmark row does not drive the reader to `Exodus 2`
     */
    func testBookmarkSelectionNavigatesReaderToSeededReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        XCTAssertTrue(
            initialReference.localizedCaseInsensitiveContains("Genesis 1"),
            "Expected the seeded bookmark-navigation scenario to start on Genesis 1, but saw '\(initialReference)'."
        )

        _ = openBookmarkList(in: app)
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
     *   - launches the seeded bookmark-navigation fixture on the reader shell
     *   - creates two additional windows, activates the third one, opens the bookmark list from
     *     that pane, and selects the seeded `Exodus 2:1` row
     *   - switches back to the first window to confirm its rendered content stayed on `Genesis 1`
     * - Failure modes:
     *   - fails if the extra windows cannot be created or activated
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

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        addWindowTab(expectingOrder: 2, in: app, timeout: 15)

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
     *   - launches the baseline reader shell, creates two additional windows, and activates the
     *     third one
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

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        addWindowTab(expectingOrder: 2, in: app, timeout: 15)

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerCommentaryToolbarButton", in: app, timeout: 10), timeout: 10)
        if waitForAnyElement(["modulePickerScreen"], in: app, timeout: 3) != nil {
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
            let kjvQuickRow = requireElement("readerBibleQuickSelectorRow_KJV", in: app, timeout: 10)
            XCTAssertEqual(
                kjvQuickRow.value as? String,
                "available",
                "KJV quick-selector row must remain selectable when returning from commentary."
            )
            for _ in 0..<8 where !isElementVisible(kjvQuickRow, within: quickSelector) {
                quickSelector.swipeUp()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            XCTAssertTrue(
                isElementVisible(kjvQuickRow, within: quickSelector),
                "Expected quick selector to scroll until KJV is visible."
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
     *   - launches the baseline reader shell, creates two additional windows, and activates the
     *     third one
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

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        addWindowTab(expectingOrder: 2, in: app, timeout: 15)

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
     Verifies that deleting one bookmark row from the real bookmark list leaves other bookmarks
     intact across reopen.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Exodus 2:1` and `Matthew 3:1` bookmarks
     *   - opens the real bookmark list from the reader overflow menu
     *   - deletes only the Exodus row through the row-level swipe action, dismisses the screen,
     *     and reopens the list to confirm the Matthew row persists
     * - Failure modes:
     *   - fails if the bookmark list or either seeded bookmark row never appears
     *   - fails if the row-level delete action is missing for the Exodus bookmark
     *   - fails if deleting the Exodus row also removes the Matthew row or if the Exodus row
     *     returns after reopening the bookmark list
     */
    func testBookmarkRowDeletePreservesOtherRowsAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        let exodusRow = requireBookmarkRow("Exodus_2_1", in: app, timeout: 10)
        _ = requireBookmarkRow("Matthew_3_1", in: app, timeout: 10)

        exodusRow.swipeLeft()
        requireElement("bookmarkListDeleteButton::Exodus_2_1", in: app, timeout: 10).tap()

        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)

        reopenBookmarkList(in: app)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)
    }

    /**
     Verifies that changing the bookmark-list sort menu reorders the visible rows.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Exodus 2:1` and `Matthew 3:1` bookmarks
     *   - opens the real bookmark list from the reader overflow menu
     *   - verifies the default `Date created` ordering, opens the real sort menu, selects `Bible
     *     order`, and waits for the visible row order to update
     * - Failure modes:
     *   - fails if the bookmark list, sort menu, or `Bible order` option never appears
     *   - fails if the default row order does not match the seeded creation order
     *   - fails if selecting `Bible order` does not move the Exodus row above the Matthew row
     */
    func testBookmarkListSortMenuReordersRows() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        waitForBookmarkListRows(
            toAppearInOrder: ["Matthew_3_1", "Exodus_2_1"],
            in: app
        )

        sortBookmarkListByBibleOrder(in: app)

        waitForBookmarkListRows(
            toAppearInOrder: ["Exodus_2_1", "Matthew_3_1"],
            in: app
        )
    }

    /**
     Verifies that bookmark-list text search narrows the visible rows and that clearing the query
     restores the full row set.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Exodus 2:1` and `Matthew 3:1` bookmarks
     *   - opens the real bookmark list from the reader overflow menu
     *   - types `Matthew` into the real bookmark search field, verifies the list narrows to the
     *     matching row, then clears the query and verifies both rows return
     * - Failure modes:
     *   - fails if the bookmark list, search field, or either seeded bookmark row never appears
     *   - fails if the search query does not hide the non-matching bookmark row
     *   - fails if clearing the search query does not restore the full bookmark row set
     */
    func testBookmarkListSearchNarrowsAndClearsVisibleRows() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        let searchField = requireBookmarkListSearchField(in: app, timeout: 10)

        replaceText(in: searchField, with: "Matthew", placeholderHints: ["Search bookmarks"])
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(containing: "query=Matthew", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)

        replaceText(in: searchField, with: "", placeholderHints: ["Search bookmarks"])
        waitForBookmarkListState(containing: "count=2", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: "query=Matthew", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)
    }

    /**
     Verifies that bookmark-list label chips narrow the visible rows and that clearing the filter
     restores the full row set.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Genesis 1:1` and `Exodus 2:1` bookmarks,
     *     each assigned to a different user label
     *   - opens the real bookmark list from the reader overflow menu
     *   - selects the seeded `UI Test Seed` label chip, verifies the list narrows to the matching
     *     bookmark row, then clears the filter through the real `All` chip
     * - Failure modes:
     *   - fails if the bookmark list, seeded filter chip, or either seeded bookmark row never
     *     appears
     *   - fails if the label filter does not hide the non-matching bookmark row
     *   - fails if clearing the filter does not restore the full bookmark row set
     */
    func testBookmarkListLabelFilterNarrowsAndClearsVisibleRows() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)

        let genesisRow = requireBookmarkRow("Genesis_1_1", in: app, timeout: 10)
        XCTAssertTrue(genesisRow.exists, "Expected Genesis bookmark row to remain visible for the selected label.")
        XCTAssertTrue(
            requireElement("bookmarkListOpenStudyPadButton::UI_Test_Seed", in: app, timeout: 10).exists,
            "Expected the seeded label StudyPad handoff to appear while the filter is active."
        )

        selectBookmarkListFilterChip("all", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=2", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row to remain visible after clearing the filter.")
        XCTAssertTrue(
            requireBookmarkRow("Exodus_2_1", in: app, timeout: 10).exists,
            "Expected Exodus bookmark row to return after clearing the filter."
        )
        XCTAssertFalse(
            app.buttons["bookmarkListOpenStudyPadButton::UI_Test_Seed"].firstMatch.exists,
            "Expected the StudyPad handoff to disappear once the label filter is cleared."
        )
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
     Verifies that adding a text entry inside the visible StudyPad document persists after the
     StudyPad is rebuilt from storage.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic label-backed StudyPad fixture
     *   - opens StudyPad from the production bookmark-list label handoff
     *   - taps the visible web StudyPad add-note control and applies deterministic text through the
     *     gated UI-test edit bridge
     *   - returns to Bible, reopens StudyPad from the same handoff, and verifies the created text
     *     entry is still present in the rebuilt document state
     * - Failure modes:
     *   - fails if the StudyPad handoff, visible add-note control, mutation export, or persisted
     *     rebuild never reaches the expected state
     */
    func testStudyPadCreateTextEntryPersistsAcrossReopen() {
        let app = makeApp()
        let createdNoteText = "UI Test StudyPad Created Note"
        let createdNoteToken = "UI Test StudyPad Created Note"
        app.launchEnvironment["UITEST_STUDYPAD_CREATED_NOTE_TEXT"] = createdNoteText
        app.launchArguments += ["-UITEST_STUDYPAD_CREATED_NOTE_TEXT", createdNoteText]
        app.launch()

        _ = openBookmarkList(in: app)
        openSeedStudyPadFromBookmarkList(in: app)
        waitForStudyPadPresentation(in: app, timeout: 20)
        waitForVisibleStudyPadState(containing: "studyPadTextEntryCount=1", in: app, timeout: 20)

        tapElementReliably(
            requireStudyPadWebControl(named: "Add StudyPad note after last entry for UI Test Seed", in: app, timeout: 20),
            timeout: 10
        )
        waitForVisibleStudyPadState(containing: "studyPadTextEntryCount=2", in: app, timeout: 20)
        waitForVisibleStudyPadState(containing: createdNoteToken, in: app, timeout: 20)
        dismissStudyPadEditor(in: app, timeout: 15)

        returnFromStudyPadIfVisible(in: app, timeout: 20)

        _ = openBookmarkList(in: app)
        openSeedStudyPadFromBookmarkList(in: app)
        waitForStudyPadPresentation(in: app, timeout: 20)
        waitForVisibleStudyPadState(containing: "studyPadTextEntryCount=2", in: app, timeout: 20)
        waitForVisibleStudyPadState(containing: createdNoteToken, in: app, timeout: 20)
    }

    /**
     Verifies that the visible My Notes document can update and delete a note-backed bookmark.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic Genesis note fixture
     *   - opens My Notes through the production reader navigation drawer
     *   - opens the visible note editor, appends through the gated UI-test bridge path, returns to
     *     Bible when needed, and reopens My Notes to verify the persisted note is rebuilt
     *   - deletes the visible My Notes row and verifies the rebuilt document stays empty
     * - Failure modes:
     *   - fails if the My Notes action, visible note editor, delete action, or persistence export
     *     never reaches the expected state
     */
    func testMyNotesNoteUpdateAndDeletePersistsFromVisibleWorkflow() {
        let app = makeApp()
        let referenceLabel = "Genesis 1:1"
        let rowToken = "Genesis_1_1"
        let originalNote = "UI_Test_My_Notes_Note"
        let updatedNoteMarker = "updated"
        app.launchEnvironment["UITEST_MY_NOTES_APPEND_TEXT"] = " \(updatedNoteMarker)"
        app.launchArguments += ["-UITEST_MY_NOTES_APPEND_TEXT", " \(updatedNoteMarker)"]
        app.launch()

        let openNoteEditorLabel = "Open My Notes note editor for \(referenceLabel)"
        let actionsLabel = "My Notes actions for \(referenceLabel)"
        let deleteLabel = "Delete My Notes note for \(referenceLabel)"

        openMyNotesFromReader(in: app)
        waitForVisibleMyNotesState(containing: "myNotesCount=1", in: app, timeout: 20)
        waitForVisibleMyNotesState(containing: "|\(rowToken)=\(originalNote)|", in: app, timeout: 20)

        openVisibleMyNotesEditor(
            actionsLabel: actionsLabel,
            editorLabel: openNoteEditorLabel,
            orPersistedMarker: updatedNoteMarker,
            in: app,
            timeout: 20
        )
        waitForVisibleMyNotesState(containing: updatedNoteMarker, in: app, timeout: 20)
        dismissMyNotesEditor(in: app, timeout: 15)
        waitForVisibleMyNotesState(containing: "myNotesEditing=false", in: app, timeout: 20)

        returnFromMyNotesIfVisible(in: app, timeout: 20)

        openMyNotesFromReader(in: app)
        waitForVisibleMyNotesState(containing: "myNotesCount=1", in: app, timeout: 20)
        waitForVisibleMyNotesState(containing: updatedNoteMarker, in: app, timeout: 20)

        tapElementReliably(requireMyNotesWebControl(named: actionsLabel, in: app, timeout: 15), timeout: 10)
        tapElementReliably(requireMyNotesWebControl(named: deleteLabel, in: app, timeout: 15), timeout: 10)
        tapElementReliably(requireMyNotesWebControl(named: "Yes", in: app, timeout: 10), timeout: 10)
        waitForVisibleMyNotesState(containing: "myNotesCount=0", in: app, timeout: 20)
        waitForVisibleMyNotesState(notContaining: "|\(rowToken)|", in: app, timeout: 20)

        returnFromMyNotesIfVisible(in: app, timeout: 20)
        openMyNotesFromReader(in: app)
        waitForVisibleMyNotesState(containing: "myNotesCount=0", in: app, timeout: 20)
        waitForVisibleMyNotesState(notContaining: updatedNoteMarker, in: app, timeout: 20)
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
     Verifies that clearing history removes the seeded row and keeps History empty after reopen.
     *
     * - Side effects:
     *   - launches the app with deterministic persisted history rows while staying on the real
     *     reader shell
     *   - opens History from the reader menu, clears the visible history, dismisses the screen,
     *     then reopens History to verify the cleared seeded rows remain deleted
     * - Failure modes:
     *   - fails if the History screen or clear control never appears
     *   - fails if reopening History still shows the seeded rows that Clear should delete
     */
    func testHistoryClearRemovesSeededRowAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openHistory(in: app)
        XCTAssertTrue(requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("historyClearButton", in: app, timeout: 10), timeout: 10)
        waitForElementExistence(
            "historyRow::Exod_2_1",
            in: app,
            shouldExist: false,
            timeout: 10
        )
        waitForElementExistence(
            "historyRow::Matt_3_1",
            in: app,
            shouldExist: false,
            timeout: 10
        )
        waitForElementExistence("historyClearButton", in: app, shouldExist: false, timeout: 10)
        tapElementReliably(requireElement("historyDoneButton", in: app, timeout: 10), timeout: 10)
        _ = openHistory(in: app)
        waitForElementExistence("historyClearButton", in: app, shouldExist: false, timeout: 10)
        waitForElementExistence("historyRow::Exod_2_1", in: app, shouldExist: false, timeout: 10)
        waitForElementExistence("historyRow::Matt_3_1", in: app, shouldExist: false, timeout: 10)
    }

    /**
     Verifies that deleting one history row leaves other history rows intact across reopen.
     *
     * - Side effects:
     *   - launches the app with two deterministic persisted history rows while staying on the real
     *     reader shell
     *   - opens History from the reader menu, deletes only the Exodus row, dismisses the screen,
     *     and reopens History to confirm the Matthew row persists
     * - Failure modes:
     *   - fails if the History screen or delete control never appears
     *   - fails if deleting Exodus also removes Matthew or if Exodus returns after reopening
     */
    func testHistoryRowDeletePreservesOtherRowsAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openHistory(in: app)
        let exodusRow = requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10)
        _ = requireHistoryRow(containing: "Matthew 3", in: app, timeout: 10)
        deleteHistoryRow(exodusRow, keyToken: "Exod_2_1", in: app, timeout: 10)
        waitForHistoryState(containing: "count=1", in: app, timeout: 10)
        waitForHistoryState(notContaining: historyRowStateToken("Exod_2_1"), in: app, timeout: 10)
        waitForHistoryState(containing: historyRowStateToken("Matt_3_1"), in: app, timeout: 10)

        tapElementReliably(requireElement("historyDoneButton", in: app, timeout: 10), timeout: 10)
        _ = openHistory(in: app)
        waitForHistoryState(containing: "count=1", in: app, timeout: 10)
        waitForHistoryState(notContaining: historyRowStateToken("Exod_2_1"), in: app, timeout: 10)
        waitForHistoryState(containing: historyRowStateToken("Matt_3_1"), in: app, timeout: 10)
    }

    /**
     Verifies that label assignment can be reached from the real bookmark-list path and still
     toggle the seeded label state.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic bookmark and seed label preloaded
     *   - opens the bookmark list from the reader overflow menu
     *   - opens label assignment from the seeded bookmark row and toggles favourite plus assignment
     * - Failure modes:
     *   - fails if the bookmark list cannot be reached from the reader menu
     *   - fails if the seeded bookmark row or inline edit-labels action is missing
     *   - fails if the label-assignment screen never appears or the seeded row state does not
     *     update after the toggles
     */
    func testBookmarkListOpensLabelAssignmentForSeededBookmark() {
        let app = makeApp()
        app.launch()

        let labelAssignmentScreen = openLabelAssignmentFromBookmarkList(in: app)
        XCTAssertTrue(labelAssignmentScreen.exists)

        assertSeedLabelAssignmentCanToggle(in: app)
    }

    /**
     Verifies that generic bookmarks are visible from the real bookmark-list path and can be
     assigned to a label through the same row affordance as Bible bookmarks.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic generic bookmark and one user label
     *   - opens the bookmark list from the reader overflow menu
     *   - confirms the generic bookmark is visible but not included under the unassigned label
     *     filter
     *   - assigns that label through Label Assignment and verifies the filtered bookmark list
     *     includes the generic row after returning
     * - Failure modes:
     *   - fails if the generic bookmark is not visible in the bookmark list
     *   - fails if the label-assignment sheet cannot load the generic bookmark
     *   - fails if the generic label mutation is not reflected by bookmark-list filtering
     */
    func testGenericBookmarkVisibleWorkflowAssignsLabelFromBookmarkList() {
        let app = makeApp()
        let genericBookmarkSegment = "UITESTDICT_Entry_1"
        app.launch()

        _ = openBookmarkList(in: app)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(
            containing: bookmarkListRowStateToken(genericBookmarkSegment),
            in: app,
            timeout: 10
        )

        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=0", in: app, timeout: 10)
        waitForBookmarkListState(
            notContaining: bookmarkListRowStateToken(genericBookmarkSegment),
            in: app,
            timeout: 10
        )

        selectBookmarkListFilterChip("all", in: app, timeout: 10)
        tapElementReliably(
            requireElement("bookmarkListEditLabelsButton::\(genericBookmarkSegment)", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("labelAssignmentScreen", in: app, timeout: 10).exists)

        let seedRow = requireElement("labelAssignmentRow::UI_Test_Seed", in: app, timeout: 10)
        XCTAssertEqual(seedRow.value as? String, "unassigned,notFavourite")
        requireElement("labelAssignmentToggleButton::UI_Test_Seed", in: app, timeout: 10).tap()

        waitForElementValue(
            "labelAssignmentRow::UI_Test_Seed",
            toEqual: "assigned,notFavourite",
            in: app,
            timeout: 10
        )

        dismissLabelAssignmentToBookmarkList(in: app)
        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(
            containing: bookmarkListRowStateToken(genericBookmarkSegment),
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies that the about screen can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu and pushes the about screen
     * - Failure modes:
     *   - fails if the about action is missing from the reader menu
     *   - fails if the about screen does not render after navigation completes
     */
}
