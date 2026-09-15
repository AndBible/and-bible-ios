import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {

    /**
     Verifies a populated Bookmarks destination with notes remains usable without diagnostic exports.

     The controlled fixture contains ten Genesis bookmarks and two notes. One real drawer action
     must expose visible rows and reachable Back chrome; one Back tap must restore actual scripture.
     Failure attachments retain the on-screen layout so clipped controls cannot be mistaken for a
     missing identifier. Fixture preparation and screenshots are outside any performance interval.
     */
    func testBookmarksWithNotesRemainVisibleAndReturnToReader() {
        let app = makeApp(enablesDetailedAccessibilityExports: false)
        app.launch()
        waitForVisibleReaderText(containing: "In the beginning", in: app)
        tapReaderAction("readerOpenBookmarksAction", in: app, timeout: 30)
        guard waitForUsableBookmarkList(in: app, requiresRows: true) else {
            XCTContext.runActivity(named: "Unusable populated Bookmarks destination") { activity in
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                activity.add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.lifetime = .keepAlways
                activity.add(hierarchy)
            }
            XCTFail("Expected visible bookmark rows and on-screen Back and filter controls.")
            return
        }
        app.buttons["bookmarkListAppBarBackButton"].tap()
        waitForVisibleReaderText(containing: "In the beginning", in: app)
    }

    /**
     Verifies persisted Android manual night mode keeps the reader drawer reachable.

     The fixture uses `night_mode_pref3=manual` plus `night_mode=true`, avoiding a dependency on
     the simulator's system appearance. The diagnostic state proves the resolved night policy; the
     visible drawer interaction proves the reader shell remains usable. This journey does not claim
     pixel-level coverage of the SwiftUI header or destination chrome.

     * - Side effects:
     *   - launches the reader with the dedicated persisted night-mode fixture
     * - Failure modes:
     *   - fails if the reader ignores its Android-equivalent persisted night-mode settings or
     *     loses the app-owned navigation drawer while the night policy is active
     */
    func testPersistedManualNightModeKeepsReaderDrawerReachable() {
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
     normal back navigation. This journey observes the visible destination's Back chrome and the
     same scripture before and after returning. Pane ownership has separate controller coverage.

     * - Side effects:
     *   - opens Reading Progress from the production navigation drawer
     *   - returns to the reader with one tap on the destination's explicit back control
     * - Failure modes:
     *   - fails if the route is absent from the drawer, becomes a generic sheet/modal, or cannot return
     *   - fails if returning does not render the original scripture
     */
    func testReadingProgressUsesReaderDestinationAndReturns() {
        let app = makeApp()
        app.launch()
        waitForVisibleReaderText(containing: "In the beginning", in: app)

        let destination = openReadingProgress(in: app)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Reading Progress should use reader destination back chrome, not a generic sheet Done button."
        )

        tapElementReliably(
            requireElement("readingProgressAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForElementToDisappear(destination, timeout: 10)
        waitForVisibleReaderText(containing: "In the beginning", in: app)
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
        waitForVisibleReaderText(containing: "there went a man of the house of Levi", in: app)
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
     Selects real EPUB and My Documents owners from Android's shared commentary quick menu.

     The fixture installs a production EPUB generation and a SwiftData My Document beside one
     native commentary so the ordinary toolbar tap must expose the three-owner popup. Each local
     row then publishes its own first-page body through the app's normal reader entrypoint. While
     the EPUB is visible, its auxiliary header must retain Back navigation and expose the same
     commentary action directly for the second selection.
     */
    func testCommentaryQuickMenuSelectsLocalEpubAndMyDocumentsBodies() {
        let app = makeApp()
        app.launch()
        waitForReaderRenderedContentState(
            containing: "category=bible;module=KJV",
            in: app,
            timeout: 20
        )
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app,
            timeout: 20
        )

        let epubRowID = "readerCommentaryQuickSelectorRow_Epub-UITESTEPUB_epub"
        let myDocumentRowID = "readerCommentaryQuickSelectorRow_UITESTDOC"
        tapElementReliably(requireElement("readerCommentaryToolbarButton", in: app, timeout: 10))
        _ = requireElement("readerCommentaryQuickSelector", in: app, timeout: 10)
        let epubRow = requireElement(epubRowID, in: app, timeout: 10)
        XCTAssertTrue(requireElement(myDocumentRowID, in: app, timeout: 10).exists)
        tapElementReliably(epubRow)

        waitForReaderRenderedContentState(
            containing: "category=general_book;module=Epub-UITESTEPUB_epub",
            in: app,
            timeout: 20
        )
        waitForVisibleReaderText(
            containing: "EPUB page one.",
            in: app,
            timeout: 20
        )
        let epubHeaderScreenshot = XCTAttachment(screenshot: app.screenshot())
        epubHeaderScreenshot.name = "EPUB auxiliary document actions"
        epubHeaderScreenshot.lifetime = .keepAlways
        add(epubHeaderScreenshot)

        let backToBibleButton = app.buttons.matching(
            NSPredicate(format: "label == %@", "Back to Bible")
        ).firstMatch
        XCTAssertTrue(
            backToBibleButton.waitForExistence(timeout: 10),
            "Expected the EPUB auxiliary header to retain its Back to Bible action."
        )
        tapElementReliably(requireElement("readerCommentaryToolbarButton", in: app, timeout: 10))
        _ = requireElement("readerCommentaryQuickSelector", in: app, timeout: 10)
        XCTAssertTrue(requireElement(epubRowID, in: app, timeout: 10).exists)
        let myDocumentRow = requireElement(myDocumentRowID, in: app, timeout: 10)
        tapElementReliably(myDocumentRow)

        waitForReaderRenderedContentState(
            containing: "category=general_book;module=UITESTDOC;book=UI Test Document;chapter=none;key=intro",
            in: app,
            timeout: 20
        )
        waitForVisibleReaderText(
            containing: "My Document page one.",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies the reader and workspace callers reach their distinct Android label behaviors.

     The reader opens Label Assignment from the real WebView bookmark label, loads the saved
     primary, changes it, commits through Back, and reopens the same route to prove persistence.
     Label Manager then starts with independent workspace state, enables auto-assignment for that
     label, commits, and reopens to prove the workspace primary and automatic assignment persist.
     The existing bookmark-list workflow separately owns `.bookmarkList` routing and remains
     selected; this journey does not use detailed accessibility exports.
     */
    func testReaderPrimaryAndWorkspaceAutoAssignmentPersistThroughActualRoutes() {
        let app = makeApp(enablesDetailedAccessibilityExports: false)
        app.launch()
        let bookChooser = requireElement("bookChooserButton", in: app, timeout: 20)
        XCTAssertTrue(
            waitForUITestCondition("real KJV header publication", timeout: 20) {
                guard let value = bookChooser.value as? String else { return false }
                return value.localizedCaseInsensitiveContains("Genesis 1") &&
                    value.localizedCaseInsensitiveContains("King James Version (1769)")
            },
            "Expected the installed KJV title, rather than the reader's pre-publication fallback."
        )
        waitForVisibleReaderText(
            containing: "God created the heaven and the earth",
            in: app
        )

        func waitForControl(
            _ control: XCUIElement,
            value expectedValue: String,
            description: String
        ) {
            XCTAssertTrue(
                waitForUITestCondition(description, timeout: 10) {
                    control.exists && control.value as? String == expectedValue
                },
                "Expected \(description) to publish value '\(expectedValue)'."
            )
        }

        func openReaderAssignmentFromVerse() -> XCUIElement {
            let webView = app.webViews.firstMatch
            let verse = webView.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "In the beginning")
            ).firstMatch
            XCTAssertTrue(verse.waitForExistence(timeout: 20))
            tapElementReliably(verse, timeout: 10)
            let label = webView.staticTexts["UI Test Seed"].firstMatch
            XCTAssertTrue(
                label.waitForExistence(timeout: 10),
                "Expected the real reader bookmark modal to expose its seeded label."
            )
            tapElementReliably(label, timeout: 10)
            let editLabels = webView.buttons["Select or edit labels…"].firstMatch
            XCTAssertTrue(
                editLabels.waitForExistence(timeout: 10),
                "Expected Android's visible bookmark-label actions menu."
            )
            tapElementReliably(editLabels, timeout: 10)
            return requireElement("labelAssignmentScreen", in: app, timeout: 10)
        }

        func reopenReaderAssignmentFromVisibleActions() -> XCUIElement {
            let editLabels = app.webViews.firstMatch.buttons["Select or edit labels…"].firstMatch
            XCTAssertTrue(
                editLabels.waitForExistence(timeout: 10),
                "Expected the reader bookmark actions to remain visible after assignment refresh."
            )
            tapElementReliably(editLabels, timeout: 10)
            return requireElement("labelAssignmentScreen", in: app, timeout: 10)
        }

        func closeToReader(screen: XCUIElement, backIdentifier: String) {
            tapElementReliably(requireElement(backIdentifier, in: app, timeout: 10), timeout: 10)
            XCTAssertTrue(
                waitForUITestCondition("Return from Manage Labels to reader", timeout: 20) {
                    !screen.exists && self.waitForReaderShellReady(in: app, timeout: 0)
                },
                "Expected the real app-bar Back action to commit and return to the reader."
            )
        }

        var assignmentScreen = openReaderAssignmentFromVerse()
        let assignmentPrefix = "manageLabelsAssignment::"
        let seedAssignment = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                assignmentPrefix,
                "UI Test Seed"
            )
        ).firstMatch
        let otherAssignment = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                assignmentPrefix,
                "Other Label"
            )
        ).firstMatch
        XCTAssertTrue(seedAssignment.waitForExistence(timeout: 10))
        XCTAssertTrue(otherAssignment.waitForExistence(timeout: 10))
        waitForControl(seedAssignment, value: "on", description: "reader seed-label assignment")
        waitForControl(otherAssignment, value: "Off", description: "reader other-label assignment")

        guard seedAssignment.identifier.hasPrefix(assignmentPrefix),
              otherAssignment.identifier.hasPrefix(assignmentPrefix) else {
            XCTFail("Expected assignment controls to carry their exact persisted label IDs.")
            return
        }
        let seedLabelID = String(seedAssignment.identifier.dropFirst(assignmentPrefix.count))
        let otherLabelID = String(otherAssignment.identifier.dropFirst(assignmentPrefix.count))
        let seedPrimaryID = "manageLabelsPrimary::\(seedLabelID)"
        let otherPrimaryID = "manageLabelsPrimary::\(otherLabelID)"
        let seedPrimary = app.buttons[seedPrimaryID].firstMatch
        XCTAssertTrue(seedPrimary.waitForExistence(timeout: 10))
        waitForControl(seedPrimary, value: "on", description: "reader persisted primary label")
        XCTAssertFalse(app.buttons[otherPrimaryID].firstMatch.exists)

        tapElementReliably(otherAssignment, timeout: 10)
        waitForControl(otherAssignment, value: "on", description: "reader added label")
        let otherPrimary = app.buttons[otherPrimaryID].firstMatch
        XCTAssertTrue(otherPrimary.waitForExistence(timeout: 10))
        waitForControl(otherPrimary, value: "Off", description: "reader non-primary added label")
        tapElementReliably(otherPrimary, timeout: 10)
        waitForControl(otherPrimary, value: "on", description: "reader selected primary label")
        waitForControl(seedPrimary, value: "Off", description: "reader displaced primary label")
        closeToReader(screen: assignmentScreen, backIdentifier: "labelAssignmentAppBarBackButton")

        assignmentScreen = reopenReaderAssignmentFromVisibleActions()
        waitForControl(
            app.buttons[otherPrimaryID].firstMatch,
            value: "on",
            description: "reopened reader primary label"
        )
        waitForControl(
            app.buttons[seedPrimaryID].firstMatch,
            value: "Off",
            description: "reopened reader non-primary label"
        )
        closeToReader(screen: assignmentScreen, backIdentifier: "labelAssignmentAppBarBackButton")

        var managerScreen = openLabelManager(in: app)
        let otherAutoAssign = app.buttons["manageLabelsAutoAssign::\(otherLabelID)"].firstMatch
        XCTAssertTrue(otherAutoAssign.waitForExistence(timeout: 10))
        waitForControl(
            otherAutoAssign,
            value: "Off",
            description: "independent initial workspace auto-assignment"
        )
        XCTAssertFalse(app.buttons[otherPrimaryID].firstMatch.exists)
        tapElementReliably(otherAutoAssign, timeout: 10)
        waitForControl(otherAutoAssign, value: "on", description: "workspace auto-assignment")
        let workspacePrimary = app.buttons[otherPrimaryID].firstMatch
        XCTAssertTrue(workspacePrimary.waitForExistence(timeout: 10))
        waitForControl(workspacePrimary, value: "on", description: "workspace auto-assignment primary")
        closeToReader(screen: managerScreen, backIdentifier: "labelManagerAppBarBackButton")

        managerScreen = openLabelManager(in: app)
        waitForControl(
            app.buttons["manageLabelsAutoAssign::\(otherLabelID)"].firstMatch,
            value: "on",
            description: "reopened workspace auto-assignment"
        )
        waitForControl(
            app.buttons[otherPrimaryID].firstMatch,
            value: "on",
            description: "reopened workspace auto-assignment primary"
        )
        closeToReader(screen: managerScreen, backIdentifier: "labelManagerAppBarBackButton")
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
     *   - opens Label Assignment for the seeded Genesis bookmark, verifies assignment state,
     *     returns through the child and Bookmark app bars to the reader, then reopens Bookmarks
     *   - holds the seeded row again, closes contextual selection, and ordinary-taps that same row
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
     *   - fails if Label Assignment cannot return to the same Bookmark activity, or if Bookmark
     *     Back cannot return to the reader and reopen the production route
     *   - fails if tapping the seeded bookmark row does not drive the reader back to `Genesis 1`
     *   - fails if the shared popup label selector does not filter the list like Android or the
     *     app-owned activity cannot return to the reader
     *
     * Label creation, favourite toggles, Bible label removal, and generic bookmark assignment are
     * covered by `LabelAssignmentMutationTests` in the app-host-free package lane.
    */
    func testBookmarkSelectionNavigatesReaderToSeededReference() {
        runBookmarkSelectionNavigationWorkflow(enablesDetailedAccessibilityExports: true)
    }

    /**
     Runs the identical seeded navigation workflow without Bookmark's detailed diagnostic export.

     This temporary causal comparison preserves every production action and visible assertion from
     `testBookmarkSelectionNavigatesReaderToSeededReference`; only the launch-time diagnostic-export
     policy differs. The seeded label's real assignment checkbox remains the route-success boundary.
     */
    func testBookmarkSelectionNavigatesReaderWithoutDetailedAccessibilityExports() {
        runBookmarkSelectionNavigationWorkflow(enablesDetailedAccessibilityExports: false)
    }

    /** Executes the shared production workflow with one explicit diagnostic-export policy. */
    private func runBookmarkSelectionNavigationWorkflow(
        enablesDetailedAccessibilityExports: Bool
    ) {
        let app = makeApp(
            enablesDetailedAccessibilityExports: enablesDetailedAccessibilityExports
        )
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
        let selectedSearchMode = requireElement(
            "studyPadSelectorSearchMode::0",
            in: app,
            timeout: 10
        )
        let searchModePopup = requireElement(
            "studyPadSelectorSearchModeSurface",
            in: app,
            timeout: 10
        )
        tapElementReliably(selectedSearchMode, timeout: 10)
        waitForElementToDisappear(selectedSearchMode, timeout: 10)
        waitForElementToDisappear(searchModePopup, timeout: 10)

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
        let helpTitle = app.staticTexts["Help"].firstMatch
        let helpBody = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Study pads are designed")
        ).firstMatch
        let helpOKButton = requireElement("androidHelpDialogOKButton", in: app, timeout: 10)
        XCTAssertTrue(
            helpTitle.waitForExistence(timeout: 10) && helpBody.waitForExistence(timeout: 10),
            "Expected the canonical visible Study Pads Help title and body."
        )
        XCTAssertFalse(app.sheets.firstMatch.exists, "Study Pads Help must remain app-owned.")
        tapElementReliably(helpOKButton, timeout: 10)
        waitForElementToDisappear(helpOKButton, timeout: 10)
        waitForElementToDisappear(helpBody, timeout: 10)

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
        waitForVisibleReaderText(containing: "there went a man of the house of Levi", in: app)

        XCTAssertTrue(openBookmarkList(in: app).exists)
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
        tapElementReliably(
            requireElement("bookmarkListAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            waitForBookmarkListDismissal(in: app, timeout: 20),
            "Expected Bookmark Back after the assignment child round trip to return to the reader."
        )
        XCTAssertTrue(
            openBookmarkList(in: app, timeout: 20).exists,
            "Expected the same reader instance to reopen Bookmarks after the child and parent Back actions."
        )

        let heldBookmarkRow = requireBookmarkRow("Genesis_1_1", in: app, timeout: 10)
        heldBookmarkRow.press(forDuration: 0.7)
        let contextualAction = requireElement("bookmarkListAssignLabelsButton", in: app, timeout: 10)
        tapElementReliably(
            requireElement("bookmarkListAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForElementToDisappear(contextualAction, timeout: 10)
        XCTAssertTrue(
            requireElement("bookmarkListSortButton", in: app, timeout: 10).exists,
            "Contextual Close must restore the ordinary Bookmark activity before the next row tap."
        )

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
        waitForVisibleReaderText(containing: "In the beginning", in: app)

        XCTAssertTrue(openBookmarkList(in: app).exists)
        selectBookmarkListLabelFilter("UI_Test_Seed", in: app, timeout: 10)
        XCTAssertTrue(requireBookmarkRow("Genesis_1_1", in: app, timeout: 10).exists)
        let excludedBookmark = app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch
        waitForElementToDisappear(excludedBookmark, timeout: 10)
        XCTAssertFalse(
            excludedBookmark.exists,
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
     *   - taps the verse once in the fixture's already active reader pane
     */
    func testReaderNoteEditorKeepsSoftwareKeyboardAndPersistsTypedNote() {
        let app = makeApp()
        let verseTextFragment = "In the beginning"
        let editorLabel = "My Notes note editor for Genesis 1:1"
        let sentinel = "Issue390NoteSentinel"

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
        openMyNotesFromReader(in: app)
        waitForVisibleReaderText(containing: sentinel, in: app, timeout: 20)
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
     *     My Notes note text and the fixture-backed shared Bible action to render
     * - Failure modes:
     *   - fails if the chooser route, pseudo-document row, actual rendered note, or Android-equivalent
     *     Bible action is unavailable from the production reader path
     */
    func testMyNotesPseudoDocumentOpensFromChooser() {
        let app = makeApp()
        let originalNote = "Creation begins with God."
        app.launch()

        openMyNotesFromReader(in: app)
        waitForVisibleReaderText(containing: originalNote, in: app, timeout: 20)
        _ = requireElement("readerBibleToolbarButton", in: app, timeout: 10)
        let myNotesHeaderScreenshot = XCTAttachment(screenshot: app.screenshot())
        myNotesHeaderScreenshot.name = "My Notes document actions"
        myNotesHeaderScreenshot.lifetime = .keepAlways
        add(myNotesHeaderScreenshot)
    }

}
