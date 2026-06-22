import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func testReadingPlansStartPlanAndAdvanceDay() {
        let app = makeApp()
        app.launch()

        _ = openReadingPlans(in: app, timeout: 20)
        tapElementReliably(requireElement("readingPlanStartButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("availablePlansScreen", in: app, timeout: 10).exists)
        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        tapElementReliably(requireElement("readingPlanActivePlanLink", in: app, timeout: 15), timeout: 10)
        let currentDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertEqual(currentDay.value as? String, "1")

        tapElementReliably(
            requireElement("dailyReadingMarkAsReadButton", in: app, timeout: 10),
            timeout: 10
        )

        waitForElementValue("dailyReadingCurrentDayLabel", toEqual: "2", in: app, timeout: 20)
    }

    /**
     Verifies the visible reading-plan list can start and delete a built-in plan and reach the
     custom import path from the available-plan picker.
     *
     * - Side effects:
     *   - launches the reader shell with empty reading-plan state
     *   - opens the real Reading Plans list, starts the first Android-parity built-in template,
     *     deletes it from the active-plan row swipe action, then opens the import picker path
     * - Failure modes:
     *   - fails if the list state does not publish the expected active-plan counts
     *   - fails if the built-in template cannot be started from the picker
     *   - fails if the row-level delete action is missing or does not remove the active plan
     *   - fails if the custom import affordance does not request file-picker presentation
     */
    func testReadingPlanListStartDeleteAndImportAffordanceFlow() {
        let builtInPlanCode = "y1ot1nt1_OTthenNT"
        let builtInPlanToken = readingPlanStateToken(builtInPlanCode)
        let app = makeApp()
        app.launch()

        _ = openReadingPlans(in: app, timeout: 20)
        waitForReadingPlanListState(containing: "active=0", in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanStartButton", in: app, timeout: 10), timeout: 10)
        _ = requireElement("availablePlansScreen", in: app, timeout: 10)
        waitForAvailablePlansState(containing: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        waitForReadingPlanListState(containing: "active=1", in: app, timeout: 15)
        waitForReadingPlanListState(containing: builtInPlanToken, in: app, timeout: 10)

        let activePlan = requireElement("readingPlanActivePlanLink", in: app, timeout: 10)
        deleteReadingPlan(activePlan, planCode: builtInPlanCode, in: app, timeout: 10)
        waitForReadingPlanListState(containing: "active=0", in: app, timeout: 10)
        waitForReadingPlanListState(notContaining: builtInPlanToken, in: app, timeout: 10)

        tapElementReliably(requireElement("readingPlanStartButton", in: app, timeout: 10), timeout: 10)
        _ = requireElement("availablePlansScreen", in: app, timeout: 10)
        tapElementReliably(revealAvailablePlansImportButton(in: app, timeout: 10), timeout: 10)
        waitForAvailablePlansState(containing: "importPickerPresented=true", in: app, timeout: 20)
    }

    /**
     Verifies that the downloads browser can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu and pushes the downloads browser
     * - Failure modes:
     *   - fails if the downloads action is missing from the reader menu
     *   - fails if the downloads browser screen does not render after navigation completes
     */
    func testDownloadsScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
    }

    /**
     Verifies that the downloads browser can open the repository manager and dismiss the add-source
     sheet back to the repository list.
     *
     * - Side effects:
     *   - launches directly into Downloads
     *   - opens the repository manager from Android's Downloads overflow menu
     *   - opens the add-source sheet and cancels it
     * - Failure modes:
     *   - fails if the downloads browser or repository manager never appears
     *   - fails if the add-source sheet cannot be presented from the repository manager
     *   - fails if cancelling the add-source sheet does not return to the repository manager
     */
    func testDownloadsRepositoryManagerAddSourceCancelFlow() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        tapElementReliably(
            requireElement("moduleBrowserOverflowButton", in: app, timeout: 10),
            timeout: 15
        )
        tapElementReliably(
            requireElement("moduleBrowserRepositoriesButton", in: app, timeout: 10),
            timeout: 15
        )

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 20).exists)
        tapElementReliably(
            requireElement("repositoryManagerAddButton", in: app, timeout: 10),
            timeout: 10
        )

        XCTAssertTrue(requireElement("repositoryManagerAddSourceScreen", in: app, timeout: 20).exists)
        tapElementReliably(
            requireElement("repositoryManagerAddSourceCancelButton", in: app, timeout: 10),
            timeout: 10
        )

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 20).exists)
    }

    /**
     Verifies that the workspace selector can create a workspace, make it active, and switch back.
     *
     * Rename, clone, and delete semantics are covered by `WorkspaceStore` unit tests because the
     * production UI exposes those actions through long-press context menus that are pathologically
     * slow under hosted XCTest.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the workspace selector from the reader
     *     menu
     *   - creates one workspace, verifies it becomes active, then switches back to the original
     *     active workspace
     * - Failure modes:
     *   - fails if the workspace selector never appears
     *   - fails if the create alert, workspace rows, or active-workspace state do not update as
     *     expected
     */
    func testWorkspaceSelectorCreateAndSwitchFlow() {
        let app = makeApp()
        let createdName = "W1"
        app.launch()

        XCTAssertTrue(openWorkspaceSelector(in: app).exists)
        let originalActiveWorkspaceName = requireActiveWorkspaceRow(in: app, timeout: 10).label

        _ = openWorkspaceCreatePrompt(in: app, timeout: 10)
        let workspaceNameField = requireWorkspaceNamePromptField(in: app, timeout: 10)
        typePromptText(
            createdName,
            into: workspaceNameField,
            in: app,
            timeout: 15,
            accessibilityIdentifier: "workspaceNamePromptTextField"
        )
        tapElementReliably(requireElement("workspaceNamePromptConfirmButton", in: app, timeout: 10), timeout: 10)

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected creating a workspace to return to the reader shell."
        )

        _ = openWorkspaceSelector(in: app)
        _ = requireWorkspaceRow(named: createdName, in: app, timeout: 15)
        XCTAssertEqual(
            requireActiveWorkspaceRow(in: app, timeout: 10).label,
            createdName,
            "Expected the new workspace to become active after creation."
        )

        tapElementReliably(
            requireWorkspaceRow(named: originalActiveWorkspaceName, in: app, timeout: 10),
            timeout: 10
        )
        dismissWorkspaceSelectorIfStillPresented(in: app, timeout: 20)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected switching workspaces to return to the reader shell."
        )
    }

    /**
     Verifies that the bookmark list can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu and pushes the bookmark list
     * - Failure modes:
     *   - fails if the bookmarks action is missing from the reader menu
     *   - fails if the bookmark list screen does not render after navigation completes
     */
}
