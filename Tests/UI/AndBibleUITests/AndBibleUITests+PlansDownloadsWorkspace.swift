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
     * Android opens reading plans through app-owned activities, not a platform sheet. Package tests
     * own algorithmic plan generation, imported-plan parsing, and persistence contracts; this smoke
     * keeps one visible route through the production reader menu and user controls.
     *
     * - Side effects:
     *   - launches the reader shell with empty reading-plan state
     *   - opens Reading Plans from the drawer and verifies Android-style destination chrome
     *   - starts the first Android-parity built-in template and marks the first day read
     *   - returns to the plan list, deletes the active plan, then opens the import picker path
     * - Failure modes:
     *   - fails if Reading Plans regresses to sheet presentation
     *   - fails if the list state does not publish the expected active-plan counts
     *   - fails if the built-in template cannot be started from the picker
     *   - fails if the daily reading route cannot advance through the visible controls
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
        waitForAvailablePlansState(containing: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        waitForReadingPlanListState(containing: "active=1", in: app, timeout: 15)
        waitForReadingPlanListState(containing: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanActivePlanLink", in: app, timeout: 15), timeout: 10)
        let currentDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertEqual(currentDay.value as? String, "1")

        tapElementReliably(
            requireElement("dailyReadingMarkAsReadButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForElementValue("dailyReadingCurrentDayLabel", toEqual: "2", in: app, timeout: 20)

        let dailyReadingBackButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            dailyReadingBackButton.waitForExistence(timeout: 10),
            "Expected Daily Reading to expose NavigationStack back chrome to the Reading Plans list."
        )
        tapElementReliably(dailyReadingBackButton, timeout: 10)
        XCTAssertTrue(requireElement("readingPlanListScreen", in: app, timeout: 20).exists)
        waitForReadingPlanListState(containing: "active=1", in: app, timeout: 10)
        waitForReadingPlanListState(containing: builtInPlanToken, in: app, timeout: 10)

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
     *   - taps the real Downloads overflow toolbar button until the requested row appears
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
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let item = resolvedElement(itemIdentifier, in: app),
               elementHasUsableFrame(item) {
                return item
            }

            let overflowButton = unresolvedElement("moduleBrowserOverflowButton", in: app)
            if !tapElementIfPossible(overflowButton, timeout: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }

            if let item = resolvedElement(itemIdentifier, in: app),
               elementHasUsableFrame(item) {
                return item
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

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
     Verifies workspace creation and Downloads repository management from reader-owned routes.

     Repository add, replace, delete, and reset persistence runs in `RepositorySourceManagerTests`
     because that is the SwordKit-owned source-management contract. This UI smoke intentionally
     stays at the visible route boundary while still proving the real reader menu opens Downloads
     and Android's Downloads overflow exposes Custom repositories. Workspace graph persistence is
     package-covered by `WorkspaceWindowStoreTests`; the visible smoke only proves the selector
     prompt can create a workspace and return control to the reader shell before another route opens.
     *
     * - Side effects:
     *   - launches the reader shell and opens the workspace selector from the reader menu
     *   - creates one workspace from the selector-owned prompt and verifies reader-shell return
     *   - opens Downloads from the real reader menu
     *   - opens the repository manager from Android's Downloads overflow menu
     * - Failure modes:
     *   - fails if the workspace selector, create alert, or reader-shell return regresses
     *   - fails if the downloads browser or repository manager never appears
     *   - fails if the repository manager loses the visible add-source affordance
     */
    func testDownloadsRepositoryManagerOpensFromOverflow() {
        let app = makeApp()
        let createdName = "W1"
        app.launch()

        XCTAssertTrue(openWorkspaceSelector(in: app).exists)
        _ = openWorkspaceCreatePrompt(in: app, timeout: 10)
        typeWorkspaceNamePromptText(createdName, in: app, timeout: 15)
        tapElementReliably(requireElement("workspaceNamePromptConfirmButton", in: app, timeout: 10), timeout: 10)

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected creating a workspace to return to the reader shell before opening Downloads."
        )

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
     test launches the real route with a deterministic cached catalog, starts one installable row, and
     asserts that only the row status changes while the visible row sequence stays unchanged.
     Failure means the app has regressed to re-sorting the visible list from transient download state.
     */
    func testDownloadsInstallKeepsRowOrderVisibleDuringActivity() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        waitForResolvedSemanticState(
            named: "moduleBrowserStateExport",
            timeout: 20,
            valueProvider: { self.semanticStateExportValue("moduleBrowserStateExport", in: app) },
            success: { value in
                value.contains("visible=3;")
                    && value.contains("order=KJV|UITESTDLREC|UITESTDLWARN;")
                    && value.contains("UITESTDLWARN:installable")
            },
            failureDescription: { "Expected deterministic Downloads smoke catalog before install, got '\($0)'." }
        )

        tapElementReliably(
            requireElement("moduleBrowserRow::UITESTDLWARN", in: app, timeout: 10),
            timeout: 10
        )

        waitForResolvedSemanticState(
            named: "moduleBrowserStateExport",
            timeout: 20,
            valueProvider: { self.semanticStateExportValue("moduleBrowserStateExport", in: app) },
            success: { value in
                value.contains("visible=3;")
                    && value.contains("order=KJV|UITESTDLREC|UITESTDLWARN;")
                    && value.contains("UITESTDLWARN:beingInstalled")
            },
            failureDescription: { "Expected tapped Downloads row to update in place, got '\($0)'." }
        )
    }
}
