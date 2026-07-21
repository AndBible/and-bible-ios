import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies the drawer Reading Plan route can start, advance, delete, and import plans.
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
     *   - returns to the plan list, deletes the active plan, then opens the import picker path
     * - Failure modes:
     *   - fails if Reading Plans regresses to sheet presentation
     *   - fails if the list state does not publish the expected active-plan counts
     *   - fails if the built-in catalog diverges from Android's bundled templates
     *   - fails if the built-in template does not navigate from picker selection to Daily Reading
     *   - fails if the daily reading route cannot complete today's due reading through the visible controls
     *   - fails if the row-level delete action is missing or does not remove the active plan
     *   - fails if the custom import affordance does not request file-picker presentation
     */
    func testReadingPlansRouteStartAdvanceDeleteAndImportAffordanceFlow() {
        let builtInPlanCode = "y1ot1nt1_OTthenNT"
        let builtInPlanToken = readingPlanStateToken(builtInPlanCode)
        let app = makeApp()
        app.launch()

        _ = openReadingPlans(in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=readingPlans", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer Reading Plan should use reader destination back chrome, not iOS sheet Done chrome."
        )
        waitForReadingPlanListState(containing: "active=0", in: app, timeout: 10)

        openAvailableReadingPlans(in: app, timeout: 10)
        waitForAvailablePlansState(containing: "templates=7", in: app, timeout: 10)
        waitForAvailablePlansState(containing: builtInPlanToken, in: app, timeout: 10)

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
            requireElement("readingPlanListScreen", in: app, timeout: 20).exists,
            "Android closes Daily Reading when the next plan day is not yet due."
        )
        waitForReadingPlanListState(containing: "active=1", in: app, timeout: 10)
        waitForReadingPlanListState(containing: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(
            requireElement("readingPlanActivePlanLink", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 20).exists)
        let advancedDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertTrue(
            waitForUITestCondition("persisted reading-plan day two", timeout: 10) {
                advancedDay.value as? String == "2"
            },
            "Done must persist Android's next current day before dismissing Daily Reading."
        )
        let dailyReadingBackButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(dailyReadingBackButton.waitForExistence(timeout: 10))
        tapElementReliably(dailyReadingBackButton, timeout: 10)
        XCTAssertTrue(requireElement("readingPlanListScreen", in: app, timeout: 20).exists)

        let activePlan = requireElement("readingPlanActivePlanLink", in: app, timeout: 10)
        deleteReadingPlan(activePlan, planCode: builtInPlanCode, in: app, timeout: 10)
        waitForReadingPlanListState(containing: "active=0", in: app, timeout: 10)
        waitForReadingPlanListState(notContaining: builtInPlanToken, in: app, timeout: 10)

        openAvailableReadingPlans(in: app, timeout: 10)
        tapElementReliably(revealAvailablePlansImportButton(in: app, timeout: 10), timeout: 10)
        waitForAvailablePlansState(containing: "importPickerPresented=true", in: app, timeout: 20)
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
        tapAlertButton("Cancel", in: app, timeout: 10)

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
        tapAlertButton("OK", in: app, timeout: 10)

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
