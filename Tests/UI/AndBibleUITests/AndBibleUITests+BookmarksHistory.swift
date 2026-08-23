import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies persisted Android manual night mode renders the reader with dark chrome.

     The fixture uses `night_mode_pref3=manual` plus `night_mode=true`, avoiding a dependency on
     the simulator's system appearance. The assertion uses the reader header's exported rendered
     state and stable drawer control instead of localized visual text.

     * - Side effects:
     *   - launches the reader with the dedicated persisted night-mode fixture
     * - Failure modes:
     *   - fails if the reader ignores its Android-equivalent persisted night-mode settings or
     *     loses the app-owned navigation drawer while night chrome is active
     */
    func testReaderNightModeRendersDarkReaderChrome() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "Expected the night-mode reader shell to become ready."
        )
        waitForReaderRenderedContentState(containing: "nightMode=true", in: app, timeout: 15)
        tapReaderNavigationDrawerButton(in: app, timeout: 30)
        XCTAssertTrue(
            requireElement("readerNavigationDrawer", in: app, timeout: 15).exists,
            "Expected the app-owned reader drawer to remain reachable in night mode."
        )
    }

    /**
     Verifies the reader drawer remains reachable with a non-English locale and XXXL Dynamic Type.

     The drawer control must retain its 44-point hit area and layout priority when the reader header
     has localized, expanded text. This test stops at the drawer surface; the default-size History
     route tests own the deferred drawer-action and dialog assertions.

     * - Side effects:
     *   - launches the baseline reader fixture with Spanish locale and XXXL Dynamic Type
     *   - opens the reader navigation drawer through its stable accessibility identifier
     * - Failure modes:
     *   - fails if the reader header compresses or hides the app-owned drawer control
     */
    func testReaderDrawerOpensInSpanishAtLargeDynamicType() {
        let app = makeApp()
        app.launchArguments += [
            "-AppleLanguages", "(es)",
            "-AppleLocale", "es_ES",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL",
        ]
        app.launch()

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "Expected the localized large-text reader shell to become ready."
        )
        tapReaderNavigationDrawerButton(in: app, timeout: 30)
        XCTAssertTrue(
            requireElement("readerNavigationDrawer", in: app, timeout: 15).exists,
            "Expected the app-owned reader drawer to be visible at large Dynamic Type."
        )
    }

    /**
     Verifies the reader's Feedback / bug report action collects evidence without terminating.

     The baseline fixture provides a real reader shell and the test invokes the production drawer
     row rather than a test-only seam. The expected result is Android's app-owned consent dialog;
     Mail remains untouched because the test does not approve the prepared report.

     * - Side effects:
     *   - launches the baseline reader and opens the production navigation drawer
     *   - captures the same bounded local evidence used by a manual report
     * - Failure modes:
     *   - fails if evidence collection terminates or backgrounds the app
     *   - fails if collection never advances to the app-owned consent dialog
     */
    func testFeedbackBugReportCollectsEvidenceAndPresentsConsentWithoutTerminating() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "Expected the baseline reader shell to become ready."
        )
        tapReaderAction("readerReportBugAction", in: app, timeout: 30)

        XCTAssertEqual(
            app.state,
            .runningForeground,
            "Feedback / bug report must not terminate or background the app while collecting evidence."
        )
        XCTAssertTrue(
            app.staticTexts["Send bug report via email"].firstMatch.waitForExistence(timeout: 30),
            "Expected evidence collection to advance to Android's app-owned consent dialog."
        )
    }

    /**
     Verifies Read/Memory Progress uses Android's full reader destination rather than a generic sheet.

     Android launches `ReadingProgressActivity` from the main drawer and returns to the reader with
     normal back navigation. The iOS equivalent must keep that destination owned by the launching
     reader pane, retain the no-sheet invariant, and return through reader back chrome.

     * - Side effects:
     *   - opens Reading Progress from the production navigation drawer
     *   - returns to the reader through the destination's explicit back control
     * - Failure modes:
     *   - fails if the route is absent from the drawer, becomes a generic sheet/modal, or cannot return
     *   - fails if the destination loses its reader-stack ownership while visible
     */
    func testReadingProgressUsesReaderDestinationAndReturns() {
        let app = makeApp()
        app.launch()

        let destination = openReadingProgress(in: app)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=readingProgress", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Reading Progress should use reader destination back chrome, not a generic sheet Done button."
        )

        tapElementReliably(
            requireElement("readingProgressAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForElementToDisappear(destination, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected destination back navigation to return to the reader shell."
        )
    }

    /**
     Verifies Android's bounded History dialog returns a selected row to its reader pane.

     Android scopes the result to its launching window and closes when the dialog is dismissed. The
     iOS dialog must therefore render its named app-owned surface, dismiss from its dimmed backdrop,
     omit iOS-only destructive controls, close after selection, and navigate the seeded reader from
     Genesis 1 to Exodus 2.

     * - Side effects:
     *   - opens the drawer History route using a window-scoped persisted History fixture
     *   - selects the seeded Exodus checkpoint and waits for reader navigation to complete
     * - Failure modes:
     *   - fails if History regresses to an unnamed generic sheet, exposes destructive controls, or
     *     cannot close and return the selection to the originating reader pane
     */
    func testHistoryDialogSelectsSeededReferenceInCapturedReaderPane() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        XCTAssertTrue(initialReference.localizedCaseInsensitiveContains("Genesis 1"))

        tapReaderNavigationDrawerButton(in: app, timeout: 30)
        tapElementReliably(requireElement("readerOpenHistoryAction", in: app, timeout: 15), timeout: 15)
        waitForReaderRenderedContentState(containing: "historyDialog=presented", in: app, timeout: 10)
        XCTAssertFalse(
            unresolvedElement("historyClearButton", in: app).exists,
            "Android's History dialog must not expose iOS-only clear-history controls."
        )

        // Tap the dimmed space left of the bounded card; this must dismiss without navigation.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).tap()
        waitForReaderRenderedContentState(containing: "historyDialog=none", in: app, timeout: 10)

        tapReaderNavigationDrawerButton(in: app, timeout: 30)
        tapElementReliably(requireElement("readerOpenHistoryAction", in: app, timeout: 15), timeout: 15)
        waitForReaderRenderedContentState(containing: "historyDialog=presented", in: app, timeout: 10)

        tapElementReliably(requireHistoryRow(containing: "Exodus 2:1", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(containing: "historyDialog=none", in: app, timeout: 10)
        let updatedReference = waitForReaderReferenceValueToChange(from: initialReference, in: app, timeout: 20)
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Exodus 2"),
            "Expected the captured History selection to navigate the reader to Exodus 2, but saw '\(updatedReference)'."
        )
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
     *     destination, exercises the shared search/overflow menus and canonical Help dialog,
     *     opens the full Label Edit activity, and returns to the reader shell
     *   - opens History from the reader menu and selects the seeded row
     *   - opens the bookmark list from the actual reader overflow menu
     *   - opens Label Assignment for the seeded Genesis bookmark, verifies assignment state, and
     *     returns to the bookmark list
     *   - taps the seeded bookmark row and waits for the visible reader reference to reach
     *     `Genesis 1`
     *   - reopens Bookmarks, selects the seeded label through Android's spinner, verifies the
     *     filtered rows, and returns through the app-owned activity bar
     * - Failure modes:
     *   - fails if StudyPads regresses to sheet/modal presentation, shows sheet Done chrome, skips
     *     its Android-style manager screen, loses its search/overflow/help/editor controls, lets
     *     nested editor chrome escape the shared safe area, or cannot return to reader chrome
     *   - fails if the history route regresses or selecting the seeded row does not navigate the
     *     reader to `Exodus 2`
     *   - fails if the bookmark list route regresses to sheet presentation
     *   - fails if the bookmark list, label-assignment screen, or seeded bookmark rows never appear
     *   - fails if Label Assignment cannot dismiss back to the bookmark list
     *   - fails if tapping the seeded bookmark row does not drive the reader back to `Genesis 1`
     *   - fails if the shared popup label selector does not filter the list like Android or the
     *     app-owned activity cannot return to the reader
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
            destinationIdentifier: "studyPadSelectorScreen",
            readinessIdentifiers: ["studyPadSelectorAddButton"],
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=studyPads", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer StudyPads should use reader destination back chrome, not iOS sheet Done chrome."
        )
        XCTAssertTrue(
            app.buttons["UI Test Seed"].waitForExistence(timeout: 10),
            "Expected the seeded Study Pad row on the Android Study Pad selector activity."
        )

        let studyPadBackButton = requireElement("studyPadSelectorAppBarBackButton", in: app, timeout: 10)
        let studyPadSearchModeButton = requireElement(
            "studyPadSelectorSearchModeButton",
            in: app,
            timeout: 10
        )
        tapElementReliably(studyPadSearchModeButton, timeout: 10)
        for identifier in [
            "studyPadSelectorSearchMode::0",
            "studyPadSelectorSearchMode::1",
            "studyPadSelectorSearchMode::2",
        ] {
            XCTAssertTrue(
                requireElement(identifier, in: app, timeout: 10).exists,
                "Expected Android's complete Study Pad search-mode popup row \(identifier)."
            )
        }
        tapElementReliably(
            requireElement("studyPadSelectorSearchMode::0", in: app, timeout: 10),
            timeout: 10
        )

        tapElementReliably(
            requireElement("studyPadSelectorOverflowButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            requireElement("studyPadSelectorExportAction", in: app, timeout: 10).exists,
            "Expected Android's Export Study Pads overflow command."
        )
        XCTAssertTrue(
            requireElement("studyPadSelectorImportAction", in: app, timeout: 10).exists,
            "Expected Android's Import Study Pads overflow command."
        )
        tapElementReliably(
            requireElement("studyPadSelectorOverflowMenuDismissalLayer", in: app, timeout: 10),
            timeout: 10
        )

        tapElementReliably(
            requireElement("studyPadSelectorHelpButton", in: app, timeout: 10),
            timeout: 10
        )
        let helpDialog = requireElement("androidHelpDialog", in: app, timeout: 10)
        XCTAssertTrue(helpDialog.exists, "Expected the canonical Android Study Pads Help dialog.")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Study Pads Help must remain app-owned.")
        tapElementReliably(
            requireElement("androidHelpDialogOKButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForElementToDisappear(helpDialog, timeout: 10)

        tapElementReliably(
            requireElement("studyPadSelectorAddButton", in: app, timeout: 10),
            timeout: 10
        )
        let labelEditor = requireElement("labelEditScreen", in: app, timeout: 10)
        let editorBackButton = requireElement("androidLabelEditorAppBarBackButton", in: app, timeout: 10)
        XCTAssertTrue(requireElement("labelEditDoneButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("labelEditNameField", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("labelEditColorButton", in: app, timeout: 10).exists)
        XCTAssertFalse(app.sheets.firstMatch.exists, "Label Edit must be a full app-owned activity.")
        XCTAssertEqual(
            editorBackButton.frame.minY,
            studyPadBackButton.frame.minY,
            accuracy: 2,
            "Nested Label Edit must use the same shared safe-area app-bar origin as Study Pads."
        )
        tapElementReliably(editorBackButton, timeout: 10)
        waitForElementToDisappear(labelEditor, timeout: 10)
        XCTAssertTrue(
            requireElement("studyPadSelectorAddButton", in: app, timeout: 10).exists,
            "Expected Label Edit Back to return to the existing Study Pads activity."
        )

        tapElementReliably(
            studyPadBackButton,
            timeout: 10
        )
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
        waitForReaderRenderedContentState(containing: "readerDestination=bookmarks", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer Bookmarks should use reader destination back chrome, not iOS sheet Done chrome."
        )

        XCTAssertTrue(openLabelAssignmentFromBookmarkList(in: app).exists)
        let seedAssignment = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                "manageLabelsAssignment::",
                "UI Test Seed"
            )
        ).firstMatch
        XCTAssertTrue(
            seedAssignment.waitForExistence(timeout: 10),
            "Expected the seeded label's shared Manage Labels assignment checkbox."
        )
        XCTAssertEqual(
            seedAssignment.value as? String,
            "on",
            "Expected the seeded label to be assigned when Label Assignment opens."
        )
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
        selectBookmarkListLabelFilter("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(
            containing: "count=1;selectedLabel=UI_Test_Seed",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireBookmarkRow("Genesis_1_1", in: app, timeout: 10).exists)
        XCTAssertFalse(
            app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch.exists,
            "Expected Android's selected-label spinner to exclude the unassigned Exodus bookmark."
        )
        tapElementReliably(
            requireElement("bookmarkListAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            waitForBookmarkListDismissal(in: app, timeout: 10),
            "Expected the app-owned Bookmark activity bar to return to the reader."
        )
    }

    /**
     Verifies a production reader note survives software-keyboard presentation and relaunch.

     Android keeps its reader pane identity stable when the IME reduces the usable content area;
     the keyboard does not reclassify the window's device orientation. This regression follows the
     same visible route on iOS: select `Genesis 1:1`, invoke Note, type through the real WebView
     editor while the full software keyboard is present, dismiss the bookmark dialog directly, and
     relaunch the same fixture session. It intentionally inspects live WebKit verse content in
     addition to the native state export because detached reader content can leave stale native
     state behind.

     * - Side effects:
     *   - forces portrait orientation and launches the public-domain baseline KJV fixture
     *   - creates a Genesis 1:1 bookmark note through the production Vue/native bridge
     *   - terminates and relaunches the app without reseeding the fixture container
     * - Failure modes:
     *   - fails if verse selection or the production Note action cannot open the named editor
     *   - fails if only the input accessory remains instead of the full software keyboard
     *   - fails if keyboard presentation reconstructs or detaches the reader WebView
     *   - fails if dismissing the dialog loses the typed note or the note does not survive relaunch
     * - Synchronization:
     *   - uses XCTest element and predicate waits instead of fixed sleeps
     *   - retries the verse tap once because a first tap may only activate an inactive reader pane
     */
    func testReaderNoteEditorKeepsSoftwareKeyboardAndPersistsTypedNote() {
        let app = makeApp()
        let verseTextFragment = "In the beginning"
        let editorLabel = "My Notes note editor for Genesis 1:1"
        let sentinel = "Issue390NoteSentinel"
        let persistedNoteToken = "|Genesis_1_1=\(sentinel)|"

        XCUIDevice.shared.orientation = .portrait
        app.launch()

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "Expected the baseline reader shell before creating a verse note."
        )
        waitForReaderRenderedContentState(
            containing: "category=bible;module=KJV",
            in: app,
            timeout: 20
        )

        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.waitForExistence(timeout: 20),
            "Expected the production reader WebView for the Genesis note workflow."
        )
        let verse = webView.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", verseTextFragment)
        ).firstMatch
        XCTAssertTrue(
            verse.waitForExistence(timeout: 20) && elementHasUsableFrame(verse),
            "Expected visible Genesis 1:1 text before opening the Note action."
        )

        let noteButton = webView.buttons.matching(
            NSPredicate(format: "label == %@", "Note")
        ).firstMatch
        tapElementReliably(verse, timeout: 10)
        if !noteButton.waitForExistence(timeout: 2) {
            tapElementReliably(verse, timeout: 10)
        }
        XCTAssertTrue(
            noteButton.waitForExistence(timeout: 10),
            "Expected the production verse-selection Note action."
        )
        tapElementReliably(noteButton, timeout: 10)

        let editor = webView.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", editorLabel)
        ).firstMatch
        XCTAssertTrue(
            editor.waitForExistence(timeout: 10),
            "Expected the accessible Genesis 1:1 note editor to enter edit mode."
        )

        let keyboard = app.keyboards.firstMatch
        let qKey = app.keys.matching(
            NSPredicate(format: "label ==[c] %@", "q")
        ).firstMatch
        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 10) && qKey.waitForExistence(timeout: 10),
            "Expected the full software keyboard, not only its input accessory, for note editing."
        )
        XCTAssertTrue(
            waitForUITestCondition("full software keyboard remains visible", timeout: 10) {
                keyboard.exists &&
                    self.elementFrameIsUsable(keyboard.frame) &&
                    keyboard.frame.height > app.frame.height * 0.2 &&
                    qKey.exists
            },
            "Expected a usable software-keyboard frame with character keys."
        )
        waitForMyNotesState(containing: "myNotesEditing=true", in: app, timeout: 10)
        XCTAssertTrue(
            verse.exists && elementHasUsableFrame(verse),
            "Expected the rendered verse to remain attached while the keyboard is visible."
        )

        app.typeText(sentinel)
        let modalCloseButton = webView.buttons.matching(
            NSPredicate(format: "label == %@", "Cancel")
        ).firstMatch
        XCTAssertTrue(
            modalCloseButton.waitForExistence(timeout: 10),
            "Expected the localized outer bookmark-dialog dismissal control."
        )
        XCTAssertTrue(
            qKey.exists,
            "Expected the full software keyboard to remain active until direct modal dismissal."
        )
        tapElementReliably(modalCloseButton, timeout: 10)

        waitForElementToDisappear(keyboard, timeout: 10)
        waitForElementToDisappear(modalCloseButton, timeout: 10)
        waitForMyNotesState(containing: "myNotesEditing=false", in: app, timeout: 10)
        waitForMyNotesState(containing: persistedNoteToken, in: app, timeout: 20)
        XCTAssertTrue(
            waitForUITestCondition("rendered verse remains attached after note dismissal", timeout: 15) {
                verse.exists && self.elementHasUsableFrame(verse)
            },
            "Expected the Genesis verse body to remain rendered after closing the note editor."
        )

        app.terminate()
        app.launch()

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "Expected relaunch to restore the reader shell without reseeding the fixture."
        )
        waitForReaderRenderedContentState(
            containing: "category=bible;module=KJV",
            in: app,
            timeout: 20
        )
        waitForMyNotesState(containing: persistedNoteToken, in: app, timeout: 20)
        let relaunchedWebView = app.webViews.firstMatch
        XCTAssertTrue(
            relaunchedWebView.waitForExistence(timeout: 20),
            "Expected the reader WebView after relaunch."
        )
        let relaunchedVerse = relaunchedWebView.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", verseTextFragment)
        ).firstMatch
        XCTAssertTrue(
            relaunchedVerse.waitForExistence(timeout: 20) && elementHasUsableFrame(relaunchedVerse),
            "Expected persisted note restoration to leave the Genesis reader body rendered."
        )
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

}
