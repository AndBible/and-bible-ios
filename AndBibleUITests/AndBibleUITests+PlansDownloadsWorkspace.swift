import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies the drawer Reading Plan route opens as an app-owned destination and can advance a day.
     *
     * Android opens reading plans through app-owned activities, not a platform sheet. This workflow
     * protects the presentation route before exercising the existing plan-start and progress path.
     *
     * - Side effects:
     *   - opens Reading Plans from the drawer
     *   - starts the first available plan and marks the first day read
     * - Failure modes:
     *   - fails if Reading Plans regresses to sheet presentation
     *   - fails if the plan cannot be started or advanced through the visible controls
     */
    func testReadingPlansStartPlanAndAdvanceDay() {
        let app = makeApp()
        app.launch()

        _ = openReadingPlans(in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=readingPlans", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Drawer Reading Plan should use reader destination back chrome, not iOS sheet Done chrome."
        )
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
            openDownloadsOverflowItem("moduleBrowserRepositoriesButton", in: app, timeout: 15),
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
