import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func requireButton(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireElement(
            identifier,
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Polls one accessibility-identified element until its value matches the expected semantic token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier whose resolved element value should be sampled.
     *   - expectedValue: Semantic value expected before the timeout expires.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - samples the live accessibility value through the shared semantic-state waiter
     *   - records an XCTest failure when the value never reaches the expected state before timeout
     * - Failure modes:
     *   - fails when the element disappears or its accessibility value never reaches the requested
     *     token within the timeout window
     */
    func waitForElementValue(
        _ identifier: String,
        toEqual expectedValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: identifier,
            timeout: timeout,
            valueProvider: { self.resolvedElementSemanticText(identifier, in: app) },
            success: { $0 == expectedValue },
            failureDescription: { finalValue in
                "Expected element '\(identifier)' to reach value '\(expectedValue)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element value to contain a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - expectedToken: Token that should appear inside the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - samples the live accessibility value through the shared semantic-state waiter
     * - Failure modes:
     *   - fails when the element disappears or never reports the requested token before timeout
     */
    func waitForElementValue(
        _ identifier: String,
        toContain expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: identifier,
            timeout: timeout,
            valueProvider: { self.resolvedElementSemanticText(identifier, in: app) },
            success: { $0.contains(expectedToken) },
            failureDescription: { finalValue in
                "Expected element '\(identifier)' to contain token '\(expectedToken)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element value to stop containing a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - unexpectedToken: Token that should disappear from the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - samples the live accessibility value through the shared semantic-state waiter
     * - Failure modes:
     *   - fails when the element disappears or keeps reporting the token after the timeout
     */
    func waitForElementValue(
        _ identifier: String,
        toNotContain unexpectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitForResolvedSemanticState(
            named: identifier,
            timeout: timeout,
            valueProvider: { self.resolvedElementSemanticText(identifier, in: app) },
            success: { !$0.contains(unexpectedToken) },
            missingCountsAsSuccess: true,
            failureDescription: { finalValue in
                "Expected element '\(identifier)' to stop containing '\(unexpectedToken)' within \(timeout) seconds. Final value: '\(finalValue)'."
            },
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element to reach the requested existence state.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to re-resolve while polling.
     *   - app: Running application under test.
     *   - shouldExist: Requested final existence state.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - observes the live XCUI hierarchy with an XCTest predicate until the requested element
     *     exists or disappears
     *   - keeps reader tab-bar controls scoped to `windowTabBar` so negative waits do not snapshot
     *     the full reader hierarchy
     * - Failure modes:
     *   - records an XCTest failure when the element never reaches the requested existence state
     */
    func waitForElementExistence(
        _ identifier: String,
        in app: XCUIApplication,
        shouldExist: Bool,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolveElement: () -> XCUIElement? = {
            if self.isWindowTabBarButtonIdentifier(identifier) {
                return self.resolvedWindowTabBarButton(identifier, in: app)
            }
            return self.resolvedElement(identifier, in: app)
        }
        let predicate = NSPredicate { _, _ in
            (resolveElement() != nil) == shouldExist
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription =
            "Wait for element '\(identifier)' existence to become \(shouldExist)"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result == .completed {
            return
        }

        let currentExists = resolveElement() != nil
        XCTAssertEqual(
            currentExists,
            shouldExist,
            "Expected element '\(identifier)' existence to become \(shouldExist) within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element to appear without recording an XCTest failure.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve while polling.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before giving up.
     * - Returns: `true` when the element appears before the timeout, otherwise `false`.
     * - Side effects:
     *   - observes the live XCUI hierarchy with an XCTest predicate without triggering
     *     `waitForExistence` debug capture when the element is legitimately absent
     * - Failure modes: This helper cannot fail.
     */
    func waitForResolvedElementAppearance(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 1
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            self.resolvedElement(identifier, in: app) != nil
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for resolved element '\(identifier)' appearance"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed || resolvedElement(identifier, in: app) != nil
    }


    /**
     Waits for the reader shell's overflow-menu button, allowing extra time for the first cold app
     launch in the UI bundle.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the reader shell to become interactive.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The reader overflow-menu button once the reader shell has rendered it.
     * - Side effects:
     *   - repeatedly queries the live XCUI hierarchy while the reader shell finishes bootstrapping
     * - Failure modes:
     *   - records an XCTest failure if the reader shell never reaches a state where the overflow
     *     menu button exists within the allotted timeout
     */
    func requireReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireButton(
            "readerMoreMenuButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Taps the reader overflow-menu button after the reader shell becomes interactive.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the toolbar button to exist and become
     *     hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the overflow-menu button from the live toolbar hierarchy
     *   - taps its center point directly through the shared reliable-tap helper
     * - Failure modes:
     *   - records an XCTest failure if the overflow-menu button never becomes usable within the
     *     allotted timeout
     */
    func tapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tryTapReaderMoreMenuButton(in: app, timeout: timeout, file: file, line: line) {
            return
        }

        XCTFail(
            "Expected the reader overflow menu to appear after tapping readerMoreMenuButton within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Opens the overflow menu with one activation of its actual production control.

     Waits passively for a hittable button and the visible menu. Returns false on timeout; it does
     not repeat an activation or substitute a guessed header coordinate. An already visible menu
     needs no additional action. File/line are retained for callers that share this helper signature.
     */
    func tryTapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if waitForReaderOverflowMenu(in: app, timeout: 0) { return true }
        let button = app.buttons["readerMoreMenuButton"].firstMatch
        guard waitForElementToBecomeHittable(button, timeout: timeout) else { return false }
        button.tap()
        return waitForReaderOverflowMenu(in: app, timeout: timeout)
    }

    /**
     Dismisses a visible overflow menu through one tap on its production backdrop.

     The sampled backdrop point avoids the menu panel. A dropped interaction fails the passive
     wait; no second tap, toolbar toggle or dragging gesture conceals the failure. If the menu is
     already absent, this is a no-op. Records a failure when the backdrop or dismissal is missing.
     */
    func dismissReaderOverflowMenu(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard waitForReaderOverflowMenu(in: app, timeout: 0) else { return }
        let dismissArea = unresolvedElement("readerOverflowMenuDismissArea", in: app)
        guard waitForUITestCondition("Wait for overflow backdrop", timeout: timeout, condition: {
            self.elementHasUsableFrame(dismissArea) && app.frame.intersects(dismissArea.frame)
        }) else {
            XCTFail("Expected the overflow dismiss backdrop", file: file, line: line)
            return
        }
        dismissArea.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2)).tap()
        XCTAssertTrue(waitForUITestCondition("Wait for overflow dismissal", timeout: timeout) {
            !self.waitForReaderOverflowMenu(in: app, timeout: 0)
        }, "Expected one backdrop tap to dismiss the overflow menu", file: file, line: line)
    }

    /**
     Passively observes visible production overflow controls within the app viewport.

     Native model exports cannot satisfy this boundary. Returns false when no actual menu surface
     or overflow-only action has usable on-screen geometry before timeout; it performs no actions.
     */
    func waitForReaderOverflowMenu(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitForUITestCondition("Wait for visible reader overflow", timeout: timeout) {
            let candidates = [
                app.otherElements["readerOverflowMenu"].firstMatch,
                app.scrollViews["readerOverflowMenu"].firstMatch,
                app.buttons["readerOverflowNightModeToggle"].firstMatch,
            ]
            return candidates.contains { self.elementHasUsableFrame($0) && app.frame.intersects($0.frame) }
        }
    }

    /**
     Taps the Android-style reader navigation drawer button and waits for the drawer to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the drawer to appear.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the production reader navigation-drawer chrome control
     *   - waits for the `readerNavigationDrawer` surface
     * - Failure modes:
     *   - records an XCTest failure if the drawer never appears in time
     */
    func tapReaderNavigationDrawerButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tryTapReaderNavigationDrawerButton(in: app, timeout: timeout, file: file, line: line) {
            return
        }

        XCTFail(
            "Expected the reader navigation drawer to appear after tapping readerNavigationDrawerButton within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Opens the navigation drawer with one activation of its actual production button.

     Waits passively for a hittable button and visible drawer. Returns false on timeout without
     repeating the action. An already visible drawer is retained. File/line are accepted for caller
     compatibility and do not change the interaction.
     */
    func tryTapReaderNavigationDrawerButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        if waitForReaderNavigationDrawer(in: app, timeout: 0) { return true }
        let button = app.buttons["readerNavigationDrawerButton"].firstMatch
        guard waitForElementToBecomeHittable(button, timeout: timeout) else { return false }
        button.tap()
        return waitForReaderNavigationDrawer(in: app, timeout: timeout)
    }

    /**
     Passively observes the actual drawer surface in the visible app viewport.

     This observation never opens or repairs the drawer and does not accept a hidden model flag.
     Returns false if usable drawer geometry does not appear within the requested timeout.
     */
    func waitForReaderNavigationDrawer(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitForUITestCondition("Wait for visible reader drawer", timeout: timeout) {
            let candidates = [
                app.otherElements["readerNavigationDrawer"].firstMatch,
                app.scrollViews["readerNavigationDrawer"].firstMatch,
            ]
            return candidates.contains { self.elementHasUsableFrame($0) && app.frame.intersects($0.frame) }
        }
    }

    /**
     Resolves one reader action on its production menu and activates it once.

     Menu opening and scrolling reveal prerequisites; the requested action is never retried.
     The caller must observe its specific destination or outcome. Failure to resolve a hittable
     control fails here, rather than tapping other coordinates until native state reports success.
     */
    func tapReaderAction(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let button = tryResolveReaderActionControl(identifier, in: app, timeout: timeout),
              waitForElementToBecomeHittable(button, timeout: timeout) else {
            XCTFail("Expected a hittable reader action '\(identifier)'", file: file, line: line)
            return
        }
        button.tap()
    }



    /**
     Opens About through one menu action and passively observes the destination.

     Records a failure if the production menu action cannot be activated or About never appears.
     The source action is not repeated when its first activation is dropped.
     */
    func openAboutFromReaderMenu(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapReaderAction("readerOpenAboutAction", in: app, timeout: timeout, file: file, line: line)
        XCTAssertTrue(waitForAboutScreenVisible(in: app, timeout: timeout, file: file, line: line),
                      "Expected About after one menu action", file: file, line: line)
    }

    /**
     Confirms the About destination rendered after reader-menu navigation.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the About destination to surface.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls explicit About-only accessibility identifiers so the waiter does not rely on broad
     *     hierarchy scans or generic localized button titles during sheet transitions
     * - Failure modes:
     *   - records an XCTest failure if none of the About-specific surface identifiers appears
     *     within the allotted timeout
     */
    func waitForAboutScreenVisible(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        waitForAnyElement(
            ["aboutDoneButton", "aboutAppTitle", "aboutScreen", "aboutSheetScreen"],
            in: app,
            timeout: timeout,
            file: file,
            line: line
        ) != nil
    }

    /**
     Maps one reader overflow action identifier to the visible English menu title exported by the
     production `Menu` rows.
     *
     * - Parameter identifier: Stable accessibility identifier attached in `BibleReaderView`.
     * - Returns: User-visible menu title that XCTest can use as a fallback query surface.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func readerActionTitle(for identifier: String) -> String {
        switch identifier {
        case "readerChooseDocumentAction":
            return "Choose Document"
        case "readerOpenSearchAction":
            return "Search"
        case "readerOpenSpeakAction":
            return "Speak"
        case "readerOpenBookmarksAction":
            return "Bookmarks"
        case "readerOpenStudyPadsAction":
            return "Study Pads"
        case "readerOpenMyNotesAction":
            return "My Notes"
        case "readerOpenHistoryAction":
            return "History"
        case "readerOpenReadingPlansAction":
            return "Reading Plan"
        case "readerOpenSettingsAction":
            return "Application preferences"
        case "readerOpenTextOptionsAction":
            return "All text options…"
        case "readerOpenWorkspacesAction":
            return "Workspaces…"
        case "readerOpenDownloadsAction":
            return "Download Documents"
        case "readerOpenImportExportAction":
            return "Backup & Restore"
        case "readerOpenSyncSettingsAction":
            return "Device synchronization"
        case "readerOpenAISettingsAction":
            return "AI Settings"
        case "readerOpenLabelSettingsAction":
            return "Label settings…"
        case "readerOpenHelpAction":
            return "Help & tips"
        case "readerNeedHelpAction":
            return "Need Help"
        case "readerContributeAction":
            return "How to Contribute"
        case "readerOpenAboutAction":
            return "About"
        case "readerOpenAppLicenseAction":
            return "App Licence"
        case "readerTellFriendAction":
            return "Recommend to a friend"
        case "readerRateAppAction":
            return "Rate & Review"
        case "readerReportBugAction":
            return "Feedback / bug report"
        default:
            return identifier
        }
    }

    /// Returns direct app-level candidates for reader drawer and overflow actions.
    func readerDirectActionCandidates(
        _ identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let title = readerActionTitle(for: identifier)
        return [
            app.buttons[identifier].firstMatch,
            app.buttons[title].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
    }

    /**
     Declares which production reader action surface should host one action identifier.
     *
     * - Parameter identifier: Stable accessibility identifier attached in `BibleReaderView`.
     * - Returns: `true` when the action belongs to the left navigation drawer; otherwise `false`
     *   and the action belongs to the overflow/options menu.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func readerActionUsesNavigationDrawer(_ identifier: String) -> Bool {
        switch identifier {
        case "readerOpenBookmarksAction",
             "readerOpenHistoryAction",
             "readerOpenReadingPlansAction",
             "readerOpenReadingProgressAction",
             "readerOpenDownloadsAction",
             "readerOpenSettingsAction",
             "readerOpenAboutAction",
             "readerChooseDocumentAction",
             "readerOpenSearchAction",
             "readerOpenSpeakAction",
             "readerOpenStudyPadsAction",
             "readerOpenMyNotesAction",
             "readerOpenImportExportAction",
             "readerOpenSyncSettingsAction",
             "readerOpenAISettingsAction",
             "readerOpenHelpAction",
             "readerNeedHelpAction",
             "readerContributeAction",
             "readerOpenAppLicenseAction",
             "readerTellFriendAction",
             "readerRateAppAction",
             "readerReportBugAction":
            return true
        default:
            return false
        }
    }

    /**
     Ensures the policy-selected drawer or overflow surface is visible once.

     A visible opposite surface is dismissed once before the requested surface is opened once.
     Returns nil on any missing transition; callers must not loop over this helper to retry menu
     opening. Existing menu state is observed from production controls, not diagnostic exports.
     */
    func ensureReaderActionSurface(
        for identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)
        if prefersDrawer {
            if waitForReaderNavigationDrawer(in: app, timeout: 0) {
                return unresolvedElement("readerNavigationDrawer", in: app)
            }
            if waitForReaderOverflowMenu(in: app, timeout: 0) {
                dismissReaderOverflowMenu(in: app, timeout: timeout, file: file, line: line)
                guard !waitForReaderOverflowMenu(in: app, timeout: 0) else { return nil }
            }
            guard tryTapReaderNavigationDrawerButton(in: app, timeout: timeout) else { return nil }
            return unresolvedElement("readerNavigationDrawer", in: app)
        }
        if waitForReaderOverflowMenu(in: app, timeout: 0) {
            return unresolvedElement("readerOverflowMenu", in: app)
        }
        if waitForReaderNavigationDrawer(in: app, timeout: 0) {
            let dismissArea = unresolvedElement("readerNavigationDrawerDismissArea", in: app)
            guard waitForElementToBecomeHittable(dismissArea, timeout: timeout) else { return nil }
            dismissArea.tap()
            guard waitForUITestCondition("Wait for drawer dismissal", timeout: timeout, condition: {
                !self.waitForReaderNavigationDrawer(in: app, timeout: 0)
            }) else { return nil }
        }
        guard tryTapReaderMoreMenuButton(in: app, timeout: timeout) else { return nil }
        return unresolvedElement("readerOverflowMenu", in: app)
    }





    /**
     Returns whether an identifier is one of the compact semantic state exports emitted for UI tests.
     *
     * - Parameter identifier: Accessibility identifier that may name a state export probe.
     * - Returns: `true` when the identifier is backed by a tiny state-export element.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    func isSemanticStateExportIdentifier(_ identifier: String) -> Bool {
        switch identifier {
        case
            "searchStateExport",
            "bookmarkListStateExport",
            "readingPlanListStateExport",
            "availablePlansStateExport",
            "labelManagerStateExport",
            "myDocumentsListStateExport",
            "myDocumentPagesStateExport",
            "syncSettingsState":
            return true
        default:
            return false
        }
    }

    /**
     Samples the value from compact state-export probes without first asking XCTest for existence.
     *
     * XCTest can spend tens of seconds rebuilding snapshots for volatile SwiftUI surfaces when a test
     * repeatedly calls `exists` before reading a known state probe. Direct `.value` reads can also
     * record hard failures when a SwiftUI sheet disappears during polling, so this helper takes one
     * throwing snapshot per candidate and treats absence as "not observable yet".
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of a compact state-export probe.
     *   - app: Running application under test.
     * - Returns: First non-empty exported value from the ordered semantic state candidates.
     * - Side effects: none.
     * - Failure modes: returns `nil` when no state probe currently publishes a value.
     */
    func semanticStateExportValue(
        _ identifier: String,
        in app: XCUIApplication
    ) -> String? {
        for candidate in semanticStateValueCandidates(for: identifier, in: app) {
            if let value = semanticStateSnapshotValue(candidate),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    /**
     Reads one semantic state export from a single XCTest snapshot.

     - Parameter element: Candidate state-export element whose `accessibilityValue` carries the
       compact UI-test state contract.
     - Returns: Non-empty accessibility value when the candidate is currently snapshottable.
     - Side effects: none.
     - Failure modes: returns `nil` when XCTest cannot snapshot the candidate during a SwiftUI
       transition instead of recording a hard query failure.
     */
    private func semanticStateSnapshotValue(_ element: XCUIElement) -> String? {
        guard let snapshot = try? element.snapshot(),
              let value = snapshot.value as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /**
     Returns semantic accessibility text from one immutable exact-identifier snapshot.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier under test.
     *   - app: Running application whose live hierarchy should be sampled.
     * - Returns: The exported accessibility value when present, otherwise a conservative label
     *   fallback for simple text-bearing controls. Compact state exports retain their dedicated
     *   snapshot path.
     * - Side effects: Requests one exact-identifier XCTest snapshot for ordinary elements.
     * - Failure modes: returns `nil` when the element is absent, changes during the snapshot, or
     *   has no safe semantic text. Snapshot absence does not record a hard query failure.
     */
    func resolvedElementSemanticText(
        _ identifier: String,
        in app: XCUIApplication
    ) -> String? {
        if isSemanticStateExportIdentifier(identifier),
           let value = semanticStateExportValue(identifier, in: app)
        {
            return value
        }

        if identifier == "readerRenderedContentState" {
            return readerRenderedContentStateValue(in: app)
        }

        let element = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
        guard let snapshot = try? element.snapshot() else {
            return nil
        }

        if let value = snapshot.value as? String {
            return value
        }

        switch snapshot.elementType {
        case .staticText, .button, .link:
            return snapshot.label
        default:
            return nil
        }
    }

    /**
     Resolves one reader overflow action from either its stable accessibility identifier or its
     visible menu title.
     *
     * - Parameters:
     *   - identifier: Stable accessibility identifier attached in `BibleReaderView`.
     *   - app: Running application under test.
     * - Returns: Best-effort live XCUI element for the action.
     * - Side effects: none.
     * - Failure modes: returns a non-existing identifier-backed element when no live match exists.
     */
    func resolveReaderActionElement(
        _ identifier: String,
        in app: XCUIApplication,
        actionSurface: XCUIElement
    ) -> XCUIElement {
        let title = readerActionTitle(for: identifier)
        let scopedCandidates = [
            actionSurface.buttons[identifier].firstMatch,
            actionSurface.buttons[title].firstMatch,
            actionSurface.otherElements[identifier].firstMatch,
        ]

        if let visibleCandidate = scopedCandidates.first(where: { isElementHittable($0) }) {
            return visibleCandidate
        }
        if let frameCandidate = scopedCandidates.first(where: { elementHasUsableFrame($0) }) {
            return frameCandidate
        }
        return scopedCandidates.first(where: { $0.exists }) ?? actionSurface.buttons[identifier].firstMatch
    }

    /**
     Resolves one reader-shell menu action, scrolling the live menu surface when the requested
     action starts below the fold.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the reader action to resolve.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to keep searching and scrolling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved reader action button.
     * - Side effects:
     *   - re-queries the live accessibility hierarchy while swiping the visible menu container
     *     upward to reveal actions lower in the overflow menu
     * - Failure modes:
     *   - records an XCTest failure when the requested action never appears before the timeout
     */
    func requireReaderActionControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if let control = tryResolveReaderActionControl(identifier, in: app, timeout: timeout) {
            return control
        }

        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)
        let directActionCandidates = readerDirectActionCandidates(identifier, in: app)

        if let finalSurface = prefersDrawer
            ? resolvedElement("readerNavigationDrawer", in: app)
            : resolvedElement("readerOverflowMenu", in: app)
        {
            let finalAction = resolveReaderActionElement(identifier, in: app, actionSurface: finalSurface)
            XCTAssertTrue(
                finalAction.exists,
                "Expected reader action '\(identifier)' to exist within \(timeout) seconds.",
                file: file,
                line: line
            )
            return finalAction
        }

        if let directAction = directActionCandidates.first(where: { elementHasUsableFrame($0) }) {
            return directAction
        }

        let preferredSurfaceIdentifier = prefersDrawer ? "readerNavigationDrawer" : "readerOverflowMenu"
        let actionSurface = resolvedElement(preferredSurfaceIdentifier, in: app)
            ?? unresolvedElement(preferredSurfaceIdentifier, in: app)
        XCTAssertTrue(
            actionSurface.exists,
            "Expected the reader action surface to appear within \(timeout) seconds before resolving '\(identifier)'.",
            file: file,
            line: line
        )
        return resolveReaderActionElement(identifier, in: app, actionSurface: actionSurface)
    }

    /**
     Finds a menu action after one menu-opening sequence, scrolling only to reveal it.

     At most four upward swipes search a long menu. These are prerequisite reveal gestures;
     the requested action is never activated here and the menu is never reopened on failure.
     Returns nil if the live control cannot become hittable within the timeout.
     */
    func tryResolveReaderActionControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        guard let surface = ensureReaderActionSurface(for: identifier, in: app, timeout: timeout) else {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        let directCandidates = readerDirectActionCandidates(identifier, in: app)
        for scrollCount in 0...4 {
            // Popup identity markers are accessibility siblings of their visible rows, so an
            // exact app-level action query is the authoritative lookup for those surfaces.
            if let directAction = directCandidates.first(where: { isElementHittable($0) }) {
                return directAction
            }

            let action = resolveReaderActionElement(identifier, in: app, actionSurface: surface)
            if waitForElementToBecomeHittable(action, timeout: min(1, max(0, deadline.timeIntervalSinceNow))) {
                return action
            }
            guard scrollCount < 4, Date() < deadline, elementHasUsableFrame(surface) else { return nil }
            surface.swipeUp()
        }
        return nil
    }

}
