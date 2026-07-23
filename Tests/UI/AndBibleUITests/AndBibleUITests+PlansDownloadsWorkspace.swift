import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies the drawer Reading Plan route can select, advance, reset, and import plans.
     *
     * Android opens the selector through `DailyReading`, returns the chosen plan code, and then
     * immediately shows that plan's daily reading. Package tests own bundled catalog parity, custom
     * parsing, and persistence details; this smoke keeps one visible route through the production
     * reader menu and user controls.
     *
     * - Side effects:
     *   - launches the reader shell with empty reading-plan state
     *   - opens Reading Plans from the drawer and verifies Android-style destination chrome
     *   - starts the first Android-parity built-in template, completes day one, and reopens day two
     *   - resets through Daily Reading's overflow, then opens Import from that same source menu
     * - Failure modes:
     *   - fails if Reading Plans regresses to sheet presentation
     *   - fails if the coordinator state does not publish the expected selected-plan lifecycle
     *   - fails if the built-in catalog diverges from Android's bundled templates
     *   - fails if the built-in template does not navigate from picker selection to Daily Reading
     *   - fails if the daily reading route cannot complete today's due reading through the visible controls
     *   - fails if Reset does not use Android's overflow/confirmation/finish lifecycle
     *   - fails if Import is incorrectly placed in the selector or does not request ZIP selection
     */
    func testReadingPlansRouteSelectAdvanceResetAndImportAffordanceFlow() {
        let builtInPlanCode = "y1ot1nt1_OTthenNT"
        let builtInPlanToken = readingPlanStateToken(builtInPlanCode)
        let app = makeApp()
        app.launch()

        _ = openReadingPlans(in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=readingPlans", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer Reading Plan should use reader destination back chrome, not iOS sheet Done chrome."
        )
        waitForReadingPlanListState(containing: "total=0", in: app, timeout: 10)
        waitForReadingPlanListState(containing: "showAvailablePlans=true", in: app, timeout: 10)

        openAvailableReadingPlans(in: app, timeout: 10)
        waitForReadingPlanListState(containing: "templates=7", in: app, timeout: 10)
        waitForReadingPlanListState(containing: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        XCTAssertTrue(
            requireElement("dailyReadingScreen", in: app, timeout: 20).exists,
            "Choosing a reading-plan template should continue directly to Daily Reading."
        )
        let currentDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertEqual(currentDay.value as? String, "1")

        tapElementReliably(
            requireElement("dailyReadingStatusToggle::1", in: app, timeout: 10),
            timeout: 10
        )
        let doneButton = requireElement("dailyReadingDoneButton", in: app, timeout: 10)
        XCTAssertTrue(
            waitForUITestCondition("Daily Reading Done button enabled", timeout: 10) {
                doneButton.isEnabled
            },
            "Android enables Done only after every reading for the day is marked read."
        )
        tapElementReliably(doneButton, timeout: 10)
        XCTAssertTrue(
            waitForUITestCondition("Daily Reading closes to reader", timeout: 20) {
                self.readerRenderedContentStateValue(in: app)?.contains(
                    "readerDestination=none"
                ) == true
            },
            "Android finishes Daily Reading when the next plan day is not yet due."
        )

        _ = openReadingPlans(in: app, timeout: 20)
        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 20).exists)
        let advancedDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertTrue(
            waitForUITestCondition("persisted reading-plan day two", timeout: 10) {
                advancedDay.value as? String == "2"
            },
            "Done must persist Android's next current day before dismissing Daily Reading."
        )
        tapElementReliably(
            openDailyReadingOverflowItem("dailyReadingResetPlanButton", in: app),
            timeout: 10
        )
        tapElementReliably(
            requireElement(
                "dailyReadingResetConfirmationDialogAction::yes",
                in: app,
                timeout: 10
            ),
            timeout: 10
        )
        XCTAssertTrue(
            waitForUITestCondition("Reset closes Daily Reading to reader", timeout: 20) {
                self.readerRenderedContentStateValue(in: app)?.contains(
                    "readerDestination=none"
                ) == true
            }
        )

        _ = openReadingPlans(in: app, timeout: 20)
        openAvailableReadingPlans(in: app, timeout: 10)
        waitForReadingPlanListState(containing: "total=0", in: app, timeout: 10)
        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 20).exists)

        tapElementReliably(
            openDailyReadingOverflowItem("readingPlanImportButton", in: app),
            timeout: 10
        )
        waitForReadingPlanListState(containing: "importPickerPresented=true", in: app, timeout: 20)
    }

    /**
     Opens Daily Reading's app-owned overflow and resolves one source menu command.

     - Parameters:
       - itemIdentifier: Stable identifier of the Android overflow row.
       - app: Running application currently showing Daily Reading.
       - timeout: Maximum time to open and resolve the popup.
       - file: XCTest failure attribution source.
       - line: XCTest failure attribution line.
     - Returns: Visible, usable popup command.
     - Side effects: Taps the real Daily Reading overflow trigger when necessary.
     - Failure modes: Records a focused failure if the trigger or command never becomes visible.
     */
    func openDailyReadingOverflowItem(
        _ itemIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if let item = resolvedElement(itemIdentifier, in: app),
           elementHasUsableFrame(item) {
            return item
        }

        let trigger = requireElement(
            "dailyReadingActionsMenuButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        tapElementReliably(trigger, timeout: timeout, file: file, line: line)

        var resolvedItem: XCUIElement?
        let didResolveItem = waitForUITestCondition(
            "Daily Reading overflow item '\(itemIdentifier)'",
            timeout: timeout
        ) {
            guard let item = self.resolvedElement(itemIdentifier, in: app),
                  self.elementHasUsableFrame(item)
            else {
                return false
            }
            resolvedItem = item
            return true
        }
        if didResolveItem, let resolvedItem {
            return resolvedItem
        }

        let fallback = unresolvedElement(itemIdentifier, in: app)
        XCTAssertTrue(
            fallback.exists,
            "Expected Daily Reading overflow item '\(itemIdentifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallback
    }

    /**
     Opens the Downloads overflow popup and resolves one visible action row.
     *
     * Android exposes repository management from the Downloads overflow menu. The iOS route mirrors
     * that with a custom SwiftUI popup, so tests must verify the popup is actually open before tapping
     * rows instead of treating a toolbar tap as enough synchronization.
     *
     * - Parameters:
     *   - itemIdentifier: Accessibility identifier of the overflow row that should become visible.
     *   - app: Running application currently showing the Downloads screen.
     *   - timeout: Maximum number of seconds to keep opening and polling the popup.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved overflow row once it exposes a usable frame.
     * - Side effects:
     *   - taps the real Downloads overflow toolbar button and waits for the requested row through
     *     XCTest-backed candidate waits
     * - Failure modes:
     *   - records an XCTest failure when the toolbar button or requested row never becomes visible
     */
    func openDownloadsOverflowItem(
        _ itemIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let itemCandidates = [
            unresolvedElement(itemIdentifier, in: app),
            app.buttons[itemIdentifier].firstMatch,
            app.cells[itemIdentifier].firstMatch,
            app.otherElements[itemIdentifier].firstMatch,
        ]
        let deadline = Date().addingTimeInterval(timeout)
        if let item = firstVisibleCandidate(from: itemCandidates, waitTimeout: min(1, timeout)) {
            return item
        }

        for attempt in 0..<2 {
            let overflowButton = unresolvedElement("moduleBrowserOverflowButton", in: app)
            let tapTimeout = min(1, max(0.1, deadline.timeIntervalSinceNow))
            _ = tapElementIfPossible(overflowButton, timeout: tapTimeout)

            let remaining = max(0, deadline.timeIntervalSinceNow)
            guard remaining > 0 else {
                break
            }
            let waitTimeout = attempt == 0 ? min(2, remaining) : remaining
            if let item = firstVisibleCandidate(from: itemCandidates, waitTimeout: waitTimeout) {
                return item
            }
        }

        let item = unresolvedElement(itemIdentifier, in: app)
        XCTAssertTrue(
            elementHasUsableFrame(item),
            "Expected Downloads overflow item '\(itemIdentifier)' to become visible within \(timeout) seconds.",
            file: file,
            line: line
        )
        return item
    }

    /**
     Verifies Choose Document and Download Documents render as the same full Android activity family.

     This is the live regression counterpart to the source-level ownership matrix. It protects the
     reported failure where Choose Document became a large-type, History-like constrained modal by
     requiring the real reader route to expose the shared app bar and all three inline
     `DocumentSelectionBase` filters, then transitions through its real overflow action and compares
     their geometry with Download Documents.

     - Side effects:
       - launches the reader, opens Choose Document, opens its app-owned overflow popup, and follows
         the Download Documents action on the same reader destination stack
     - Failure modes:
       - fails if either activity loses its app-owned Back/overflow controls or shared filters
       - fails if Choose Document is hosted as a History dialog or native iOS sheet
       - fails if the shared filter controls no longer occupy equivalent activity geometry
     */
    func testDocumentChooserMatchesDownloadDocumentsActivityStructure() {
        let app = makeApp()
        app.launch()

        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerDestination=chooseDocument",
            in: app,
            timeout: 20
        )

        let chooserBack = requireElement("modulePickerBackButton", in: app, timeout: 20)
        let chooserOverflow = requireElement("modulePickerOverflowButton", in: app, timeout: 10)
        let chooserLanguage = requireElement("modulePickerLanguageFilter", in: app, timeout: 10)
        let chooserSearch = requireElement("modulePickerSearchField", in: app, timeout: 10)
        let chooserCategory = requireElement("modulePickerCategoryFilter", in: app, timeout: 10)
        let chooserFrames = (
            back: chooserBack.frame,
            language: chooserLanguage.frame,
            search: chooserSearch.frame,
            category: chooserCategory.frame
        )

        XCTAssertFalse(
            unresolvedElement("androidHistoryDialog", in: app).exists,
            "Choose Document must not reuse the constrained History dialog host."
        )
        XCTAssertFalse(
            app.sheets.firstMatch.exists,
            "Choose Document must remain an app-owned activity rather than a native iOS sheet."
        )
        XCTAssertLessThan(
            chooserFrames.search.midY,
            app.frame.midY,
            "The shared document filter strip must remain in the activity header, not a centered modal."
        )

        tapElementReliably(chooserOverflow, timeout: 10)
        tapElementReliably(
            requireElement("modulePickerDownloadsButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForReaderRenderedContentState(
            containing: "readerDestination=downloads",
            in: app,
            timeout: 20
        )

        let downloadsBack = requireElement("moduleBrowserBackButton", in: app, timeout: 20)
        _ = requireElement("moduleBrowserOverflowButton", in: app, timeout: 10)
        let downloadsLanguage = requireElement("moduleBrowserLanguageFilter", in: app, timeout: 10)
        let downloadsSearch = requireElement("moduleBrowserSearchField", in: app, timeout: 10)
        let downloadsCategory = requireElement("moduleBrowserCategoryFilter", in: app, timeout: 10)

        XCTAssertEqual(chooserFrames.back.height, downloadsBack.frame.height, accuracy: 2)
        XCTAssertEqual(chooserFrames.language.minY, downloadsLanguage.frame.minY, accuracy: 2)
        XCTAssertEqual(chooserFrames.search.minY, downloadsSearch.frame.minY, accuracy: 2)
        XCTAssertEqual(chooserFrames.search.height, downloadsSearch.frame.height, accuracy: 2)
        XCTAssertEqual(chooserFrames.category.minY, downloadsCategory.frame.minY, accuracy: 2)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    /**
     Verifies Downloads repository management from the reader-owned route.

     Repository add, replace, delete, and reset persistence runs in `RepositorySourceManagerTests`
     because that is the SwordKit-owned source-management contract. This UI smoke intentionally
     stays at the visible route boundary while still proving the real reader menu opens Downloads
     and Android's Downloads overflow exposes Custom repositories. Workspace graph persistence and
     prompt behavior stay covered by workspace-specific package and UI contracts instead of being
     coupled to this Downloads route smoke.
     *
     * - Side effects:
     *   - launches the reader shell
     *   - opens Downloads from the real reader menu
     *   - opens the repository manager from Android's Downloads overflow menu
     * - Failure modes:
     *   - fails if the downloads browser or repository manager never appears
     *   - fails if the repository manager loses the visible add-source affordance
     */
    func testDownloadsRepositoryManagerOpensFromOverflow() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        tapElementReliably(
            openDownloadsOverflowItem("moduleBrowserRepositoriesButton", in: app, timeout: 15),
            timeout: 15
        )

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 20).exists)
        XCTAssertTrue(requireElement("repositoryManagerAddButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies Downloads keeps Android's visible row order stable while an install row changes status.

     Android's Downloads list updates the tapped row in place after `downloadDocument(...)` and does
     not re-run the install-status sort until the user rebuilds the filtered document list. This smoke
     test launches the real route with a deterministic cached catalog, cancels the first confirmation
     to prove Android's dialog gate is honored, then confirms one installable row whose UI-test
     install is held in progress. It asserts that only the row status changes while the visible row
     sequence stays unchanged.
     Failure means the app has regressed to re-sorting the visible list from transient download state.
     */
    func testDownloadsInstallKeepsRowOrderVisibleDuringActivity() {
        let warningRowIdentifier = "moduleBrowserRow::UITest Downloads--UITESTDLWARN"
        let app = makeApp(heldDownloadModules: ["UITESTDLWARN"])
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        waitForResolvedSemanticState(
            named: "moduleBrowserStateExport",
            timeout: 20,
            valueProvider: { self.semanticStateExportValue("moduleBrowserStateExport", in: app) },
            success: { value in
                value.contains("visible=3;")
                    && value.contains("refreshing=false;")
                    && value.contains("order=KJV|UITESTDLREC|UITESTDLWARN;")
                    && value.contains("UITESTDLWARN:installable")
            },
            failureDescription: { "Expected deterministic Downloads smoke catalog before install, got '\($0)'." }
        )

        tapElementReliably(
            requireElement(warningRowIdentifier, in: app, timeout: 10),
            timeout: 10
        )
        tapAppOwnedDialogAction(
            "androidModulePickerDecisionDialogAction::cancel",
            dialogIdentifier: "androidModulePickerDecisionDialog",
            expectedTitle: "Cancel",
            in: app,
            timeout: 10
        )

        waitForResolvedSemanticState(
            named: "moduleBrowserStateExport",
            timeout: 20,
            valueProvider: { self.semanticStateExportValue("moduleBrowserStateExport", in: app) },
            success: { value in
                value.contains("visible=3;")
                    && value.contains("refreshing=false;")
                    && value.contains("order=KJV|UITESTDLREC|UITESTDLWARN;")
                    && value.contains("UITESTDLWARN:installable")
            },
            failureDescription: { "Expected cancelling Downloads confirmation to keep row installable, got '\($0)'." }
        )

        tapElementReliably(
            requireElement(warningRowIdentifier, in: app, timeout: 10),
            timeout: 10
        )
        tapAppOwnedDialogAction(
            "androidModulePickerDecisionDialogAction::install",
            dialogIdentifier: "androidModulePickerDecisionDialog",
            expectedTitle: "OK",
            in: app,
            timeout: 10
        )

        waitForResolvedSemanticState(
            named: "moduleBrowserStateExport",
            timeout: 20,
            valueProvider: { self.semanticStateExportValue("moduleBrowserStateExport", in: app) },
            success: { value in
                value.contains("visible=3;")
                    && value.contains("refreshing=false;")
                    && value.contains("order=KJV|UITESTDLREC|UITESTDLWARN;")
                    && value.contains("UITESTDLWARN:beingInstalled")
            },
            failureDescription: { "Expected tapped Downloads row to update in place, got '\($0)'." }
        )
    }
}
