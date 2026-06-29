import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func openWorkspaceSelector(in app: XCUIApplication) -> XCUIElement {
        tapReaderAction("readerOpenWorkspacesAction", in: app)
        return requireElement("workspaceSelectorAddButton", in: app, timeout: 15)
    }

    /**
     Opens the workspace-name prompt from the workspace selector.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for prompt controls to appear.
     * - Returns: The first visible prompt control or prompt root.
     * - Side effects:
     *   - taps the production Add toolbar button in the workspace selector
     *   - waits for prompt-specific controls instead of relying on one container type
     * - Failure modes:
     *   - records an XCTest failure if the prompt never becomes visible
     */
    @discardableResult
    func openWorkspaceCreatePrompt(
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> XCUIElement {
        tapElementReliably(
            requireElement("workspaceSelectorAddButton", in: app, timeout: timeout),
            timeout: timeout
        )
        if let promptElement = waitForAnyElement(
            [
                "workspaceNamePromptScreen",
                "workspaceNamePromptTextField",
                "workspaceNamePromptConfirmButton",
                "workspaceNamePromptCancelButton",
            ],
            in: app,
            timeout: timeout
        ) {
            return promptElement
        }

        let promptField = unresolvedElement("workspaceNamePromptTextField", in: app)
        XCTAssertTrue(
            promptField.exists,
            "Expected the workspace name prompt to appear within \(timeout) seconds."
        )
        return promptField
    }

    /**
     Resolves the workspace-name prompt field using prompt-scoped fallbacks when SwiftUI does not
     export the text-field accessibility identifier reliably.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the prompt field to appear.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The prompt text field used to enter the workspace name.
     * - Side effects:
     *   - polls the custom prompt and system modal surfaces for one owned text field
     * - Failure modes:
     *   - records an XCTest failure when no prompt text field becomes available in time
     */
    func requireWorkspaceNamePromptField(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let promptField = firstExistingElement(
                workspaceNamePromptTextFieldCandidates(in: app),
                timeout: 0.2
            ) {
                return promptField
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallbackField = unresolvedElement("workspaceNamePromptTextField", in: app)
        XCTAssertTrue(
            fallbackField.exists,
            "Expected the workspace name field to appear within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallbackField
    }

    /**
     Opens Label Manager through the reader overflow admin route.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Manager screen element.
     * - Side effects:
     *   - opens the reader overflow menu and presents the Label Manager screen
     * - Failure modes:
     *   - fails when the Label Manager screen never appears
     */
    func openLabelManager(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenLabelSettingsAction",
            destinationIdentifier: "labelManagerScreen",
            readinessIdentifiers: ["labelManagerAddButton"],
            in: app,
            timeout: 20
        )
    }

    /**
     Opens Label Assignment from the bookmark list.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Assignment screen element.
     * - Side effects:
     *   - opens the bookmark list and taps the seeded bookmark's edit-labels affordance
     * - Failure modes:
     *   - fails when the Label Assignment screen never appears
     */
    func openLabelAssignment(in app: XCUIApplication) -> XCUIElement {
        return openLabelAssignmentFromBookmarkList(in: app)
    }

    /**
     Opens Label Assignment from the actual bookmark-list flow.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Assignment screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes the bookmark list
     *   - taps the seeded bookmark row's real edit-label affordance
     * - Failure modes:
     *   - fails when the bookmark list or seeded bookmark edit-labels action never appears
     */
    func openLabelAssignmentFromBookmarkList(
        in app: XCUIApplication,
        referenceSegment: String = "Genesis_1_1"
    ) -> XCUIElement {
        _ = openBookmarkList(in: app)
        tapElementReliably(
            requireElement("bookmarkListEditLabelsButton::\(referenceSegment)", in: app, timeout: 10),
            timeout: 10
        )
        return requireElement("labelAssignmentScreen", in: app, timeout: 10)
    }

    /**
     Opens the bookmark list from the reader shell.
     *
     * - Parameter app: Running application whose reader shell should present the bookmark list.
     * - Returns: The root accessibility-identified bookmark list element.
     * - Side effects:
     *   - opens the reader drawer and pushes the bookmark list
     * - Failure modes:
     *   - fails if the reader menu button, bookmark action, or bookmark list root never appears
     */
    @discardableResult
    func openBookmarkList(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenBookmarksAction",
            destinationIdentifier: "bookmarkListScreen",
            readinessIdentifiers: ["bookmarkListDoneButton", "bookmarkListSortMenu"],
            in: app,
            timeout: timeout
        )
    }

    /**
     Dismisses the bookmark list and reopens it from the reader shell.
     *
     * - Parameter app: Running application whose bookmark surface should be reopened.
     * - Side effects:
     *   - dismisses the bookmark surface through the real Done button, navigation-stack back
     *     affordance, or legacy sheet drag fallback when available
     *   - opens the bookmark list again through the standard reader navigation path
     * - Failure modes:
     *   - fails when the bookmark list cannot be dismissed or reopened
     */
    func reopenBookmarkList(in app: XCUIApplication) {
        XCTAssertTrue(
            dismissBookmarkList(in: app, timeout: 20),
            "Expected bookmark list dismissal to return to the reader shell."
        )
        _ = openBookmarkList(in: app, timeout: 20)
    }

    /**
     Dismisses the bookmark-list surface from either the legacy sheet host or reader destination.

     - Parameters:
       - app: Running application whose bookmark list should close.
       - timeout: Maximum number of seconds to spend on close attempts.
       - file: Source file used for XCTest failure attribution.
       - line: Source line used for XCTest failure attribution.
     - Returns: `true` once the reader state export reports the shell is visible again.
     - Side effects:
       - taps the sheet `Done` button when present
       - taps the reader-destination back affordance when the bookmark list is hosted as an
         Android-parity app route
       - taps the navigation-stack back button for drawer-owned destination hosting
       - falls back to a top-edge drag for the older sheet route
     - Failure modes:
       - returns `false` when no close path dismisses the list before the timeout
     */
    func dismissBookmarkList(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if waitForBookmarkListDismissal(in: app, timeout: min(0.5, max(0, deadline.timeIntervalSinceNow))) {
                return true
            }

            let remaining = max(0.1, deadline.timeIntervalSinceNow)
            let doneButton = app.buttons["bookmarkListDoneButton"].firstMatch
            if tapElementIfPossible(doneButton, timeout: min(1, remaining)) {
                continue
            }

            let destinationBackButton = app.buttons["readerDestinationBackButton"].firstMatch
            if tapElementIfPossible(destinationBackButton, timeout: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                continue
            }

            dismissKeyboardIfPresent(in: app)
            let refreshedDoneButton = app.buttons["bookmarkListDoneButton"].firstMatch
            if tapElementIfPossible(refreshedDoneButton, timeout: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                continue
            }
            let refreshedDestinationBackButton = app.buttons["readerDestinationBackButton"].firstMatch
            if tapElementIfPossible(refreshedDestinationBackButton, timeout: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                continue
            }

            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            if tapElementIfPossible(backButton, timeout: min(1, max(0.1, deadline.timeIntervalSinceNow))) {
                continue
            }

            let sheet = unresolvedElement("bookmarkListScreen", in: app)
            if elementHasUsableFrame(sheet) {
                dismissSheetByDraggingDown(sheet, file: file, line: line)
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        } while Date() < deadline

        return waitForBookmarkListDismissal(in: app, timeout: 0.5)
    }

    /**
     Waits until bookmark-list dismissal leaves the reader chrome available again.
     *
     * Reader-destination dismissal is proven by the compact reader state export reporting that
     * reader-owned sheets and destinations are closed. SwiftUI can leave stale bookmark-list
     * accessibility nodes queryable briefly after a navigation pop, so this helper treats the reader
     * state export as authoritative and uses bookmark-list sentinels only as a fallback when compact
     * reader state is unavailable.
     *
     * - Parameters:
     *   - app: Running application whose bookmark list is being dismissed.
     *   - timeout: Maximum number of seconds to wait for reader chrome to return.
     * - Returns: `true` when the reader shell is ready, or when fallback chrome is present and the
     *   bookmark-list surface is no longer visible.
     * - Side effects:
     *   - polls reader and bookmark-list accessibility state while SwiftUI transitions settle
     * - Failure modes:
     *   - returns `false` when neither reader state nor fallback chrome proves dismissal before timeout
     */
    func waitForBookmarkListDismissal(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if waitForReaderShellReady(in: app, timeout: 0) {
                return true
            }
            if readerDocumentHeaderStateValue(in: app) != nil,
               !bookmarkListSurfaceIsVisible(in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if waitForReaderShellReady(in: app, timeout: 0.5) {
            return true
        }
        let bookmarkListHidden = !bookmarkListSurfaceIsVisible(in: app)
        return readerDocumentHeaderStateValue(in: app) != nil && bookmarkListHidden
    }

    /// Returns whether the bookmark-list surface still exposes one of its lightweight sentinels.
    func bookmarkListSurfaceIsVisible(in app: XCUIApplication) -> Bool {
        let doneButton = app.buttons["bookmarkListDoneButton"].firstMatch
        if doneButton.exists {
            return true
        }
        return app.staticTexts["bookmarkListStateExport"].firstMatch.exists
    }

    /**
     Activates one bookmark-list filter chip and waits for the exported bookmark-list state to
     report the matching selected label.
     *
     * - Parameters:
     *   - labelToken: Sanitized label token exported in the chip identifier and screen state.
     *   - app: Running application whose bookmark list should change filters.
     *   - timeout: Maximum number of seconds to wait for the selected-label state update.
     * - Side effects:
     *   - taps the production filter chip and waits for the bookmark-list screen state to settle
     * - Failure modes:
     *   - fails if the chip is unavailable or the bookmark-list state never reflects the selection
     */
    func selectBookmarkListFilterChip(
        _ labelToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        tapElementReliably(
            requireElement("bookmarkListFilterChip::\(labelToken)", in: app, timeout: timeout),
            timeout: timeout
        )
        waitForBookmarkListState(containing: "selectedLabel=\(labelToken)", in: app, timeout: timeout)
    }

    /**
     Waits for the bookmark-list screen accessibility state to contain one token.
     *
     * - Parameters:
     *   - token: State fragment expected from the exported bookmark-list accessibility value.
     *   - app: Running application whose bookmark list should reach the requested state.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - polls the bookmark-list screen accessibility export until the requested token appears
     * - Failure modes:
     *   - records an XCTest failure if the bookmark-list state never contains the token
     */
    func waitForBookmarkListState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "bookmarkListStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedBookmarkListStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected element 'bookmarkListStateExport' to contain token '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            }
        )
    }

    /**
     Waits for the bookmark-list screen accessibility state to stop containing one token.
     *
     * - Parameters:
     *   - token: State fragment that should disappear from the exported bookmark-list value.
     *   - app: Running application whose bookmark list should drop the requested token.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - polls the bookmark-list screen accessibility export until the requested token disappears
     * - Failure modes:
     *   - records an XCTest failure if the bookmark-list state keeps reporting the token
     */
    func waitForBookmarkListState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "bookmarkListStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedBookmarkListStateValue(in: app) },
            success: { !$0.contains(token) },
            missingCountsAsSuccess: true,
            failureDescription: { _ in
                "Expected element 'bookmarkListStateExport' to stop containing '\(token)' within \(timeout) seconds."
            }
        )
    }

    /**
     Returns one bookmark-row token as serialized by the bookmark-list accessibility state.
     *
     * - Parameter referenceToken: Sanitized row reference token, such as `Genesis_1_1`.
     * - Returns: Bookmark-list row token wrapped in delimiters for exact containment checks.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func bookmarkListRowStateToken(_ referenceToken: String) -> String {
        "|\(referenceToken)|"
    }

    /// Waits for the Reading Plans list accessibility state to contain one token.
    func waitForReadingPlanListState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "readingPlanListStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedReadingPlanListStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected element 'readingPlanListStateExport' to contain token '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            }
        )
    }

    /// Waits for the Reading Plans list accessibility state to stop containing one token.
    func waitForReadingPlanListState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "readingPlanListStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedReadingPlanListStateValue(in: app) },
            success: { !$0.contains(token) },
            missingCountsAsSuccess: true,
            failureDescription: { _ in
                "Expected element 'readingPlanListStateExport' to stop containing '\(token)' within \(timeout) seconds."
            }
        )
    }

    /// Waits for the available-plan picker accessibility state to contain one token.
    func waitForAvailablePlansState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "availablePlansStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedAvailablePlansStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected element 'availablePlansStateExport' to contain token '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            }
        )
    }

    /// Returns one reading-plan token as serialized by the list accessibility state.
    func readingPlanStateToken(_ planCode: String) -> String {
        "|\(sanitizedReadingPlanStateToken(planCode))|"
    }

    /// Returns one reading-plan delete button identifier for the visible row swipe action.
    func readingPlanDeleteButtonIdentifier(for planCode: String) -> String {
        "readingPlanDeleteButton::\(sanitizedReadingPlanStateToken(planCode))"
    }

    /// Performs one Reading Plan row deletion through SwiftUI's swipe affordance.
    func deleteReadingPlan(
        _ row: XCUIElement,
        planCode: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let rowToken = readingPlanStateToken(planCode)
        let deleteIdentifier = readingPlanDeleteButtonIdentifier(for: planCode)

        row.swipeLeft()
        if waitForReadingPlanListStateToExclude(rowToken, in: app, timeout: 1) {
            return
        }

        if !waitForResolvedElementAppearance(deleteIdentifier, in: app, timeout: 2) {
            row.swipeLeft()
        }
        tapElementReliably(requireElement(deleteIdentifier, in: app, timeout: timeout), timeout: timeout)

        if !waitForReadingPlanListStateToExclude(rowToken, in: app, timeout: 3),
           let refreshedRow = resolvedElement("readingPlanActivePlanLink", in: app) {
            refreshedRow.swipeLeft()
            if waitForResolvedElementAppearance(deleteIdentifier, in: app, timeout: 2) {
                tapElementReliably(requireElement(deleteIdentifier, in: app, timeout: timeout), timeout: timeout)
            }
        }
    }

    /// Returns true when the Reading Plans state drops one token before the timeout.
    func waitForReadingPlanListStateToExclude(
        _ token: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentValue = resolvedReadingPlanListStateValue(in: app),
               !currentValue.contains(token) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return resolvedReadingPlanListStateValue(in: app)?.contains(token) == false
    }

    /// Sanitizes one reading-plan code to match the production accessibility export.
    func sanitizedReadingPlanStateToken(_ value: String) -> String {
        let mapped = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar)
            }
            return "_"
        }
        let collapsed = mapped.joined().replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Sanitizes one label token to match the production accessibility export.
    func sanitizedLabelManagerStateToken(_ value: String) -> String {
        let replaced = value.replacingOccurrences(
            of: "[^A-Za-z0-9]+",
            with: "_",
            options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    /// Returns one label-row token as serialized by the Label Manager accessibility state.
    func labelManagerRowStateToken(_ labelName: String) -> String {
        "|\(sanitizedLabelManagerStateToken(labelName))|"
    }

    /// Waits for the Label Manager accessibility state to contain one token.
    func waitForLabelManagerState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "labelManagerStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedLabelManagerStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected element 'labelManagerStateExport' to contain token '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            }
        )
    }

    /// Waits for the Label Manager accessibility state to stop containing one token.
    func waitForLabelManagerState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "labelManagerStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedLabelManagerStateValue(in: app) },
            success: { !$0.contains(token) },
            missingCountsAsSuccess: true,
            failureDescription: { _ in
                "Expected element 'labelManagerStateExport' to stop containing '\(token)' within \(timeout) seconds."
            }
        )
    }

    /**
     Builds one row token for My Documents semantic state assertions.

     - Parameter value: Raw document initials or page key rendered by the My Documents UI.
     - Returns: Token formatted the same way as the `MyDocumentsListView` state export.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func myDocumentsRowStateToken(_ value: String) -> String {
        "|\(sanitizedLabelManagerStateToken(value))|"
    }

    /**
     Waits for the My Documents list state export to contain one expected token.

     - Parameters:
       - token: Serialized token expected in the list state.
       - app: Running application whose My Documents destination should publish the state.
       - timeout: Maximum number of seconds to wait before failing.
     - Side effects:
       - polls the compact accessibility state export instead of walking every visible row
     - Failure modes:
       - records an XCTest failure when the expected token never appears
     */
    func waitForMyDocumentsListState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "myDocumentsListStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedMyDocumentsListStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected element 'myDocumentsListStateExport' to contain token '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            }
        )
    }

    /**
     Waits for the My Document pages state export to contain one expected token.

     - Parameters:
       - token: Serialized token expected in the page-list state.
       - app: Running application whose page-list destination should publish the state.
       - timeout: Maximum number of seconds to wait before failing.
     - Side effects:
       - polls the compact accessibility state export instead of walking every visible row
     - Failure modes:
       - records an XCTest failure when the expected token never appears
     */
    func waitForMyDocumentPagesState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForResolvedSemanticState(
            named: "myDocumentPagesStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedMyDocumentPagesStateValue(in: app) },
            success: { $0.contains(token) },
            failureDescription: { finalValue in
                "Expected element 'myDocumentPagesStateExport' to contain token '\(token)' within \(timeout) seconds. Final value: '\(finalValue)'."
            }
        )
    }

    /**
     Waits for the exported bookmark-list state to report one specific visible row ordering.
     *
     * - Parameters:
     *   - orderedReferenceTokens: Sanitized bookmark reference tokens in the expected visible
     *     order, such as `["Matthew_3_1", "Exodus_2_1"]`.
     *   - app: Running application whose bookmark list should publish the requested row order.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - samples the bookmark-list accessibility export through the shared semantic-state waiter
     *     until all requested row tokens appear in the requested sequence
     * - Failure modes:
     *   - records an XCTest failure if the bookmark-list export never reaches the requested order
     */
    func waitForBookmarkListRows(
        toAppearInOrder orderedReferenceTokens: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let orderedTokens = orderedReferenceTokens.map(bookmarkListRowStateToken)
        waitForResolvedSemanticState(
            named: "bookmarkListStateExport",
            timeout: timeout,
            valueProvider: { self.resolvedBookmarkListStateValue(in: app) },
            success: { self.bookmarkListRowsAppearInOrder(orderedTokens, within: $0) },
            failureDescription: { finalState in
                "Expected bookmark-list rows \(orderedReferenceTokens) to appear in order within \(timeout) seconds; last state was '\(finalState)'."
            },
            file: file,
            line: line
        )
    }

    /// Returns whether the exported bookmark-list state contains the requested row tokens in order.
    func bookmarkListRowsAppearInOrder(_ orderedTokens: [String], within state: String) -> Bool {
        var searchRange = state.startIndex..<state.endIndex
        for token in orderedTokens {
            guard let tokenRange = state.range(of: token, range: searchRange) else {
                return false
            }
            searchRange = tokenRange.upperBound..<state.endIndex
        }
        return true
    }

    /**
     Opens History from the reader shell.
     *
     * - Parameter app: Running application whose reader shell should present History.
     * - Returns: The root accessibility-identified History screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes the History sheet
     * - Failure modes:
     *   - fails if the reader menu button, History action, or History screen root never appears
     */
    @discardableResult
    func openHistory(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenHistoryAction",
            destinationIdentifier: "historyScreen",
            readinessIdentifiers: ["historyDoneButton", "historyClearButton", "historyEmptyState"],
            in: app
        )
    }

    /**
     Opens Reading Plans from the reader shell.
     *
     * - Parameters:
     *   - app: Running application whose reader shell should present Reading Plans.
     *   - timeout: Maximum number of seconds to wait for the screen or one stable control.
     * - Returns: The first resolved Reading Plans root or readiness control.
     * - Side effects:
     *   - opens the reader navigation drawer and activates the production Reading Plans action
     * - Failure modes:
     *   - fails if neither the screen root nor one stable Reading Plans control appears
     */
    @discardableResult
    func openReadingPlans(
        in app: XCUIApplication,
        timeout: TimeInterval = 20
    ) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenReadingPlansAction",
            destinationIdentifier: "readingPlanListScreen",
            readinessIdentifiers: ["readingPlanStartButton", "readingPlanActivePlanLink"],
            in: app,
            timeout: timeout
        )
    }

    /**
     Reveals and returns the custom reading-plan import button in the available-plan picker.
     *
     * - Parameters:
     *   - app: Running application whose available-plan picker should be visible.
     *   - timeout: Maximum time to scroll before recording a failure.
     * - Returns: The resolved import button.
     * - Side effects:
     *   - scrolls the picker list downward until the custom-plan section is visible
     * - Failure modes:
     *   - fails if the import button cannot be reached within the timeout
     */
    func revealAvailablePlansImportButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement {
        let scrollSurface = resolvedElement("availablePlansScreen", in: app)
            ?? unresolvedElement("availablePlansScreen", in: app)
        if elementHasUsableFrame(scrollSurface) {
            scrollSurface.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let directCandidates = [
                app.buttons["readingPlanImportButton"].firstMatch,
                app.collectionViews.buttons["readingPlanImportButton"].firstMatch,
                app.cells.buttons["readingPlanImportButton"].firstMatch,
                app.otherElements["readingPlanImportButton"].firstMatch,
            ]
            if let button = directCandidates.first(where: {
                $0.exists && waitForElementToBecomeHittable($0, timeout: 0.2)
            }) {
                return button
            }

            if elementHasUsableFrame(scrollSurface) {
                scrollSurface.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return requireElement("readingPlanImportButton", in: app, timeout: 1)
    }

    /**
     Opens Downloads from the reader shell.
     *
     * - Parameter app: Running application whose reader shell should present Downloads.
     * - Returns: The root accessibility-identified downloads screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes Downloads
     * - Failure modes:
     *   - fails if the reader menu button, downloads action, or downloads screen root never appears
     */
    func openDownloads(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenDownloadsAction",
            destinationIdentifier: "moduleBrowserScreen",
            readinessIdentifiers: ["moduleBrowserOverflowButton", "moduleBrowserSearchField"],
            in: app
        )
    }

    /**
     Opens Backup & Restore through the reader drawer administration route.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Backup & Restore screen element.
     * - Side effects:
     *   - opens the reader drawer and presents the Android-aligned Backup & Restore screen
     * - Failure modes:
     *   - fails when the Backup & Restore screen never appears
     */
    func openImportExport(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenImportExportAction",
            destinationIdentifier: "importExportScreen",
            readinessIdentifiers: ["backupWorkflowBackupButton", "backupWorkflowRestoreButton"],
            in: app,
            timeout: 20
        )
    }

    /**
     Opens Sync Settings through Settings navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Sync Settings screen element.
     * - Side effects:
     *   - opens Settings and pushes the Sync Settings screen
     * - Failure modes:
     *   - fails when the Sync Settings screen never appears
     */
    func openSyncSettings(in app: XCUIApplication) -> XCUIElement {
        openSettingsDestination(
            linkIdentifier: "settingsSyncLink",
            destinationIdentifier: "syncSettingsScreen",
            readinessIdentifiers: ["syncBackendPicker"],
            in: app,
            destinationTimeout: 20
        )
    }

    /**
     Opens one reader-overflow destination and waits for either its root or one of its stable
     ready controls.
     *
     * - Parameters:
     *   - actionIdentifier: Accessibility identifier of the reader action button.
     *   - destinationIdentifier: Accessibility identifier exported by the destination root.
     *   - readinessIdentifiers: Stable controls that prove the destination is usable even when the
     *     root view is materialized under a different XCUI type.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the destination to become usable.
     * - Returns: The resolved destination root when available, otherwise one ready control.
     * - Side effects:
     *   - opens the reader overflow menu and activates the requested production action
     * - Failure modes:
     *   - fails when neither the destination root nor any readiness control appears in time
     */
    @discardableResult
    func openReaderActionDestination(
        actionIdentifier: String,
        destinationIdentifier: String,
        readinessIdentifiers: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> XCUIElement {
        let destination = unresolvedElement(destinationIdentifier, in: app)
        let readinessCandidates = [destinationIdentifier] + readinessIdentifiers

        for attempt in 1...2 {
            tapReaderAction(actionIdentifier, in: app, timeout: timeout)

            if waitForAnyElement(readinessCandidates, in: app, timeout: timeout) != nil {
                if let resolvedDestination = resolvedElement(destinationIdentifier, in: app) {
                    return resolvedDestination
                }
                if destination.exists || destination.waitForExistence(timeout: 1) {
                    return destination
                }
                if let readyElement = waitForAnyElement(readinessIdentifiers, in: app, timeout: 1) {
                    return readyElement
                }
            }

            if attempt == 1 {
                if readerActionUsesNavigationDrawer(actionIdentifier) {
                    if let dismissArea = resolvedElement("readerNavigationDrawerDismissArea", in: app) {
                        tapElementReliably(dismissArea, timeout: min(5, timeout))
                    }
                } else if isReaderOverflowMenuLikelyVisible(in: app) {
                    dismissReaderOverflowMenu(
                        in: app,
                        timeout: min(8, timeout),
                        file: #filePath,
                        line: #line
                    )
                }
            }
        }

        XCTAssertTrue(
            destination.exists,
            "Expected destination '\(destinationIdentifier)' to appear after activating '\(actionIdentifier)'."
        )
        return destination
    }

    /**
     Opens Sync Settings directly from the reader action surface.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Sync Settings screen element.
     * - Side effects:
     *   - opens the reader overflow menu and presents Sync Settings directly from the reader shell
     * - Failure modes:
     *   - fails when the Sync Settings screen never appears
     */
    func openSyncSettingsFromReaderAction(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenSyncSettingsAction",
            destinationIdentifier: "syncSettingsScreen",
            readinessIdentifiers: ["syncBackendPicker"],
            in: app,
            timeout: 20
        )
    }

    /**
     Dismisses Sync Settings back to the reader shell.
     *
     * - Parameter app: Running application whose Sync sheet should be dismissed.
     * - Side effects:
     *   - taps the real Done button when the sheet exposes it
     *   - falls back to a top-edge drag gesture when the toolbar button is not present
     * - Failure modes:
     *   - fails when Sync Settings cannot be dismissed back to the reader shell
     */
    func dismissSyncSettings(in app: XCUIApplication) {
        let syncScreen = requireElement("syncSettingsScreen", in: app, timeout: 10)
        let doneButton = app.buttons["syncSettingsDoneButton"].firstMatch
        if doneButton.exists || doneButton.waitForExistence(timeout: 2) {
            tapElementReliably(doneButton, timeout: 10)
        } else {
            dismissSheetByDraggingDown(syncScreen)
        }
        waitForElementToDisappear(syncScreen, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected Sync Settings dismissal to return to the reader shell."
        )
    }

    /**
     Dismisses the integrated Settings destination back to the reader shell.
     *
     * - Parameter app: Running application whose Settings sheet should be dismissed.
     * - Side effects:
     *   - activates the navigation back button when Settings is pushed on the reader stack
     * - Failure modes:
     *   - fails when Settings cannot be dismissed back to the reader shell
     */
    func dismissSettings(in app: XCUIApplication) {
        let settingsForm = requireElement("settingsForm", in: app, timeout: 10)
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists {
            tapElementReliably(backButton, timeout: 10)
        } else {
            settingsForm.swipeRight()
        }
        waitForElementToDisappear(settingsForm, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected Settings dismissal to return to the reader shell."
        )
    }

    /**
     Switches Sync Settings to one backend through the production picker.
     *
     * - Parameters:
     *   - backendRawValue: Target backend raw value that should become active.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the switch control to resolve and become
     *     hittable.
     * - Side effects:
     *   - opens the backend picker and selects the requested production option
     * - Failure modes:
     *   - fails if no backend-switch control for the requested backend becomes available
     */
    func tapSyncBackend(
        _ backendRawValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) {
        let picker = requireElement("syncBackendPicker", in: app, timeout: timeout)
        tapElementReliably(picker, timeout: timeout)

        let backendLabel: String = switch backendRawValue {
        case "ICLOUD":
            "iCloud Sync"
        case "NEXT_CLOUD":
            "NextCloud"
        default:
            backendRawValue
        }

        let option = resolveSyncBackendOption(named: backendLabel, in: app, timeout: timeout)
        XCTAssertTrue(
            option.waitForExistence(timeout: timeout),
            "Expected sync backend option '\(backendLabel)' to exist."
        )
        tapElementReliably(option, timeout: timeout)
    }

    /**
     Resolves the first live picker option for one Sync backend label across the system control
     presentations SwiftUI may choose on CI.
     *
     * - Parameters:
     *   - backendLabel: User-visible backend option label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the first option candidate to appear.
     * - Returns: The first live picker-option candidate, preferring visible controls.
     * - Side effects:
     *   - probes multiple XCUI query families because SwiftUI `Picker` presentations may surface
     *     options as buttons, cells, static texts, or generic elements depending on platform state
     * - Failure modes:
     *   - returns an unresolved fallback query when no picker option becomes available before the
     *     timeout expires; the caller records the assertion failure
     */
    func resolveSyncBackendOption(
        named backendLabel: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement {
        let candidates: [XCUIElement] = [
            app.sheets.buttons[backendLabel].firstMatch,
            app.sheets.staticTexts[backendLabel].firstMatch,
            app.alerts.buttons[backendLabel].firstMatch,
            app.alerts.staticTexts[backendLabel].firstMatch,
            app.collectionViews.buttons[backendLabel].firstMatch,
            app.collectionViews.staticTexts[backendLabel].firstMatch,
            app.tables.buttons[backendLabel].firstMatch,
            app.tables.staticTexts[backendLabel].firstMatch,
            app.buttons[backendLabel].firstMatch,
            app.cells[backendLabel].firstMatch,
            app.staticTexts[backendLabel].firstMatch,
            app.otherElements[backendLabel].firstMatch,
        ]

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let visible = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                return visible
            }
            if let existing = candidates.first(where: { $0.exists }) {
                return existing
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return candidates[0]
    }

    /**
     Opens Colors through Android's All Text Options navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Colors screen element.
     * - Side effects:
     *   - opens the reader All Text Options screen
     *   - taps the Colors preference row and pushes the Colors screen
     * - Failure modes:
     *   - fails when the Colors screen never appears
     */
    func openColorSettings(in app: XCUIApplication) -> XCUIElement {
        _ = openAllTextOptions(in: app)
        let colorsLink = requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10)
        tapElementReliably(colorsLink, timeout: 10)
        return requireElement("colorSettingsScreen", in: app, timeout: 20)
    }

    /**
     Opens Text Display through Android's All Text Options route.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Text Display screen element.
     * - Side effects:
     *   - opens the reader All Text Options screen
     * - Failure modes:
     *   - fails when the Text Display screen never appears
     */
    func openTextDisplaySettings(in app: XCUIApplication) -> XCUIElement {
        openAllTextOptions(in: app)
    }

    /**
     Opens Android's All Text Options route from the reader overflow menu.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Text Display screen element.
     * - Side effects:
     *   - opens the reader overflow menu and activates the production All Text Options action
     *   - pushes the workspace-scoped Text Display screen onto the reader navigation stack
     * - Failure modes:
     *   - fails when the All Text Options action or Text Display screen never appears
     */
    func openAllTextOptions(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenTextOptionsAction",
            destinationIdentifier: "textDisplaySettingsScreen",
            readinessIdentifiers: [
                "textDisplayFontFamilyButton",
                "textDisplayJustifyTextToggleButton",
            ],
            in: app,
            timeout: 20
        )
    }

    /**
     Opens Settings from the reader shell action surface.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - resolves the stable reader action surface and pushes the Settings screen onto the
     *     navigation stack
     *   - dismisses the language restart alert only when it is already present after Settings loads
     * - Failure modes:
     *   - fails when the reader action surface or Settings action cannot be found
     *   - fails when the settings form never appears
     */
    func openSettings(in app: XCUIApplication) {
        for attempt in 1...2 {
            if !waitForReaderShellReady(in: app, timeout: 20) {
                if attempt == 1 {
                    continue
                }
                break
            }

            tapReaderAction("readerOpenSettingsAction", in: app, timeout: 20)
            if waitForSettingsReady(in: app, timeout: 20) {
                return
            }
            if attempt == 1 {
                continue
            }
        }
        XCTFail("Expected the Settings screen to become ready after opening it from the reader menu.")
    }

    /**
     Resolves one settings navigation control from the production Settings form.
     *
     * - Parameters:
     *   - identifier: Production settings-row identifier requested by the test.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The production settings row element.
     * - Side effects:
     *   - scans the current Settings viewport, then uses the production Settings search field as an
     *     early reveal path for title-backed rows
     *   - scrolls through the form while re-querying the live XCUI hierarchy when search cannot
     *     reveal the row
     *   - retries the production Settings search field as a final reveal path when CI scrolling cannot
     *     reliably bring an offscreen row into the accessibility hierarchy
     * - Failure modes:
     *   - records an XCTest failure if the production row never appears
     *
     * Broad `otherElements.containing(staticText:)` fallbacks are intentionally avoided here:
     * after the Android-style flat settings conversion they resolve to the full scroll surface
     * instead of the target row and produce false-positive container taps.
     */
    func requireSettingsNavigationControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let settingsForm = requireElement("settingsForm", in: app, timeout: timeout, file: file, line: line)
        let visibleTitle = settingsNavigationTitle(for: identifier)
        let deadline = Date().addingTimeInterval(timeout)
        func resolvedVisibleControl() -> XCUIElement? {
            var candidates = [
                settingsForm.links[identifier].firstMatch,
                settingsForm.buttons[identifier].firstMatch,
                settingsForm.cells[identifier].firstMatch,
                settingsForm.otherElements[identifier].firstMatch,
                app.links[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]

            if let visibleTitle {
                candidates.insert(contentsOf: [
                    settingsForm.links[visibleTitle].firstMatch,
                    settingsForm.buttons[visibleTitle].firstMatch,
                    settingsForm.cells[visibleTitle].firstMatch,
                    settingsForm.otherElements[visibleTitle].firstMatch,
                    settingsForm.cells.containing(.staticText, identifier: visibleTitle).firstMatch,
                    app.links[visibleTitle].firstMatch,
                    app.buttons[visibleTitle].firstMatch,
                    app.cells[visibleTitle].firstMatch,
                    app.otherElements[visibleTitle].firstMatch,
                    app.cells.containing(.staticText, identifier: visibleTitle).firstMatch,
                ], at: 0)
            }

            if let control = candidates.first(where: { $0.exists && waitForElementToBecomeHittable($0, timeout: 0.5) }) {
                return control
            }
            if let control = candidates.first(where: { $0.exists && isElementVisible($0, within: settingsForm) }) {
                return control
            }
            return nil
        }

        if let control = resolvedVisibleControl() {
            return control
        }
        if let control = resolveSettingsNavigationControlViaSearch(
            title: visibleTitle,
            settingsForm: settingsForm,
            app: app,
            timeout: min(max(timeout / 4, 3), 5),
            resolveControl: resolvedVisibleControl
        ) {
            return control
        }

        repeat {
            if let control = resolvedVisibleControl() {
                return control
            }
            guard settingsForm.exists, !settingsForm.frame.isEmpty else {
                break
            }

            settingsForm.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let recoveryDeadline = Date().addingTimeInterval(min(3, max(1, timeout / 4)))
        repeat {
            if let control = resolvedVisibleControl() {
                return control
            }
            guard settingsForm.exists, !settingsForm.frame.isEmpty else {
                break
            }

            settingsForm.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < recoveryDeadline

        if let control = resolveSettingsNavigationControlViaSearch(
            title: visibleTitle,
            settingsForm: settingsForm,
            app: app,
            timeout: min(max(timeout / 2, 5), 10),
            resolveControl: resolvedVisibleControl
        ) {
            return control
        }

        let control = unresolvedElement(identifier, in: app)
        if control.exists {
            return control
        }

        XCTAssertTrue(
            false,
            "Expected settings navigation control '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return control
    }

    /**
     Reveals one Settings navigation row by narrowing the production Settings search field.

     This is a fallback for hosted simulator runs where repeated `Form` swipes do not expose a
     lower Settings row before the XCTest timeout. It does not bypass production navigation; after
     search narrows the form, callers still tap the same native row element.
     *
     * - Parameters:
     *   - title: Visible English title used as the search query.
     *   - settingsForm: The live Settings form element.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend revealing and applying Settings search.
     *   - resolveControl: Existing row resolver scoped to the live Settings hierarchy.
     * - Returns: The resolved native row element, or `nil` when Settings search cannot reveal it.
     * - Side effects:
     *   - scrolls toward the top of the Settings form to reveal SwiftUI's searchable field
     *   - types the visible row title into Settings search
     * - Failure modes: This helper does not fail directly; the caller reports a single row-missing
     *   assertion if both direct scanning and search reveal fail.
     */
    func resolveSettingsNavigationControlViaSearch(
        title: String?,
        settingsForm: XCUIElement,
        app: XCUIApplication,
        timeout: TimeInterval,
        resolveControl: () -> XCUIElement?
    ) -> XCUIElement? {
        guard let title, !title.isEmpty else {
            return nil
        }

        let searchDeadline = Date().addingTimeInterval(timeout)
        var searchField: XCUIElement?
        repeat {
            if let field = settingsSearchFieldCandidates(in: app, settingsForm: settingsForm).first(
                where: { $0.exists && !$0.frame.isEmpty }
            ) {
                searchField = field
                break
            }

            guard settingsForm.exists, !settingsForm.frame.isEmpty else {
                return nil
            }
            settingsForm.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < searchDeadline

        guard let searchField else {
            return nil
        }

        replaceText(in: searchField, with: title, placeholderHints: ["Search"])

        let resultDeadline = Date().addingTimeInterval(min(max(timeout / 2, 3), 5))
        repeat {
            if let control = resolveControl() {
                return control
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < resultDeadline

        return nil
    }

    /**
     Returns Settings search-field candidates exposed by SwiftUI's `searchable` modifier.

     * - Parameters:
     *   - app: Running application under test.
     *   - settingsForm: The live Settings form element.
     * - Returns: Search and text-field candidates ordered from form-scoped to broader app queries.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func settingsSearchFieldCandidates(in app: XCUIApplication, settingsForm: XCUIElement) -> [XCUIElement] {
        [
            settingsForm.searchFields["Search"].firstMatch,
            settingsForm.textFields["Search"].firstMatch,
            app.navigationBars.searchFields["Search"].firstMatch,
            app.navigationBars.textFields["Search"].firstMatch,
            app.searchFields["Search"].firstMatch,
            app.textFields["Search"].firstMatch,
        ]
    }

    /**
     Maps one production Settings row identifier to the English title rendered in UI tests.
     *
     * `makeApp()` forces `AppleLanguages=(en)` and `AppleLocale=en_US`, so these labels are stable
     * across local and CI runs even when SwiftUI does not surface the row identifiers through the
     * underlying `Form` hierarchy.
     *
     * - Parameter identifier: Stable production identifier used by the test helpers.
     * - Returns: The visible English title for the row, or `nil` when the identifier has no
     *   title-based fallback.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func settingsNavigationTitle(for identifier: String) -> String? {
        switch identifier {
        case "settingsDownloadsLink":
            "Downloads"
        case "settingsRepositoriesLink":
            "Repositories"
        case "settingsImportExportLink":
            "Import & Export"
        case "settingsGlobalTextOptionsLink":
            "Global text options"
        case "settingsSyncLink":
            "Device synchronization"
        case "settingsReadingProgressLink":
            "Reading Progress Settings"
        case "settingsLabelsLink":
            "Labels"
        default:
            nil
        }
    }

    /**
     Opens one Settings destination and retries the row tap once when hosted simulators leave the
     view on the Settings form after a no-op navigation attempt.
     *
     * - Parameters:
     *   - linkIdentifier: Accessibility identifier of the Settings row to activate.
     *   - destinationIdentifier: Accessibility identifier of the destination root screen.
     *   - app: Running application under test.
     *   - rowTimeout: Maximum number of seconds to wait for the Settings row to resolve.
     *   - destinationTimeout: Maximum number of seconds to wait for the destination screen.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved destination root element.
     * - Side effects:
     *   - opens Settings, taps the requested row, and retries the tap in place when the first
     *     attempt leaves the UI on the Settings form
     * - Failure modes:
     *   - records an XCTest failure if the destination screen never appears after two attempts
     */
    func openSettingsDestination(
        linkIdentifier: String,
        destinationIdentifier: String,
        readinessIdentifiers: [String] = [],
        in app: XCUIApplication,
        rowTimeout: TimeInterval = 20,
        destinationTimeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        openSettings(in: app)
        let destination = unresolvedElement(destinationIdentifier, in: app)
        let readinessCandidates = [destinationIdentifier] + readinessIdentifiers

        for attempt in 0..<2 {
            tapSettingsElement(linkIdentifier, in: app, timeout: rowTimeout, file: file, line: line)
            if waitForAnyElement(
                readinessCandidates,
                in: app,
                timeout: destinationTimeout,
                file: file,
                line: line
            ) != nil {
                if let resolvedDestination = resolvedElement(destinationIdentifier, in: app) {
                    return resolvedDestination
                }
                if destination.exists || destination.waitForExistence(timeout: 1) {
                    return destination
                }
                if let readyElement = waitForAnyElement(
                    readinessIdentifiers,
                    in: app,
                    timeout: 1,
                    file: file,
                    line: line
                ) {
                    return readyElement
                }
            }

            if attempt == 0 {
                let settingsStillVisible =
                    waitForSettingsReady(in: app, timeout: 3) ||
                    unresolvedElement("settingsForm", in: app).exists
                if settingsStillVisible {
                    continue
                }
            }
        }

        XCTAssertTrue(
            destination.exists,
            "Expected Settings destination '\(destinationIdentifier)' to appear after activating '\(linkIdentifier)'.",
            file: file,
            line: line
        )
        return destination
    }

    /**
     Produces narrow typed fallback queries for identifiers that do not have an explicit override.
     *
     * This helper intentionally avoids `descendants(matching: .any)` because the broad descendant
     * scan was the recurring source of snapshot timeouts in CI. The suffix/prefix heuristics keep
     * the fallback path typed enough to remain stable while still covering new identifiers that
     * follow the test harness naming conventions.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve heuristically.
     *   - app: Running application under test.
     * - Returns: Ordered typed XCUI queries derived from the identifier naming convention.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
}
