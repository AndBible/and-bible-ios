import Foundation
import Darwin
import XCTest

extension AndBibleUITests {
    /**
     Types a workspace name into the selector-owned prompt without broad text-field queries.
     *
     * The workspace prompt autofocuses its text entry. Hosted XCTest can still stall when resolving
     * broad prompt containers for this prompt, so this helper treats the prompt controls as the
     * synchronization contract, types through the active application keyboard focus, and waits for
     * the prompt-owned confirm button to become enabled.
     *
     * - Parameters:
     *   - text: Workspace name to enter.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for prompt readiness and submit enablement.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - sends keyboard input through the running application
     * - Failure modes:
     *   - records an XCTest failure if the prompt is absent or the confirm button never enables
     */
    func typeWorkspaceNamePromptText(
        _ text: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let promptReady = waitForAnyElement(
            [
                "workspaceNamePromptConfirmButton",
                "workspaceNamePromptCancelButton",
            ],
            in: app,
            timeout: min(5, timeout)
        )
        XCTAssertNotNil(
            promptReady,
            "Expected the workspace name prompt before typing.",
            file: file,
            line: line
        )

        app.typeText(text)

        func confirmButtonIsEnabled() -> Bool {
            let candidates = workspaceNamePromptButtonCandidates(
                "workspaceNamePromptConfirmButton",
                in: app
            )
            return candidates.contains(where: { $0.exists && $0.isEnabled })
        }

        let predicate = NSPredicate(block: { _, _ in confirmButtonIsEnabled() })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for workspace name prompt confirm button"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result == .completed || confirmButtonIsEnabled() {
            return
        }

        XCTFail(
            "Expected the workspace name prompt confirm button to enable within \(timeout) seconds after typing.",
            file: file,
            line: line
        )
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
     Opens Label Assignment from the actual bookmark-list flow.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Assignment screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes the bookmark list when it is not already open
     *   - long-presses the seeded bookmark row to enter Android contextual action mode
     *   - taps the app-owned contextual Assign labels action
     * - Failure modes:
     *   - fails when the bookmark list, seeded bookmark row, contextual action, or assignment
     *     destination never appears
     */
    func openLabelAssignmentFromBookmarkList(
        in app: XCUIApplication,
        referenceSegment: String = "Genesis_1_1"
    ) -> XCUIElement {
        if resolvedElement("bookmarkListScreen", in: app) == nil {
            _ = openBookmarkList(in: app)
        }
        let bookmarkRow = requireBookmarkRow(referenceSegment, in: app, timeout: 10)
        bookmarkRow.press(forDuration: 0.7)
        tapElementReliably(
            requireElement("bookmarkListAssignLabelsButton", in: app, timeout: 10),
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
            readinessIdentifiers: [
                "bookmarkListAppBarBackButton",
                "bookmarkListLabelFilterButton",
                "bookmarkListSortButton",
            ],
            in: app,
            timeout: timeout
        )
    }

    /**
     Waits until bookmark-list dismissal leaves the reader chrome available again.
     *
     * Reader-destination dismissal is proven by the compact reader state export reporting that the
     * app-owned destination is closed. SwiftUI can leave stale bookmark-list
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
        let didDismiss = waitForUITestCondition(
            "Wait for bookmark list dismissal",
            timeout: max(0, timeout)
        ) {
            if self.waitForReaderShellReady(in: app, timeout: 0) {
                return true
            }
            if self.readerDocumentHeaderStateValue(in: app) != nil,
               !self.bookmarkListSurfaceIsVisible(in: app) {
                return true
            }
            return false
        }

        if didDismiss || waitForReaderShellReady(in: app, timeout: 0.5) {
            return true
        }
        let bookmarkListHidden = !bookmarkListSurfaceIsVisible(in: app)
        return readerDocumentHeaderStateValue(in: app) != nil && bookmarkListHidden
    }

    /**
     Returns whether the bookmark list is still the active reader destination.

     The reader state export is authoritative because SwiftUI can leave the bookmark-list state
     export queryable after the destination has already navigated to a document. The app-owned
     activity root and compact state export remain the fallback for hosts without reader state.

     - Parameter app: Running application whose bookmark-list presentation is being inspected.
     - Returns: `true` when the current reader state or fallback sentinels show the bookmark list.
     - Side effects: Reads accessibility state without activating controls.
     - Failure modes: Falls back to sentinel existence when reader state is unavailable.
     */
    func bookmarkListSurfaceIsVisible(in app: XCUIApplication) -> Bool {
        if let readerState = readerRenderedContentStateValue(in: app),
           readerState.contains("readerDestination=")
        {
            return readerState.contains("readerDestination=bookmarks")
        }

        return resolvedElement("bookmarkListScreen", in: app) != nil
            || app.staticTexts["bookmarkListStateExport"].firstMatch.exists
    }

    /**
     Selects one label through Android's bookmark spinner and shared app-owned popup menu.
     *
     * - Parameters:
     *   - labelToken: Sanitized label segment exported in the popup-row identifier and screen state.
     *   - app: Running application whose bookmark list should change filters.
     *   - timeout: Maximum number of seconds to wait for the selected-label state update.
     * - Side effects:
     *   - opens the production spinner-style selector
     *   - chooses the matching shared `AndroidPopupMenuRow`
     *   - waits for the bookmark-list screen state to settle
     * - Failure modes:
     *   - fails if the selector, popup option, or matching state transition is unavailable
     */
    func selectBookmarkListLabelFilter(
        _ labelToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        tapElementReliably(
            requireElement("bookmarkListLabelFilterButton", in: app, timeout: timeout),
            timeout: timeout
        )
        tapElementReliably(
            requireElement("bookmarkListFilterOption::\(labelToken)", in: app, timeout: timeout),
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

    /// Returns one reading-plan token as serialized by the list accessibility state.
    func readingPlanStateToken(_ planCode: String) -> String {
        "|\(sanitizedReadingPlanStateToken(planCode))|"
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
     Opens History from the reader shell's app-owned Android dialog.
     *
     * - Parameter app: Running application whose reader shell should present History.
     * - Returns: The root accessibility-identified Android History dialog.
     * - Side effects:
     *   - opens the reader navigation drawer and presents History's app-owned dialog
     * - Failure modes:
     *   - fails if the reader action or Android History dialog never appears
     */
    @discardableResult
    func openHistory(in app: XCUIApplication) -> XCUIElement {
        tapReaderAction("readerOpenHistoryAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "historyDialog=presented", in: app, timeout: 10)
        return requireElement("androidHistoryDialog", in: app, timeout: 10)
    }

    /**
     Opens Android's Read/Memory Progress activity equivalent from the reader drawer.

     - Parameter app: Running application whose reader shell owns the navigation destination.
     - Returns: The root accessibility-identified Reading Progress destination.
     - Side effects: Opens the reader navigation drawer and pushes Reading Progress onto the reader stack.
     - Failure modes: Fails if the drawer action, destination root, or destination presentation never appears.
     */
    @discardableResult
    func openReadingProgress(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenReadingProgressAction",
            destinationIdentifier: "readingProgressScreen",
            readinessIdentifiers: [],
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
            readinessIdentifiers: ["availablePlansScreen", "dailyReadingScreen"],
            in: app,
            timeout: timeout
        )
    }

    /**
     Opens Android's Reading Plan selector from its current activity route.
     *
     * Android enters the selector directly when no plan is selected. With a selected plan it opens
     * Daily Reading first, and tapping the plan title launches `ReadingPlanSelectorList`.
     *
     * - Parameters:
     *   - app: Running application currently showing the Reading Plans list.
     *   - timeout: Maximum time to activate the Start action and resolve the picker root.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first usable selector root or concrete selector control. SwiftUI may merge a
     *   noninteractive scroll-view identifier into its activity container, so route readiness is
     *   established from the app bar or a real template row when no standalone root is exposed.
     * - Side effects:
     *   - taps the production Daily Reading plan-title target only when the selector is not already
     *     visible
     * - Failure modes:
     *   - records an XCTest failure when neither the picker root nor a concrete app-owned selector
     *     control becomes visible
     */
    @discardableResult
    func openAvailableReadingPlans(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var lastListState = resolvedReadingPlanListStateValue(in: app) ?? "<missing>"

        func resolvedAvailablePlansSurface() -> XCUIElement? {
            for identifier in [
                "availablePlansScreen",
                "readingPlanSelectorAppBarBackButton",
                "readingPlanTemplateButton",
            ] {
                if let element = resolvedElement(identifier, in: app),
                   elementHasUsableFrame(element) {
                    return element
                }
            }
            return nil
        }

        repeat {
            if let selector = resolvedAvailablePlansSurface() {
                return selector
            }

            lastListState = resolvedReadingPlanListStateValue(in: app) ?? "<missing>"
            if let planTitle = resolvedElement("dailyReadingPlanTitleButton", in: app) {
                let remaining = max(0.1, deadline.timeIntervalSinceNow)
                _ = tapElementIfPossible(planTitle, timeout: min(1, remaining))
            }

            var resolvedPicker: XCUIElement?
            let didResolvePicker = waitForUITestCondition(
                "Wait for Available Plans picker",
                timeout: min(1, max(0, deadline.timeIntervalSinceNow))
            ) {
                if let selector = resolvedAvailablePlansSurface() {
                    resolvedPicker = selector
                    return true
                }
                lastListState = self.resolvedReadingPlanListStateValue(in: app) ?? "<missing>"
                return false
            }
            if didResolvePicker, let resolvedPicker {
                return resolvedPicker
            }
        } while Date() < deadline

        let fallback = unresolvedElement("readingPlanTemplateButton", in: app)
        XCTAssertTrue(
            fallback.exists,
            "Expected an app-owned Available Plans control to appear within \(timeout) seconds. Final Reading Plans state: '\(lastListState)'.",
            file: file,
            line: line
        )
        return fallback
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
     * - Parameter app: Running application whose app-owned Sync activity should be dismissed.
     * - Side effects:
     *   - activates the shared Android Up action in the Sync Settings top app bar
     * - Failure modes:
     *   - fails when the app-owned Up action is missing or cannot return to the reader shell
     */
    func dismissSyncSettings(in app: XCUIApplication) {
        let syncScreen = requireElement("syncSettingsScreen", in: app, timeout: 10)
        let backButton = requireElement("syncSettingsTopAppBarBackButton", in: app, timeout: 10)
        tapElementReliably(backButton, timeout: 10)
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

        func resolvedBackendOption() -> XCUIElement? {
            if let visible = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                return visible
            }
            return candidates.first(where: { $0.exists })
        }

        if let option = resolvedBackendOption() {
            return option
        }

        var resolvedOption: XCUIElement?
        _ = waitForUITestCondition(
            "Wait for Sync backend option \(backendLabel)",
            timeout: max(0, timeout)
        ) {
            if let option = resolvedBackendOption() {
                resolvedOption = option
                return true
            }
            return false
        }

        return resolvedOption ?? resolvedBackendOption() ?? candidates[0]
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
     * Exact production identifiers stay ahead of localized-title fallbacks. Navigation-button
     * queries precede unrelated element types, while identifiers ending in `Toggle` retain switch
     * priority; this avoids exhausting a hosted-runner timeout on known-wrong type queries. Title-
     * matched text fields are intentionally excluded: while Settings search is focused, its value
     * can equal a row title and XCTest would otherwise return the search editor instead of the
     * navigation row. Broad `otherElements.containing(staticText:)` fallbacks are also avoided
     * because the Android-style flat settings conversion makes them resolve to the full scroll
     * surface.
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
        func candidateElements() -> [XCUIElement] {
            let prefersToggle = identifier.hasSuffix("Toggle")
            var candidates = prefersToggle ? [
                settingsForm.switches[identifier].firstMatch,
                app.switches[identifier].firstMatch,
                settingsForm.buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
            ] : [
                settingsForm.buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                settingsForm.links[identifier].firstMatch,
                app.links[identifier].firstMatch,
                settingsForm.cells[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                settingsForm.otherElements[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                settingsForm.switches[identifier].firstMatch,
                app.switches[identifier].firstMatch,
                settingsForm.textFields[identifier].firstMatch,
                app.textFields[identifier].firstMatch,
            ]

            if prefersToggle {
                candidates.append(contentsOf: [
                    settingsForm.links[identifier].firstMatch,
                    app.links[identifier].firstMatch,
                    settingsForm.cells[identifier].firstMatch,
                    app.cells[identifier].firstMatch,
                    settingsForm.otherElements[identifier].firstMatch,
                    app.otherElements[identifier].firstMatch,
                    settingsForm.textFields[identifier].firstMatch,
                    app.textFields[identifier].firstMatch,
                ])
            }

            if let visibleTitle {
                let titleCandidates = prefersToggle ? [
                    settingsForm.switches[visibleTitle].firstMatch,
                    app.switches[visibleTitle].firstMatch,
                    settingsForm.buttons[visibleTitle].firstMatch,
                    app.buttons[visibleTitle].firstMatch,
                ] : [
                    settingsForm.buttons[visibleTitle].firstMatch,
                    app.buttons[visibleTitle].firstMatch,
                    settingsForm.links[visibleTitle].firstMatch,
                    app.links[visibleTitle].firstMatch,
                    settingsForm.cells[visibleTitle].firstMatch,
                    app.cells[visibleTitle].firstMatch,
                    settingsForm.otherElements[visibleTitle].firstMatch,
                    app.otherElements[visibleTitle].firstMatch,
                    settingsForm.switches[visibleTitle].firstMatch,
                    app.switches[visibleTitle].firstMatch,
                ]
                candidates.append(contentsOf: titleCandidates)
                candidates.append(contentsOf: [
                    settingsForm.cells.containing(.staticText, identifier: visibleTitle).firstMatch,
                    app.cells.containing(.staticText, identifier: visibleTitle).firstMatch,
                ])
            }

            return candidates
        }

        enum SettingsScrollDirection {
            case higherRows
            case lowerRows
        }

        func firstExistingControl() -> XCUIElement? {
            candidateElements().first(where: { $0.exists && elementHasUsableFrame($0) })
        }

        func immediateVisibleControl() -> XCUIElement? {
            let candidates = candidateElements()

            if let control = candidates.first(where: { isElementHittable($0) }) {
                return control
            }
            if let control = candidates.first(where: { $0.exists && isElementVisible($0, within: settingsForm) }) {
                return control
            }
            return nil
        }

        func resolvedVisibleControl() -> XCUIElement? {
            immediateVisibleControl()
        }

        func settingsScrollDirection(toward control: XCUIElement) -> SettingsScrollDirection? {
            guard elementHasUsableFrame(control), elementHasUsableFrame(settingsForm) else {
                return nil
            }

            let verticalInset = min(24, max(0, settingsForm.frame.height * 0.08))
            let visibleFrame = settingsForm.frame.insetBy(dx: 0, dy: verticalInset)
            if control.frame.minY >= visibleFrame.maxY {
                return .lowerRows
            }
            if control.frame.maxY <= visibleFrame.minY {
                return .higherRows
            }
            return nil
        }

        func scrollSettingsForm(toward direction: SettingsScrollDirection) {
            guard elementHasUsableFrame(settingsForm) else {
                return
            }

            let startOffset: CGVector
            let endOffset: CGVector
            switch direction {
            case .higherRows:
                startOffset = CGVector(dx: 0.5, dy: 0.28)
                endOffset = CGVector(dx: 0.5, dy: 0.82)
            case .lowerRows:
                startOffset = CGVector(dx: 0.5, dy: 0.82)
                endOffset = CGVector(dx: 0.5, dy: 0.28)
            }
            settingsForm.coordinate(withNormalizedOffset: startOffset).press(
                forDuration: 0.01,
                thenDragTo: settingsForm.coordinate(withNormalizedOffset: endOffset)
            )
        }

        func waitForControlAfterScroll(previousFrame: CGRect?) -> XCUIElement? {
            let predicate = NSPredicate { _, _ in
                if immediateVisibleControl() != nil {
                    return true
                }
                guard let previousFrame,
                      let control = firstExistingControl(),
                      self.elementHasUsableFrame(control)
                else {
                    return false
                }
                return abs(control.frame.midY - previousFrame.midY) > 2
            }
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
            expectation.expectationDescription = "Wait for Settings row reveal after scroll"
            _ = XCTWaiter().wait(for: [expectation], timeout: 0.6)
            return resolvedVisibleControl()
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

            let existingControl = firstExistingControl()
            let direction = existingControl.flatMap { settingsScrollDirection(toward: $0) } ?? .lowerRows
            let previousFrame = existingControl?.frame
            scrollSettingsForm(toward: direction)
            if let control = waitForControlAfterScroll(previousFrame: previousFrame) {
                return control
            }
        } while Date() < deadline

        let recoveryDeadline = Date().addingTimeInterval(min(3, max(1, timeout / 4)))
        repeat {
            if let control = resolvedVisibleControl() {
                return control
            }
            guard settingsForm.exists, !settingsForm.frame.isEmpty else {
                break
            }

            let existingControl = firstExistingControl()
            let direction = existingControl.flatMap { settingsScrollDirection(toward: $0) } ?? .higherRows
            let previousFrame = existingControl?.frame
            scrollSettingsForm(toward: direction)
            if let control = waitForControlAfterScroll(previousFrame: previousFrame) {
                return control
            }
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
     Reveals one Settings navigation row through the production app-owned Settings search field.

     This is a fallback for hosted simulator runs where repeated form swipes do not expose a lower
     Settings row before the XCTest timeout. It activates Android's real search action when needed,
     then narrows the app-owned activity; callers still tap the same production preference row.
     *
     * - Parameters:
     *   - title: Visible English title used as the search query.
     *   - settingsForm: The live Settings form element.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend revealing and applying Settings search.
     *   - resolveControl: Existing row resolver scoped to the live Settings hierarchy.
     * - Returns: The resolved native row element, or `nil` when Settings search cannot reveal it.
     * - Side effects:
     *   - expands the app-owned Android Settings search row when it is collapsed
     *   - types the visible row title into that production search field
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
        if settingsSearchFieldCandidates(in: app, settingsForm: settingsForm).allSatisfy({ !$0.exists }) {
            let searchButtonCandidates = [
                settingsForm.buttons["settingsSearchButton"].firstMatch,
                settingsForm.otherElements["settingsSearchButton"].firstMatch,
                app.buttons["settingsSearchButton"].firstMatch,
                app.otherElements["settingsSearchButton"].firstMatch,
            ]
            if let searchButton = searchButtonCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                tapElementReliably(searchButton, timeout: min(3, timeout))
            }
        }
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

        replaceText(in: searchField, with: title, placeholderHints: ["Find", "Search"])

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
     Returns Settings search-field candidates exposed by the app-owned Android search row.

     Stable production identifiers come first. Type-only fallbacks remain for accessibility
     flattening, and localized prompt fallbacks preserve coverage across translated builds without
     mistaking unrelated preference editors for the Settings search control.

     * - Parameters:
     *   - app: Running application under test.
     *   - settingsForm: The live Settings form element.
     * - Returns: Search and text-field candidates ordered from form-scoped to broader app queries.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func settingsSearchFieldCandidates(in app: XCUIApplication, settingsForm: XCUIElement) -> [XCUIElement] {
        [
            settingsForm.textFields["settingsSearchField"].firstMatch,
            settingsForm.searchFields["settingsSearchField"].firstMatch,
            app.textFields["settingsSearchField"].firstMatch,
            app.searchFields["settingsSearchField"].firstMatch,
            settingsForm.searchFields.firstMatch,
            app.navigationBars.searchFields.firstMatch,
            app.searchFields.firstMatch,
            settingsForm.searchFields["Find"].firstMatch,
            settingsForm.textFields["Find"].firstMatch,
            app.navigationBars.searchFields["Find"].firstMatch,
            app.navigationBars.textFields["Find"].firstMatch,
            app.searchFields["Find"].firstMatch,
            app.textFields["Find"].firstMatch,
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
        case "settingsAISettingsLink":
            "AI Settings"
        case "settingsReadingProgressLink":
            "Reading Progress Settings"
        case "settingsLabelsLink":
            "Labels"
        case "discreteHelpButton":
            "Read this first!"
        case "discreteModeToggle":
            "Hide religious symbols"
        case "showCalculatorToggle":
            "Calculator"
        case "calculatorPinRow":
            "Calculator PIN"
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
